#include "ai.h"
#include "population.h"
#include "plan.h"

#include "modules/Units.h"

#include "df/entity_position_assignment.h"
#include "df/historical_entity.h"
#include "df/historical_figure.h"
#include "df/histfig_entity_link_positionst.h"
#include "df/history_event_add_hf_entity_linkst.h"
#include "df/plotinfo_positionst.h"
#include "df/record_precision_level_type.h"
#include "df/squad_routine_schedulest.h"
#include "df/squad_schedule_entry.h"
#include "df/squad.h"
#include "df/squad_schedule_order.h"
#include "df/plotinfost.h"
#include "df/unit_skill.h"
#include "df/unit_soul.h"
#include "df/world.h"

REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(cur_year_tick);
REQUIRE_GLOBAL(hist_event_next_id);
REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

bool Population::unit_hasmilitaryduty(df::unit *u)
{
    if (u->military.squad_id == -1)
    {
        return false;
    }
    df::squad *squad = df::squad::find(u->military.squad_id);
    if (!squad)
    {
        return false;
    }
    auto routine = vector_get(squad->schedule.routine, squad->cur_routine_idx);
    if (!routine)
    {
        return false;
    }
    std::vector<df::squad_schedule_order *> & curmonth = routine->month[*cur_year_tick / 28 / 1200].orders;
    return !curmonth.empty() && (curmonth.size() != 1 || curmonth[0]->min_count != 0);
}

int32_t Population::unit_totalxp(const df::unit *u)
{
    int32_t t = 0;
    for (auto sk : u->status.current_soul->skills)
    {
        int32_t rat = sk->rating;
        t += 400 * rat + 100 * rat * (rat + 1) / 2 + sk->experience;
    }
    return t;
}

static bool position_allows_unit(df::entity_position *position, df::unit *u)
{
    if (position->flags.is_set(entity_position_flags::GENDER_MALE) && !Units::isMale(u))
    {
        return false;
    }
    if (position->flags.is_set(entity_position_flags::GENDER_FEMALE) && !Units::isFemale(u))
    {
        return false;
    }
    if (!position->allowed_creature.empty() && std::find(position->allowed_creature.begin(), position->allowed_creature.end(), u->race) == position->allowed_creature.end())
    {
        return false;
    }
    if (std::find(position->rejected_creature.begin(), position->rejected_creature.end(), u->race) != position->rejected_creature.end())
    {
        return false;
    }
    return true;
}

// In DF 0.47 this went through the nobles screen. In v50+ we assign the
// position directly, the same way DFHack's make-monarch script does: set the
// assignment's histfig and give the historical figure a position link.
class AssignNoblesExclusive : public ExclusiveCallback
{
    AI & ai;
    df::entity_position_responsibility responsibility;

public:
    AssignNoblesExclusive(AI & ai, df::entity_position_responsibility responsibility) :
        ExclusiveCallback("assign noble position with responsibility " + enum_item_key(responsibility)),
        ai(ai),
        responsibility(responsibility)
    {
    }
    ~AssignNoblesExclusive() {}

