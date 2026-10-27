#include "ai.h"
#include "population.h"
#include "room.h"

#include "modules/Units.h"
#include "plan.h"
#include "stocks.h"
#include "df/workshop_type.h"
#include "df/inorganic_raw.h"
#include "df/material_flags.h"
#include "modules/Materials.h"
#include "df/item.h"
#include "df/tiletype.h"
#include "df/general_ref_type.h"
#include "df/buildings_other_id.h"
#include "df/items_other_id.h"
#include "df/furniture_type.h"
#include "modules/Maps.h"
#include "modules/Items.h"
#include "modules/Buildings.h"

#include "df/abstract_building_inn_tavernst.h"
#include "df/building_stockpilest.h"
#include "df/stockpile_settings.h"
#include "df/abstract_building_flags.h"
#include "df/abstract_building_type.h"
#include "df/abstract_building.h"
#include "modules/World.h"
#include "df/abstract_building_libraryst.h"
#include "df/abstract_building_templest.h"
#include "df/agreement.h"
#include "df/agreement_details.h"
#include "df/agreement_details_data_citizenship.h"
#include "df/agreement_details_data_location.h"
#include "df/agreement_details_data_parley.h"
#include "df/agreement_details_data_residency.h"
#include "df/agreement_party.h"
#include "df/building.h"
#include "df/gamest.h"
#include "df/historical_entity.h"
#include "df/historical_figure.h"
#include "df/history_event_agreement_formedst.h"
#include "df/occupation.h"
#include "df/job_skill.h"
#include "df/entity_position_responsibility.h"
#include "df/entity_position.h"
#include "df/abstract_building_hospitalst.h"
#include "df/plotinfost.h"
#include "df/religious_practice_type.h"
#include "df/world.h"
#include "df/world_site.h"

REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(cur_year_tick);
REQUIRE_GLOBAL(game);
REQUIRE_GLOBAL(hist_event_next_id);
REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

// with a population of 200:
const static int32_t wanted_tavern_keeper = 4;
const static int32_t wanted_tavern_keeper_min = 1;
const static int32_t wanted_tavern_performer = 8;
const static int32_t wanted_tavern_performer_min = 0;
const static int32_t wanted_library_scholar = 16;
const static int32_t wanted_library_scholar_min = 0;
const static int32_t wanted_library_scribe = 2;
const static int32_t wanted_library_scribe_min = 0;
const static int32_t wanted_temple_performer = 4;
const static int32_t wanted_temple_performer_min = 0;

class AssignOccupationExclusive : public ExclusiveCallback
{
    AI & ai;
    int32_t location_id;
    df::occupation_type occupation;

    static df::abstract_building *get_location(int32_t location_id)
    {
        auto site = plotinfo->main.fortress_site;
        if (!site)
            return nullptr;

        return binsearch_in_vector(site->buildings, location_id);
    }
    static std::string get_location_name(int32_t location_id)
    {
        auto location = get_location(location_id);
        if (!location)
            return "(unknown location)";

        auto name = location->getName();
        if (!name)
            return "(unnamed " + enum_item_key(location->getType()) + ")";

        return AI::describe_name(*name, true);
    }

public:
    AssignOccupationExclusive(AI & ai, int32_t location_id, df::occupation_type occupation) :
        ExclusiveCallback("assign new " + enum_item_key(occupation) + " at " + get_location_name(location_id)),
        ai(ai),
        location_id(location_id),
        occupation(occupation)
    {
    }

