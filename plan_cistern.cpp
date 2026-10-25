#include "ai.h"
#include "plan.h"

#include "modules/Items.h"
#include "modules/Job.h"
#include "modules/Maps.h"
#include "modules/Units.h"

#include "df/building_floodgatest.h"
#include "df/building_trapst.h"
#include "df/general_ref_building_holderst.h"
#include "df/general_ref_building_triggertargetst.h"
#include "df/job.h"
#include "df/map_block.h"
#include "df/unit.h"
#include "df/world.h"

REQUIRE_GLOBAL(world);

bool Plan::construct_cistern(color_ostream & out, room *r)
{
    furnish_room(out, r);
    smooth_cistern(out, r);

    // remove boulders
    room_items(out, r, [](df::item *i) { i->flags.bits.dump = true; });

    // build levers for floodgates
    wantdig(out, r->workshop);

    // check smoothing progress, channel intermediate levels
    if (r->cistern_type == cistern_type::well)
    {
        add_task(task_type::dig_cistern, r);
    }

    return true;
}

void Plan::smooth_cistern(color_ostream & out, room *r)
{
    for (auto it : r->accesspath)
    {
        smooth_cistern_access(out, it);
    }

    std::set<df::coord> tiles;
    for (auto f : r->layout)
    {
        for (int16_t dx = -1; dx <= 1; dx++)
        {
            for (int16_t dy = -1; dy <= 1; dy++)
            {
                df::coord c = r->min + f->pos + df::coord(dx, dy, 0);
                if (c.x < r->min.x || c.x > r->max.x || c.y < r->min.y || c.y > r->max.y || c.z < r->min.z || c.z > r->max.z)
                {
                    tiles.insert(c);
                }
            }
        }
    }
    for (int16_t z = r->min.z; z <= r->max.z; z++)
    {
        for (int16_t x = r->min.x - 1; x <= r->max.x + 1; x++)
        {
            for (int16_t y = r->min.y - 1; y <= r->max.y + 1; y++)
            {
                if (z != r->min.z &&
                    r->min.x <= x && x <= r->max.x &&
                    r->min.y <= y && y <= r->max.y)
                    continue;

                tiles.insert(df::coord(x, y, z));
            }
        }
    }
    smooth(tiles);
}

// smooth only the inside of the room and any walls, but not adjacent floors
void Plan::smooth_cistern_access(color_ostream & out, room *r)
{
    if (r->type != room_type::cistern && (r->type != room_type::corridor || r->corridor_type != corridor_type::aqueduct))
    {
        return;
    }

    std::set<df::coord> tiles;
    for (int16_t x = r->min.x - 1; x <= r->max.x + 1; x++)
    {
        for (int16_t y = r->min.y - 1; y <= r->max.y + 1; y++)
        {
            for (int16_t z = r->min.z; z <= r->max.z; z++)
            {
                if (x < r->min.x || r->max.x < x || y < r->min.y || r->max.y < y)
                {
                    if (ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *Maps::getTileType(x, y, z))) != tiletype_shape_basic::Wall)
                    {
                        continue;
                    }
                }
                tiles.insert(df::coord(x, y, z));
            }
        }
    }
    smooth(tiles);
    for (auto it : r->accesspath)
    {
        smooth_cistern_access(out, it);
    }
}

