// Strange moods: help a moody dwarf get the items its artifact needs.
//
// A dwarf in a strange mood claims a workshop, then waits for specific items
// (job->job_items). Moody dwarves don't eat or drink, so if an item is never
// found they die (Searabbeys lost a possessed miner to thirst). DF only looks
// at usable items, so release matching items that are forbidden or marked for
// dumping, and log clearly when the fort has nothing that fits.

#include "ai.h"

#include <sstream>
#include <limits>
#include "population.h"
#include "stocks.h"
#include "room.h"
#include "plan.h"
#include "df/buildings_other_id.h"
#include "df/workshop_type.h"
#include "df/building_workshopst.h"

#include "modules/Buildings.h"
#include "modules/Maps.h"
#include "df/tile_designation.h"
#include "df/tile_occupancy.h"
#include "df/material.h"
#include "modules/Items.h"
#include "df/map_block.h"
#include "df/inorganic_raw.h"
#include "df/block_square_event_mineralst.h"
#include "df/manager_order_template.h"
#include "df/material_flags.h"
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

REQUIRE_GLOBAL(standing_orders_auto_collect_webs);
REQUIRE_GLOBAL(world);

// Job::isSuitableItem checks material flags (silk/plant/yarn) against the job
// item's own (blank) material and fails every cloth; isSuitableMaterial does
// not know the item type. Check the item type with the item's real material.
static bool mood_item_matches(df::job_item *ji, df::item *item)
{
    MaterialInfo minfo(item);
    if (!minfo.isValid())
        return false;
    // Moods want whole pieces: a cloth requirement has min_dimension 10000,
    // and leftover 2000-8000 scraps (dressings, hospital cloth) never count.
    // Counting them hid that the fort had no usable silk cloth at all
    // (Tobul, a fey miner, died of thirst with 7 silk scraps "available").
    if (ji->min_dimension > 0 && item->getTotalDimension() < ji->min_dimension)
        return false;
    // DFHack's ItemTypeInfo::matches only accepts plant/silk/yarn for THREAD,
    // so "silk cloth" / "plant cloth" never matched anything. Check those
    // material flags ourselves.
    auto itype = item->getType();
    if ((itype == item_type::CLOTH || itype == item_type::THREAD) &&
        (ji->flags2.bits.plant || ji->flags2.bits.silk || ji->flags2.bits.yarn))
    {
        if (ji->mat_type != -1 && (ji->mat_type != minfo.type || ji->mat_index != minfo.index))
            return false;
        if (!minfo.material)
            return false;
        auto & mf = minfo.material->flags;
        if (ji->flags2.bits.plant && !mf.is_set(material_flags::THREAD_PLANT))
            return false;
        if (ji->flags2.bits.silk && !mf.is_set(material_flags::SILK))
            return false;
        if (ji->flags2.bits.yarn && !mf.is_set(material_flags::YARN))
            return false;
        return true;
    }
    ItemTypeInfo iinfo(itype, item->getSubtype());
    return iinfo.isValid() && iinfo.matches(*ji, &minfo, false, itype);
}

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