    // In DF 0.47 this went through the locations screen. In v50+ the
    // location's occupation slots are df::occupation objects (also listed in
    // world->occupations.all); filling one means setting its holder and
    // linking it from the unit.
    void Run(color_ostream & out)
    {
        auto location = get_location(location_id);
        if (!location)
        {
            ai.debug(out, "[ERROR] could not find location " + get_location_name(location_id));
            return;
        }

        df::occupation *slot = nullptr;
        for (auto occ : location->occupations)
        {
            if (occ && occ->type == occupation && occ->unit_id == -1 && occ->histfig_id == -1)
            {
                slot = occ;
                break;
            }
        }

        if (!slot)
        {
            // Locations df-ai creates itself (and quickfort's) start with no
            // occupation slots at all; DF's own location screen adds them.
            // Add one the same way: a df::occupation owned by the fort group.
            int32_t next_id = 0;
            for (auto o : world->occupations.all)
            {
                next_id = std::max(next_id, o->id + 1);
            }
            slot = df::allocate<df::occupation>();
            slot->id = next_id;
            slot->type = occupation;
            slot->histfig_id = -1;
            slot->unit_id = -1;
            slot->location_id = location->id;
            slot->site_id = location->site_id;
            slot->group_id = plotinfo->group_id;
            world->occupations.all.push_back(slot);
            world->occupations.order_load.push_back(slot);
            location->occupations.push_back(slot);
            ai.debug(out, "[Population] created " + enum_item_key(occupation) + " slot at " + get_location_name(location_id));
        }

        df::unit *chosen = nullptr;
        int32_t best = std::numeric_limits<int32_t>::max();
        if (occupation == occupation_type::DOCTOR)
        {
            // The chief medical dwarf is the natural doctor; otherwise take
            // the best diagnostician who isn't already busy elsewhere.
            for (auto u : world->units.active)
            {
                if (!u || !Units::isCitizen(u) || !Units::isAlive(u) || !Units::isSane(u) || !u->occupations.empty())
                {
                    continue;
                }
                std::vector<Units::NoblePosition> positions;
                Units::getNoblePositions(&positions, u);
                for (auto & np : positions)
                {
                    if (np.position && np.position->responsibilities[entity_position_responsibility::HEALTH_MANAGEMENT])
                    {
                        chosen = u;
                    }
                }
                if (chosen)
                {
                    break;
                }
            }
            if (!chosen)
            {
                int32_t best_skill = -1;
                for (auto u : world->units.active)
                {
                    if (!u || !Units::isCitizen(u) || !Units::isAdult(u) || !Units::isAlive(u) || !Units::isSane(u) ||
                        u->military.squad_id != -1 || u->mood != mood_type::None || !u->occupations.empty())
                    {
                        continue;
                    }
                    int32_t skill = Units::getEffectiveSkill(u, job_skill::DIAGNOSE);
                    if (skill > best_skill)
                    {
                        best_skill = skill;
                        chosen = u;
                    }
                }
            }
        }
        for (auto u : world->units.active)
        {
            if (chosen && occupation == occupation_type::DOCTOR)
            {
                break;
            }
            if (!u || !Units::isCitizen(u) || !Units::isAdult(u) || !Units::isAlive(u) || !Units::isSane(u))
            {
                continue;
            }

            if (u->military.squad_id != -1 || u->mood != mood_type::None)
            {
                continue;
            }

            if (!df::historical_figure::find(u->hist_figure_id))
            {
                continue;
            }

            std::vector<Units::NoblePosition> positions;
            Units::getNoblePositions(&positions, u);
            if (!positions.empty())
            {
                continue;
            }

            if (!u->occupations.empty())
            {
                continue;
            }

            bool has_occupation = false;
            for (auto o : world->occupations.all)
            {
                if (o->unit_id == u->id)
                {
                    has_occupation = true;
                    break;
                }
            }

            if (has_occupation)
            {
                continue;
            }

            int32_t score = ai.pop.unit_totalxp(u);
            if (!chosen || score < best)
            {
                chosen = u;
                best = score;
            }
        }

        if (!chosen)
        {
            ai.debug(out, "[ERROR] could not find unit for occupation " + enum_item_key(occupation) + " at " + get_location_name(location_id));
            return;
        }

        ai.debug(out, "[Population] assigning occupation " + enum_item_key(occupation) + " at " + get_location_name(location_id) + " to " + AI::describe_unit(chosen));

        slot->unit_id = chosen->id;
        slot->histfig_id = chosen->hist_figure_id;
        chosen->occupations.push_back(slot);
    }
};