// check smoothing progress, channel intermediate floors when done
bool Plan::try_digcistern(color_ostream & out, room *r)
{
    auto dig_channel = [r](df::coord t)
    {
        if (std::find_if(r->layout.begin(), r->layout.end(), [r, t](furniture *f) -> bool
        {
            return f->dig == tile_dig_designation::Channel &&
                f->pos == t - r->min;
        }) == r->layout.end())
        {
            furniture *f = new furniture();
            f->dig = tile_dig_designation::Channel;
            f->pos = t - r->min;
            r->layout.push_back(f);
        }
        AI::dig_tile(t, tile_dig_designation::Channel);
    };

    // XXX hardcoded layout..
    int32_t cnt = 0;
    int16_t acc_y = (r->min.y + r->max.y) / 2;
    for (int16_t z = r->min.z + 1; z <= r->max.z; z++)
    {
        for (int16_t x = r->max.x; x >= r->min.x; x--)
        {
            bool stop = false;
            for (int16_t y = r->min.y; y <= r->max.y; y++)
            {
                switch (ENUM_ATTR(tiletype_shape, basic_shape,
                    ENUM_ATTR(tiletype, shape,
                        *Maps::getTileType(x, y, z))))
                {
                case tiletype_shape_basic::Floor:
                    stop = true;
                    if (!is_smooth(df::coord(x + 1, y - 1, z)) ||
                        !is_smooth(df::coord(x + 1, y, z)) ||
                        !is_smooth(df::coord(x + 1, y + 1, z)))
                    {
                        continue;
                    }
                    if (ENUM_ATTR(tiletype_shape, basic_shape,
                        ENUM_ATTR(tiletype, shape,
                            *Maps::getTileType(x - 1, y, z))) ==
                        tiletype_shape_basic::Floor)
                    {
                        dig_channel(df::coord(x, y, z));
                    }
                    else
                    {
                        // last column before stairs
                        df::coord nt10(x, y - 1, z);
                        df::coord nt12(x, y + 1, z);
                        df::coord nt00(x - 1, y - 1, z);
                        df::coord nt02(x - 1, y + 1, z);
                        if (y > acc_y ?
                            is_smooth(nt12) && is_smooth(nt02) :
                            is_smooth(nt10) && is_smooth(nt00))
                        {
                            dig_channel(df::coord(x, y, z));
                        }
                    }
                    break;
                case tiletype_shape_basic::Open:
                    if (r->min.x <= x && x <= r->max.x &&
                        r->min.y <= y && y <= r->max.y)
                    {
                        cnt++;
                    }
                    break;
                default:
                    break;
                }
            }
            if (stop)
                break;
        }
    }

    trycistern_count++;
    if (trycistern_count % 12 == 0)
    {
        smooth_cistern(out, r);
    }

    df::coord size = r->size();
    if (cnt == size.x * size.y * (size.z - 1))
    {
        r->channeled = true;
        return true;
    }
    return false;
}

