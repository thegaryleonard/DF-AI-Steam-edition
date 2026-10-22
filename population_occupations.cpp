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
#include "df/historical_entity.h"
#include "df/historical_figure.h"
#include "df/occupation.h"
#include "df/plotinfost.h"
#include "df/world.h"
#include "df/world_site.h"

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
            ai.debug(out, "[ERROR] could not find vacant occupation " + enum_item_key(occupation) + " at " + get_location_name(location_id));
            return;
        }

        df::unit *chosen = nullptr;
        int32_t best = std::numeric_limits<int32_t>::max();
        for (auto u : world->units.active)
        {
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

    // In DF 0.47 the AI answered petitions through the petitions screen.
    // Accepting a petition in v50+ runs game-side logic (changing a unit's
    // residency/citizenship, creating location agreements, ...) that DFHack
    // does not expose, so we only log what the AI would have decided and
    // leave the petition for the player.
    void Run(color_ostream & out)
    {
        static std::set<int32_t> logged;

        for (auto agreement_id : plotinfo->petitions)
        {
            auto petition = df::agreement::find(agreement_id);
            if (!petition || petition->details.empty())
            {
                continue;
            }

            if (!logged.insert(agreement_id).second)
            {
                continue;
            }

            auto details = petition->details.at(0);

            auto describe_party = [petition](int32_t party_id) -> std::string
            {
                auto party = binsearch_in_vector(petition->parties, &df::agreement_party::id, party_id);
                if (!party)
                {
                    party = vector_get(petition->parties, size_t(party_id));
                }
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
            };

            std::string decision;
            switch (details->type)
            {
                case agreement_details_type::Residency:
                    decision = "accept residency petition from " + describe_party(details->data.Residency->applicant);
                    break;
                case agreement_details_type::Citizenship:
                    decision = "accept citizenship petition from " + describe_party(details->data.Citizenship->applicant);
                    break;
                case agreement_details_type::Parley:
                    decision = "reject petition for a parley from " + describe_party(details->data.Parley->asker);
                    break;
                case agreement_details_type::Location:
                {
                    auto loc = details->data.Location;
                    decision = "consider petition to construct a " + toLower_cp437(enum_item_key(loc->type)) + " from " + describe_party(loc->applicant);
                    break;
                }
                default:
                    decision = "reject petition of type " + enum_item_key(details->type);
                    break;
            }

            ai.debug(out, "[v50] [Population] answering petitions is not supported yet; would " + decision + ".");
        }
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
