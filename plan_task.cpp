#include "ai.h"
#include <cstdio>
#include <fstream>
#include <set>
#include "debug.h"
#include "plan.h"

#include "modules/Buildings.h"
#include "modules/Maps.h"

#include "df/abstract_building.h"
#include "df/general_ref.h"
#include "df/building_cagest.h"
#include "df/building_trapst.h"
#include "df/item_cagest.h"
#include "df/tile_occupancy.h"
#include "df/job.h"
#include "df/job_list_link.h"
#include "df/world.h"
#include "df/item.h"
#include "df/building_farmplotst.h"

REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(world);
REQUIRE_GLOBAL(cur_year_tick);

static bool want_reupdate = false;

void Plan::update(color_ostream &)
{
    last_update_year = *cur_year;
    last_update_tick = *cur_year_tick;
    if (bg_idx_generic == tasks_generic.end())
    {
        bg_idx_generic = tasks_generic.begin();

        nrdig.clear();
        for (auto it = tasks_generic.begin(); it != tasks_generic.end(); it++)
        {
            task *t = *it;
            if ((t->type != task_type::dig_room && t->type != task_type::dig_room_immediate) || (t->r->type == room_type::corridor && (t->r->corridor_type == corridor_type::veinshaft || t->r->corridor_type == corridor_type::outpost)))
                continue;
            // a pit's hatch and dump tiles wait (possibly a long time) for the
            // shaft below; they must not hold dig slots meanwhile
            if (t->r->type == room_type::pitcage || t->r->type == room_type::garbagedump)
                continue;
            df::coord size = t->r->size();
            if (t->r->type != room_type::corridor || size.z > 1)
                nrdig[t->r->queue]++;
            if (t->r->type != room_type::corridor && size.x * size.y * size.z >= 10)
                nrdig[t->r->queue]++;
        }

        want_reupdate = false;
        events.onupdate_register_once("df-ai plan bg generic", [this](color_ostream & out) -> bool
        {
            if (!Core::getInstance().isMapLoaded())
            {
                return true;
            }

            if (bg_idx_generic == tasks_generic.end())
            {
                if (want_reupdate)
                {
                    update(out);
                }
                return true;
            }
            std::ostringstream reason;
            task & t = **bg_idx_generic;

            auto any_immediate = [this]() -> bool
            {
                for (auto t : tasks_generic)
                {
                    if (t->type == task_type::dig_room_immediate)
                    {
                        return true;
                    }
                }
                return false;
            };

            bool del = false;
            switch (t.type)
            {
            case task_type::want_dig:
            {
                size_t wantdig_max = ai.stocks.count_total.count(stock_item::pick) ? std::max(ai.stocks.count_total.at(stock_item::pick), 2) : 2;
                if (any_immediate())
                {
                    reason << "waiting for more important room to be dug";
                }
                else if (t.r->is_dug() || nrdig[t.r->queue] < wantdig_max)
                {
                    digroom(out, t.r);
                    del = true;
                }
                else
                {
                    reason << "dig queue " << t.r->queue << " has " << nrdig[t.r->queue] << " of " << wantdig_max << " slots already filled";
                }
                break;
            }
            case task_type::dig_room:
            case task_type::dig_room_immediate:
                // a room still being dug when its neighbour turned out to
                // be an aqueduct (planned later, or a fort from before
                // this check) stops here, before the last wall goes
                if (t.r->abandoned || (!t.r->is_dug() && keep_off_aqueduct(out, t.r)))
                {
                    del = true;
                    break;
                }
                fixup_open(out, t.r);
                if (t.r->is_dug(reason))
                {
                    t.r->status = room_status::dug;
                    construct_room(out, t.r);
                    want_reupdate = true; // wantdig asap
                    del = true;
                }
                else if ([&]() -> bool
                {
                    // stalled only if nothing on the way to it can be dug
                    // either (a room waits for its corridor: that's progress)
                    std::vector<room *> todo{t.r};
                    std::set<room *> seen;
                    while (!todo.empty())
                    {
                        room *x = todo.back();
                        todo.pop_back();
                        if (!seen.insert(x).second || seen.size() > 40)
                            continue;
                        if (x->status == room_status::dig || x->status == room_status::plan || x == t.r)
                        {
                            if (dig_reachable(x) && !x->is_dug())
                                return false;
                        }
                        for (auto ap : x->accesspath)
                            todo.push_back(ap);
                    }
                    return true;
                }())
                {
                    // no tile of it a miner can get at (a cavern outpost
                    // behind a sealed cavern: 12 corridors waited for years).
                    // After two weeks it is set aside, its designations
                    // cleared, and retried when something can reach it.
                    int32_t now = *cur_year * 403200 + *cur_year_tick;
                    if (t.stalled_since == -1 || now < t.stalled_since)
                        t.stalled_since = now;
                    reason << "; no miner can reach it (" << (now - t.stalled_since) / 1200 << " days)";
                    if (now - t.stalled_since > 14 * 1200 &&
                        !(t.r->type == room_type::corridor && t.r->corridor_type == corridor_type::aqueduct))
                    {
                        for (int16_t x = t.r->min.x; x <= t.r->max.x; x++)
                            for (int16_t y = t.r->min.y; y <= t.r->max.y; y++)
                                for (int16_t z = t.r->min.z; z <= t.r->max.z; z++)
                                {
                                    auto td = Maps::getTileDesignation(df::coord(x, y, z));
                                    if (td)
                                        td->bits.dig = tile_dig_designation::No;
                                }
                        t.r->abandoned = true;
                        t.r->parked_until = now + 28 * 1200;
                        ai.debug(out, "[STALL] no miner can reach " + AI::describe_room(t.r) + ": set aside until one can");
                        del = true;
                    }
                }
                else
                {
                    t.stalled_since = -1;
                    t.r->dig();
                    if (t.r->is_food_room())
                    {
                        // food first: this room and the corridors to it
                        std::vector<room *> todo{t.r};
                        std::set<room *> seen;
                        while (!todo.empty())
                        {
                            room *fr = todo.back();
                            todo.pop_back();
                            if (!seen.insert(fr).second || seen.size() > 40)
                                continue;
                            fr->set_dig_priority(2);
                            for (auto ap : fr->accesspath)
                                todo.push_back(ap);
                        }
                    }
                    // DF never makes a dig job for a hidden tile whose only
                    // way in is a staircase below or above it (miners can't
                    // "see" up a stair): 18 rooms, the wood furnace among
                    // them, waited forever. Uncover such tiles.
                    for (int16_t z = t.r->min.z; z <= t.r->max.z; z++)
                        for (int16_t x = t.r->min.x; x <= t.r->max.x; x++)
                            for (int16_t y = t.r->min.y; y <= t.r->max.y; y++)
                            {
                                df::coord c(x, y, z);
                                auto des = Maps::getTileDesignation(c);
                                if (!des || !des->bits.hidden || des->bits.dig == tile_dig_designation::No)
                                    continue;
                                for (int dz : {-1, 1})
                                {
                                    df::coord n(x, y, z + dz);
                                    auto nd = Maps::getTileDesignation(n);
                                    auto nt = Maps::getTileType(n);
                                    if (!nd || !nt || nd->bits.hidden)
                                        continue;
                                    auto sh = ENUM_ATTR(tiletype, shape, *nt);
                                    if ((dz < 0 && (sh == tiletype_shape::STAIR_UP || sh == tiletype_shape::STAIR_UPDOWN)) ||
                                        (dz > 0 && (sh == tiletype_shape::STAIR_DOWN || sh == tiletype_shape::STAIR_UPDOWN)))
                                    {
                                        des->bits.hidden = 0;
                                        break;
                                    }
                                }
                            }
                }
                break;
            case task_type::construct_tradedepot:
                del = try_construct_tradedepot(out, t.r, reason);
                break;
            case task_type::construct_workshop:
                del = try_construct_workshop(out, t.r, reason);
                break;
            case task_type::construct_farmplot:
                del = try_construct_farmplot(out, t.r, reason);
                break;
            case task_type::construct_furnace:
                del = try_construct_furnace(out, t.r, reason);
                break;
            case task_type::construct_stockpile:
                del = try_construct_stockpile(out, t.r, reason);
                break;
            case task_type::construct_activityzone:
                del = try_construct_activityzone(out, t.r, reason);
                break;
            case task_type::construct_windmill:
                del = try_construct_windmill(out, t.r, reason);
                break;
            case task_type::monitor_farm_irrigation:
                del = monitor_farm_irrigation(out, t.r, reason);
                break;
            case task_type::setup_farmplot:
                del = try_setup_farmplot(out, t.r, reason);
                break;
            case task_type::furnish:
                break;
            case task_type::check_furnish:
                break;
            case task_type::check_construct:
                del = try_endconstruct(out, t.r, reason);
                break;
            case task_type::dig_cistern:
                del = try_digcistern(out, t.r);
                break;
            case task_type::dig_garbage:
                del = try_digpitshaft(out, t.r, reason);
                break;
            case task_type::check_idle:
                del = checkidle(out, reason);
                break;
            case task_type::check_rooms:
                checkrooms(out);
                break;
            case task_type::monitor_cistern:
                monitor_cistern(out, reason);
                break;
            case task_type::monitor_room_value:
                del = monitor_room_value(out, t.r, reason);
                break;
            case task_type::rescue_caged:
                del = rescue_caged(out, t.r, t.f, t.item_id, reason);
                break;
            case task_type::_task_type_count:
                break;
            }

            if (del)
            {
                delete *bg_idx_generic;
                tasks_generic.erase(bg_idx_generic++);
            }
            else
            {
                t.last_status = reason.str();
                bg_idx_generic++;
            }
            return false;
        });
    }
    if (bg_idx_furniture == tasks_furniture.end())
    {
        bg_idx_furniture = tasks_furniture.begin();

        cache_nofurnish.clear();
        // a pass over every furniture task is done: what they waited for is
        // the demand the stock targets follow (73 statues waited, and df-ai
        // never ordered one)
        furnish_demand_last.swap(furnish_waiting);
        furnish_waiting.clear();

        events.onupdate_register_once("df-ai plan bg furniture", [this](color_ostream & out) -> bool
        {
            if (!Core::getInstance().isMapLoaded())
            {
                return true;
            }

            if (bg_idx_furniture == tasks_furniture.end())
            {
                return true;
            }
            std::ostringstream reason;
            task & t = **bg_idx_furniture;

            bool del = false;
            switch (t.type)
            {
            case task_type::furnish:
                // a room called off (a seal for a tap that came back into
                // use) gets nothing more built in it
                del = t.r && t.r->abandoned ? true : try_furnish(out, t.r, t.f, reason);
                break;
            case task_type::check_furnish:
                del = t.r && t.r->abandoned ? true : try_endfurnish(out, t.r, t.f, reason);
                break;
            default:
                break;
            }

            if (del)
            {
                delete *bg_idx_furniture;
                tasks_furniture.erase(bg_idx_furniture++);
            }
            else
            {
                t.last_status = reason.str();
                bg_idx_furniture++;
            }
            return false;
        });
    }
}

