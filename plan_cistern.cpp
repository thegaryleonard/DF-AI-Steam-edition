#include "ai.h"
#include "plan.h"

#include "modules/Items.h"
#include "modules/Job.h"
#include "modules/Maps.h"
#include "modules/Units.h"

#include "df/building_floodgatest.h"
#include "df/building_hatchst.h"
#include "df/building_trapst.h"
#include "df/general_ref_building_holderst.h"
#include "df/general_ref_building_triggertargetst.h"
#include "df/job.h"
#include "df/map_block.h"
#include "df/unit.h"
#include "df/world.h"

#include <queue>

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

    // the reserve's inlet only gets a tunnel to water at embark, and only if
    // the map has a river: on every other map it was dug up to its floodgate
    // and stopped there, and the levers were pulled forever over an empty
    // reserve. Look for any real water the inlet can reach instead.
    if (!m_c_reserve->channel_enable.isValid())
    {
        if (m_c_tap_wait > 0)
        {
            m_c_tap_wait--;
            reason << "no water source the reserve can tap yet";
            return;
        }
        if (!plan_cistern_tap(out, f_in, reason))
        {
            m_c_tap_wait = 100;
            return;
        }
        m_c_testgate_delay = 2;
    }

    {
        static int32_t reroute_wait = 200;
        if (m_c_reserve->channel_enable.isValid() && --reroute_wait <= 0)
        {
            reroute_wait = 200;
            std::ostringstream why;
            if (reroute_cistern_aqueduct(out, why, true))
            {
                reason << "rerouted the aqueduct to nearer water";
                return;
            }
        }
    }

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

            if (empty && !seal_tap_stair(out, reason))
            {
                m_c_testgate_delay = 1;
            }
            else if (empty)
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