class CheckPetitionsExclusive : public ExclusiveCallback
{
    AI & ai;

public:
    CheckPetitionsExclusive(AI & ai) :
        ExclusiveCallback("check petitions"),
        ai(ai)
    {
    }

    // In DF 0.47 the AI answered petitions through the petitions screen,
    // which no longer exists. In v50+ we apply the result directly:
    //
    // - Citizenship: the applicant unit is converted with DFHack's makeown
    //   script (the same conversion DFHack uses for "make this unit a
    //   citizen"), then the agreement is marked approved and concluded.
    // - Location (temple/guildhall): accepting is a promise. The agreement
    //   is marked approved, recorded as formed, and moved from
    //   plotinfo->petitions to plotinfo->continuing_agreement_id; the AI
    //   then plans the location as it did in 0.47.
    // - Rejection: the agreement keeps/gets flags.petition_not_accepted
    //   (bay12 NOT_APPROVED) and leaves plotinfo->petitions.
    //
    // Residency and parley petitions are left for the player: DF's own
    // changes to an accepted resident (and to invaders waiting for a parley)
    // are not documented well enough to reproduce safely.
    void Run(color_ostream & out)
    {
        // Agreements we have either reported as unsupported or failed to
        // answer: never retry them.
        static std::set<int32_t> given_up;

        // The petitions screen caches its own list of agreement ids; don't
        // change petitions underneath it while the player has it open.
        if (game->main_interface.petitions.open)
        {
            return;
        }

        std::vector<int32_t> pending(plotinfo->petitions.begin(), plotinfo->petitions.end());
        for (auto agreement_id : pending)
        {
            if (given_up.count(agreement_id))
            {
                continue;
            }

            auto petition = df::agreement::find(agreement_id);
            if (!petition || petition->details.empty())
            {
                continue;
            }

            auto details = petition->details.at(0);
            std::string what;
            bool done = false;

            switch (details->type)
            {
                case agreement_details_type::Residency:
                {
                    // DF's own residency conversion isn't documented well
                    // enough to copy, so a dwarf who asks to stay (the public
                    // tavern's bards and dancers) is welcomed as a citizen
                    // instead, the same conversion as a citizenship petition.
                    // Other races are left for the player.
                    auto ru = applicant_unit(petition, details->data.Residency->applicant);
                    what = "residency petition from " + describe_party(petition, details->data.Residency->applicant);
                    if (!ru || ru->race != plotinfo->race_id)
                    {
                        ai.debug(out, "[Population] leaving " + what + " for the player (not a dwarf)");
                        given_up.insert(agreement_id);
                        continue;
                    }
                    done = accept_as_citizen(out, petition, details->data.Residency->applicant, what + " (welcomed as a citizen)");
                    break;
                }
                case agreement_details_type::Parley:
                    ai.debug(out, "[v50] [Population] answering parley petitions is not supported yet; would reject petition for a parley from " + describe_party(petition, details->data.Parley->asker) + ".");
                    given_up.insert(agreement_id);
                    continue;
                case agreement_details_type::Citizenship:
                    what = "citizenship petition from " + describe_party(petition, details->data.Citizenship->applicant);
                    done = accept_citizenship(out, petition, details->data.Citizenship, what);
                    break;
                case agreement_details_type::Location:
                {
                    auto loc = details->data.Location;
                    what = "petition to construct a " + toLower_cp437(enum_item_key(loc->type)) + " from " + describe_party(petition, loc->applicant);
                    done = answer_location(out, petition, loc, what);
                    break;
                }
                default:
                    what = "petition of type " + enum_item_key(details->type);
                    ai.debug(out, "[Population] rejecting " + what);
                    reject(petition);
                    done = true;
                    break;
            }

            if (!done || std::find(plotinfo->petitions.begin(), plotinfo->petitions.end(), agreement_id) != plotinfo->petitions.end())
            {
                ai.debug(out, "[ERROR] [Population] failed to answer " + what + "; leaving it for the player.");
                given_up.insert(agreement_id);
            }
        }
    }

private:
    static std::string describe_party(df::agreement *petition, int32_t party_id)
    {
        auto party = find_party(petition, party_id);
        if (!party)
            return "(unknown)";

        if (!party->entity_ids.empty())
        {
            auto ent = df::historical_entity::find(party->entity_ids.at(0));
            auto name = ent ? &ent->name : nullptr;
            return name ? AI::describe_name(*name, true) + ", " + enum_item_key(ent->type) : "(unknown)";
        }

        if (!party->histfig_ids.empty())
        {
            auto fig = df::historical_figure::find(party->histfig_ids.at(0));
            if (auto u = fig ? df::unit::find(fig->unit_id) : nullptr)
            {
                return AI::describe_unit(u);
            }
            auto name = fig ? &fig->name : nullptr;
            return name ? AI::describe_name(*name, false) : "(unknown)";
        }

        return "(unknown)";
    }