task *Plan::is_digging()
{
    for (auto t : tasks_generic)
    {
        if ((t->type == task_type::want_dig || t->type == task_type::dig_room || t->type == task_type::dig_room_immediate) && t->r->type != room_type::corridor)
        {
            return t;
        }
    }
    return nullptr;
}

bool Plan::is_idle()
{
    if (!tasks_furniture.empty())
    {
        return false;
    }
    for (auto it = tasks_generic.begin(); it != tasks_generic.end(); it++)
    {
        task *t = *it;
        if (t->type != task_type::monitor_cistern && t->type != task_type::check_rooms && t->type != task_type::check_idle)
            return false;
    }
    return true;
}

bool Plan::checkidle(color_ostream & out, std::ostream & reason)
{
    // Smoothing is capped at 1000 outstanding jobs, and rooms are smoothed
    // only once when finished, so keep topping the queue up from finished
    // rooms that still have rough tiles (a few rooms per pass).
    {
        static size_t smooth_cursor = 0;
        size_t outstanding = 0;
        for (auto j : world->jobs.list)
        {
            if (j->job_type == job_type::SmoothWall || j->job_type == job_type::SmoothFloor ||
                j->job_type == job_type::DetailWall || j->job_type == job_type::DetailFloor)
                outstanding++;
        }
        for (int n = 0; outstanding < 500 && n < 8 && !rooms_and_corridors.empty(); n++)
        {
            smooth_cursor = (smooth_cursor + 1) % rooms_and_corridors.size();
            room *r = rooms_and_corridors[smooth_cursor];
            if (r && r->status == room_status::finished && !r->outdoor)
                smooth_room(out, r);
        }
    }


    // The overseer's construction order (Overseer's Desk, user request): rooms
    // listed in dfhack-config/dfai-overseer-dig.txt ("x,y,z" of a room's min
    // corner, one per line, in order) are dug before df-ai's own priorities,
    // even while df-ai has a room of its own queued (each starts once).
    {
        std::ifstream f("dfhack-config/dfai-overseer-dig.txt");
        std::string line;
        while (f && std::getline(f, line))
        {
            int x, y, z;
            if (sscanf(line.c_str(), "%d,%d,%d", &x, &y, &z) != 3)
                continue;
            for (auto r : rooms_and_corridors)
            {
                if (!r || r->min.x != x || r->min.y != y || r->min.z != z)
                    continue;
                if (r->status == room_status::plan)
                {
                    if (digroom(out, r, true))
                    {
                        reason << "overseer's order: " << AI::describe_room(r);
                        ai.debug(out, "[OVERSEER] digging " + AI::describe_room(r) + " (construction order)");
                        return false;
                    }
                }
                break;
            }
        }
    }

    // Food first: while the fort isn't fed, the next food room (farm plot,
    // butcher, farmer's workshop, kitchen, still, quern, fishery, mechanic's
    // for the well) jumps the queue, one at a time. Channelevened starved in
    // year two with its butcher, farmer's workshop, kitchen and mechanic's
    // workshop never dug, all behind a noble's office queued for value 250.
    // (autolabor won't make fishers without a fishery or hunters without a
    // butcher, so these unlock food as well as process it.)
    if (!food_secure())
    {
        bool food_digging = false;
        for (auto t : tasks_generic)
        {
            if ((t->type == task_type::dig_room || t->type == task_type::dig_room_immediate) && t->r->is_food_room() &&
                !(t->r->type == room_type::workshop && (t->r->workshop_type == workshop_type::Still || t->r->workshop_type == workshop_type::Quern)))
            {
                food_digging = true;
                break;
            }
        }
        if (!food_digging)
        {
            // what makes food comes first; a kind that already has one
            // dug or built is skipped (a second still feeds nobody)
            auto rank = [](room *r) -> int
            {
                if (r->type == room_type::farmplot)
                    return 5;
                switch (r->workshop_type)
                {
                    case workshop_type::Butchers: return 0; // and autolabor makes hunters
                    case workshop_type::Fishery: return 1;  // and autolabor makes fishers
                    case workshop_type::Farmers: return 2;
                    case workshop_type::Mechanics: return 3; // mechanisms for the well
                    case workshop_type::Kitchen: return 4;
                    case workshop_type::Quern: return 6;
                    case workshop_type::Still: return 7;
                    default: return 9;
                }
            };
            auto kind = [](room *r) -> int
            {
                return r->type == room_type::farmplot ? -1 : int(r->workshop_type);
            };
            std::set<int> have;
            size_t farms_have = 0;
            for (auto r : rooms_and_corridors)
            {
                if (r && r->status >= room_status::dig && r->is_food_room())
                {
                    if (r->type == room_type::farmplot)
                        farms_have++;
                    else
                        have.insert(kind(r));
                }
            }
            room *best = nullptr;
            for (auto r : rooms_and_corridors)
            {
                if (!r || r->status != room_status::plan || !r->is_food_room() || r->outdoor)
                    continue;
                if (r->type == room_type::farmplot ? farms_have >= 4 : have.count(kind(r)) != 0)
                    continue;
                if (!best || rank(r) < rank(best))
                    best = r;
            }
            if (best && digroom(out, best, true))
            {
                reason << "food first: " << AI::describe_room(best);
                ai.debug(out, "[FOOD] digging " + AI::describe_room(best) + " ahead of the queue (the fort is not fed)");
                return false;
            }
        }
    }

    for (auto t : tasks_generic)
    {
        if ((t->type == task_type::want_dig || t->type == task_type::dig_room_immediate) && t->r->type != room_type::corridor && t->r->queue == 0)
        {
            reason << "already have queued room: " << AI::describe_room(t->r);
            return false;
        }
    }

    if (!priorities.empty())
    {
        for (auto & priority : priorities)
        {
            if (priority.working)
            {
                bool any_active_task = false;
                for (auto t : tasks_generic)
                {
                    if (priority.match_task(t))
                    {
                        any_active_task = true;
                        break;
                    }
                }
                if (!any_active_task)
                {
                    for (auto t : tasks_furniture)
                    {
                        if (priority.match_task(t))
                        {
                            any_active_task = true;
                            break;
                        }
                    }
                }
                if (!any_active_task)
                {
                    priority.working = false;
                }
            }

            if (priority.act(ai, out, reason))
            {
                break;
            }
        }
        return false;
    }

    reason << "no priority list!";
    return false;
}