// Find water for the reserve's inlet after embark: a tunnel through solid
// rock from behind the inlet floodgate, level or rising (water has to run
// down to the reserve), to a wall that has real standing or running water on
// its far side. That wall is breached by channeling it from above, so the
// tile above it and the tile above the tunnel's end must be open ground the
// fort walks on: a dwarf breaches from outside and walks away dry. The tunnel
// keeps one tile of rock between itself and any open space so it can't flood
// anything but the reserve. The breach itself is monitor_cistern's usual
// "test channel" step (tunnel empty and smoothed, outlet closed first).
bool cistern_tap_test_small = false;   // "ai cistern-tap X Y Z small": any pool will do (testing)
// open tiles of the existing aqueduct a branch may sit beside (reroute)
static const std::set<df::coord> *cistern_tap_ok_neighbours = nullptr;
bool Plan::plan_cistern_tap(color_ostream & out, df::building *gate_bld, std::ostream & reason, df::coord test_origin, df::coord attach, bool commit, int32_t *path_len)
{
    // test_origin: a dry run from any rock tile ("ai cistern-tap X Y Z"):
    // plans and describes the tunnel, digs nothing
    const bool dry = test_origin.isValid() && !commit;
    if (!gate_bld && !test_origin.isValid())
        return false;
    const df::coord gate = attach.isValid() ? attach : test_origin.isValid() ? df::coord() : df::coord(gate_bld->x1, gate_bld->y1, gate_bld->z);

    auto shape_at = [](df::coord t) -> df::tiletype_shape_basic
    {
        df::tiletype *tt = Maps::getTileType(t);
        return tt ? ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) : tiletype_shape_basic::None;
    };
    auto natural_rock = [&](df::coord t) -> bool
    {
        df::tiletype *tt = Maps::getTileType(t);
        if (!tt || ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) != tiletype_shape_basic::Wall)
            return false;
        df::tiletype_material tm = ENUM_ATTR(tiletype, material, *tt);
        if (tm != tiletype_material::STONE && tm != tiletype_material::MINERAL && tm != tiletype_material::SOIL)
            return false;
        df::tile_designation *td = Maps::getTileDesignation(t);
        return td && !td->bits.water_table;   // never into an aquifer
    };

    // which side of the gate is the reserve: the tunnel starts on the other
    df::coord origin = test_origin;
    static const int16_t D4[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
    for (auto & d : D4)
    {
        if (test_origin.isValid())
            break;
        df::coord in = gate + df::coord(d[0], d[1], 0);
        df::coord outside = gate - df::coord(d[0], d[1], 0);
        if (shape_at(in) != tiletype_shape_basic::Wall && natural_rock(outside))
        {
            origin = outside;
            break;
        }
    }
    if (!origin.isValid())
    {
        reason << "the reserve's inlet has no rock behind it to tunnel through";
        return false;
    }

    // the walkable area the fort lives in
    uint16_t fort_group = 0;
    {
        std::map<uint16_t, int32_t> counts;
        int32_t seen = 0, best = 0;
        for (auto u : world->units.active)
        {
            if (!Units::isCitizen(u) || Units::isDead(u))
                continue;
            uint16_t g = Maps::getWalkableGroup(Units::getPosition(u));
            if (g && ++counts[g] > best)
                best = counts[g], fort_group = g;
            if (++seen >= 40)
                break;
        }
    }
    if (!fort_group)
        return false;

    auto inside_any_room = [this](df::coord t) -> bool
    {
        for (auto r : rooms_and_corridors)
            if (!r->abandoned && r->include(t))
                return true;
        return false;
    };
    auto open_ground = [&](df::coord t) -> bool
    {
        df::tiletype *tt = Maps::getTileType(t);
        df::tile_designation *td = Maps::getTileDesignation(t);
        return tt && td && ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) == tiletype_shape_basic::Floor &&
            td->bits.flow_size == 0 && Maps::getWalkableGroup(t) == fort_group;
    };
    // standing or running water, not a puddle and not one of the fort's own
    // tanks (cisterns, wells, the mist generator's pool)
    auto real_water = [&](df::coord t) -> bool
    {
        df::tile_designation *td = Maps::getTileDesignation(t);
        if (!td || td->bits.liquid_type || td->bits.flow_size < 4)
            return false;
        df::tiletype *tt = Maps::getTileType(t);
        if (!tt || ENUM_ATTR(tiletype, material, *tt) == tiletype_material::CONSTRUCTION || inside_any_room(t))
            return false;
        if (td->bits.feature_local)
            return true;   // a river or brook
        int32_t n = 0;
        for (int16_t dx = -3; dx <= 3; dx++)
            for (int16_t dy = -3; dy <= 3; dy++)
            {
                df::tile_designation *d2 = Maps::getTileDesignation(t + df::coord(dx, dy, 0));
                if (d2 && !d2->bits.liquid_type && d2->bits.flow_size >= 3)
                    n++;
            }
        return n >= (dry && cistern_tap_test_small ? 1 : 12);
    };
    // a tunnel tile: natural rock with rock all around (the gate excepted)
    auto sealed = [&](df::coord t) -> bool
    {
        if (!natural_rock(t))
            return false;
        for (int16_t dx = -1; dx <= 1; dx++)
            for (int16_t dy = -1; dy <= 1; dy++)
            {
                df::coord n = t + df::coord(dx, dy, 0);
                if ((dx || dy) && n != gate && !(cistern_tap_ok_neighbours && cistern_tap_ok_neighbours->count(n)) && !natural_rock(n))
                    return false;
            }
        return !inside_any_room(t);
    };
    if (!sealed(origin))
    {
        reason << (dry ? "the rock at the start isn't solid" : "the rock behind the reserve's inlet isn't solid");
        return false;
    }

    // 1. every place a tunnel could end: water two tiles out, one rock wall
    //    between, open ground above that wall and above the tunnel's end
    struct cand { df::coord end, breach; int32_t dist; };
    std::vector<cand> cands;
    for (int16_t z = origin.z; z <= origin.z + 20; z++)
        for (int16_t x = origin.x - 100; x <= origin.x + 100; x++)
            for (int16_t y = origin.y - 100; y <= origin.y + 100; y++)
            {
                df::coord t(x, y, z);
                df::tile_designation *td = Maps::getTileDesignation(t);
                if (!td || td->bits.liquid_type || td->bits.flow_size < 4)
                    continue;
                for (auto & d : D4)
                {
                    df::coord w = t - df::coord(d[0], d[1], 0), e = w - df::coord(d[0], d[1], 0);
                    if (natural_rock(w) && open_ground(w + df::coord(0, 0, 1)) && open_ground(e + df::coord(0, 0, 1)) && sealed(e) && real_water(t))
                        cands.push_back(cand{ e, w, std::abs(e.x - origin.x) + std::abs(e.y - origin.y) + (e.z - origin.z) });
                }
            }
    std::sort(cands.begin(), cands.end(), [](const cand & l, const cand & r) { return l.dist < r.dist; });

    // 2. the shortest sealed tunnel to the nearest of them (level or rising)
    std::map<df::coord, df::coord> from;
    df::coord end, breach;
    int32_t tried = 0;
    for (auto & c : cands)
    {
        if (++tried > 8)
            break;
        from.clear();
        // states are (tile, how we got here) so a turn can cost extra: one
        // straight stair and straight runs instead of a corkscrew of little
        // pieces, each its own dig job
        typedef std::pair<df::coord, int> state;
        std::map<state, int32_t> g;
        std::map<state, state> came;
        typedef std::pair<int32_t, state> node;
        auto worse = [](const node & l, const node & r) { return l.first > r.first; };
        std::priority_queue<node, std::vector<node>, decltype(worse)> open(worse);
        auto h = [&c](df::coord t) { return std::abs(t.x - c.end.x) + std::abs(t.y - c.end.y) + std::abs(t.z - c.end.z); };
        static const int16_t M5[5][3] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 } };
        state start(origin, -1);
        g[start] = 0;
        open.push(node(h(origin), start));
        int32_t expanded = 0;
        while (!open.empty() && ++expanded < 60000)
        {
            node top = open.top();
            open.pop();
            state cur = top.second;
            if (top.first - h(cur.first) > g[cur])
                continue;   // stale entry
            if (cur.first == c.end)
            {
                for (state s2 = cur; ; s2 = came.at(s2))
                {
                    if (s2.first == origin)
                        break;
                    from[s2.first] = came.at(s2).first;
                }
                from[origin] = origin;
                end = c.end;
                breach = c.breach;
                break;
            }
            for (int m = 0; m < 5; m++)
            {
                df::coord n = cur.first + df::coord(M5[m][0], M5[m][1], M5[m][2]);
                if (n.z > c.end.z || !sealed(n))
                    continue;
                state ns(n, m);
                int32_t cost = g[cur] + 1 + (cur.second != -1 && cur.second != m ? 3 : 0);
                auto it = g.find(ns);
                if (it != g.end() && it->second <= cost)
                    continue;
                g[ns] = cost;
                came[ns] = cur;
                open.push(node(cost + h(n), ns));
            }
        }
        if (end.isValid())
            break;
    }
    if (!end.isValid())
    {
        reason << "no water the reserve can reach through solid rock (" << cands.size() << " possible spots)";
        ai.debug(out, stl_sprintf("cistern: no water source to tap from (%d, %d, %d): %d possible spots, %d tried", origin.x, origin.y, origin.z, int(cands.size()), std::min(tried, 8)));
        return false;
    }

    // the path, origin first, plus the stair up out of the tunnel's end
    std::vector<df::coord> path;
    for (df::coord c = end; ; c = from.at(c))
    {
        path.insert(path.begin(), c);
        if (c == origin)
            break;
    }
    path.push_back(end + df::coord(0, 0, 1));
    if (path_len)
        *path_len = int32_t(path.size());

    // cut it into straight corridors, no tile in two of them: runs of stair
    // (same x,y going up) and straight level runs
    std::vector<room *> segs;
    size_t i = 0;
    while (i < path.size())
    {
        size_t j = i;
        if (i + 1 < path.size() && path[i + 1].z != path[i].z)
        {
            while (j + 1 < path.size() && path[j + 1].z != path[j].z)
                j++;
        }
        else
        {
            while (j + 1 < path.size() && path[j + 1].z == path[j].z &&
                !(j + 2 < path.size() && path[j + 2].z != path[j + 1].z) &&
                (j == i || (path[j + 1] - path[j]) == (path[j] - path[j - 1])))
                j++;
        }
        df::coord a = path[i], b = path[j];
        room *seg = new room(corridor_type::aqueduct, df::coord(std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)), df::coord(std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)), "tunnel to water for the cistern");
        segs.push_back(seg);
        i = j + 1;
    }
    if (dry)
    {
        reason << stl_sprintf("tunnel of %d tiles in %d pieces from (%d, %d, %d) to the wall at (%d, %d, %d); %d possible spots\n", int(path.size()), int(segs.size()), origin.x, origin.y, origin.z, breach.x, breach.y, breach.z, int(cands.size()));
        for (auto seg : segs)
        {
            reason << stl_sprintf("  (%d, %d, %d) - (%d, %d, %d)\n", seg->min.x, seg->min.y, seg->min.z, seg->max.x, seg->max.y, seg->max.z);
            delete seg;
        }
        return true;
    }
    for (auto seg : segs)
    {
        rooms_and_corridors.push_back(seg);
        m_c_reserve->accesspath.push_back(seg);
    }
    m_c_reserve->channel_enable = breach;
    m_c_reserve->channeled = false;
    categorize_all();
    for (auto seg : segs)
        digroom(out, seg);

    ai.debug(out, stl_sprintf("cistern: tunnel of %d tiles in %d pieces from (%d, %d, %d) to water past (%d, %d, %d)", int(path.size()), int(segs.size()), origin.x, origin.y, origin.z, breach.x, breach.y, breach.z));
    reason << "digging a " << path.size() << "-tile tunnel to water for the cistern";
    return true;
}

