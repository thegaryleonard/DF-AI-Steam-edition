// Strange moods: help a moody dwarf get the items its artifact needs.
//
// A dwarf in a strange mood claims a workshop, then waits for specific items
// (job->job_items). Moody dwarves don't eat or drink, so if an item is never
// found they die (Searabbeys lost a possessed miner to thirst). DF only looks
// at usable items, so release matching items that are forbidden or marked for
// dumping, and log clearly when the fort has nothing that fits.

#include "ai.h"
#include "population.h"
#include "room.h"
#include "plan.h"
#include "df/buildings_other_id.h"
#include "df/workshop_type.h"
#include "df/building_workshopst.h"

#include "modules/Items.h"
#include "modules/Job.h"
#include "modules/Materials.h"
#include "modules/Units.h"

#include "df/item.h"
#include "df/items_other_id.h"
#include "df/building.h"
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

// The workshop each strange mood claims (Brooding/Fell take any workshop;
// the glassmaker needs a glass furnace, which df-ai plans as a furnace).
static df::workshop_type mood_workshop(df::job_type t)
{
    switch (t)
    {
    case job_type::StrangeMoodCrafter: return workshop_type::Craftsdwarfs;
    case job_type::StrangeMoodJeweller: return workshop_type::Jewelers;
    case job_type::StrangeMoodForge: return workshop_type::MetalsmithsForge;
    case job_type::StrangeMoodMagmaForge: return workshop_type::MagmaForge;
    case job_type::StrangeMoodCarpenter: return workshop_type::Carpenters;
    case job_type::StrangeMoodMason: return workshop_type::Masons;
    case job_type::StrangeMoodBowyer: return workshop_type::Bowyers;
    case job_type::StrangeMoodTanner: return workshop_type::Leatherworks;
    case job_type::StrangeMoodWeaver: return workshop_type::Loom;
    case job_type::StrangeMoodMechanics: return workshop_type::Mechanics;
    default: return workshop_type::Custom;   // none needed / not handled
    }
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

        // No workshop claimed yet: the fort may not have the kind this mood
        // needs (a possessed weaver and no loom). Build the planned one now.
        df::workshop_type need_ws = mood_workshop(job->job_type);
        if (!Job::getHolder(job) && need_ws != workshop_type::Custom)
        {
            bool have = false;
            for (auto b : world->buildings.other[buildings_other_id::WORKSHOP_ANY])
            {
                auto ws = virtual_cast<df::building_workshopst>(b);
                if (ws && ws->type == need_ws && ws->getBuildStage() == ws->getMaxBuildStage())
                {
                    have = true;
                    break;
                }
            }
            // already being dug or built for this mood (or anything else)?
            if (!have && ai.find_room(room_type::workshop, [need_ws](room *r) -> bool { return r->workshop_type == need_ws && r->status != room_status::plan; }))
            {
                have = true;
            }
            if (!have)
            {
                room *r = ai.find_room(room_type::workshop, [need_ws](room *r) -> bool { return r->workshop_type == need_ws && r->status == room_status::plan; });
                if (r && ai.plan.digroom(out, r, true))
                {
                    ai.debug(out, "[MOOD] " + AI::describe_unit(u) + " needs a " + enum_item_key(need_ws) + " workshop; building one now");
                }
                else if (!r && mood_warned.insert(AI::describe_unit(u) + "|ws").second)
                {
                    ai.debug(out, "[MOOD] " + AI::describe_unit(u) + " needs a " + enum_item_key(need_ws) + " workshop, and none is planned or being built");
                }
            }
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
                // isSuitableItem only checks the job item's flags, not its type
                if ((ji->item_type != item_type::NONE && itype != ji->item_type) ||
                    (ji->item_subtype != -1 && item->getSubtype() != ji->item_subtype) ||
                    !Job::isSuitableItem(ji, itype, item->getSubtype()) ||
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
            if (!usable)
            {
                // Last resort: supplies a location holds (hospital cloth,
                // thread, splints in the hospital chest) are flagged foreign
                // and invisible to the mood. A dying dwarf beats a full chest.
                int32_t need = ji->quantity - have, got = 0;
                for (auto item : world->items.other[items_other_id::IN_PLAY])
                {
                    if (got >= need)
                    {
                        break;
                    }
                    df::item_type itype = item->getType();
                    auto & f = item->flags.bits;
                    if (!f.foreign || f.trader || f.in_job || f.owned || f.artifact || f.removed || f.garbage_collect)
                    {
                        continue;
                    }
                    if ((ji->item_type != item_type::NONE && itype != ji->item_type) ||
                        (ji->item_subtype != -1 && item->getSubtype() != ji->item_subtype) ||
                        !Job::isSuitableItem(ji, itype, item->getSubtype()) ||
                        !Job::isSuitableMaterial(ji, item->getMaterial(), item->getMaterialIndex(), itype))
                    {
                        continue;
                    }
                    df::building *holder = Items::getHolderBuilding(item);
                    if (!holder || holder->getType() != building_type::Box)
                    {
                        continue;
                    }
                    df::coord pos = Items::getPosition(item);
                    if (!Items::moveToGround(item, pos))
                    {
                        continue;
                    }
                    f.foreign = false;
                    got += ji->quantity > 100 ? item->getTotalDimension() : item->getStackSize();
                    usable++;
                }
                if (got)
                {
                    ai.debug(out, stl_sprintf("[MOOD] took %s from a location chest for %s", describe_job_item(ji).c_str(), who.c_str()));
                }
            }
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