    static df::agreement_party *find_party(df::agreement *petition, int32_t party_id)
    {
        auto party = binsearch_in_vector(petition->parties, &df::agreement_party::id, party_id);
        if (!party)
        {
            party = vector_get(petition->parties, size_t(party_id));
        }
        return party;
    }

    static void remove_petition(df::agreement *petition)
    {
        auto & p = plotinfo->petitions;
        p.erase(std::remove(p.begin(), p.end(), petition->id), p.end());
    }

    static void reject(df::agreement *petition)
    {
        petition->flags.bits.petition_not_accepted = 1;
        remove_petition(petition);
    }

    // Records the approval the way DF does for agreements it forms
    // (list-waves.lua finds accepted petitions through these events).
    static void approve(df::agreement *petition)
    {
        petition->flags.bits.petition_not_accepted = 0;
        remove_petition(petition);

        auto event = df::allocate<df::history_event_agreement_formedst>();
        event->year = *cur_year;
        event->seconds = *cur_year_tick;
        event->id = (*hist_event_next_id)++;
        event->agreement_id = petition->id;
        world->history.events.push_back(event);
    }

    bool accept_citizenship(color_ostream & out, df::agreement *petition, df::agreement_details_data_citizenship *data, const std::string & what)
    {
        return accept_as_citizen(out, petition, data->applicant, what);
    }

    df::unit *applicant_unit(df::agreement *petition, int32_t applicant)
    {
        if (auto party = find_party(petition, applicant))
        {
            for (auto hfid : party->histfig_ids)
            {
                auto fig = df::historical_figure::find(hfid);
                if (auto u = fig ? df::unit::find(fig->unit_id) : nullptr)
                    return u;
            }
        }
        return nullptr;
    }

    bool accept_as_citizen(color_ostream & out, df::agreement *petition, int32_t applicant, const std::string & what)
    {
        df::unit *u = nullptr;
        if (auto party = find_party(petition, applicant))
        {
            for (auto hfid : party->histfig_ids)
            {
                auto fig = df::historical_figure::find(hfid);
                if (fig && (u = df::unit::find(fig->unit_id)))
                {
                    break;
                }
            }
        }

        if (!u || !Units::isActive(u) || Units::isDead(u))
        {
            ai.debug(out, "[Population] cannot accept " + what + ": applicant is not on the map");
            return false;
        }

        ai.debug(out, "[Population] accepting " + what);

        if (!Units::isCitizen(u, true))
        {
            // makeown.lua is a module; make_own(unit) is the same conversion
            // its command form applies to the selected unit.
            Core::getInstance().runCommand(out, stl_sprintf(":lua dfhack.reqscript('makeown').make_own(df.unit.find(%d))", u->id));
        }

        if (!Units::isCitizen(u, true))
        {
            ai.debug(out, "[ERROR] [Population] makeown did not make " + AI::describe_unit(u) + " a citizen");
            return false;
        }

        approve(petition);
        petition->flags.bits.convicted_accepted = 1;
        return true;
    }