void Plan::checkrooms(color_ostream & out)
{
    check_parked(out);
    size_t ncheck = 8;
    for (size_t i = ncheck * 4; i > 0; i--)
    {
        if (checkroom_idx < rooms_and_corridors.size())
        {
            room* r = rooms_and_corridors.at(checkroom_idx);
            if (r->status == room_status::plan && r->build_when_accessible)
            {
                bool all_ready = true;
                for (auto ap : r->accesspath)
                {
                    if (ap->status < room_status::dug)
                    {
                        all_ready = false;
                    }
                }

                if (all_ready)
                {
                    wantdig(out, r, 2);
                }
            }

            if (r->status != room_status::plan)
            {
                checkroom(out, r);
                ncheck--;
            }
        }
        checkroom_idx++;
        if (ncheck <= 0)
            break;
    }
    if (checkroom_idx >= rooms_and_corridors.size())
        checkroom_idx = 0;
}

// ensure room was not tantrumed etc
void Plan::checkroom(color_ostream & out, room *r)
{
    if (r->status == room_status::plan || r->abandoned)
    {
        return;
    }

    // fix missing walls/staircases
    fixup_open(out, r);
    // designation cancelled: damp stone, cave-in, or tree
    r->dig();

    if (r->required_value > 0 && r->compute_value() < r->required_value)
    {
        add_task(task_type::monitor_room_value, r);
    }

    if (r->status == room_status::dug || r->status == room_status::finished)
    {
        // tantrumed furniture
        for (auto it = r->layout.begin(); it != r->layout.end(); it++)
        {
            furniture *f = *it;
            if (f->ignore)
                continue;
            // a well that was never built (its cistern was dry when the room
            // was furnished) gets built once there is water: the furnish task
            // waits for it (add_task keeps one per well)
            if (f->type == layout_type::well && f->bld_id == -1)
                add_task(task_type::furnish, r, f);
            df::coord t = r->min + f->pos;
            // a stale id (e.g. saved in a timeline a crash reload threw away)
            // can name some other building elsewhere: treat it as missing
            df::building *fb = f->bld_id != -1 ? df::building::find(f->bld_id) : nullptr;
            bool stale = fb && (fb->z != t.z || t.x < fb->x1 || t.x > fb->x2 || t.y < fb->y1 || t.y > fb->y2);
            if (f->bld_id != -1 && (!fb || stale))
            {
                std::ostringstream str;
                str << "fix furniture " << f->type << " in " << AI::describe_room(r);
                ai.debug(out, str.str());
                f->bld_id = -1;

                add_task(task_type::furnish, r, f);
            }
            if (f->construction != construction_type::NONE)
            {
                std::ostringstream discard;
                try_furnish_construction(out, f->construction, t, discard);
            }
        }
        // tantrumed building
        if (r->bld_id != -1 && !r->dfbuilding())
        {
            ai.debug(out, "rebuild " + AI::describe_room(r));
            r->bld_id = -1;
            construct_room(out, r);
        }
        // A finished depot/workshop/furnace that lost its building id entirely
        // (destroyed by a ghost, or the reference was lost across a reload)
        // was never rebuilt; the depot stayed "Done" while caravans waited.
        else if (r->status == room_status::finished && r->bld_id == -1 &&
            (r->type == room_type::tradedepot || r->type == room_type::workshop || r->type == room_type::furnace))
        {
            ai.debug(out, "rebuild missing " + AI::describe_room(r));
            construct_room(out, r);
        }
    }
}