void Plan::monitor_cistern(color_ostream & out, std::ostream & reason)
{
    if (!m_c_lever_in)
    {
        m_c_cistern = ai.find_room(room_type::cistern, [](room* r) -> bool { return r->cistern_type == cistern_type::well; });
        m_c_reserve = ai.find_room(room_type::cistern, [](room* r) -> bool { return r->cistern_type == cistern_type::reserve; });
        for (auto f : m_c_cistern->workshop->layout)
        {
            if (f->type == layout_type::lever)
            {
                if (f->internal)
                    m_c_lever_in = f;
                else
                    m_c_lever_out = f;
            }
        }
        if (m_c_reserve->channel_enable.isValid())
        {
            m_c_testgate_delay = m_c_reserve->channeled ? -1 : 2;
        }
    }

    df::building_trapst *l_in = nullptr, *l_out = nullptr;
    df::building_floodgatest *f_in = nullptr, *f_out = nullptr;
    if (m_c_lever_in->bld_id != -1)
        l_in = virtual_cast<df::building_trapst>(df::building::find(m_c_lever_in->bld_id));
    if (m_c_lever_in->target && m_c_lever_in->target->bld_id != -1)
        f_in = virtual_cast<df::building_floodgatest>(df::building::find(m_c_lever_in->target->bld_id));
    if (m_c_lever_out->bld_id != -1)
        l_out = virtual_cast<df::building_trapst>(df::building::find(m_c_lever_out->bld_id));
    if (m_c_lever_out->target && m_c_lever_out->target->bld_id != -1)
        f_out = virtual_cast<df::building_floodgatest>(df::building::find(m_c_lever_out->target->bld_id));

    if (l_in && f_in && !f_out && !l_in->linked_mechanisms.empty())
    {
        if (f_in->gate_flags.bits.closing || f_in->gate_flags.bits.closed)
        {
            if (!f_in->gate_flags.bits.opening)
            {
                reason << "pulling lever to open input floodgate: ";
                pull_lever(out, m_c_lever_in, reason);
            }
            else
            {
                reason << "waiting for input floodgate to open";
            }
            return;
        }

        // f_in is linked, can furnish f_out now without risking walling
        // workers in the reserve
        for (auto l = m_c_reserve->layout.begin(); l != m_c_reserve->layout.end(); l++)
        {
            (*l)->ignore = false;
        }
        furnish_room(out, m_c_reserve);
    }

    if (!l_in || !f_in || !l_out || !f_out)
    {
        reason << "waiting for mechanic";
        return;
    }
    if (l_in->linked_mechanisms.empty() || l_out->linked_mechanisms.empty())
    {
        reason << "waiting for lever to be linked";
        return;
    }
    if (!l_in->jobs.empty() || !l_out->jobs.empty())
    {
        reason << "lever waiting to be pulled";
        return;
    }

    // may use mechanisms for entrance cage traps now
    bool furnish_entrance = false;
    for (auto f = fort_entrance->layout.begin(); f != fort_entrance->layout.end(); f++)
    {
        if ((*f)->ignore)
        {
            (*f)->ignore = false;
            furnish_entrance = true;
        }
    }
    if (furnish_entrance)
    {
        furnish_room(out, fort_entrance);
    }

    bool f_in_closed = (f_in->gate_flags.bits.closed || f_in->gate_flags.bits.closing) && !f_in->gate_flags.bits.opening;
    bool f_out_closed = (f_out->gate_flags.bits.closed || f_out->gate_flags.bits.closing) && !f_out->gate_flags.bits.opening;

    if (m_c_testgate_delay != -1)
    {
        // expensive, dont check too often
        m_c_testgate_delay--;
        if (m_c_testgate_delay > 0)
        {
            reason << "waiting to test gate again (" << m_c_testgate_delay << " times remaining)";
            return;
        }

        // re-dump garbage + smooth reserve accesspath
        construct_cistern(out, m_c_reserve);

        df::coord gate = m_c_reserve->channel_enable;
        if (ENUM_ATTR(tiletype_shape, basic_shape,
            ENUM_ATTR(tiletype, shape,
                *Maps::getTileType(gate))) ==
            tiletype_shape_basic::Wall)
        {
            ai.debug(out, "cistern: test channel");
            bool empty = true;
            std::list<room *> todo;
            todo.push_back(m_c_reserve);
            while (empty && !todo.empty())
            {
                room *r = todo.front();
                todo.pop_front();
                todo.insert(todo.end(), r->accesspath.begin(), r->accesspath.end());
                if (r->type != room_type::cistern && (r->type != room_type::corridor || r->corridor_type != corridor_type::aqueduct))
                {
                    continue;
                }
                for (int16_t x = r->min.x - 1; empty && x <= r->max.x + 1; x++)
                {
                    for (int16_t y = r->min.y - 1; empty && y <= r->max.y + 1; y++)
                    {
                        for (int16_t z = r->min.z; z <= r->max.z; z++)
                        {
                            df::coord t(x, y, z);
                            if (!is_smooth(t) && Maps::getTileDesignation(t)->bits.flow_size < 3 && (r->type != room_type::corridor || (r->min.x <= x && x <= r->max.x && r->min.y <= y && y <= r->max.y) || ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *Maps::getTileType(t))) == tiletype_shape_basic::Wall))
                            {
                                std::string msg = stl_sprintf("unsmoothed %s (%d, %d, %d) %s", enum_item_key_str(*Maps::getTileType(t)), x, y, z, AI::describe_room(r).c_str());
                                ai.debug(out, "cistern: " + msg);
                                reason << msg << "\n";
                                empty = false;
                                break;
                            }
                            df::tile_occupancy occ = *Maps::getTileOccupancy(t);
                            if (occ.bits.unit || occ.bits.unit_grounded)
                            {
                                for (auto u = world->units.active.begin(); u != world->units.active.end(); u++)
                                {
                                    if (Units::getPosition(*u) == t)
                                    {
                                        std::string msg = stl_sprintf("unit (%d, %d, %d) (%s) %s", x, y, z, AI::describe_unit(*u).c_str(), AI::describe_room(r).c_str());
                                        ai.debug(out, "cistern: " + msg);
                                        reason << msg << "\n";
                                        break;
                                    }
                                }
                                empty = false;
                                break;
                            }
                            if (occ.bits.item)
                            {
                                auto & items = Maps::getTileBlock(t)->items;
                                for (auto it = items.begin(); it != items.end(); it++)
                                {
                                    df::item *i = df::item::find(*it);
                                    if (Items::getPosition(i) == t)
                                    {
                                        std::string msg = stl_sprintf("item (%d, %d, %d) (%s) %s", x, y, z, AI::describe_item(i).c_str(), AI::describe_room(r).c_str());
                                        ai.debug(out, "cistern: " + msg);
                                        i->flags.bits.dump = true;
                                        break;
                                    }
                                }
                                empty = false;
                                break;
                            }
                        }
                    }
                }
            }

            if (empty)
            {
                if (!f_out_closed)
                {
                    // avoid floods. wait for the output to be closed.
                    reason << "waiting for output floodgate to be closed: ";
                    pull_lever(out, m_c_lever_out, reason);
                    m_c_testgate_delay = 1;
                }
                else
                {
                    reason << "waiting for channel";
                    if (f_in_closed)
                    {
                        reason << "; ";
                        pull_lever(out, m_c_lever_in, reason);
                    }
                    ai.debug(out, "cistern: do channel");
                    cistern_channel_requested = true;
                    AI::dig_tile(gate + df::coord(0, 0, 1), tile_dig_designation::Channel);
                    m_c_testgate_delay = 16;
                }
            }
            else
            {
                room *well = m_c_cistern->workshop;
                if (Maps::getTileDesignation(well->min + df::coord(-2, well->size().y / 2, 0))->bits.flow_size == 7)
                {
                    // something went not as planned, but we have a water source
                    m_c_testgate_delay = -1;
                    reason << "we have water (unexpectedly)";
                }
                else
                {
                    if (!cistern_channel_requested)
                    {
                        // make sure we can actually access the cistern
                        if (f_in_closed)
                            pull_lever(out, m_c_lever_in, reason);
                        if (f_out_closed)
                            pull_lever(out, m_c_lever_out, reason);
                    }
                    m_c_testgate_delay = 1;
                    reason << "not ready to channel";
                }
            }
        }
        else
        {
            m_c_testgate_delay = -1;
            // channel surrounding tiles
            for (int16_t x = -1; x <= 1; x++)
            {
                for (int16_t y = -1; y <= 1; y++)
                {
                    df::tiletype tt = *Maps::getTileType(gate + df::coord(x, y, 0));
                    if (ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, tt)) != tiletype_shape_basic::Wall)
                        continue;
                    df::tiletype_material tm = ENUM_ATTR(tiletype, material, tt);
                    if (tm != tiletype_material::STONE && tm != tiletype_material::MINERAL && tm != tiletype_material::SOIL && tm != tiletype_material::ROOT)
                        continue;
                    if (AI::spiral_search(gate + df::coord(x, y, 0), 1, 1, [](df::coord ttt) -> bool { df::tile_designation *td = Maps::getTileDesignation(ttt); return td && td->bits.feature_local; }).isValid())
                    {
                        AI::dig_tile(gate + df::coord(x, y, 1), tile_dig_designation::Channel);
                    }
                }
            }
            reason << "waiting for channel";
        }
        return;
    }

    if (!m_c_cistern->channeled)
    {
        reason << "waiting for channel";
        return;
    }

    // cistlvl = water level for the top floor
    // if it is flooded, reserve output tile is probably > 4 and prevents
    // buildingdestroyers from messing with the floodgates
    uint32_t cistlvl = Maps::getTileDesignation(m_c_cistern->pos() + df::coord(0, 0, 1))->bits.flow_size;
    uint32_t resvlvl = Maps::getTileDesignation(m_c_reserve->pos())->bits.flow_size;

    df::coord river = AI::spiral_search(m_c_reserve->channel_enable, 0, 2, [](df::coord t) -> bool { df::tile_designation *td = Maps::getTileDesignation(t); return td && td->bits.feature_local; });
    bool river_is_frozen_or_dry = river.isValid() && (ENUM_ATTR(tiletype, material, *Maps::getTileType(river)) == tiletype_material::FROZEN_LIQUID || Maps::getTileDesignation(river)->bits.flow_size == 0);

    if (resvlvl <= 1)
    {
        reason << "reserve empty";
        // reserve empty, fill it
        if (!f_out_closed)
        {
            reason << "; closing output: ";
            pull_lever(out, m_c_lever_out, reason);
        }
        else if (f_in_closed)
        {
            reason << "; opening input: ";
            pull_lever(out, m_c_lever_in, reason);
        }
    }
    else if (resvlvl == 7 || river_is_frozen_or_dry)
    {
        if (resvlvl == 7)
        {
            reason << "reserve full";
        }
        if (river_is_frozen_or_dry)
        {
            if (resvlvl == 7)
            {
                reason << " and ";
            }
            reason << "river is frozen or dry";
        }
        // reserve full, empty into cistern if needed
        if (!f_in_closed)
        {
            reason << "; closing input: ";
            pull_lever(out, m_c_lever_in, reason);
        }
        else
        {
            if (cistlvl < 7)
            {
                reason << "; cistern filling (" << cistlvl << "/7)";
                if (f_out_closed)
                {
                    reason << "; opening output: ";
                    pull_lever(out, m_c_lever_out, reason);
                }
            }
            else
            {
                reason << "; cistern full";
                if (!f_out_closed)
                {
                    reason << "; closing output: ";
                    pull_lever(out, m_c_lever_out, reason);
                }
            }
        }
    }
    else
    {
        reason << "cistern " << cistlvl << "/7, reserve " << resvlvl << "/7";
        // ensure it's either filling up or emptying
        if (f_in_closed && f_out_closed)
        {
            if (resvlvl >= 6 && cistlvl < 7)
            {
                reason << "; opening output: ";
                pull_lever(out, m_c_lever_out, reason);
            }
            else
            {
                reason << "; opening input: ";
                pull_lever(out, m_c_lever_in, reason);
            }
        }
    }
}