// Put a workshop down right now on free floor near the moody dwarf. Digging
// the planned room took weeks: a possessed weaver died of thirst first.
df::building *place_workshop_near(df::coord origin, df::workshop_type type)
{
    auto free3x3 = [origin](df::coord c) -> bool
    {
        for (int16_t dx = -1; dx <= 1; dx++)
        {
            for (int16_t dy = -1; dy <= 1; dy++)
            {
                df::coord t = c + df::coord(dx, dy, 0);
                df::tiletype *tt = Maps::getTileType(t);
                if (!tt || ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) != tiletype_shape_basic::Floor)
                    return false;
                auto des = Maps::getTileDesignation(t);
                auto occ = Maps::getTileOccupancy(t);
                if (!des || !occ || des->bits.outside || des->bits.flow_size || occ->bits.building != tile_building_occ::None)
                    return false;
            }
        }
        return Maps::canWalkBetween(origin, c);
    };
    df::coord c = AI::spiral_search(origin, 30, 2, free3x3);
    if (!c.isValid())
        return nullptr;

    // any building material: blocks, then stone boulders, then logs
    df::item *mat = nullptr;
    for (auto id : {items_other_id::BLOCKS, items_other_id::BOULDER, items_other_id::WOOD})
    {
        for (auto item : world->items.other[id])
        {
            auto & f = item->flags.bits;
            if (f.forbid || f.dump || f.in_job || f.owned || f.trader || f.foreign || f.construction || f.in_building || f.removed || f.garbage_collect || f.hidden)
                continue;
            if (id == items_other_id::BOULDER)
            {
                MaterialInfo mi(item);
                if (!mi.isInorganic() || !mi.material->flags.is_set(material_flags::IS_STONE))
                    continue;
            }
            mat = item;
            break;
        }
        if (mat)
            break;
    }
    if (!mat)
        return nullptr;

    df::building *bld = Buildings::allocInstance(c - df::coord(1, 1, 0), building_type::Workshop, type);
    Buildings::setSize(bld, df::coord(3, 3, 1));
    std::vector<df::item *> items{mat};
    Buildings::constructWithItems(bld, items);
    return bld;
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
                if (df::building *bld = place_workshop_near(u->pos, need_ws))
                {
                    ai.debug(out, stl_sprintf("[MOOD] %s needs a %s workshop; placed one at (%d, %d, %d)", AI::describe_unit(u).c_str(), enum_item_key(need_ws).c_str(), bld->centerx, bld->centery, bld->z));
                }
                else if (mood_warned.insert(AI::describe_unit(u) + "|ws").second)
                {
                    ai.debug(out, "[MOOD] " + AI::describe_unit(u) + " needs a " + enum_item_key(need_ws) + " workshop, and there is no free floor or building material for one");
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
                    !mood_item_matches(ji, item))
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
                        !mood_item_matches(ji, item))
                    {
                        continue;
                    }
                    // in a location chest: take it out; loose (hospital cloth
                    // hauled to a stockpile keeps the flag): just claim it
                    df::building *holder = Items::getHolderBuilding(item);
                    if (holder && holder->getType() != building_type::Box)
                    {
                        continue;
                    }
                    if (holder)
                    {
                        df::coord pos = Items::getPosition(item);
                        if (!Items::moveToGround(item, pos))
                        {
                            continue;
                        }
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
            if (!usable && ji->item_type == item_type::CLOTH && (ji->flags2.bits.plant || ji->flags2.bits.silk || ji->flags2.bits.yarn) &&
                mood_warned.insert(who + "|cloth|" + std::to_string(idx)).second)
            {
                // Weave it: a moody butcher died of thirst needing silk and
                // plant cloth while 2000 silk threads sat in the stockpile
                // (nothing ever ordered weaving).
                auto flag = ji->flags2.bits.plant ? material_flags::THREAD_PLANT : ji->flags2.bits.silk ? material_flags::SILK : material_flags::YARN;
                int32_t thread = 0;
                for (auto item : world->items.other[items_other_id::THREAD])
                {
                    auto & f = item->flags.bits;
                    if (f.forbid || f.in_job || f.dump || f.removed || f.trader || f.owned)
                        continue;
                    MaterialInfo mi(item);
                    if (mi.material && mi.material->flags.is_set(flag))
                        thread++;
                }
                std::ostringstream why;
                df::manager_order_template tmpl;
                if (thread > 0)
                {
                    tmpl.job_type = job_type::WeaveCloth;
                    if (ji->flags2.bits.plant)
                        tmpl.material_category.bits.plant = 1;
                    else if (ji->flags2.bits.silk)
                        tmpl.material_category.bits.silk = 1;
                    else
                        tmpl.material_category.bits.yarn = 1;
                    ai.stocks.add_manager_order(out, tmpl, 1, why);
                    ai.debug(out, "[MOOD] ordered " + describe_job_item(ji) + " woven for " + who + " (" + std::to_string(thread) + " thread available) " + why.str());
                }
                else if (ji->flags2.bits.plant)
                {
                    tmpl.job_type = job_type::ProcessPlants; // pig tails etc. into thread
                    ai.stocks.add_manager_order(out, tmpl, 2, why);
                    ai.debug(out, "[MOOD] no plant thread for " + who + ": ordered plant processing " + why.str());
                }
                else if (ji->flags2.bits.silk)
                {
                    *standing_orders_auto_collect_webs = 1;
                    ai.debug(out, "[MOOD] no silk for " + who + ": web collection turned on");
                }
            }
            if (!usable && ji->item_type == item_type::ROUGH && mood_warned.insert(who + "|rough|" + std::to_string(idx)).second)
            {
                // No rough gem anywhere: mine one. Look for a gem vein tile
                // next to a walkable tile the dwarf can reach, near its level.
                // Bounded (z +-12, a few thousand tiles) so it can't stall DF.
                df::coord best;
                int32_t best_d = std::numeric_limits<int32_t>::max();
                int32_t checked = 0;
                for (auto block : world->map.map_blocks)
                {
                    if (checked > 4000)
                        break;
                    if (std::abs(block->map_pos.z - u->pos.z) > 12)
                        continue;
                    for (auto ev : block->block_events)
                    {
                        auto min = virtual_cast<df::block_square_event_mineralst>(ev);
                        if (!min)
                            continue;
                        auto raw = df::inorganic_raw::find(min->inorganic_mat);
                        if (!raw || !raw->material.flags.is_set(material_flags::IS_GEM))
                            continue;
                        for (int16_t x = 0; x < 16; x++)
                        {
                            for (int16_t y = 0; y < 16; y++)
                            {
                                if (!min->getassignment(x, y))
                                    continue;
                                if (++checked > 4000)
                                    break;
                                df::coord t = block->map_pos + df::coord(x, y, 0);
                                df::tiletype *tt = Maps::getTileType(t);
                                if (!tt || ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) != tiletype_shape_basic::Wall)
                                    continue;
                                int32_t d = std::abs(t.x - u->pos.x) + std::abs(t.y - u->pos.y) + 4 * std::abs(t.z - u->pos.z);
                                if (d >= best_d)
                                    continue;
                                for (auto off : {df::coord(1, 0, 0), df::coord(-1, 0, 0), df::coord(0, 1, 0), df::coord(0, -1, 0)})
                                {
                                    df::coord n = t + off;
                                    if (Maps::isValidTilePos(n) && Maps::canWalkBetween(u->pos, n))
                                    {
                                        best = t;
                                        best_d = d;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
                if (best.isValid())
                {
                    AI::dig_tile(best, tile_dig_designation::Default);
                    ai.debug(out, stl_sprintf("[MOOD] no rough gems for %s: mining a gem vein at (%d, %d, %d)", who.c_str(), best.x, best.y, best.z));
                    usable++;
                }
                else
                {
                    ai.debug(out, "[MOOD] no rough gems for " + who + " and no reachable gem vein near the fort");
                }
            }
            if (!usable && ji->item_type == item_type::SMALLGEM)
            {
                // cut one from the rough gems the miners bring up; that needs
                // a Jeweler's workshop, which the plan may not have built yet
                // (a fey carpenter died of thirst next to 150 rough gems)
                bool have_jeweler = false;
                for (auto bld : world->buildings.other[buildings_other_id::WORKSHOP_JEWELER])
                {
                    if (bld->getBuildStage() == bld->getMaxBuildStage())
                        have_jeweler = true;
                }
                if (!have_jeweler && mood_warned.insert(who + "|jeweler").second)
                {
                    if (df::building *bld = place_workshop_near(u->pos, workshop_type::Jewelers))
                        ai.debug(out, stl_sprintf("[MOOD] no Jeweler's workshop for %s's gem: placed one (building %d)", who.c_str(), bld->id));
                }
                std::ostringstream why;
                ai.stocks.queue_use_gems(out, 1, why);
                ai.debug(out, "[MOOD] queued gem cutting for " + who + (why.str().empty() ? std::string() : " (" + why.str() + ")"));
                usable++;
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
