// Strange moods: help a moody dwarf get the items its artifact needs.
//
// A dwarf in a strange mood claims a workshop, then waits for specific items
// (job->job_items). Moody dwarves don't eat or drink, so if an item is never
// found they die (Searabbeys lost a possessed miner to thirst). DF only looks
// at usable items, so release matching items that are forbidden or marked for
// dumping, and log clearly when the fort has nothing that fits.

#include "ai.h"
#include "population.h"

#include "modules/Items.h"
#include "modules/Job.h"
#include "modules/Materials.h"
#include "modules/Units.h"

#include "df/item.h"
#include "df/items_other_id.h"
#include "df/job.h"
#include "df/job_item.h"
#include "df/job_item_ref.h"
#include "df/job_type.h"
#include "df/job_type_class.h"
#include "df/mood_type.h"
#include "df/unit.h"
#include "df/world.h"

REQUIRE_GLOBAL(world);

static bool is_strange_mood(df::mood_type m)
{
    return m == mood_type::Fey || m == mood_type::Secretive || m == mood_type::Possessed ||
        m == mood_type::Macabre || m == mood_type::Fell;
}

static std::string describe_job_item(df::job_item *ji)
{
    std::string s = ENUM_KEY_STR(item_type, ji->item_type);
    if (ji->mat_type != -1)
    {
        MaterialInfo mat(ji->mat_type, ji->mat_index);
        s += " of " + mat.toString();
    }
    std::vector<std::string> flags;
    bitfield_to_string(&flags, ji->flags1);
    bitfield_to_string(&flags, ji->flags2);
    bitfield_to_string(&flags, ji->flags3);
    for (auto & f : flags)
    {
        s += " [" + f + "]";
    }
    if (ji->quantity > 1)
    {
        s += " x" + std::to_string(ji->quantity);
    }
    return s;
}

void Population::update_moods(color_ostream & out)
{
    for (auto u : world->units.active)
    {
        if (!Units::isCitizen(u) || !is_strange_mood(u->mood))
        {
            continue;
        }
        df::job *job = u->job.current_job;
        if (!job || ENUM_ATTR(job_type, type, job->job_type) != job_type_class::StrangeMood)
        {
            continue;
        }

        for (size_t idx = 0; idx < job->job_items.elements.size(); idx++)
        {
            df::job_item *ji = job->job_items.elements.at(idx);
            if (!ji)
            {
                continue;
            }

            // already collected?
            int32_t have = 0;
            for (auto ref : job->items)
            {
                if (ref && ref->job_item_idx == int32_t(idx) && ref->item)
                {
                    have += ref->item->getStackSize();
                }
            }
            if (have >= ji->quantity)
            {
                continue;
            }

            int32_t usable = 0, released = 0;
            for (auto item : world->items.other[items_other_id::IN_PLAY])
            {
                df::item_type itype = item->getType();
                if (!Job::isSuitableItem(ji, itype, item->getSubtype()) ||
                    !Job::isSuitableMaterial(ji, item->getMaterial(), item->getMaterialIndex(), itype))
                {
                    continue;
                }
                auto & f = item->flags.bits;
                if (f.in_job || f.owned || f.trader || f.foreign || f.artifact || f.removed ||
                    f.garbage_collect || f.on_fire || f.rotten || f.construction || f.spider_web || f.hidden)
                {
                    continue;
                }
                if (f.forbid || f.dump)
                {
                    f.forbid = false;
                    f.dump = false;
                    released++;
                }
                usable++;
            }

            std::string who = AI::describe_unit(u);
            if (released)
            {
                ai.debug(out, stl_sprintf("[MOOD] released %d forbidden/dumped item(s) for %s: %s", released, who.c_str(), describe_job_item(ji).c_str()));
            }
            if (!usable)
            {
                std::string key = who + "|" + std::to_string(idx);
                if (mood_warned.insert(key).second)
                {
                    ai.debug(out, "[MOOD] " + who + " needs " + describe_job_item(ji) + ", and the fortress has none. They will starve unless it is made or bought.");
                }
            }
        }
    }
}