bool Plan::setup_lever(color_ostream & out, room *r, furniture *f, std::ostream & reason)
{
    if (!f->target)
    {
        return true;
    }
    if (link_lever(out, f, f->target, reason))
    {
        pull_lever(out, f, reason);
        if (f->internal)
        {
            add_task(task_type::monitor_cistern);
        }

        return true;
    }
    return false;
}

bool Plan::pull_lever(color_ostream &, furniture *f, std::ostream & reason)
{
    auto bld = df::building::find(f->bld_id);
    if (!bld)
    {
        reason << "missing " << AI::describe_furniture(f);
        return false;
    }

    for (auto job : bld->jobs)
    {
        if (job->job_type == job_type::PullLever)
        {
            reason << "waiting for someone to pull " << AI::describe_furniture(f);
            return true;
        }
    }

    if (bld->jobs.size() >= 10)
    {
        reason << AI::describe_furniture(f) << " job list is full";
        return false;
    }

    auto ref = df::allocate<df::general_ref_building_holderst>();
    ref->building_id = bld->id;

    auto job = df::allocate<df::job>();
    job->job_type = job_type::PullLever;
    job->pos = df::coord(bld->x1, bld->y1, bld->z);
    job->general_refs.push_back(ref);
    bld->jobs.push_back(job);
    Job::linkIntoWorld(job);

    reason << "waiting for someone to pull " << AI::describe_furniture(f);

    return true;
}