// queue a room for digging when other dig jobs are finished
bool Plan::surface_farm_ok(room *r)
{
    if (!r || r->type != room_type::farmplot || !r->outdoor)
        return true;
    const df::coord & mn = ai.pop.defense_min;
    const df::coord & mx = ai.pop.defense_max;
    if (mn.isValid() && mx.isValid())
        return r->min.x > mn.x && r->max.x < mx.x && r->min.y > mn.y && r->max.y < mx.y;
    if (!fort_entrance)
        return false;
    df::coord e = fort_entrance->pos();
    const int16_t R = 9;
    return r->min.x >= e.x - R && r->max.x <= e.x + R && r->min.y >= e.y - R && r->max.y <= e.y + R;
}

// An aqueduct is always full of river water under pressure (its breach on
// the river has no gate; the floodgate is at the cistern end), so anything
// dug next to it fills to one level under the river. Roughnessbell (year 180):
// a corridor planned alongside the aqueduct's stair shaft was dug into it and
// 13 levels flooded, 19 dwarves drowned. A room opens into an aqueduct if one
// of its tiles is beside an aqueduct tile on the same level (diagonals too:
// water flows diagonally), or, for a room over several levels (stairs), right
// above or below one. Cisterns and the aqueducts themselves are exempt.
bool Plan::opens_into_aqueduct(room *r, df::coord & where)
{
    if (r->type == room_type::cistern || (r->type == room_type::corridor && r->corridor_type == corridor_type::aqueduct))
        return false;
    bool multi_z = r->min.z != r->max.z;
    for (auto a : rooms_and_corridors)
    {
        if (!a || a->abandoned || a->type != room_type::corridor || a->corridor_type != corridor_type::aqueduct)
            continue;
        // quick box test: within 1 tile in x/y, and on a shared level (or
        // one level apart for a room with stairs)
        int dz = multi_z ? 1 : 0;
        if (r->max.x < a->min.x - 1 || r->min.x > a->max.x + 1 || r->max.y < a->min.y - 1 || r->min.y > a->max.y + 1 ||
            r->max.z < a->min.z - dz || r->min.z > a->max.z + dz)
            continue;
        for (int16_t x = r->min.x; x <= r->max.x; x++)
            for (int16_t y = r->min.y; y <= r->max.y; y++)
                for (int16_t z = r->min.z; z <= r->max.z; z++)
                {
                    for (int16_t ax = std::max(a->min.x, int16_t(x - 1)); ax <= std::min(a->max.x, int16_t(x + 1)); ax++)
                        for (int16_t ay = std::max(a->min.y, int16_t(y - 1)); ay <= std::min(a->max.y, int16_t(y + 1)); ay++)
                        {
                            if (z >= a->min.z && z <= a->max.z)
                            {
                                where = df::coord(ax, ay, z);
                                return true;
                            }
                            if (multi_z && ax == x && ay == y && ((z + 1 >= a->min.z && z + 1 <= a->max.z) || (z - 1 >= a->min.z && z - 1 <= a->max.z)))
                            {
                                where = df::coord(ax, ay, z + 1 >= a->min.z && z + 1 <= a->max.z ? z + 1 : z - 1);
                                return true;
                            }
                        }
                }
    }
    return false;
}