    void Run(color_ostream & out)
    {
        auto entity = plotinfo->main.fortress_entity;
        if (!entity)
        {
            return;
        }

        if (!entity->assignments_by_type[responsibility].empty())
        {
            // someone else filled it in the meantime
            return;
        }

        bool bookkeeper = responsibility == entity_position_responsibility::ACCOUNTING;

        std::vector<df::unit *> candidates;
        for (auto u : world->units.active)
        {
            if (!Units::isCitizen(u) || Units::isChild(u) || Units::isBaby(u) || !Units::isAlive(u) || !Units::isSane(u))
            {
                continue;
            }

            if (bookkeeper && u->status.labors[unit_labor::MINE])
            {
                continue;
            }

            if (!df::historical_figure::find(u->hist_figure_id))
            {
                continue;
            }

            std::vector<Units::NoblePosition> positions;
            if (u->mood == mood_type::None && u->military.squad_id == -1 && !Units::getNoblePositions(&positions, u))
            {
                candidates.push_back(u);
            }
        }
        if (candidates.empty())
        {
            ai.debug(out, "Cannot assign noble position for " + enum_item_key(responsibility) + ": no candidates");
            return;
        }
        std::sort(candidates.begin(), candidates.end(), [this](df::unit *a, df::unit *b) -> bool
        {
            return ai.pop.unit_totalxp(a) > ai.pop.unit_totalxp(b);
        });

        bool found = false;

        for (size_t i = 0; i < entity->positions.assignments.size(); i++)
        {
            auto assignment = entity->positions.assignments.at(i);
            if (!assignment)
            {
                continue;
            }

            auto position = binsearch_in_vector(entity->positions.own, assignment->position_id);
            if (!position || !position->responsibilities[responsibility])
            {
                continue;
            }

            found = true;

            auto old_hf = df::historical_figure::find(assignment->histfig);
            if (old_hf && old_hf->died_year == -1)
            {
                continue;
            }

            df::unit *chosen = nullptr;
            while (!candidates.empty() && !chosen)
            {
                auto candidate_unit = candidates.back();
                if (position_allows_unit(position, candidate_unit))
                {
                    chosen = candidate_unit;
                }
                else
                {
                    ai.debug(out, "Discarding candidate " + AI::describe_unit(candidate_unit) + " for position " + position->name[0] + ": not eligible");
                    candidates.pop_back();
                }
            }
            if (!chosen)
            {
                ai.debug(out, "Ran out of candidates for " + position->name[0] + "!");
                return;
            }

            auto hf = df::historical_figure::find(chosen->hist_figure_id);

            ai.debug(out, "Appointing " + AI::describe_unit(chosen) + " as position " + position->name[0]);

            if (old_hf)
            {
                // dead previous holder: drop their active position link
                for (size_t j = 0; j < old_hf->entity_links.size(); j++)
                {
                    auto link = virtual_cast<df::histfig_entity_link_positionst>(old_hf->entity_links.at(j));
                    if (link && link->assignment_id == assignment->id && link->entity_id == entity->id)
                    {
                        vector_erase_at(old_hf->entity_links, j);
                        // not freed: DFHack 53.14+ refuses to free pool-allocated game objects
                        break;
                    }
                }
                assignment->histfig2 = old_hf->id;
            }

            assignment->histfig = hf->id;

            auto link = df::allocate<df::histfig_entity_link_positionst>();
            link->entity_id = entity->id;
            link->link_strength = 100;
            link->assignment_id = assignment->id;
            link->assignment_vector_idx = int32_t(i);
            link->start_year = *cur_year;
            hf->entity_links.push_back(link);

            auto event = df::allocate<df::history_event_add_hf_entity_linkst>();
            event->year = *cur_year;
            event->seconds = *cur_year_tick;
            event->id = (*hist_event_next_id)++;
            event->civ = entity->id;
            event->histfig = hf->id;
            event->link_type = histfig_entity_link_type::POSITION;
            event->position_id = position->id;
            event->appointer_hfid = -1;
            event->promise_to_hfid = -1;
            world->history.events.push_back(event);

            // The game rebuilds this cache, but update it now so we don't
            // try to fill the same position again before it does.
            FOR_ENUM_ITEMS(entity_position_responsibility, r)
            {
                if (position->responsibilities[r])
                {
                    auto & vec = entity->assignments_by_type[r];
                    if (std::find(vec.begin(), vec.end(), assignment) == vec.end())
                    {
                        vec.push_back(assignment);
                    }
                }
            }

            if (bookkeeper && plotinfo->nobles.bookkeeper_settings != record_precision_level_type::all_accurate)
            {
                plotinfo->nobles.bookkeeper_settings = record_precision_level_type::all_accurate;
            }

            return;
        }

        if (found)
        {
            ai.debug(out, "Found position for " + enum_item_key(responsibility) + ", but it was already occupied.");
        }
        else
        {
            ai.debug(out, "Could not find position for " + enum_item_key(responsibility));
        }
    }
};

void Population::update_nobles(color_ostream & out)
{
    check_noble_apartments(out);

    if (!config.manage_nobles)
    {
        return;
    }

    for (auto & asn : plotinfo->main.fortress_entity->assignments_by_type[entity_position_responsibility::HEALTH_MANAGEMENT])
    {
        auto hf = df::historical_figure::find(asn->histfig);
        auto doctor = hf ? df::unit::find(hf->unit_id) : nullptr;
        if (!doctor)
        {
            continue;
        }

        // Enable healthcare labors on chief medical officer.
        doctor->status.labors[unit_labor::DIAGNOSE] = true;
        doctor->status.labors[unit_labor::SURGERY] = true;
        doctor->status.labors[unit_labor::BONE_SETTING] = true;
        doctor->status.labors[unit_labor::SUTURING] = true;
        doctor->status.labors[unit_labor::DRESSING_WOUNDS] = true;
    }

#define WANT_POS(pos) \
    if (plotinfo->main.fortress_entity->assignments_by_type[entity_position_responsibility::pos].empty()) \
    { \
        events.queue_exclusive(std::make_unique<AssignNoblesExclusive>(ai, entity_position_responsibility::pos)); \
    }

    WANT_POS(MANAGE_PRODUCTION);
    WANT_POS(ACCOUNTING);
    if (ai.find_room(room_type::infirmary, [](room *r) -> bool { return r->status != room_status::plan; }))
    {
        WANT_POS(HEALTH_MANAGEMENT);
    }
    WANT_POS(TRADE);
    if (ai.find_room(room_type::jail, [](room *r) -> bool { return r->status == room_status::finished; }))
    {
        WANT_POS(LAW_ENFORCEMENT);
        WANT_POS(EXECUTIONS);
    }
}

void Population::check_noble_apartments(color_ostream & out)
{
    std::set<int32_t> noble_ids;

    for (auto asn : plotinfo->main.fortress_entity->positions.assignments)
    {
        df::entity_position *pos = binsearch_in_vector(plotinfo->main.fortress_entity->positions.own, asn->position_id);
        if (pos && (pos->required_office > 0 || pos->required_dining > 0 || pos->required_tomb > 0))
        {
            if (df::historical_figure *hf = df::historical_figure::find(asn->histfig))
            {
                noble_ids.insert(hf->unit_id);
            }
        }
    }

    ai.plan.attribute_noblerooms(out, noble_ids);
}