// The embark blueprint's aqueduct runs to whatever water it found on the
// whole map: Channelevened's went 180 tiles south and 11 levels up to a lake
// on the map edge, was dug about a third of the way and stalled, while a river
// ran ten tiles from the reserve. When the planned aqueduct still has a long
// way to go, plan a tap from the end of what is dug instead; if it is much
// shorter, drop the undug rest and dig the tap.
bool Plan::reroute_cistern_aqueduct(color_ostream & out, std::ostream & reason, bool commit)
{
    if (!m_c_reserve || !m_c_reserve->channel_enable.isValid())
    {
        reason << "no planned aqueduct";
        return false;
    }
    auto is_wall = [](df::coord t) -> bool
    {
        df::tiletype *tt = Maps::getTileType(t);
        return tt && ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) == tiletype_shape_basic::Wall;
    };
    auto is_aq = [](room *r) { return r->type == room_type::corridor && r->corridor_type == corridor_type::aqueduct; };
    // which dug aqueduct tiles are joined to the reserve (through its inlet
    // floodgate, which is in no aqueduct room: seed within 3 tiles of it)
    std::set<df::coord> open_all, joined;
    for (auto r : rooms_and_corridors)
        if (is_aq(r))
            for (int16_t x = r->min.x; x <= r->max.x; x++)
                for (int16_t y = r->min.y; y <= r->max.y; y++)
                    for (int16_t z = r->min.z; z <= r->max.z; z++)
                        if (!is_wall(df::coord(x, y, z)))
                            open_all.insert(df::coord(x, y, z));
    {
        static const int16_t N6[6][3] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
        std::list<df::coord> q;
        room *rv = m_c_reserve;
        for (auto t : open_all)
            if (rv->min.x - 3 <= t.x && t.x <= rv->max.x + 3 && rv->min.y - 3 <= t.y && t.y <= rv->max.y + 3 && rv->min.z <= t.z && t.z <= rv->max.z)
                if (joined.insert(t).second)
                    q.push_back(t);
        while (!q.empty())
        {
            df::coord t = q.front();
            q.pop_front();
            for (auto & d : N6)
            {
                df::coord n = t + df::coord(d[0], d[1], d[2]);
                if (open_all.count(n) && joined.insert(n).second)
                    q.push_back(n);
            }
        }
    }
    auto piece = [&](room *r, bool & any_open, bool & any_joined, bool & any_wall)
    {
        any_open = any_joined = any_wall = false;
        for (int16_t x = r->min.x; x <= r->max.x; x++)
            for (int16_t y = r->min.y; y <= r->max.y; y++)
                for (int16_t z = r->min.z; z <= r->max.z; z++)
                {
                    df::coord t(x, y, z);
                    if (is_wall(t))
                        any_wall = true;
                    else
                        any_open = true;
                    if (joined.count(t))
                        any_joined = true;
                }
    };
    if (commit)
    {
        for (auto r : rooms_and_corridors)
        {
            if (!is_aq(r))
                continue;
            bool o, j, w;
            piece(r, o, j, w);
            bool touches_live = false;
            if (r->abandoned && w && r->comment == "tunnel to water for the cistern")
            {
                // a tap piece still to dig right beside a live one is part of it
                for (auto r2 : rooms_and_corridors)
                    if (r2 != r && is_aq(r2) && !r2->abandoned &&
                        r->min.x <= r2->max.x + 1 && r2->min.x - 1 <= r->max.x &&
                        r->min.y <= r2->max.y + 1 && r2->min.y - 1 <= r->max.y &&
                        r->min.z <= r2->max.z && r2->min.z <= r->max.z)
                        touches_live = true;
            }
            if (r->abandoned && (j || touches_live))
            {
                // wrongly given up (joined to the reserve): back in the chain
                r->abandoned = false;
                bool held = false;
                for (auto r2 : rooms_and_corridors)
                    if (!r2->abandoned && std::find(r2->accesspath.begin(), r2->accesspath.end(), r) != r2->accesspath.end())
                        held = true;
                if (!held)
                    m_c_reserve->accesspath.push_back(r);
                if (r->status == room_status::dig && w)
                {
                    r->dig();
                    add_task(task_type::dig_room, r);
                }
                ai.debug(out, "cistern: an aqueduct piece joined to the reserve is back in the plan");
            }
            else if (!r->abandoned && o && !j && !w)
            {
                // dug out, but cut off from the reserve (the far end of a
                // stalled aqueduct): it can only ever hold up the gate test.
                // Its parents take over its own access path.
                r->abandoned = true;
                for (auto r2 : rooms_and_corridors)
                {
                    auto it = std::find(r2->accesspath.begin(), r2->accesspath.end(), r);
                    if (it == r2->accesspath.end())
                        continue;
                    r2->accesspath.erase(it);
                    for (auto ap : r->accesspath)
                        if (!ap->abandoned && std::find(r2->accesspath.begin(), r2->accesspath.end(), ap) == r2->accesspath.end())
                            r2->accesspath.push_back(ap);
                }
                ai.debug(out, "cistern: dropped an aqueduct piece cut off from the reserve");
            }
        }
    }
    std::vector<room *> aq;
    {
        std::list<room *> todo{m_c_reserve};
        std::set<room *> seen;
        while (!todo.empty())
        {
            room *r = todo.front();
            todo.pop_front();
            if (!seen.insert(r).second)
                continue;
            todo.insert(todo.end(), r->accesspath.begin(), r->accesspath.end());
            if (is_aq(r) && !r->abandoned)
                aq.push_back(r);
        }
    }
    int32_t undug = 0;
    std::set<df::coord> open;
    for (auto r : aq)
        for (int16_t x = r->min.x; x <= r->max.x; x++)
            for (int16_t y = r->min.y; y <= r->max.y; y++)
                for (int16_t z = r->min.z; z <= r->max.z; z++)
                {
                    df::coord t(x, y, z);
                    if (is_wall(t))
                        undug++;
                    else if (joined.count(t))
                        open.insert(t);
                }
    if (undug <= 40)
    {
        reason << "the aqueduct has only " << undug << " tiles left to dig";
        return false;
    }
    // branch from the dug tiles nearest real water
    std::vector<df::coord> water;
    {
        df::coord mn(32767, 32767, 32767), mx(-1, -1, -1);
        for (auto t : open)
        {
            mn = df::coord(std::min(mn.x, t.x), std::min(mn.y, t.y), std::min(mn.z, t.z));
            mx = df::coord(std::max(mx.x, t.x), std::max(mx.y, t.y), std::max(mx.z, t.z));
        }
        for (int16_t z = mn.z; z <= mx.z + 20; z++)
            for (int16_t x = mn.x - 60; x <= mx.x + 60; x++)
                for (int16_t y = mn.y - 60; y <= mx.y + 60; y++)
                {
                    df::tile_designation *td = Maps::getTileDesignation(df::coord(x, y, z));
                    if (td && !td->bits.liquid_type && td->bits.flow_size >= 4)
                        water.push_back(df::coord(x, y, z));
                }
    }
    std::vector<std::pair<int32_t, df::coord>> near;
    for (auto t : open)
    {
        int32_t d = std::numeric_limits<int32_t>::max();
        for (auto w : water)
            if (w.z >= t.z)
                d = std::min(d, int32_t(std::abs(w.x - t.x) + std::abs(w.y - t.y) + 2 * (w.z - t.z)));
        if (d != std::numeric_limits<int32_t>::max())
            near.push_back(std::make_pair(d, t));
    }
    std::sort(near.begin(), near.end(), [](const std::pair<int32_t, df::coord> & l, const std::pair<int32_t, df::coord> & r) { return l.first < r.first; });
    static const int16_t D4[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
    int32_t best_len = std::numeric_limits<int32_t>::max();
    df::coord best_at, best_from;
    int tries = 0;
    cistern_tap_ok_neighbours = &open;
    for (size_t i = 0; i < near.size() && tries < 16; i++)
    {
        df::coord t = near[i].second;
        for (auto & d : D4)
        {
            df::coord n = t + df::coord(d[0], d[1], 0);
            if (open.count(n) || !is_wall(n) || tries >= 16)
                continue;
            tries++;
            int32_t len = 0;
            std::ostringstream why;
            if (plan_cistern_tap(out, nullptr, why, n, t, false, &len) && len < best_len)
            {
                best_len = len;
                best_at = t;
                best_from = n;
            }
        }
    }
    cistern_tap_ok_neighbours = nullptr;
    if (!best_at.isValid())
    {
        reason << "no tunnel to water from the dug end of the aqueduct (" << undug << " tiles still to dig, " << tries << " starts tried)";
        return false;
    }
    if (best_len * 2 > undug)
    {
        reason << "the planned aqueduct (" << undug << " tiles to go) is not much longer than a tap (" << best_len << ")";
        return false;
    }
    reason << stl_sprintf("tap of %d tiles from (%d, %d, %d) instead of %d undug aqueduct tiles", best_len, best_at.x, best_at.y, best_at.z, undug);
    if (!commit)
        return true;

    // drop what isn't dug: wholly undug pieces are abandoned, a part-dug
    // straight piece shrinks to its dug run
    std::set<room *> dropped;
    for (auto r : aq)
    {
        df::coord mn(32767, 32767, 32767), mx(-1, -1, -1);
        bool any_open = false;
        for (int16_t x = r->min.x; x <= r->max.x; x++)
            for (int16_t y = r->min.y; y <= r->max.y; y++)
                for (int16_t z = r->min.z; z <= r->max.z; z++)
                {
                    df::coord t(x, y, z);
                    if (is_wall(t))
                        continue;
                    any_open = true;
                    mn = df::coord(std::min(mn.x, x), std::min(mn.y, y), std::min(mn.z, z));
                    mx = df::coord(std::max(mx.x, x), std::max(mx.y, y), std::max(mx.z, z));
                }
        for (int16_t x = r->min.x; x <= r->max.x; x++)
            for (int16_t y = r->min.y; y <= r->max.y; y++)
                for (int16_t z = r->min.z; z <= r->max.z; z++)
                {
                    df::coord t(x, y, z);
                    bool keep = any_open && mn.x <= x && x <= mx.x && mn.y <= y && y <= mx.y && mn.z <= z && z <= mx.z;
                    if (!keep && is_wall(t))
                        Maps::getTileDesignation(t)->bits.dig = tile_dig_designation::No;
                }
        if (!any_open)
        {
            r->abandoned = true;
            dropped.insert(r);
        }
        else if (mn != r->min || mx != r->max)
        {
            r->min = mn;
            r->max = mx;
            r->status = room_status::dug;
        }
    }
    for (auto r : rooms_and_corridors)
    {
        r->accesspath.erase(std::remove_if(r->accesspath.begin(), r->accesspath.end(), [&dropped](room *a) { return dropped.count(a) != 0; }), r->accesspath.end());
    }
    std::ostringstream why;
    cistern_tap_ok_neighbours = &open;
    bool tapped = plan_cistern_tap(out, nullptr, why, best_from, best_at, true, nullptr);
    cistern_tap_ok_neighbours = nullptr;
    if (!tapped)
    {
        reason << "; planning the tap failed: " << why.str();
        return false;
    }
    m_c_testgate_delay = 2;
    ai.debug(out, stl_sprintf("cistern: rerouted the aqueduct: tap of %d tiles from (%d, %d, %d), %d undug tiles and %d pieces dropped", best_len, best_at.x, best_at.y, best_at.z, undug, int(dropped.size())));
    return true;
}

