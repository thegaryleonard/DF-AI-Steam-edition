#include "ai.h"
#include "plan.h"

#include "modules/Buildings.h"
#include "modules/Units.h"

#include "df/building_civzonest.h"
#include "df/general_ref.h"
#include "df/squad.h"
#include "df/world.h"
#include "df/buildings_other_id.h"

REQUIRE_GLOBAL(world);
#include "df/squad_use_flags.h"
#include "modules/Military.h"
#include "df/caste_raw.h"
#include "df/creature_raw.h"
#include "df/squad.h"

void Plan::new_citizen(color_ostream & out, int32_t uid)
{
    add_task(task_type::check_idle);
    getdiningroom(out, uid);
    getbedroom(out, uid);

    size_t required_jail_cells = ai.pop.citizen.size() / 10;
    ai.find_room(room_type::jail, [this, &out, &required_jail_cells](room *r) -> bool
    {
        if (required_jail_cells == 0)
        {
            return true;
        }

        if (r->status == room_status::plan)
        {
            return false;
        }

        for (auto f : r->layout)
        {
            if (f->type == layout_type::cage || f->type == layout_type::restraint)
            {
                if (!f->ignore)
                {
                    required_jail_cells--;
                    if (required_jail_cells == 0)
                    {
                        return true;
                    }
                }
                else
                {
                    f->ignore = false;
                    required_jail_cells--;
                    if (r->status == room_status::finished)
                    {
                        furnish_room(out, r);
                    }
                    if (required_jail_cells == 0)
                    {
                        return true;
                    }
                }
            }
        }
        return false;
    });
}

void Plan::del_citizen(color_ostream & out, int32_t uid)
{
    freecommonrooms(out, uid);
    freebedroom(out, uid);
}

void Plan::getbedroom(color_ostream & out, int32_t id)
{
    room *r = ai.find_room(room_type::bedroom, [id](room *r) -> bool { return r->owner == id; });
    if (!r)
        r = ai.find_room(room_type::bedroom, [](room *r) -> bool { return r->status != room_status::plan && r->owner == -1; });
    if (!r)
        r = ai.find_room(room_type::bedroom, [](room *r) -> bool { return r->status == room_status::plan && !r->queue_dig; });
    if (r)
    {
        wantdig(out, r, -1);
        set_owner(out, r, id);
        ai.debug(out, "assign " + AI::describe_room(r));
        if (r->status == room_status::finished)
            furnish_room(out, r);
    }
    else
    {
        ai.debug(out, stl_sprintf("[ERROR] AI can't getbedroom(%d)", id));
    }
}

void Plan::getdiningroom(color_ostream & out, int32_t id)
{
    // skip allocating space if there's already a dining room for this dwarf.
    auto is_user = [id](furniture *f) -> bool
    {
        return f->users.count(id);
    };
    if (ai.find_room(room_type::dininghall, [is_user](room *r) -> bool
    {
        return std::find_if(r->layout.begin(), r->layout.end(), is_user) != r->layout.end();
    }))
        return;

    if (room *r = ai.find_room(room_type::farmplot, [](room *r_) -> bool
    {
        return r_->farm_type == farm_type::food &&
            !r_->outdoor &&
            r_->users.size() < r_->has_users;
    }))
    {
        wantdig(out, r, -3);
        r->users.insert(id);
    }

    if (room *r = ai.find_room(room_type::farmplot, [](room *r_) -> bool
    {
        return r_->farm_type == farm_type::cloth &&
            !r_->outdoor &&
            r_->users.size() < r_->has_users;
    }))
    {
        wantdig(out, r, -3);
        r->users.insert(id);
    }

    if (room *r = ai.find_room(room_type::farmplot, [](room *r_) -> bool
    {
        return r_->farm_type == farm_type::food &&
            r_->outdoor &&
            r_->users.size() < r_->has_users;
    }))
    {
        wantdig(out, r, -3);
        r->users.insert(id);
    }

    if (room *r = ai.find_room(room_type::farmplot, [](room *r_) -> bool
    {
        return r_->farm_type == farm_type::cloth &&
            r_->outdoor &&
            r_->users.size() < r_->has_users;
    }))
    {
        wantdig(out, r, -3);
        r->users.insert(id);
    }

    if (room *r = ai.find_room(room_type::dininghall, [](room *r_) -> bool
    {
        for (auto it = r_->layout.begin(); it != r_->layout.end(); it++)
        {
            furniture *f = *it;
            if (f->has_users && f->users.size() < f->has_users)
                return true;
        }
        return false;
    }))
    {
        wantdig(out, r, -2);
        for (auto it = r->layout.begin(); it != r->layout.end(); it++)
        {
            furniture *f = *it;
            if (f->type == layout_type::table && f->users.size() < f->has_users)
            {
                f->ignore = false;
                f->users.insert(id);
                break;
            }
        }
        for (auto it = r->layout.begin(); it != r->layout.end(); it++)
        {
            furniture *f = *it;
            if (f->type == layout_type::chair && f->users.size() < f->has_users)
            {
                f->ignore = false;
                f->users.insert(id);
                break;
            }
        }
        if (r->status == room_status::finished)
        {
            furnish_room(out, r);
        }
    }
}