    bool answer_location(color_ostream & out, df::agreement *petition, df::agreement_details_data_location *loc, const std::string & what)
    {
        auto & difficulty = plotinfo->main.custom_difficulty;
        int32_t data1 = -1;
        int32_t data2 = -1;
        int32_t required_value;
        location_type::type type;
        switch (loc->type)
        {
            case abstract_building_type::TEMPLE:
                required_value = loc->tier >= 2 ? difficulty.temple_complex_value : difficulty.temple_value;
                type = location_type::temple;
                data1 = int32_t(loc->deity_type);
                data2 = loc->deity_type == religious_practice_type::RELIGION_ENID ? loc->deity_data.Religion : loc->deity_data.Deity;
                break;
            case abstract_building_type::GUILDHALL:
                required_value = loc->tier >= 2 ? difficulty.grand_guildhall_value : difficulty.guildhall_value;
                type = location_type::guildhall;
                data1 = int32_t(loc->profession);
                break;
            default:
                ai.debug(out, "[Population] rejecting " + what + ": don't know how to construct this location for a petition");
                reject(petition);
                return true;
        }

        auto found_room = ai.find_room(room_type::location, [type](room *r) -> bool { return r->status == room_status::plan && !r->queue_dig && r->location_type == type; });
        if (!found_room)
        {
            ai.debug(out, "[Population] rejecting " + what + ": no remaining space for buildings of this type");
            reject(petition);
            return true;
        }

        ai.debug(out, "[Population] accepting " + what);

        approve(petition);
        insert_into_vector(plotinfo->continuing_agreement_id, petition->id);

        found_room->data1 = data1;
        found_room->data2 = data2;
        found_room->required_value = required_value;
        ai.plan.wantdig(out, found_room, -2);
        return true;
    }
};


// Empty barrels have nowhere to go: drinks are drunk straight from barrels in
// the tavern's booze stockpile, the emptied barrel stays put, and with the
// fort's only barrel stockpile full they pile up until the booze stockpile has
// no room left for drink (Showerwheels: 56 empty barrels on 5 tiles, 3 drinks).
// When 10+ empty barrels lie loose (not in a stockpile that wants them), give
// them a barrels-only stockpile near the still, where brewers need them anyway.
static bool barrel_ok_tile(df::coord t)
{
    auto tt = Maps::getTileType(t);
    auto des = Maps::getTileDesignation(t);
    auto occ = Maps::getTileOccupancy(t);
    if (!tt || !des || !occ || des->bits.outside || des->bits.flow_size || occ->bits.building != tile_building_occ::None)
        return false;
    return ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) == tiletype_shape_basic::Floor;
}