// Never dig a room that opens into an aqueduct: drop it for good (no retry)
// and clear any dig designations it already has.
bool Plan::keep_off_aqueduct(color_ostream & out, room *r)
{
    df::coord where;
    if (!opens_into_aqueduct(r, where))
        return false;
    for (int16_t x = r->min.x; x <= r->max.x; x++)
        for (int16_t y = r->min.y; y <= r->max.y; y++)
            for (int16_t z = r->min.z; z <= r->max.z; z++)
            {
                auto td = Maps::getTileDesignation(df::coord(x, y, z));
                auto tt = Maps::getTileType(df::coord(x, y, z));
                // only tiles not dug yet; an open tile stays as it is
                if (td && tt && ENUM_ATTR(tiletype, shape, *tt) == tiletype_shape::WALL)
                    td->bits.dig = tile_dig_designation::No;
            }
    r->abandoned = true;
    r->parked_until = -1; // never retried
    r->queue_dig = false;
    ai.debug(out, stl_sprintf("[WATER] not digging %s: it would open into the aqueduct at (%d, %d, %d), which carries river water under pressure",
        AI::describe_room(r).c_str(), where.x, where.y, where.z));
    return true;
}

bool Plan::wantdig(color_ostream & out, room *r, int32_t queue)
{
    if (r->queue_dig || r->status != room_status::plan || r->abandoned)
    {
        return false;
    }
    if (!surface_farm_ok(r))
    {
        return false;
    }
    if (keep_off_aqueduct(out, r))
    {
        return false;
    }

    if (queue != 0)
    {
        r->queue = queue;
    }
    ai.debug(out, "wantdig " + AI::describe_room(r));
    r->queue_dig = true;
    r->dig(true);
    add_task(task_type::want_dig, r);
    return true;
}

