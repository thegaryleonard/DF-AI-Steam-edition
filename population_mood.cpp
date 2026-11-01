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
#include "df/creature_raw.h"
#include "df/reaction.h"
#include "df/reaction_product_itemst.h"
#include "df/reaction_reagent_itemst.h"
#include "df/item_barst.h"
#include "df/block_square_event_mineralst.h"
#include "df/manager_order_template.h"
#include "df/manager_order.h"
#include "df/material_flags.h"
#include "modules/Job.h"
#include "modules/Materials.h"
#include "modules/Units.h"

#include "df/item_body_component.h"
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
#include "df/building_actual.h"
#include "df/building_item_role_type.h"
#include "df/job_role_type.h"

#include "df/plotinfost.h"
REQUIRE_GLOBAL(standing_orders_auto_collect_webs);
REQUIRE_GLOBAL(world);
REQUIRE_GLOBAL(plotinfo);

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
    // isSuitableMaterial ignores the job item's mat_type: "BLOCKS of rock"
    // (mat_type 0) matched wooden blocks, so the rescue below picked them.
    if (ji->mat_type != -1 && minfo.type != ji->mat_type)
        return false;
    if (ji->mat_type != -1 && ji->mat_index != -1 && minfo.index != ji->mat_index)
        return false;
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

// thirst_timer at which a stalled mood gets its items carried in (dwarves
// die of thirst somewhere past ~75000 for a moody dwarf who won't drink)
static const int32_t MOOD_RESCUE_THIRST = 40000;
// thirst_timer past which a requirement the fort can't make in time is
// created outright (a small cheat the user approved over a dead dwarf)
static const int32_t MOOD_CHEAT_THIRST = 45000;