static void barrel_overflow(AI & ai, color_ostream & out)
{
    static int32_t last = -1;
    if (last != -1 && *cur_year_tick >= last && *cur_year_tick - last < 1200)
        return; // daily
    last = *cur_year_tick;

    int loose = 0;
    for (auto item : world->items.other[items_other_id::BARREL])
    {
        auto & f = item->flags.bits;
        if (f.in_building || f.trader || f.forbid || f.in_job || f.removed || f.garbage_collect || f.construction || f.in_inventory || f.foreign)
            continue;
        if (Items::getGeneralRef(item, general_ref_type::CONTAINS_ITEM))
            continue; // holds something
        auto sp = virtual_cast<df::building_stockpilest>(Buildings::findAtTile(Items::getPosition(item)));
        if (sp && sp->settings.flags.bits.furniture && size_t(furniture_type::BARREL) < sp->settings.furniture.type.size() && sp->settings.furniture.type[furniture_type::BARREL])
            continue; // already stored where barrels belong
        loose++;
    }
    if (loose < 10)
        return;

    // free space in existing barrel stockpiles?
    int space = 0;
    for (auto bld : world->buildings.other[buildings_other_id::STOCKPILE])
    {
        auto sp = virtual_cast<df::building_stockpilest>(bld);
        if (!sp || !sp->settings.flags.bits.furniture || size_t(furniture_type::BARREL) >= sp->settings.furniture.type.size() || !sp->settings.furniture.type[furniture_type::BARREL])
            continue;
        for (int16_t x = sp->x1; x <= sp->x2; x++)
            for (int16_t y = sp->y1; y <= sp->y2; y++)
            {
                auto occ = Maps::getTileOccupancy(df::coord(x, y, sp->z));
                if (occ && !occ->bits.item && Buildings::containsTile(sp, df::coord2d(x, y)))
                    space++;
            }
    }
    if (space >= loose)
        return;

    // the fort's own plan has more furniture stockpile levels waiting: dig the
    // next one (tidy rooms next to the first, not loose piles by the still)
    room *next = nullptr;
    bool busy = false; // one furniture stockpile at a time
    ai.find_room(room_type::stockpile, [&busy](room *r) -> bool
    {
        if (r->stockpile_type == stockpile_type::furniture && (r->queue_dig || r->status == room_status::dig || r->status == room_status::dug))
            busy = true;
        return busy;
    });
    if (busy)
        return;
    ai.find_room(room_type::stockpile, [&next](room *r) -> bool
    {
        if (r->stockpile_type == stockpile_type::furniture && r->status == room_status::plan && !r->queue_dig
                && (!next || r->level < next->level))
            next = r;
        return false;
    });
    if (!next)
    {
        ai.debug(out, stl_sprintf("[LOCATIONS] %d empty barrels lying loose and no furniture stockpile left to dig", loose));
        return;
    }
    ai.debug(out, stl_sprintf("[LOCATIONS] %d empty barrels had nowhere to go: digging the next furniture stockpile", loose));
    ai.plan.wantdig(out, next);
}


// Fish and meat rot in a fishery or butcher's shop unless the tile above the
// workshop's center is open to the sky (user tip). For any such workshop
// whose center-above tile is the natural surface: channel it open, then cover
// the hole with floor bars so nothing climbs in.
static void vent_workshops(AI & ai, color_ostream & out)
{
    static int32_t last = -1;
    if (last != -1 && *cur_year_tick >= last && *cur_year_tick - last < 1200)
        return; // daily
    last = *cur_year_tick;

    ai.find_room(room_type::workshop, [&ai, &out](room *r) -> bool
    {
        if (r->status != room_status::finished || (r->workshop_type != workshop_type::Fishery && r->workshop_type != workshop_type::Butchers))
            return false;
        df::coord c((r->min.x + r->max.x) / 2, (r->min.y + r->max.y) / 2, r->max.z + 1);
        // only over a workshop that really stands there (a reload can leave the
        // plan ahead of the map: channelling over rock makes a ramp, not a vent)
        auto ws = df::building::find(r->bld_id);
        if (!ws || ws->z != r->max.z || ws->centerx != c.x || ws->centery != c.y || ws->getBuildStage() < ws->getMaxBuildStage())
            return false;
        auto tt = Maps::getTileType(c);
        auto des = Maps::getTileDesignation(c);
        auto occ = Maps::getTileOccupancy(c);
        if (!tt || !des || !occ || !des->bits.outside)
            return false; // not under the sky: needs a move, not a vent
        auto shape = ENUM_ATTR(tiletype, shape, *tt);
        if (occ->bits.building != tile_building_occ::None)
            return false; // bars (or something) already there
        if (shape == tiletype_shape::FLOOR || shape == tiletype_shape::RAMP)
        {
            if (des->bits.dig != tile_dig_designation::Channel)
            {
                AI::dig_tile(c, tile_dig_designation::Channel);
                ai.debug(out, "[VENT] channel the roof over " + AI::describe_room(r));
            }
            return false;
        }
        if (shape != tiletype_shape::EMPTY && shape != tiletype_shape::RAMP_TOP)
            return false;
        df::item *bar = nullptr;
        for (auto it : world->items.other[items_other_id::BAR])
        {
            MaterialInfo mi(it);
            if (mi.isInorganic() && mi.inorganic->material.flags.is_set(material_flags::IS_METAL) && Stocks::is_item_free(it))
            {
                bar = it;
                break;
            }
        }
        if (!bar)
        {
            ai.debug(out, "[VENT] no free metal bar for the floor bars over " + AI::describe_room(r));
            return false;
        }
        auto bld = Buildings::allocInstance(c, building_type::BarsFloor);
        if (!bld)
            return false;
        Buildings::setSize(bld, df::coord(1, 1, 1));
        std::vector<df::item *> items{bar};
        Buildings::constructWithItems(bld, items);
        ai.debug(out, "[VENT] floor bars over the vent of " + AI::describe_room(r));
        return false;
    });
}