bool Plan::digroom(color_ostream & out, room *r, bool immediate)
{
    if (r->status != room_status::plan || r->abandoned)
        return false;
    if (!surface_farm_ok(r))
        return false;
    if (keep_off_aqueduct(out, r))
        return false;
    ai.debug(out, "digroom " + AI::describe_room(r));
    r->queue_dig = false;
    r->status = room_status::dig;
    fixup_open(out, r);
    r->dig();

    add_task(immediate ? task_type::dig_room_immediate : task_type::dig_room, r);

    for (auto it = r->accesspath.begin(); it != r->accesspath.end(); it++)
    {
        digroom(out, *it, immediate);
    }

    for (auto f : r->layout)
    {
        if (f->type == layout_type::floodgate)
        {
            continue;
        }

        add_task(task_type::furnish, r, f);
    }

    ai.find_room(room_type::stockpile, [this, &out, r, immediate](room *r_) -> bool
    {
        if (r_->workshop != r)
        {
            return false;
        }

        // dig associated stockpiles
        digroom(out, r_, immediate);

        // search all stockpiles in case there's more than one
        return false;
    });

    df::coord size = r->size();
    if ((r->type != room_type::corridor || size.z > 1) && r->type != room_type::pitcage && r->type != room_type::garbagedump)
    {
        nrdig[r->queue]++;
        if (size.x * size.y * size.z >= 10)
            nrdig[r->queue]++;
    }

    return true;
}

