#include "ai.h"

#include <set>
#include "population.h"
#include "plan.h"

#include "modules/Units.h"

#include "df/entity_position_assignment.h"
#include "df/entity_position_flags.h"
#include "df/job_skill.h"
#include "df/entity_position.h"
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
                // DF 53 added NONE = -1 to this enum; it is not a valid array index.
                if (r < 0)
                    continue;
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


// ---------------------------------------------------------------------------
// Appointments (user request): besides the core jobs above, fill every empty
// seat the fort's own leader can appoint (dungeon master, messengers, a
// sheriff when there is no captain of the guard...), each with the citizen
// best suited by skill. Messengers have no seats until someone adds one, so
// we keep MESSENGERS_WANTED of them.
static const int MESSENGERS_WANTED = 2;

static int32_t skill_score(df::unit *u, std::initializer_list<df::job_skill> skills)
{
    int32_t t = 0;
    for (auto sk : skills)
        t += Units::getEffectiveSkill(u, sk) * 100 + 1;
    return t;
}

static int32_t position_fit(df::unit *u, const std::string & code)
{
    if (code == "MESSENGER")
        return skill_score(u, {job_skill::NEGOTIATION, job_skill::PERSUASION, job_skill::JUDGING_INTENT, job_skill::CONVERSATION, job_skill::FLATTERY, job_skill::LYING});
    if (code == "DUNGEON_MASTER")
        return skill_score(u, {job_skill::ANIMALTRAIN, job_skill::ANIMALCARE, job_skill::TRAPPING});
    if (code == "SHERIFF")
        return skill_score(u, {job_skill::DISCIPLINE, job_skill::JUDGING_INTENT, job_skill::WRESTLING, job_skill::SITUATIONAL_AWARENESS});
    return 1;
}

static df::entity_position_assignment *add_position_slot(df::historical_entity *entity, df::entity_position *position)
{
    df::entity_position_assignment *like = nullptr;
    for (auto a : entity->positions.assignments)
    {
        auto p = binsearch_in_vector(entity->positions.own, a->position_id);
        if (p && p->squad_size == 0 && !p->flags.is_set(entity_position_flags::ELECTED))
        {
            like = a;
            break;
        }
    }
    auto asn = df::allocate<df::entity_position_assignment>();
    asn->id = entity->positions.next_assignment_id++;
    asn->histfig = -1;
    asn->histfig2 = -1;
    asn->position_id = position->id;
    asn->position_vector_idx = -1;
    for (size_t i = 0; i < entity->positions.own.size(); i++)
        if (entity->positions.own[i] == position)
            asn->position_vector_idx = int32_t(i);
    if (like)
        asn->flags = like->flags;
    asn->squad_id = -1;
    asn->st_id = -1;
    asn->ab_id = -1;
    asn->vassal_of_entity_id = -1;
    asn->vassal_of_position_profile_id = -1;
    asn->assigned_army_controller_id = -1;
    asn->temp = 0;
    entity->positions.assignments.push_back(asn);
    return asn;
}

static void appoint(AI & ai, color_ostream & out, df::historical_entity *entity, df::entity_position *position, df::entity_position_assignment *assignment, df::unit *chosen)
{
    auto hf = df::historical_figure::find(chosen->hist_figure_id);
    int32_t idx = -1;
    for (size_t i = 0; i < entity->positions.assignments.size(); i++)
        if (entity->positions.assignments[i] == assignment)
            idx = int32_t(i);
    assignment->histfig = hf->id;
    auto link = df::allocate<df::histfig_entity_link_positionst>();
    link->entity_id = entity->id;
    link->link_strength = 100;
    link->assignment_id = assignment->id;
    link->assignment_vector_idx = idx;
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

    FOR_ENUM_ITEMS(entity_position_responsibility, r)
    {
        if (r < 0)
            continue;
        if (position->responsibilities[r])
        {
            auto & vec = entity->assignments_by_type[r];
            if (std::find(vec.begin(), vec.end(), assignment) == vec.end())
                vec.push_back(assignment);
        }
    }
    ai.debug(out, "[APPOINT] " + AI::describe_unit(chosen) + " appointed " + position->name[0]);
}

class FillSeatsExclusive : public ExclusiveCallback
{
    AI & ai;
public:
    FillSeatsExclusive(AI & ai) : ExclusiveCallback("fill empty appointed seats"), ai(ai) {}
    void Run(color_ostream & out)
    {
        auto entity = plotinfo->main.fortress_entity;
        if (!entity)
            return;

        auto pos_by_code = [entity](const char *code) -> df::entity_position *
        {
            for (auto p : entity->positions.own)
                if (p->code == code)
                    return p;
            return nullptr;
        };
        auto filled = [entity](df::entity_position *p) -> int
        {
            int n = 0;
            for (auto a : entity->positions.assignments)
                if (a->position_id == p->id && df::historical_figure::find(a->histfig) && df::historical_figure::find(a->histfig)->died_year == -1)
                    n++;
            return n;
        };

        // who can appoint: positions currently held by a living dwarf
        std::set<int32_t> appointers;
        for (auto a : entity->positions.assignments)
        {
            auto hf = df::historical_figure::find(a->histfig);
            if (hf && hf->died_year == -1)
                appointers.insert(a->position_id);
        }

        auto captain = pos_by_code("CAPTAIN_OF_THE_GUARD");
        for (auto position : entity->positions.own)
        {
            if (position->flags.is_set(entity_position_flags::ELECTED) || position->squad_size > 0 || position->code == "EXPEDITION_LEADER")
                continue;
            if (position->code == "SHERIFF" && captain && filled(captain))
                continue; // the captain of the guard already does the sheriff's job
            bool can_appoint = false;
            for (auto by : position->appointed_by)
                if (appointers.count(by))
                    can_appoint = true;
            if (!can_appoint)
                continue;

            // a free seat (dead or empty holder), or a new messenger seat
            df::entity_position_assignment *seat = nullptr;
            for (auto a : entity->positions.assignments)
            {
                if (a->position_id != position->id)
                    continue;
                auto hf = df::historical_figure::find(a->histfig);
                if (!hf || hf->died_year != -1)
                {
                    seat = a;
                    break;
                }
            }
            if (!seat && position->code == "MESSENGER" && filled(position) < MESSENGERS_WANTED)
                seat = add_position_slot(entity, position);
            if (!seat)
                continue;

            df::unit *best = nullptr;
            int32_t best_fit = -1;
            for (auto u : world->units.active)
            {
                if (!Units::isCitizen(u) || Units::isChild(u) || Units::isBaby(u) || !Units::isAlive(u) || !Units::isSane(u))
                    continue;
                if (!df::historical_figure::find(u->hist_figure_id) || u->mood != mood_type::None)
                    continue;
                std::vector<Units::NoblePosition> held;
                if (Units::getNoblePositions(&held, u))
                    continue;
                if (!position_allows_unit(position, u))
                    continue;
                // most adults serve in a squad (everyone fights): prefer
                // civilians, but a soldier can carry a message too
                int32_t fit = position_fit(u, position->code) + (u->military.squad_id == -1 ? 1000000 : 0);
                if (fit > best_fit)
                {
                    best_fit = fit;
                    best = u;
                }
            }
            if (!best)
                continue;
            appoint(ai, out, entity, position, seat, best);
            return; // one per run; the rest next time
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

    events.queue_exclusive(std::make_unique<FillSeatsExclusive>(ai));
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