void Population::update_locations(color_ostream & out)
{
    vent_workshops(ai, out);
    barrel_overflow(ai, out);

    // Tavern booze stockpiles hold drinks only (user request). The template
    // left prepared meals on, and 5 tiles of meals kept every barrel out, so
    // the tavern keeper walked to the main stores for each mug.
    ai.find_room(room_type::stockpile, [&](room *r) -> bool
    {
        if (r->comment.find("booze stockpile") == std::string::npos)
            return false;
        if (auto sp = virtual_cast<df::building_stockpilest>(r->dfbuilding()))
        {
            if (sp->settings.food.prepared_meals || sp->storage.max_barrels < 5)
            {
                sp->settings.food.prepared_meals = false;
                if (sp->storage.max_barrels < 5)
                    sp->storage.max_barrels = 5;
                ai.debug(out, stl_sprintf("[LOCATIONS] tavern stockpile %d set to drinks only", sp->id));
            }
        }
        return false;
    });

    // One public tavern: the site's first tavern lets visitors in (bards,
    // mercenaries, monster hunters and the odd animal person make the fort
    // livelier, and some ask to stay), every other location stays closed so
    // visitors have one place to go instead of wandering the whole fort.
    if (auto site = df::world_site::find(World::GetCurrentSiteId()))
    {
        df::abstract_building *pub = nullptr;
        for (auto loc : site->buildings)
        {
            if (loc && loc->getType() == abstract_building_type::INN_TAVERN && !loc->flags.is_set(abstract_building_flags::DOES_NOT_EXIST) &&
                (!pub || loc->id < pub->id))
            {
                pub = loc;
            }
        }
        for (auto loc : site->buildings)
        {
            if (!loc)
                continue;
            auto t = loc->getType();
            if (t != abstract_building_type::INN_TAVERN && t != abstract_building_type::TEMPLE && t != abstract_building_type::LIBRARY &&
                t != abstract_building_type::GUILDHALL && t != abstract_building_type::HOSPITAL)
                continue;
            bool want = loc == pub;
            if (loc->flags.is_set(abstract_building_flags::VISITORS_ALLOWED) != want)
            {
                loc->flags.set(abstract_building_flags::VISITORS_ALLOWED, want);
                if (want)
                    ai.debug(out, "[LOCATIONS] opened " + AI::describe_name(*loc->getName(), true) + " to visitors (the one public tavern)");
            }
        }
    }

    if (!plotinfo->petitions.empty())
    {
        events.queue_exclusive(std::make_unique<CheckPetitionsExclusive>(ai));
    }

#define INIT_NEED(name) int32_t need_##name = std::max(wanted_##name * int32_t(citizen.size()) / 200, wanted_##name##_min)
    INIT_NEED(tavern_keeper);
    INIT_NEED(tavern_performer);
    INIT_NEED(library_scholar);
    INIT_NEED(library_scribe);
    INIT_NEED(temple_performer);
#undef INIT_NEED

    if (room *tavern = ai.find_room(room_type::location, [](room *r) -> bool { return r->location_type == location_type::tavern && r->dfbuilding(); }))
    {
        df::building *bld = tavern->dfbuilding();
        if (auto loc = virtual_cast<df::abstract_building_inn_tavernst>((df::world_site::find(bld->site_id) ? binsearch_in_vector(df::world_site::find(bld->site_id)->buildings, bld->location_id) : nullptr)))
        {
            for (auto occ : loc->occupations)
            {
                if (occ->unit_id != -1)
                {
                    if (occ->type == occupation_type::TAVERN_KEEPER)
                    {
                        need_tavern_keeper--;
                    }
                    else if (occ->type == occupation_type::PERFORMER)
                    {
                        need_tavern_performer--;
                    }
                }
            }
            if (need_tavern_keeper > 0)
            {
                events.queue_exclusive(std::make_unique<AssignOccupationExclusive>(ai, loc->id, occupation_type::TAVERN_KEEPER));
            }
            if (need_tavern_performer > 0)
            {
                events.queue_exclusive(std::make_unique<AssignOccupationExclusive>(ai, loc->id, occupation_type::PERFORMER));
            }
        }
    }

    if (room *library = ai.find_room(room_type::location, [](room *r) -> bool { return r->location_type == location_type::library && r->dfbuilding(); }))
    {
        df::building *bld = library->dfbuilding();
        if (auto loc = virtual_cast<df::abstract_building_libraryst>((df::world_site::find(bld->site_id) ? binsearch_in_vector(df::world_site::find(bld->site_id)->buildings, bld->location_id) : nullptr)))
        {
            for (auto occ : loc->occupations)
            {
                if (occ->unit_id != -1)
                {
                    if (occ->type == occupation_type::SCHOLAR)
                    {
                        need_library_scholar--;
                    }
                    else if (occ->type == occupation_type::SCRIBE)
                    {
                        need_library_scribe--;
                    }
                }
            }
            if (need_library_scholar > 0)
            {
                events.queue_exclusive(std::make_unique<AssignOccupationExclusive>(ai, loc->id, occupation_type::SCHOLAR));
            }
            if (need_library_scribe > 0)
            {
                events.queue_exclusive(std::make_unique<AssignOccupationExclusive>(ai, loc->id, occupation_type::SCRIBE));
            }
        }
    }

    // A hospital only works with a doctor on staff (DF's "no functional
    // hospital"). One doctor per hospital zone df-ai created.
    // Every infirmary: tlg01 digs "Additional Infirmaries", and only the
    // first one used to get a doctor (Quakefocus had 2 of 4 hospitals with
    // no DOCTOR slot, so patients taken there were never treated).
    std::vector<room *> infirmaries;
    ai.find_room(room_type::infirmary, [&infirmaries](room *r) -> bool
    {
        if (r->dfbuilding() != nullptr)
            infirmaries.push_back(r);
        return false;
    });
    for (room *infirmary : infirmaries)
    {
        df::building *bld = infirmary->dfbuilding();
        auto site = df::world_site::find(bld->site_id);
        auto loc = virtual_cast<df::abstract_building_hospitalst>(site ? binsearch_in_vector(site->buildings, bld->location_id) : nullptr);
        bool staffed = loc == nullptr;
        for (auto occ : loc ? loc->occupations : std::vector<df::occupation *>())
        {
            if (occ->unit_id != -1 && occ->type == occupation_type::DOCTOR)
            {
                staffed = true;
            }
        }
        if (!staffed)
        {
            events.queue_exclusive(std::make_unique<AssignOccupationExclusive>(ai, loc->id, occupation_type::DOCTOR));
        }
    }

    if (room *temple = ai.find_room(room_type::location, [](room *r) -> bool { return r->location_type == location_type::temple && r->dfbuilding(); }))
    {
        df::building *bld = temple->dfbuilding();
        if (auto loc = virtual_cast<df::abstract_building_templest>((df::world_site::find(bld->site_id) ? binsearch_in_vector(df::world_site::find(bld->site_id)->buildings, bld->location_id) : nullptr)))
        {
            for (auto occ : loc->occupations)
            {
                if (occ->unit_id != -1)
                {
                    if (occ->type == occupation_type::PERFORMER)
                    {
                        need_temple_performer--;
                    }
                }
            }
            if (need_temple_performer > 0)
            {
                events.queue_exclusive(std::make_unique<AssignOccupationExclusive>(ai, loc->id, occupation_type::PERFORMER));
            }
        }
    }
}