// A mood also ends in insanity when unit.job.mood_timeout (counts down
// while the dwarf has not started working) runs out, whatever the thirst:
// Rovod "Dangercopper" went melancholy at thirst 35000, before any
// thirst-based rescue fired. Treat a nearly expired timer like high thirst.
static bool mood_urgent(df::unit *u, int32_t thirst)
{
    if (u->counters2.thirst_timer > thirst)
        return true;
    int32_t left = u->job.mood_timeout;
    int32_t margin = thirst <= MOOD_RESCUE_THIRST ? 10000 : 6000;
    return u->counters2.thirst_timer > 15000 && left > 0 && left < margin;
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
                // count unfinished ones too: a workshop placed for this mood
                // stays unbuilt until someone brings the material, and treating
                // it as missing placed a new one every tick (12 jewelers' at once)
                if (ws && ws->type == need_ws)
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

        // Every item is in but the dwarf still hasn't started (seen after we
        // carried items in): start the work.
        if (Job::getHolder(job) && !job->flags.bits.working && mood_urgent(u, MOOD_RESCUE_THIRST))
        {
            bool complete = true;
            for (size_t idx = 0; idx < job->job_items.elements.size() && complete; idx++)
            {
                auto ji = job->job_items.elements.at(idx);
                int32_t have = 0;
                for (auto ref : job->items)
                {
                    if (ref && ref->job_item_idx == int32_t(idx) && ref->item)
                        have += ref->item->getStackSize();
                }
                if (ji && have < ji->quantity)
                    complete = false;
            }
            if (complete)
            {
                job->flags.bits.working = true;
                ai.debug(out, "[MOOD] " + AI::describe_unit(u) + " has every item but had not started; starting the work");
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
                // in_building: built into a workshop or depot. Counting those
                // as usable hid that the fort had no free rock blocks at all,
                // so the blocks handler never fired (a fey carpenter waited
                // past thirst 30000 for 2 BLOCKS while 6 sat in buildings).
                if (f.in_job || f.owned || f.trader || f.foreign || f.artifact || f.removed ||
                    f.garbage_collect || f.on_fire || f.rotten || f.construction || f.spider_web || f.hidden ||
                    f.in_building)
                {
                    continue;
                }
                // Items in a chest (the hospital's cloth, thread, splints)
                // are not fetched by the mood even when not flagged foreign:
                // Monom waited a month beside two whole yarn cloths there.
                if (auto hb = Items::getHolderBuilding(item))
                {
                    if (hb->getType() == building_type::Box)
                    {
                        continue;
                    }
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
                    if (f.trader || f.in_job || f.owned || f.artifact || f.removed || f.garbage_collect)
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
                    // hauled to a stockpile keeps the flag): just claim it.
                    // Chest items need not be flagged foreign to be hidden.
                    df::building *holder = Items::getHolderBuilding(item);
                    if (!f.foreign && !(holder && holder->getType() == building_type::Box))
                    {
                        continue;
                    }
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
            // Stalled: the items are free and reachable but the dwarf never
            // fetches them (a fey weaponsmith sat thirsty beside free plant
            // cloth and leather). Once thirst is high, carry one to the
            // workshop and attach it to the job ourselves.
            auto holder = virtual_cast<df::building_actual>(Job::getHolder(job));
            if (usable && holder && mood_urgent(u, MOOD_RESCUE_THIRST))
            {
                df::coord wpos(holder->centerx, holder->centery, holder->z);
                // Nothing reachable at all (Reg's mason mood: all 70 logs lay
                // where the workshop couldn't walk, so the log was "usable"
                // and no felling was ordered): past the cheat line, carry the
                // nearest unreachable one in anyway.
                df::item *far_item = nullptr;
                int32_t far_d = std::numeric_limits<int32_t>::max();
                bool attached = false;
                for (auto item : world->items.other[items_other_id::IN_PLAY])
                {
                    df::item_type itype = item->getType();
                    if ((ji->item_type != item_type::NONE && itype != ji->item_type) ||
                        (ji->item_subtype != -1 && item->getSubtype() != ji->item_subtype) ||
                        !mood_item_matches(ji, item))
                    {
                        continue;
                    }
                    auto & f = item->flags.bits;
                    // items in a bin count (in_inventory is set for them too:
                    // all 183 of Reg's cut gems sat in bins and were skipped);
                    // items a unit carries do not
                    if (f.in_job || f.owned || f.trader || f.foreign || f.artifact || f.removed || f.forbid || f.dump ||
                        f.garbage_collect || f.on_fire || f.rotten || f.construction || f.spider_web || f.hidden ||
                        (f.in_inventory && Items::getHolderUnit(item)) || f.in_building)
                    {
                        continue;
                    }
                    df::coord ipos = Items::getPosition(item);
                    if (!ipos.isValid())
                    {
                        continue;
                    }
                    if (!Maps::canWalkBetween(wpos, ipos))
                    {
                        int32_t d = std::abs(ipos.x - wpos.x) + std::abs(ipos.y - wpos.y) + 10 * std::abs(ipos.z - wpos.z);
                        if (d < far_d)
                        {
                            far_d = d;
                            far_item = item;
                        }
                        continue;
                    }
                    if (Items::moveToBuilding(item, holder, df::building_item_role_type::TEMP) &&
                        Job::attachJobItem(job, item, df::job_role_type::Reagent, int32_t(idx), -1))
                    {
                        ai.debug(out, stl_sprintf("[MOOD] %s was not fetching %s (thirst %d): carried %s to the workshop", who.c_str(), describe_job_item(ji).c_str(), u->counters2.thirst_timer, AI::describe_item(item).c_str()));
                        have = ji->quantity;
                        attached = true;
                        break;
                    }
                    // a failed move (item held by a building, container) must
                    // not end the search: Rakust waited on BLOCKS this way
                }
                if (!attached && far_item && mood_urgent(u, MOOD_CHEAT_THIRST) &&
                    Items::moveToBuilding(far_item, holder, df::building_item_role_type::TEMP) &&
                    Job::attachJobItem(job, far_item, df::job_role_type::Reagent, int32_t(idx), -1))
                {
                    ai.debug(out, stl_sprintf("[MOOD] CHEAT: no reachable %s for %s (thirst %d): moved unreachable %s to the workshop", describe_job_item(ji).c_str(), who.c_str(), u->counters2.thirst_timer, AI::describe_item(far_item).c_str()));
                    have = ji->quantity;
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
                int32_t thread = 0, webs = 0;
                for (auto item : world->items.other[items_other_id::THREAD])
                {
                    auto & f = item->flags.bits;
                    if (f.forbid || f.in_job || f.dump || f.removed || f.trader || f.owned)
                        continue;
                    MaterialInfo mi(item);
                    if (!mi.material || !mi.material->flags.is_set(flag))
                        continue;
                    // Webs still hanging in the caverns count as THREAD but
                    // nobody weaves them until collected: Rakust's silk weave
                    // order sat two months on 662 uncollected webs.
                    if (f.spider_web)
                        webs++;
                    else
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
                    usable++;
                }
                else if (ji->flags2.bits.plant)
                {
                    tmpl.job_type = job_type::ProcessPlants; // pig tails etc. into thread
                    ai.stocks.add_manager_order(out, tmpl, 2, why);
                    ai.debug(out, "[MOOD] no plant thread for " + who + ": ordered plant processing " + why.str());
                    usable++;
                }
                else if (ji->flags2.bits.silk)
                {
                    *standing_orders_auto_collect_webs = 1;
                    ai.debug(out, "[MOOD] no silk for " + who + ": web collection turned on (" + std::to_string(webs) + " webs to collect)");
                }
            }
            if (!usable && ji->item_type == item_type::CLOTH && (ji->flags2.bits.plant || ji->flags2.bits.silk || ji->flags2.bits.yarn) &&
                holder && mood_urgent(u, MOOD_CHEAT_THIRST))
            {
                // Last resort: Monom needed silk cloth with no silk thread in
                // the fort and 545 webs, none reachable. Rather than lose the
                // dwarf, create one whole piece at the workshop (a cheat).
                auto flag = ji->flags2.bits.plant ? material_flags::THREAD_PLANT : ji->flags2.bits.silk ? material_flags::SILK : material_flags::YARN;
                df::item *src = nullptr;
                for (auto item : world->items.other[items_other_id::THREAD])
                {
                    MaterialInfo mi(item);
                    if (mi.material && mi.material->flags.is_set(flag))
                    {
                        src = item;
                        break;
                    }
                }
                std::vector<df::item *> made;
                if (src && Items::createItem(made, u, item_type::CLOTH, -1, src->getMaterial(), src->getMaterialIndex()) && !made.empty())
                {
                    df::item *c = made[0];
                    if (Items::moveToBuilding(c, holder, df::building_item_role_type::TEMP) &&
                        Job::attachJobItem(job, c, df::job_role_type::Reagent, int32_t(idx), -1))
                    {
                        ai.debug(out, stl_sprintf("[MOOD] CHEAT: nothing could supply %s for %s (thirst %d): created %s at the workshop",
                            describe_job_item(ji).c_str(), who.c_str(), u->counters2.thirst_timer, AI::describe_item(c).c_str()));
                        usable++;
                    }
                }
            }
            if (!usable && ji->item_type == item_type::WOOD && mood_warned.insert(who + "|wood|" + std::to_string(idx)).second)
            {
                // No free logs at all (Unib's glassmaker mood sat at thirst
                // 48000 needing one log in a fort with zero logs): fell trees.
                std::ostringstream why;
                ai.stocks.cuttrees(out, 3, why);
                ai.debug(out, "[MOOD] no logs for " + who + ": marked trees for felling " + why.str());
            }
            if (!usable && ji->item_type == item_type::ROUGH && ji->mat_type >= 3 && ji->mat_type <= 5 &&
                mood_warned.insert(who + "|rawglass|" + std::to_string(idx)).second)
            {
                // Raw glass (green/clear/crystal), not a gem: mining gem veins
                // never supplies it. Order it made at a glass furnace.
                std::ostringstream why;
                df::manager_order_template tmpl;
                tmpl.job_type = job_type::MakeRawGlass;
                tmpl.mat_type = ji->mat_type;
                tmpl.mat_index = -1;
                ai.stocks.add_manager_order(out, tmpl, std::max<int32_t>(1, ji->quantity), why);
                ai.debug(out, "[MOOD] no raw glass for " + who + ": ordered " + describe_job_item(ji) + " " + why.str());
            }
            if (!usable && holder && mood_urgent(u, MOOD_CHEAT_THIRST) &&
                ((ji->item_type == item_type::ROUGH && ji->mat_type >= 3 && ji->mat_type <= 5) || ji->item_type == item_type::WOOD))
            {
                // Last resort (a cheat): create the raw glass / log at the
                // workshop rather than let the dwarf die of thirst.
                int16_t mt = ji->mat_type;
                int32_t mi = -1;
                if (ji->item_type == item_type::WOOD)
                {
                    for (auto plant : world->raws.plants.trees)
                    {
                        MaterialInfo wm;
                        if (wm.find("PLANT:" + plant->id + ":WOOD"))
                        {
                            mt = wm.type;
                            mi = wm.index;
                            break;
                        }
                    }
                }
                int32_t want = ji->item_type == item_type::ROUGH ? std::max<int32_t>(1, ji->quantity) : 1;
                for (int32_t n = 0; n < want && mt >= 0; n++)
                {
                    std::vector<df::item *> made;
                    if (!Items::createItem(made, u, ji->item_type, -1, mt, mi) || made.empty())
                        break;
                    df::item *c = made[0];
                    if (Items::moveToBuilding(c, holder, df::building_item_role_type::TEMP) &&
                        Job::attachJobItem(job, c, df::job_role_type::Reagent, int32_t(idx), -1))
                    {
                        ai.debug(out, stl_sprintf("[MOOD] CHEAT: nothing could supply %s for %s (thirst %d): created %s at the workshop",
                            describe_job_item(ji).c_str(), who.c_str(), u->counters2.thirst_timer, AI::describe_item(c).c_str()));
                        usable++;
                    }
                }
            }
            if (!usable && ji->item_type == item_type::ROUGH && !(ji->mat_type >= 3 && ji->mat_type <= 5) && mood_warned.insert(who + "|rough|" + std::to_string(idx)).second)
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
            if (!usable && ji->item_type == item_type::BLOCKS && (ji->mat_type == 0 || ji->mat_type == -1) &&
                mood_warned.insert(who + "|blocks|" + std::to_string(idx)).second)
            {
                // Rock blocks: the fort's free blocks were all built into
                // walls, and nothing ever ordered more (a fey broker sat at
                // thirst 62000 waiting for 2 BLOCKS beside 1900 boulders).
                // Order blocks cut at a mason's from the commonest free
                // non-economic stone (economic stone never starts a job).
                bool have_mason = false;
                for (auto bld : world->buildings.other[buildings_other_id::WORKSHOP_MASON])
                {
                    if (bld->getBuildStage() == bld->getMaxBuildStage())
                        have_mason = true;
                }
                if (!have_mason && mood_warned.insert(who + "|mason").second)
                {
                    if (df::building *bld = place_workshop_near(u->pos, workshop_type::Masons))
                        ai.debug(out, stl_sprintf("[MOOD] no Mason's workshop for %s's blocks: placed one (building %d)", who.c_str(), bld->id));
                }
                // Only boulders the moody dwarf can walk to: a pass that picked
                // microcline sitting on an unreachable ledge just cancelled.
                std::map<int32_t, int32_t> stone, econ;
                for (auto i : world->items.other[items_other_id::BOULDER])
                {
                    auto & f = i->flags.bits;
                    if (i->getMaterial() != 0 || f.forbid || f.in_job || f.trader || f.dump || f.garbage_collect ||
                        f.construction || f.in_building || f.owned || f.removed)
                        continue;
                    int32_t mi = i->getMaterialIndex();
                    if (ji->mat_index >= 0 && mi != ji->mat_index)
                        continue;
                    if (mi < 0 || size_t(mi) >= plotinfo->economic_stone.size())
                        continue;
                    df::coord ipos = Items::getPosition(i);
                    if (!ipos.isValid() || !Maps::canWalkBetween(u->pos, ipos))
                        continue;
                    if (plotinfo->economic_stone[mi])
                        econ[mi]++;
                    else
                        stone[mi]++;
                }
                int32_t best = -1, best_n = 0;
                for (auto & kv : stone)
                {
                    if (kv.second > best_n)
                    {
                        best = kv.first;
                        best_n = kv.second;
                    }
                }
                if (best < 0)
                {
                    // Every reachable boulder is flagged economic (Ral Athamlogem
                    // had only ore, coal, gypsum and kaolinite loose, so every
                    // mason job cancelled). Free the commonest stone that is not
                    // an ore, flux, fuel or plaster.
                    for (auto & kv : econ)
                    {
                        auto raw = df::inorganic_raw::find(kv.first);
                        if (!raw || !raw->metal_ore.mat_index.empty())
                            continue;
                        bool keep = false;
                        for (auto rc : raw->material.reaction_class)
                        {
                            if (rc && (*rc == "FLUX" || *rc == "COAL" || *rc == "GYPSUM"))
                                keep = true;
                        }
                        if (keep || raw->material.flags.is_set(material_flags::IS_METAL))
                            continue;
                        if (kv.second > best_n)
                        {
                            best = kv.first;
                            best_n = kv.second;
                        }
                    }
                    if (best >= 0)
                    {
                        plotinfo->economic_stone[best] = 0;
                        ai.debug(out, stl_sprintf("[MOOD] %s needs rock blocks and all reachable stone is economic: freed %s (%d boulders)", who.c_str(), MaterialInfo(0, best).toString().c_str(), best_n));
                    }
                }
                bool pending = false;
                for (auto mo : world->manager_orders.all)
                {
                    if (mo->job_type == job_type::ConstructBlocks && mo->amount_left > 0 && mo->mat_index >= 0)
                        pending = true;
                }
                if (best >= 0 && !pending)
                {
                    df::manager_order_template tmpl;
                    tmpl.job_type = job_type::ConstructBlocks;
                    tmpl.mat_type = 0;
                    tmpl.mat_index = best;
                    std::ostringstream why;
                    // one boulder gives four blocks
                    ai.stocks.add_manager_order(out, tmpl, (ji->quantity + 3) / 4 + 1, why);
                    ai.debug(out, stl_sprintf("[MOOD] %s needs rock blocks: ordered %s blocks cut ", who.c_str(), MaterialInfo(0, best).toString().c_str()) + why.str());
                }
                else if (best < 0)
                {
                    ai.debug(out, "[MOOD] " + who + " needs rock blocks and no free non-economic boulder exists");
                }
                if (best >= 0 || pending)
                    usable++;
            }
            if (!usable && ji->item_type == item_type::BLOCKS && (ji->mat_type == 0 || ji->mat_type == -1) &&
                holder && mood_urgent(u, MOOD_CHEAT_THIRST))
            {
                // Last resort: the mason's order never turned into a job and
                // the mood is running out. Create rock blocks from a free
                // boulder's stone at the workshop (a cheat).
                df::item *src = nullptr;
                for (auto i : world->items.other[items_other_id::BOULDER])
                {
                    auto & f = i->flags.bits;
                    if (i->getMaterial() == 0 && !f.forbid && !f.in_job && !f.trader && !f.construction && !f.in_building && !f.removed &&
                        (ji->mat_index < 0 || i->getMaterialIndex() == ji->mat_index))
                    {
                        src = i;
                        break;
                    }
                }
                std::vector<df::item *> made;
                if (src && Items::createItem(made, u, item_type::BLOCKS, -1, 0, src->getMaterialIndex()) && !made.empty())
                {
                    df::item *c = made[0];
                    if (Items::moveToBuilding(c, holder, df::building_item_role_type::TEMP) &&
                        Job::attachJobItem(job, c, df::job_role_type::Reagent, int32_t(idx), -1))
                    {
                        ai.debug(out, stl_sprintf("[MOOD] CHEAT: no rock blocks reached %s in time (thirst %d, mood timeout %d): created %s at the workshop",
                            who.c_str(), u->counters2.thirst_timer, u->job.mood_timeout, AI::describe_item(c).c_str()));
                        usable++;
                    }
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
            if (!usable && ji->item_type == item_type::BAR && ji->mat_type == 0 && ji->mat_index >= 0 &&
                !mood_warned.insert(who + "|barmat|" + std::to_string(idx)).second)
            {
                // already ordered the specific metal: don't fall through to the
                // generic any-ore order (wrong metal, and it ran before stocks
                // had counted and crashed DF)
                usable++;
            }
            else if (!usable && ji->item_type == item_type::BAR && ji->mat_type == 0 && ji->mat_index >= 0)
            {
                // The mood wants one SPECIFIC metal (a metalcrafter asked for
                // silver while the smelters only ran magnetite, and the generic
                // ore order below bails out whenever any SmeltOre order exists).
                // Smelt an ore that yields that metal, best yield first.
                int32_t metal = ji->mat_index;
                int32_t best_ore = -1, best_prob = 0, free_boulders = 0;
                std::map<int32_t, int32_t> ore_count;
                for (auto i : world->items.other[items_other_id::BOULDER])
                {
                    if (i->getMaterial() != 0 || i->flags.bits.forbid || i->flags.bits.in_job || i->flags.bits.trader ||
                        i->flags.bits.dump || i->flags.bits.garbage_collect || i->flags.bits.construction || i->flags.bits.in_building)
                        continue;
                    auto inorg = df::inorganic_raw::find(i->getMaterialIndex());
                    if (!inorg)
                        continue;
                    for (size_t k = 0; k < inorg->metal_ore.mat_index.size(); k++)
                    {
                        if (inorg->metal_ore.mat_index[k] != metal)
                            continue;
                        int32_t prob = k < inorg->metal_ore.probability.size() ? inorg->metal_ore.probability[k] : 100;
                        ore_count[i->getMaterialIndex()]++;
                        if (prob > best_prob)
                        {
                            best_prob = prob;
                            best_ore = i->getMaterialIndex();
                        }
                    }
                }
                if (best_ore >= 0)
                {
                    free_boulders = ore_count[best_ore];
                    bool pending = false;
                    for (auto mo : world->manager_orders.all)
                    {
                        if (mo->job_type == job_type::SmeltOre && mo->mat_type == 0 && mo->mat_index == best_ore && mo->amount_left > 0)
                            pending = true;
                    }
                    if (!pending)
                    {
                        // each smelt gives the metal with probability prob%
                        int32_t want = (ji->quantity * 100 + best_prob - 1) / std::max<int32_t>(best_prob, 1) + 2;
                        want = std::min(std::min(want, free_boulders), int32_t(30));
                        df::manager_order_template tmpl;
                        tmpl.job_type = job_type::SmeltOre;
                        tmpl.mat_type = 0;
                        tmpl.mat_index = best_ore;
                        std::ostringstream why;
                        ai.stocks.add_manager_order(out, tmpl, want, why);
                        ai.debug(out, stl_sprintf("[MOOD] %s needs %s bars: ordered %d %s smelted (%d%% yield) ", who.c_str(),
                            MaterialInfo(0, metal).toString().c_str(), want, MaterialInfo(0, best_ore).toString().c_str(), best_prob) + why.str());
                    }
                    usable++;
                }
                else
                {
                    // No ore yields it: an alloy (a fey armorsmith wanted
                    // bronze, the fort had neither copper nor tin bars and
                    // reached thirst 65000). Queue the alloy reaction at the
                    // smelter and smelt ore for each missing ingredient metal.
                    auto smelt_for = [&](int32_t m, int32_t bars) -> bool
                    {
                        int32_t ore = -1, prob = 0, n = 0;
                        std::map<int32_t, int32_t> cnt;
                        for (auto i : world->items.other[items_other_id::BOULDER])
                        {
                            auto & f = i->flags.bits;
                            if (i->getMaterial() != 0 || f.forbid || f.in_job || f.trader || f.dump || f.garbage_collect || f.construction || f.in_building)
                                continue;
                            auto inorg = df::inorganic_raw::find(i->getMaterialIndex());
                            if (!inorg)
                                continue;
                            for (size_t k = 0; k < inorg->metal_ore.mat_index.size(); k++)
                            {
                                if (inorg->metal_ore.mat_index[k] != m)
                                    continue;
                                int32_t pr = k < inorg->metal_ore.probability.size() ? inorg->metal_ore.probability[k] : 100;
                                cnt[i->getMaterialIndex()]++;
                                if (pr > prob)
                                {
                                    prob = pr;
                                    ore = i->getMaterialIndex();
                                }
                            }
                        }
                        if (ore < 0)
                            return false;
                        n = cnt[ore];
                        for (auto mo : world->manager_orders.all)
                        {
                            if (mo->job_type == job_type::SmeltOre && mo->mat_type == 0 && mo->mat_index == ore && mo->amount_left > 0)
                                return true;
                        }
                        int32_t want = std::min(std::min((bars * 100 + prob - 1) / std::max<int32_t>(prob, 1) + 1, n), int32_t(30));
                        df::manager_order_template tmpl;
                        tmpl.job_type = job_type::SmeltOre;
                        tmpl.mat_type = 0;
                        tmpl.mat_index = ore;
                        std::ostringstream why;
                        ai.stocks.add_manager_order(out, tmpl, want, why);
                        ai.debug(out, stl_sprintf("[MOOD] %s's alloy needs %s: ordered %d %s smelted ", who.c_str(),
                            MaterialInfo(0, m).toString().c_str(), want, MaterialInfo(0, ore).toString().c_str()) + why.str());
                        return true;
                    };
                    bool alloy = false;
                    for (auto r : world->raws.reactions.reactions)
                    {
                        bool makes = false;
                        for (auto rp : r->products)
                        {
                            auto rpi = virtual_cast<df::reaction_product_itemst>(rp);
                            if (rpi && rpi->item_type == item_type::BAR && rpi->mat_type == 0 && rpi->mat_index == metal)
                                makes = true;
                        }
                        if (!makes)
                            continue;
                        bool ok = true;
                        std::vector<std::pair<int32_t, int32_t>> need;
                        for (auto rr : r->reagents)
                        {
                            auto rri = virtual_cast<df::reaction_reagent_itemst>(rr);
                            if (!rri || rri->item_type != item_type::BAR || rri->mat_type != 0 || rri->mat_index < 0)
                            {
                                // fuel/flux reagents (coal, boulders) are left to the smelter
                                if (rri && rri->item_type == item_type::BAR && rri->mat_type != 0)
                                    continue;
                                ok = false;
                                break;
                            }
                            int32_t have = 0;
                            for (auto i : world->items.other[items_other_id::BAR])
                            {
                                auto & f = i->flags.bits;
                                if (i->getMaterial() == 0 && i->getMaterialIndex() == rri->mat_index &&
                                    !(f.forbid || f.in_job || f.trader || f.dump || f.garbage_collect || f.construction || f.in_building || f.owned))
                                    have += virtual_cast<df::item_barst>(i)->dimension;
                            }
                            if (have < rri->quantity)
                                need.push_back(std::make_pair(rri->mat_index, (rri->quantity - have + 149) / 150));
                        }
                        if (!ok)
                            continue;
                        bool reachable = true;
                        for (auto & nb : need)
                        {
                            if (!smelt_for(nb.first, nb.second))
                                reachable = false;
                        }
                        if (!reachable)
                            continue;
                        bool pending = false;
                        for (auto mo : world->manager_orders.all)
                        {
                            if (mo->job_type == job_type::CustomReaction && mo->reaction_name == r->code && mo->amount_left > 0)
                                pending = true;
                        }
                        if (!pending)
                        {
                            df::manager_order_template tmpl;
                            tmpl.job_type = job_type::CustomReaction;
                            tmpl.reaction_name = r->code;
                            tmpl.item_type = item_type::NONE;
                            tmpl.item_subtype = -1;
                            tmpl.mat_type = -1;
                            tmpl.mat_index = -1;
                            std::ostringstream why;
                            ai.stocks.add_manager_order(out, tmpl, 1, why);
                            ai.debug(out, "[MOOD] " + who + " needs " + MaterialInfo(0, metal).toString() + " bars: ordered alloy reaction " + r->code + " " + why.str());
                        }
                        alloy = true;
                        break;
                    }
                    if (alloy)
                        usable++;
                    else
                        ai.debug(out, "[MOOD] " + who + " needs " + MaterialInfo(0, metal).toString() + " bars and no free ore or alloy ingredients yield it");
                }
            }
            if (!usable && ji->item_type == item_type::BAR && mood_warned.insert(who + "|bar|" + std::to_string(idx)).second)
            {
                // No metal bar: smelt some ore (the moody dwarf takes any metal
                // unless the mood asks for a specific one)
                std::ostringstream why;
                ai.stocks.queue_use_metal_ore(out, 2, why);
                ai.debug(out, "[MOOD] no metal bars for " + who + ": queued ore smelting (" + why.str() + ")");
                if (why.str().find("could not") == std::string::npos && why.str().find("not enough") == std::string::npos)
                    usable++;
            }
            if (!usable && ji->item_type == item_type::SKIN_TANNED && mood_warned.insert(who + "|leather|" + std::to_string(idx)).second)
            {
                // No leather: nothing in df-ai ever tanned hides, so a moody
                // scholar starved waiting for SKIN_TANNED next to 5 yaks.
                // Slaughter one animal (most numerous species, keep at least
                // one of each, never pets), make sure a Tanner's exists, and
                // order the hide tanned.
                bool pending = false;
                std::map<int32_t, std::vector<df::unit *>> herd;
                for (auto a : world->units.active)
                {
                    // units.active keeps slaughtered/dead animals (flags1.inactive)
                    // with the slaughter flag still set: 32 such carcasses read as
                    // "slaughter pending" and no new animal was ever marked.
                    if (!Units::isActive(a) || !Units::isAlive(a) || !Units::isTame(a) || !Units::isOwnCiv(a) || Units::isCitizen(a))
                        continue;
                    if (a->flags2.bits.slaughter)
                        pending = true;
                    if (Units::isPet(a) || !Units::isAdult(a) || Units::isMarkedForWarTraining(a) || Units::isMarkedForHuntTraining(a))
                        continue;
                    herd[a->race].push_back(a);
                }
                df::unit *pick = nullptr;
                size_t best = 1; // never the last of a species
                for (auto & h : herd)
                {
                    if (h.second.size() > best)
                    {
                        best = h.second.size();
                        pick = h.second.front();
                    }
                }
                if (!pending && pick)
                {
                    pick->flags2.bits.slaughter = 1;
                    ai.debug(out, "[MOOD] no leather for " + who + ": marked " + AI::describe_unit(pick) + " for slaughter");
                }
                bool have_tanner = false;
                for (auto bld : world->buildings.other[buildings_other_id::WORKSHOP_ANY])
                {
                    auto ws = virtual_cast<df::building_workshopst>(bld);
                    if (ws && ws->type == workshop_type::Tanners)
                        have_tanner = true;
                }
                if (!have_tanner)
                {
                    if (df::building *bld = place_workshop_near(u->pos, workshop_type::Tanners))
                        ai.debug(out, stl_sprintf("[MOOD] no Tanner's workshop for %s's leather: placed one (building %d)", who.c_str(), bld->id));
                }
                std::ostringstream why;
                df::manager_order_template tmpl;
                tmpl.job_type = job_type::CustomReaction;
                tmpl.reaction_name = "TAN_A_HIDE";
                ai.stocks.add_manager_order(out, tmpl, 1, why);
                ai.debug(out, "[MOOD] ordered a hide tanned for " + who + " " + why.str());
                if (pending || pick)
                    usable++;
            }
            if (!usable && ji->item_type == item_type::SKIN_TANNED && holder && mood_urgent(u, MOOD_CHEAT_THIRST))
            {
                // Last resort (a cheat): Solon's glassmaker mood reached thirst
                // 62000 waiting on leather (nothing slaughtered or tanned in
                // time). Create one tanned hide at the workshop.
                MaterialInfo lm;
                bool found = lm.find("CREATURE:COW:LEATHER");
                for (size_t c = 0; !found && c < world->raws.creatures.all.size(); c++)
                    found = lm.find("CREATURE:" + world->raws.creatures.all[c]->creature_id + ":LEATHER");
                std::vector<df::item *> made;
                if (found && Items::createItem(made, u, item_type::SKIN_TANNED, -1, lm.type, lm.index) && !made.empty())
                {
                    df::item *c = made[0];
                    if (Items::moveToBuilding(c, holder, df::building_item_role_type::TEMP) &&
                        Job::attachJobItem(job, c, df::job_role_type::Reagent, int32_t(idx), -1))
                    {
                        ai.debug(out, stl_sprintf("[MOOD] CHEAT: nothing could supply %s for %s (thirst %d): created %s at the workshop",
                            describe_job_item(ji).c_str(), who.c_str(), u->counters2.thirst_timer, AI::describe_item(c).c_str()));
                        usable++;
                    }
                }
            }
            if (!usable && (ji->flags2.bits.shell || ji->flags2.bits.pearl || ji->flags2.bits.horn || ji->flags2.bits.ivory_tooth) &&
                mood_urgent(u, MOOD_CHEAT_THIRST - 15000))
            {
                // Rare body-part materials: Ushat, a moody bone carver, wanted
                // "any shells" in a fort with no shelled creature at all and
                // nearly died of thirst. Nothing in the fort can make a shell,
                // and a hand-made corpse piece crashed DF (empty body data), so
                // relax the requirement to bone when free bone exists (a cheat).
                auto saved = ji->flags2.whole;
                ji->flags2.bits.shell = 0;
                ji->flags2.bits.pearl = 0;
                ji->flags2.bits.horn = 0;
                ji->flags2.bits.ivory_tooth = 0;
                ji->flags2.bits.bone = 1;
                int32_t bones = 0;
                for (auto item : world->items.other[items_other_id::IN_PLAY])
                {
                    df::item_type itype = item->getType();
                    if ((ji->item_type != item_type::NONE && itype != ji->item_type) ||
                        (ji->item_subtype != -1 && item->getSubtype() != ji->item_subtype) ||
                        !mood_item_matches(ji, item))
                        continue;
                    auto & f = item->flags.bits;
                    if (f.in_job || f.owned || f.trader || f.foreign || f.artifact || f.removed ||
                        f.garbage_collect || f.on_fire || f.rotten || f.construction || f.hidden)
                        continue;
                    if (auto c = virtual_cast<df::item_body_component>(item))
                        if (c->hist_figure_id != -1)
                            continue; // named remains stay buryable
                    f.forbid = false;
                    f.dump = false;
                    bones++;
                }
                if (bones)
                {
                    ai.debug(out, stl_sprintf("[MOOD] CHEAT: nothing in the fort supplies %s's rare body-part item (thirst %d): requirement relaxed to bone (%d free)",
                        who.c_str(), u->counters2.thirst_timer, bones));
                    usable++;
                }
                else
                {
                    ji->flags2.whole = saved;
                }
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