// The tap's stair comes up on open ground (miners dig it from there, and the
// breach is channelled from above), so until it is shut the reserve is a
// public walkway: Channelevened's dwarves walked down it, through the reserve
// and on, and the gate test never found it empty. Before the breach, a hatch
// goes on the stairhead and is locked (only once nobody is inside).
bool Plan::seal_tap_stair(color_ostream &, std::ostream & reason)
{
    room *stair = nullptr;
    for (auto r : rooms_and_corridors)
    {
        if (r->type == room_type::corridor && r->corridor_type == corridor_type::aqueduct && !r->abandoned &&
            r->comment == "tunnel to water for the cistern" && r->max.z > r->min.z)
        {
            stair = r;
        }
    }
    if (!stair)
        return true;   // a blueprint aqueduct: nothing of ours to shut
    df::coord top(stair->min.x, stair->min.y, stair->max.z);
    for (auto f : stair->layout)
    {
        if (f->type != layout_type::hatch)
            continue;
        auto hatch = f->bld_id != -1 ? virtual_cast<df::building_hatchst>(df::building::find(f->bld_id)) : nullptr;
        if (!hatch || hatch->getBuildStage() < hatch->getMaxBuildStage())
        {
            reason << "waiting for the hatch over the tunnel's stair";
            return false;
        }
        hatch->door_flags.bits.forbidden = 1;
        return true;
    }
    furniture *f = new furniture();
    f->type = layout_type::hatch;
    f->pos = top - stair->min;
    stair->layout.push_back(f);
    add_task(task_type::furnish, stair, f);
    reason << "ordered a hatch over the tunnel's stair";
    return false;
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
    // DF 53 clears the dig flag once a job exists, so look for the job too
    bool queued = Maps::getTileDesignation(s0)->bits.dig == tile_dig_designation::Channel;
    for (auto job : world->jobs.list)
    {
        if (job->pos == s0 && ENUM_ATTR(job_type, type, job->job_type) == job_type_class::Digging)
            queued = true;
    }
    if (!queued)
    {
        ai.debug(out, "[PIT] pit shaft channeled; cutting off its access stair");
        AI::dig_tile(s0, tile_dig_designation::Channel);
    }
    reason << "channeling the top of the pit shaft's access stair";
    return false;
}