class FinalizeLocationExclusive : public ExclusiveCallback
{
    AI & ai;
    room *r;
public:
    FinalizeLocationExclusive(AI & ai, room *r) :
        ExclusiveCallback("finalize location " + AI::describe_room(r)),
        ai(ai),
        r(r)
    {}

    virtual void Run(color_ostream & out)
    {
        if (r->location_type == location_type::temple && r->data2 != -1)
        {
            FinalizeTemple(out);
        }
    }

    void FinalizeTemple(color_ostream & out)
    {
        // Recognizing a priesthood is done through the v50 locations screen,
        // which df-ai cannot operate. The temple still works without one.
        static bool warned = false;
        if (!warned)
        {
            warned = true;
            ai.debug(out, "[v50] recognizing a priesthood for " + AI::describe_room(r) + " must be done manually for now");
        }
    }
};

bool Plan::monitor_room_value(color_ostream & out, room *r, std::ostream & reason)
{
    if (r->required_value <= 0)
    {
        return true;
    }

    int32_t value = r->compute_value();
    if (value < 0)
    {
        reason << "cannot compute room value";

        for (auto f : r->layout)
        {
            if (f->makeroom)
            {
                reason << " (waiting for " << ai.describe_furniture(f) << " to be built)";
                break;
            }
        }

        return false;
    }

    if (value >= r->required_value)
    {
        if (r->type == room_type::location)
        {
            events.queue_exclusive(std::make_unique<FinalizeLocationExclusive>(ai, r));
        }

        return true;
    }

    reason << "room value is " << (r->required_value - value) << " too low";

    if (!food_secure())
    {
        reason << " (smoothing waits for food and drink)";
        return false;
    }

    if (!smooth_room(out, r, false))
    {
        reason << " (smoothing)";
    }
    else if (!smooth_room(out, r, true))
    {
        reason << " (engraving)";
    }
    else
    {
        // TODO: build statues, etc.
        reason << " (TODO)";
    }

    return false;
}