void Plan::attribute_noblerooms(color_ostream & out, const std::set<int32_t> & id_list)
{
    // XXX tomb may be populated...
    while (room *old = ai.find_room(room_type::nobleroom, [id_list](room *r) -> bool { return r->owner != -1 && !id_list.count(r->owner); }))
    {
        old->required_value = 0;
        set_owner(out, old, -1);
    }

    for (auto it = id_list.begin(); it != id_list.end(); it++)
    {
        // the noble may be off the map (on a raid or mission): DF removes the
        // unit, and getNoblePositions(nullptr) throws, which crashed the game
        // in a loop. Keep their rooms and look again when they're back.
        df::unit *noble = df::unit::find(*it);
        if (!noble)
            continue;
        std::vector<Units::NoblePosition> entpos;
        Units::getNoblePositions(&entpos, noble);
        room *base = ai.find_room(room_type::nobleroom, [it](room *r) -> bool { return r->owner == *it; });
        if (!base)
            base = ai.find_room(room_type::nobleroom, [](room *r) -> bool { return r->owner == -1; });
        std::set<nobleroom_type::type> seen;
        while (room *r = ai.find_room(room_type::nobleroom, [base, seen](room *r_) -> bool { return r_->noblesuite == base->noblesuite && !seen.count(r_->nobleroom_type); }))
        {
            seen.insert(r->nobleroom_type);
            set_owner(out, r, *it);
#define DIG_ROOM_IF(type, req) \
            if (r->nobleroom_type == nobleroom_type::type && std::find_if(entpos.begin(), entpos.end(), [](Units::NoblePosition np) -> bool { return np.position->required_ ## req > 0; }) != entpos.end()) \
            { \
                for (auto & np : entpos) \
                { \
                    r->required_value = r->required_value > np.position->required_ ## req ? r->required_value : np.position->required_ ## req; \
                } \
                wantdig(out, r, -2); \
            }
            DIG_ROOM_IF(tomb, tomb);
            DIG_ROOM_IF(dining, dining);
            DIG_ROOM_IF(bedroom, bedroom);
            DIG_ROOM_IF(office, office);
#undef DIG_ROOM_IF
        }
    }
}

void Plan::getsoldierbarrack(color_ostream & out, int32_t id)
{
    df::unit *u = df::unit::find(id);
    if (!u)
        return;
    int32_t squad_id = u->military.squad_id;
    if (squad_id == -1)
        return;

    room *r = ai.find_room(room_type::barracks, [squad_id](room *r) -> bool { return r->squad_id == squad_id; });
    if (!r)
    {
        r = ai.find_room(room_type::barracks, [](room *r) -> bool { return r->squad_id == -1; });
        if (!r)
        {
            ai.debug(out, "[ERROR] no free barracks");
            return;
        }
        r->squad_id = squad_id;
        ai.debug(out, stl_sprintf("squad %d assign %s", squad_id, AI::describe_room(r).c_str()));
        wantdig(out, r, -2);
        if (df::building *bld = r->dfbuilding())
        {
            assign_barrack_squad(out, bld, squad_id);
        }
    }

    auto find_furniture = [id, r](layout_type::type type)
    {
        for (auto f : r->layout)
        {
            if (f->type == type && f->users.count(id))
            {
                f->ignore = false;
                return;
            }
        }
        for (auto f : r->layout)
        {
            if (f->type == type && f->users.size() < f->has_users)
            {
                f->users.insert(id);
                f->ignore = false;
                return;
            }
        }
    };
    find_furniture(layout_type::weapon_rack);
    find_furniture(layout_type::armor_stand);
    find_furniture(layout_type::bed);
    find_furniture(layout_type::cabinet);
    find_furniture(layout_type::chest);
    find_furniture(layout_type::archery_target);

    if (r->status == room_status::finished)
    {
        furnish_room(out, r);
    }
}

void Plan::assign_barrack_squad(color_ostream &, df::building *bld, int32_t squad_id)
{
    // In DF v50+, squads are assigned to barracks/archery zones, not furniture.
    auto zone = virtual_cast<df::building_civzonest>(bld);
    if (!zone && bld)
    {
        std::vector<df::building_civzonest *> zones;
        Buildings::findCivzonesAt(&zones, df::coord(bld->centerx, bld->centery, bld->z));
        for (auto z : zones)
        {
            if (z->type == civzone_type::Barracks || z->type == civzone_type::ArcheryRange)
            {
                zone = z;
                break;
            }
        }
    }
    if (!zone || !df::squad::find(squad_id))
    {
        return;
    }

    df::squad_use_flags flags;
    flags.bits.sleep = 1;
    flags.bits.train = 1;
    flags.bits.indiv_eq = 1;
    flags.bits.squad_eq = 1;
    Military::updateRoomAssignments(squad_id, zone->id, flags);

    // A squad whose room is only an archery range never got a training
    // activity or its weapons (squad 67 stood idle, unarmed). Give it a
    // barracks too; DF lets squads share one.
    if (zone->type != civzone_type::Barracks)
    {
        for (auto b : world->buildings.other[buildings_other_id::ACTIVITY_ZONE])
        {
            auto z = virtual_cast<df::building_civzonest>(b);
            if (z && z->type == civzone_type::Barracks && z->spec_sub_flag.bits.active)
            {
                Military::updateRoomAssignments(squad_id, z->id, flags);
                break;
            }
        }
    }
}

void Plan::getcoffin(color_ostream & out)
{
    if (room *r = ai.find_room(room_type::cemetery, [](room *r_) -> bool { return std::find_if(r_->layout.begin(), r_->layout.end(), [](furniture *f) -> bool { return f->has_users && f->users.empty(); }) != r_->layout.end(); }))
    {
        wantdig(out, r, -1);
        for (auto it = r->layout.begin(); it != r->layout.end(); it++)
        {
            furniture *f = *it;
            if (f->type == layout_type::coffin && f->users.empty())
            {
                f->users.insert(-1);
                f->ignore = false;
                break;
            }
        }
        if (r->status == room_status::finished)
        {
            furnish_room(out, r);
        }
    }
}

// free / deconstruct the bedroom assigned to this dwarf
void Plan::freebedroom(color_ostream & out, int32_t id)
{
    if (room *r = ai.find_room(room_type::bedroom, [id](room *r_) -> bool { return r_->owner == id; }))
    {
        ai.debug(out, "free " + AI::describe_room(r));
        set_owner(out, r, -1);
        for (auto it = r->layout.begin(); it != r->layout.end(); it++)
        {
            furniture *f = *it;
            if (f->ignore)
                continue;
            if (f->type == layout_type::door)
                continue;
            if (df::building *bld = df::building::find(f->bld_id))
            {
                Buildings::deconstruct(bld);
            }
            f->bld_id = -1;
        }
        r->bld_id = -1;
        remove_room_zone(out, r);
    }
}

// free / deconstruct the common facilities assigned to this dwarf
// optionnaly restricted to a single subtype among:
//  [dininghall, farmplots, barracks]
void Plan::freecommonrooms(color_ostream & out, int32_t id)
{
    freecommonrooms(out, id, room_type::dininghall);
    freecommonrooms(out, id, room_type::farmplot);
    freecommonrooms(out, id, room_type::barracks);
}

void Plan::freecommonrooms(color_ostream & out, int32_t id, room_type::type subtype)
{
    if (subtype == room_type::farmplot)
    {
        ai.find_room(subtype, [id](room *r) -> bool
        {
            r->users.erase(id);
            return false;
        });
    }
    else
    {
        ai.find_room(subtype, [this, &out, id](room *r) -> bool
        {
            for (auto it = r->layout.begin(); it != r->layout.end(); it++)
            {
                furniture *f = *it;
                if (!f->has_users)
                    continue;
                if (f->ignore)
                    continue;
                if (f->users.erase(id) && f->users.empty() && !past_initial_phase)
                {
                    // delete the specific table/chair/bed/etc for the dwarf
                    if (f->bld_id != -1 && f->bld_id != r->bld_id)
                    {
                        if (df::building *bld = df::building::find(f->bld_id))
                        {
                            Buildings::deconstruct(bld);
                        }
                        f->bld_id = -1;
                        f->ignore = true;
                    }

                    // clear the whole room if it is entirely unused
                    if (r->bld_id != -1 && std::find_if(r->layout.begin(), r->layout.end(), [](furniture *f) -> bool { return f->has_users && !f->users.empty(); }) == r->layout.end())
                    {
                        if (df::building *bld = r->dfbuilding())
                        {
                            Buildings::deconstruct(bld);
                        }
                        r->bld_id = -1;
                        remove_room_zone(out, r);

                        if (r->squad_id != -1)
                        {
                            ai.debug(out, stl_sprintf("squad %d free %s", r->squad_id, AI::describe_room(r).c_str()));
                            r->squad_id = -1;
                        }
                    }
                }
            }
            return false;
        });
    }
}

void Plan::freesoldierbarrack(color_ostream & out, int32_t id)
{
    freecommonrooms(out, id, room_type::barracks);
}

// the grazing value of an animal's caste (0 when there is none to read)
static int32_t pasture_grazer(df::unit *u)
{
    if (!u)
        return 0;
    auto race = df::creature_raw::find(u->race);
    if (!race || u->caste < 0 || size_t(u->caste) >= race->caste.size() || !race->caste[u->caste])
        return 0;
    return race->caste[u->caste]->misc.grazer;
}

// Grass an animal needs, in pasture tiles. df-ai's old rule fitted animals
// as if every pasture were 11x11 (121 tiles): an animal with grazer value g
// took 121/g of one, i.e. 14641/g tiles (a cow 28, a horse 24, a goat 4).
// Pastures are now often smaller (5x5, 7x7): Boatsbrands packed 18 grazers
// into a 5x5 and 45 animals starved while three pastures stood empty.
static int32_t grass_need(df::unit *u)
{
    int32_t g = pasture_grazer(u);
    return g > 0 ? std::max<int32_t>(1, 14641 / g) : 0;
}
static int32_t pasture_area(room *r)
{
    df::coord sz = r->size();
    return std::max<int32_t>(1, int32_t(sz.x) * int32_t(sz.y));
}
// grass the animals already in a pasture need (drops dead or vanished ones)
static int32_t pasture_load(room *r, int32_t except = -1)
{
    int32_t sum = 0;
    for (auto it = r->users.begin(); it != r->users.end(); )
    {
        // an animal butchered or gone from the map leaves its id here:
        // df::unit::find returned null and df-ai crashed on load
        df::unit *u = df::unit::find(*it);
        if (!u || Units::isDead(u))
        {
            it = r->users.erase(it);
            continue;
        }
        if (*it != except)
            sum += grass_need(u);
        it++;
    }
    return sum;
}

// The same sums on the game's own pasture zones, whoever made them: at
// Boatsbrands five of the six pens weren't linked to a df-ai room, so a
// room-only check never saw the crowding
static int32_t zone_area(df::building_civzonest *z)
{
    return std::max<int32_t>(1, (z->x2 - z->x1 + 1) * (z->y2 - z->y1 + 1));
}
static int32_t zone_grass(df::building_civzonest *z)
{
    int32_t g = 0;
    for (int32_t x = z->x1; x <= z->x2; x++)
        for (int32_t y = z->y1; y <= z->y2; y++)
        {
            if (z->room.extents && !z->room.extents[(y - z->room.y) * z->room.width + (x - z->room.x)])
                continue;
            if (auto tt = Maps::getTileType(x, y, z->z))
            {
                auto tm = ENUM_ATTR(tiletype, material, *tt);
                if (tm == tiletype_material::GRASS_LIGHT || tm == tiletype_material::GRASS_DARK)
                    g++;
            }
        }
    return g;
}
static int32_t zone_load(df::building_civzonest *z, int32_t except = -1)
{
    int32_t sum = 0;
    for (auto id : z->assigned_units)
    {
        if (id == except)
            continue;
        df::unit *u = df::unit::find(id);
        if (u && !Units::isDead(u))
            sum += grass_need(u);
    }
    return sum;
}
// grass a zone can still feed: its grass tiles (all of its tiles count while
// the grass is at least a fifth, as it grows back) minus what's eating there
static int32_t zone_free(df::building_civzonest *z, int32_t except = -1)
{
    int32_t area = zone_area(z), grass = zone_grass(z);
    if (grass < area / 5)
        return -1;
    return area - zone_load(z, except);
}

// keep_if_full: an animal already in an overgrazed or overcrowded pasture
// stays there when no other has room (false: it is let go, and the caller
// decides, e.g. to slaughter it)
df::building *Plan::getpasture(color_ostream & out, int32_t pet_id, bool keep_if_full)
{
    df::unit *pet = df::unit::find(pet_id);
    if (!pet)
        return nullptr;

    int32_t own = grass_need(pet);
    room *was = nullptr;
    // an animal already in a pasture zone: stay unless it's overgrazed or
    // has more mouths than grass, then go to the pen with the most to spare
    if (auto ref = Units::getGeneralRef(pet, general_ref_type::BUILDING_CIVZONE_ASSIGNED))
    {
        auto cz = virtual_cast<df::building_civzonest>(ref->getBuilding());
        if (cz && cz->type == civzone_type::Pen && own > 0 && zone_free(cz) < 0)
        {
            df::building_civzonest *best = nullptr;
            int32_t best_free = 0;
            for (auto b : world->buildings.other.ZONE_PEN)
            {
                auto z = virtual_cast<df::building_civzonest>(b);
                if (!z || z == cz)
                    continue;
                int32_t f = zone_free(z);
                if (f >= own && f > best_free)
                {
                    best = z;
                    best_free = f;
                }
            }
            if (best || !keep_if_full)
            {
                ai.find_room(room_type::pasture, [&](room *r_) -> bool { r_->users.erase(pet_id); return false; });
                if (best)
                    if (room *r = ai.find_room(room_type::pasture, [best](room *r_) -> bool { return r_->bld_id == best->id; }))
                        r->users.insert(pet_id);
                return best;
            }
            return cz;
        }
    }
    // don't assign multiple pastures
    if (auto ref = Units::getGeneralRef(pet, general_ref_type::BUILDING_CIVZONE_ASSIGNED))
    {
        auto bld = ref->getBuilding();
        if (auto r = ai.find_room(room_type::pasture, [bld](room *r_) -> bool { return r_->dfbuilding() == bld; }))
        {
            r->users.insert(pet->id);
            // overgrazed, or more mouths than it has grass for: try another
            if (r->low_grass() || pasture_load(r) > pasture_area(r))
            {
                r->users.erase(pet->id);
                was = r;
                bld = nullptr;
            }
        }

        if (bld)
        {
            return bld;
        }
    }

    if (own <= 0)
        return nullptr;
    // the pasture with the most grass to spare that has room for this one
    room *best = nullptr;
    int32_t best_free = 0;
    ai.find_room(room_type::pasture, [&](room *r_) -> bool
    {
        if (r_ == was || r_->low_grass())
            return false;
        int32_t free_ = pasture_area(r_) - pasture_load(r_);
        if (free_ >= own && free_ > best_free)
        {
            best = r_;
            best_free = free_;
        }
        return false;
    });
    if (!best && was && keep_if_full)
    {
        was->users.insert(pet_id);
        return was->dfbuilding();
    }
    if (room *r = best)
    {
        r->users.insert(pet_id);
        if (r->bld_id == -1)
            construct_room(out, r);
        return r->dfbuilding();
    }
    return nullptr;
}

void Plan::freepasture(color_ostream &, int32_t pet_id)
{
    if (room *r = ai.find_room(room_type::pasture, [pet_id](room *r_) -> bool { return r_->users.count(pet_id); }))
    {
        r->users.erase(pet_id);
    }
}

bool Plan::pastures_ready(color_ostream & out)
{
    return !ai.find_room(room_type::pasture, [](room *r) -> bool
    {
        return r->status != room_status::plan && !r->dfbuilding();
    }) && !ai.find_room(room_type::pasture, [&](room *r) -> bool
    {
        if (r->status == room_status::plan)
        {
            r->queue = -4;
            digroom(out, r);
            return true;
        }

        return false;
    });
}

void Plan::set_owner(color_ostream &, room *r, int32_t uid)
{
    r->owner = uid;
    // DF v50+: ownership belongs to the zone that defines the room.
    if (auto zone = virtual_cast<df::building_civzonest>(df::building::find(r->zone_id)))
    {
        Buildings::setOwner(zone, df::unit::find(uid));
    }
}

void Plan::move_dininghall_fromtemp(color_ostream &, room *r, room *t)
{
    // if we dug a real hall, get rid of the temporary one
    for (auto f : t->layout)
    {
        if (f->type == layout_type::none || !f->has_users)
        {
            continue;
        }
        for (auto of : r->layout)
        {
            if (of->type == f->type && of->has_users && of->users.empty())
            {
                of->users = f->users;
                if (!f->ignore)
                {
                    of->ignore = false;
                }
                if (df::building *bld = df::building::find(f->bld_id))
                {
                    Buildings::deconstruct(bld);
                }
                break;
            }
        }
    }
    rooms_and_corridors.erase(std::remove(rooms_and_corridors.begin(), rooms_and_corridors.end(), t), rooms_and_corridors.end());
    for (auto it = tasks_generic.begin(); it != tasks_generic.end(); )
    {
        if ((*it)->r == t)
        {
            delete *it;
            if (bg_idx_generic == it)
            {
                bg_idx_generic++;
            }
            tasks_generic.erase(it++);
        }
        else
        {
            it++;
        }
    }
    for (auto it = tasks_furniture.begin(); it != tasks_furniture.end(); )
    {
        if ((*it)->r == t)
        {
            delete *it;
            if (bg_idx_furniture == it)
            {
                bg_idx_furniture++;
            }
            tasks_furniture.erase(it++);
        }
        else
        {
            it++;
        }
    }
    delete t;
    categorize_all();
}