// Underground pit (corridor_type pitshaft): the shaft is first dug as plain
// floors on every level from a stair column beside it, so channeling those
// floors afterwards never turns rock into ramps. Then the stair is cut off at
// the top (channel + constructed floor), so nothing at the bottom - corpses,
// refuse, survivors - is ever reachable from the fort. Only after that may the
// hatch and the dump at the top be channeled (pit_channel_blocked).
bool Plan::try_digpitshaft(color_ostream & out, room *r, std::ostream & reason)
{
    if (r->channeled)
        return true;

    std::set<std::pair<int16_t, int16_t>> stairs;
    for (auto f : r->layout)
    {
        if (f->dig == tile_dig_designation::UpDownStair || f->dig == tile_dig_designation::UpStair || f->dig == tile_dig_designation::DownStair)
        {
            stairs.insert(std::make_pair(int16_t(r->min.x + f->pos.x), int16_t(r->min.y + f->pos.y)));
        }
    }
    if (stairs.empty())
    {
        reason << "pit shaft has no access stair in its layout";
        return false;
    }

    auto basic = [](df::coord t) -> df::tiletype_shape_basic
    {
        return ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *Maps::getTileType(t)));
    };

    // 1. channel every shaft floor except the bottom one
    int32_t left = 0;
    for (int16_t z = r->max.z; z > r->min.z; z--)
    {
        for (int16_t x = r->min.x; x <= r->max.x; x++)
        {
            for (int16_t y = r->min.y; y <= r->max.y; y++)
            {
                if (stairs.count(std::make_pair(x, y)))
                    continue;
                df::coord t(x, y, z);
                if (basic(t) == tiletype_shape_basic::Open)
                    continue;
                left++;
                if (basic(t - df::coord(0, 0, 1)) == tiletype_shape_basic::Wall)
                {
                    // not dug below yet: channeling now would leave a ramp
                    continue;
                }
                if (Maps::getTileDesignation(t)->bits.dig != tile_dig_designation::Channel)
                {
                    AI::dig_tile(t, tile_dig_designation::Channel);
                }
            }
        }
    }
    if (left)
    {
        reason << "channeling the pit shaft: " << left << " tiles left";
        return false;
    }

    // 2. cut the access stair off at the top
    df::coord s0(stairs.begin()->first, stairs.begin()->second, r->max.z + 1);
    df::tiletype stt = *Maps::getTileType(s0);
    auto sb = ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, stt));

    df::unit *inside = nullptr;
    for (auto u : world->units.active)
    {
        if (Units::isDead(u) || !Units::isActive(u))
            continue;
        if (r->include(Units::getPosition(u)) || Units::getPosition(u) == s0)
        {
            inside = u;
            break;
        }
    }

    if (ENUM_ATTR(tiletype, material, stt) == tiletype_material::CONSTRUCTION && sb == tiletype_shape_basic::Floor)
    {
        if (inside && Units::isCitizen(inside))
        {
            // someone got shut in while the floor went up: bring them back up
            df::coord to = AI::spiral_search(s0, 2, 1, [s0](df::coord t) -> bool
            {
                return t.z == s0.z && t != s0 && ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *Maps::getTileType(t))) == tiletype_shape_basic::Floor && Maps::getTileWalkable(t) != 0;
            });
            if (to.isValid() && Units::teleport(inside, to))
            {
                ai.debug(out, "[PIT] " + AI::describe_unit(inside) + " was shut in the pit shaft; moved back up");
            }
            reason << "waiting for " << AI::describe_unit(inside) << " to get out of the pit shaft";
            return false;
        }
        r->channeled = true;
        ai.debug(out, "[PIT] pit shaft sealed: " + AI::describe_room(r) + "; the pit bottom is now out of reach");
        return true;
    }

    if (sb == tiletype_shape_basic::Open)
    {
        if (!try_furnish_construction(out, construction_type::Floor, s0, reason))
        {
            return false;
        }
        reason << "sealing the pit shaft (floor over its stair)";
        return false;
    }

    // a stair still leads down: nobody may be in there when it goes
    if (inside)
    {
        reason << "waiting for " << AI::describe_unit(inside) << " to leave the pit shaft";
        return false;
    }
    // nothing down there is worth a trip
    room_items(out, r, [](df::item *i) { i->flags.bits.forbid = true; });
    // stop the stair's own room from re-digging or rebuilding the stair
    for (auto rr : r->accesspath)
    {
        for (auto f : rr->layout)
        {
            if (rr->min + f->pos == s0)
            {
                f->dig = tile_dig_designation::Channel;
                f->construction = construction_type::NONE;
            }
        }
    }
    if (Maps::getTileDesignation(s0)->bits.dig != tile_dig_designation::Channel)
    {
        ai.debug(out, "[PIT] pit shaft channeled; cutting off its access stair");
        AI::dig_tile(s0, tile_dig_designation::Channel);
    }
    reason << "channeling the top of the pit shaft's access stair";
    return false;
}