bool Plan::rescue_caged(color_ostream & out, room *r, furniture *f, int32_t item_id, std::ostream & reason)
{
    auto cage = virtual_cast<df::item_cagest>(df::item::find(item_id));
    if (!cage)
    {
        // cage no longer exists.
        return true;
    }

    df::unit *prisoner = nullptr;
    for (auto ref : cage->general_refs)
    {
        if (ref->getType() == general_ref_type::CONTAINS_UNIT)
        {
            prisoner = ref->getUnit();
            break;
        }
    }
    df::building_cagest *cage_bld = nullptr;
    for (auto ref : cage->general_refs)
    {
        if (ref->getType() == general_ref_type::BUILDING_HOLDER)
        {
            cage_bld = virtual_cast<df::building_cagest>(ref->getBuilding());
            break;
        }
    }

    if (prisoner == nullptr)
    {
        // there's no longer someone in the cage.
        // if we secured the cage to the floor, free it up.
        if (cage_bld)
        {
            Buildings::deconstruct(cage_bld);
        }
        return true;
    }

    auto lever = virtual_cast<df::building_trapst>(df::building::find(f->bld_id));
    if (!lever || lever->getBuildStage() != lever->getMaxBuildStage())
    {
        reason << "cannot free " << AI::describe_unit(prisoner) << ": missing lever";
        return false;
    }
    DFAI_ASSERT(lever->trap_type == trap_type::Lever, "lever is trap_type::" + enum_item_key(lever->trap_type));

    reason << "freeing " << AI::describe_unit(prisoner) << ": ";

    // step 1: someone's trapped in a cage. check for a free tile in the "release zone"
    // and create a job to secure the cage to that spot.
    if (!cage_bld)
    {
        for (auto ref : cage->specific_refs)
        {
            if (ref->type == specific_ref_type::JOB)
            {
                reason << "waiting for cage to be secured to floor";
                return false;
            }
        }

        df::coord free_tile;
        for (int16_t x = r->min.x; x <= r->max.x; x++)
        {
            for (int16_t y = r->min.y; y <= r->max.y; y++)
            {
                df::coord c(x, y, r->min.z);

                auto tt = *Maps::getTileType(c);
                if (ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, tt)) != tiletype_shape_basic::Floor)
                {
                    continue;
                }

                if (Maps::getTileOccupancy(c)->bits.building != tile_building_occ::None)
                {
                    continue;
                }

                free_tile = c;
                break;
            }
        }

        if (free_tile.isValid())
        {
            auto bld = Buildings::allocInstance(free_tile, building_type::Cage);
            Buildings::setSize(bld, df::coord(1, 1, 1));

            std::vector<df::item*> cage_item;
            cage_item.push_back(cage);
            Buildings::constructWithItems(bld, cage_item);

            reason << "waiting for cage to be secured to floor";
            return false;
        }

        reason << "waiting for space in release zone";

        return false;
    }

    // step 2: the cage has been secured in the "release zone". make sure we have two
    // mechanisms and tell the dwarves to link the lever to the cage.
    furniture cage_f;
    cage_f.bld_id = cage_bld->id;
    if (!link_lever(out, f, &cage_f, reason))
    {
        return false;
    }

    // step 3: the cage is linked to the lever. give it a pull. if all goes well,
    // we'll end up freeing the task on the next iteration as the cage will be empty
    // and left on the floor as an item.
    pull_lever(out, f, reason);

    // we could deconstruct the lever periodically to reclaim mechanisms, but the
    // potential humor of having a lever with hundreds of mechanisms outweighs the
    // cost of a few extra boulders being needed in most forts.
    return false;
}

void Plan::add_task(task_type::type type, room *r, furniture *f, int32_t item_id)
{
    auto & tasks = (type == task_type::furnish || type == task_type::check_furnish) ? tasks_furniture : tasks_generic;
    for (auto t : tasks)
    {
        if (t->type == type && t->r == r && t->f == f && t->item_id == item_id)
        {
            return;
        }
    }
    tasks.push_back(new task(type, r, f, item_id));
}
