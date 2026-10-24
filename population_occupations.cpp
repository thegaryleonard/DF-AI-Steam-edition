#include "ai.h"
#include "population.h"
#include "room.h"

#include "modules/Units.h"

#include "df/abstract_building_inn_tavernst.h"
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
                    ai.debug(out, "[v50] [Population] answering residency petitions is not supported yet; would accept residency petition from " + describe_party(petition, details->data.Residency->applicant) + ".");
                    given_up.insert(agreement_id);
                    continue;
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
        df::unit *u = nullptr;
        if (auto party = find_party(petition, data->applicant))
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

void Population::update_locations(color_ostream &)
{
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
