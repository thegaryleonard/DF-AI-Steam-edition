#include "ai.h"
#include "df/caste_raw.h"
#include "df/historical_figure.h"
#include "df/incident.h"
#include "df/squad_position.h"
#include <algorithm>
#include <set>
#include "population.h"
#include "plan.h"

REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(cur_year_tick);

#include "df/activity_entry.h"
#include "df/activity_event_conflictst.h"
#include "df/conflict_sidest.h"
#include "df/conflict_statest.h"
#include "df/creature_raw.h"
#include "df/historical_entity.h"
#include "df/job.h"
#include "df/squad.h"
#include "df/squad_order_kill_listst.h"
#include "df/plotinfost.h"
#include "df/world.h"

#include "modules/Maps.h"
#include "modules/Units.h"

REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

// an invader still far from the fort (and from every citizen) is left alone:
// the squads muster at the gate in full kit first (Population::battle_stations)
// user: "once dudes are mustered you can just go attack, you don't have to
// wait for them" / "as soon as say 40% of the troops are mustered, go off and
// start killing in a murder ball, especially if dwarves are dying out there":
// when 40% of the soldiers at home stand at the gate - or any dwarf has died
// in the last two days - the muster is over and every reachable invader is a
// target for every squad, however far off.
static bool army_mustered(AI & ai)
{
    static int32_t at_tick = -1;
    static bool cached = false;
    if (*cur_year_tick == at_tick)
        return cached;
    at_tick = *cur_year_tick;
    cached = false;
    if (!ai.plan.entrance())
        return false;
    df::coord e = ai.plan.entrance()->pos();
    int32_t total = 0, there = 0;
    for (auto sqid : plotinfo->main.fortress_entity->squads)
    {
        auto sq = df::squad::find(sqid);
        if (!sq || sq->assigned_army_controller_id != -1)
            continue;
        for (auto pos : sq->positions)
        {
            if (!pos || pos->occupant == -1)
                continue;
            auto hf = df::historical_figure::find(pos->occupant);
            auto m = hf ? df::unit::find(hf->unit_id) : nullptr;
            if (!m || !Units::isActive(m) || Units::isDead(m))
                continue;
            total++;
            df::coord q = Units::getPosition(m);
            if (std::abs(q.x - e.x) <= 8 && std::abs(q.y - e.y) <= 8 && std::abs(q.z - e.z) <= 2)
                there++;
        }
    }
    cached = total > 0 && there * 5 >= total * 2;
    return cached;
}

static bool dwarves_dying()
{
    static int32_t at_tick = -1;
    static bool cached = false;
    if (*cur_year_tick / 100 == at_tick)
        return cached;
    at_tick = *cur_year_tick / 100;
    cached = false;
    int64_t now = int64_t(*cur_year) * 403200 + *cur_year_tick;
    for (auto u : world->units.all)
    {
        if (!Units::isDead(u) || !Units::isOwnCiv(u) || u->counters.death_id < 0)
            continue;
        auto inc = df::incident::find(u->counters.death_id);
        if (inc && now - (int64_t(inc->event_year) * 403200 + inc->event_time) <= 2 * 1200)
        {
            cached = true;
            break;
        }
    }
    return cached;
}

static bool invader_close(AI & ai, df::unit *u)
{
    if (army_mustered(ai) || dwarves_dying())
        return true;
    df::coord p = Units::getPosition(u);
    if (ai.plan.entrance())
    {
        df::coord e = ai.plan.entrance()->pos();
        if (std::abs(p.x - e.x) <= 25 && std::abs(p.y - e.y) <= 25 && std::abs(p.z - e.z) <= 6)
            return true;
    }
    for (auto id : ai.pop.citizen)
    {
        auto c = df::unit::find(id);
        if (!c)
            continue;
        df::coord q = Units::getPosition(c);
        if (std::abs(p.x - q.x) <= 10 && std::abs(p.y - q.y) <= 10 && std::abs(p.z - q.z) <= 2)
            return true;
    }
    return false;
}

// Wildlife is only the army's business at home (user: "i issued some 'stay at
// home' orders but people are deployed" - squads of hungry wrestlers chased
// platybelodon herds across the whole surface because one had swiped at a
// woodcutter): inside the fort, or within 25 tiles / 6 levels of the gate.
// Agitated wildlife (user: "one agitated animal picking off dwarves"): an
// agitated quetzalcoatlus circled 25 levels above the gate, out of the
// wildlife range, swooping on the surface workers. Agitated creatures count
// as near the fort anywhere over its yard, at any height (fliers), and they
// are not "ordinary" targets: a hungry squad doesn't drop them.
static bool is_flier(df::unit *u)
{
    auto craw = df::creature_raw::find(u->race);
    return craw && size_t(u->caste) < craw->caste.size() && craw->caste[u->caste]->flags.is_set(caste_raw_flags::FLIER);
}

static bool agitated_over_fort(AI & ai, df::unit *u)
{
    if (!Units::isAgitated(u) || !ai.plan.entrance())
        return false;
    df::coord p = Units::getPosition(u);
    df::coord e = ai.plan.entrance()->pos();
    return std::abs(p.x - e.x) <= 40 && std::abs(p.y - e.y) <= 40 && p.z >= e.z - 6;
}

static bool near_fort(AI & ai, df::unit *u)
{
    df::coord p = Units::getPosition(u);
    auto d = Maps::getTileDesignation(p);
    if (d && !d->bits.outside)
        return true;
    if (ai.plan.entrance())
    {
        df::coord e = ai.plan.entrance()->pos();
        if (std::abs(p.x - e.x) <= 25 && std::abs(p.y - e.y) <= 25 && std::abs(p.z - e.z) <= 6)
            return true;
    }
    return false;
}

// A squad that's mostly hungry or thirsty is let off ordinary targets so it
// can eat (soldiers locked on a kill order don't; Hammerfaiths' squads went
// 40+ days on a war tiger and a platybelodon, and one died of thirst).
bool squad_needs_meal(df::squad *squad)
{
    int32_t n = 0, needy = 0;
    for (auto pos : squad->positions)
    {
        if (!pos || pos->occupant == -1)
            continue;
        auto hf = df::historical_figure::find(pos->occupant);
        auto u = hf ? df::unit::find(hf->unit_id) : nullptr;
        if (!u || Units::isDead(u))
            continue;
        n++;
        if (u->counters2.hunger_timer > 50000 || u->counters2.thirst_timer > 30000)
            needy++;
    }
    return n > 0 && needy * 2 >= n;
}

static bool ordinary_target(df::unit *t)
{
    return !Units::isGreatDanger(t) && !Units::isAgitated(t) && !t->flags1.bits.active_invader && !t->flags1.bits.marauder &&
        !Units::isOpposedToLife(t) && !t->flags2.bits.underworld;
}

// Dangerous creatures loose in the fort. Cloisterbolt lost 17 dwarves in one
// game week (168-08) to a single giant cave spider down in the deep workings
// (z118, far from the gate): it was neither a "danger" nor agitated to DF, so
// df-ai only reacted once it was seen attacking someone, once a game day, and
// then with ONE squad. Now any creature that can hurt dwarves (agitated, a
// DF danger, a large/ambush predator or a webber, or one seen attacking a
// citizen) that is reachable and either in the fort's own dug space or within
// 15 tiles / 3 levels of a citizen gets EVERY home squad, and the civilians
// go to the Safety burrow until it's dead or gone (Population::update_military).
static bool harmless_guest(df::unit *u)
{
    return Units::isTame(u) || Units::isMerchant(u) || Units::isDiplomat(u) || Units::isVisitor(u) ||
        u->flags1.bits.caged || u->flags1.bits.chained || u->flags1.bits.inactive;
}

static bool dangerous_creature(df::unit *u)
{
    if (Units::isAgitated(u) || Units::isDanger(u))
        return true;
    auto craw = df::creature_raw::find(u->race);
    if (craw && u->caste >= 0 && size_t(u->caste) < craw->caste.size())
    {
        auto & f = craw->caste[u->caste]->flags;
        if (f.is_set(caste_raw_flags::LARGE_PREDATOR) || f.is_set(caste_raw_flags::AMBUSHPREDATOR) || f.is_set(caste_raw_flags::WEBBER))
            return true;
    }
    return AI::is_attacking_citizen(u) != nullptr;
}

// fort-dug space: underground, and not a cavern or the magma sea/underworld
static bool in_fort_dug(df::coord p)
{
    auto d = Maps::getTileDesignation(p);
    return d && !d->bits.outside && !d->bits.feature_local && !d->bits.feature_global;
}

static df::unit *citizen_near(AI & ai, df::coord p, int16_t r, int16_t rz)
{
    for (auto id : ai.pop.citizen)
    {
        auto c = df::unit::find(id);
        if (!c || Units::isDead(c) || !Units::isActive(c))
            continue;
        df::coord q = Units::getPosition(c);
        if (std::abs(p.x - q.x) <= r && std::abs(p.y - q.y) <= r && std::abs(p.z - q.z) <= rz)
            return c;
    }
    return nullptr;
}

// invaders and marauders keep their own rules (muster, hold inside the wall)
static bool close_threat(AI & ai, df::unit *u)
{
    if (u->flags1.bits.active_invader || u->flags1.bits.marauder || harmless_guest(u) || Units::isOwnCiv(u))
        return false;
    if (!dangerous_creature(u) || !ai.pop.military_target_reachable(u))
        return false;
    df::coord p = Units::getPosition(u);
    return in_fort_dug(p) || citizen_near(ai, p, 15, 3) != nullptr;
}

// a hostile flier over the yard (or diving at a dwarf): every crossbow squad
// goes after it, and the civilians go indoors (22 dwarves killed by giant
// wrens, sparrows, butterflies, eagles and ospreys at Cloisterbolt, 166-169)
static bool hostile_flier_over_fort(AI & ai, df::unit *u)
{
    if (!is_flier(u) || u->flags1.bits.active_invader || u->flags1.bits.marauder || harmless_guest(u) || Units::isOwnCiv(u))
        return false;
    if (!Units::isAgitated(u) && !Units::isDanger(u) && !AI::is_attacking_citizen(u))
        return false;
    if (!ai.pop.military_target_reachable(u) && !ai.pop.military_target_shootable(u))
        return false;
    df::coord p = Units::getPosition(u);
    if (ai.plan.entrance())
    {
        df::coord e = ai.plan.entrance()->pos();
        if (std::abs(p.x - e.x) <= 40 && std::abs(p.y - e.y) <= 40 && p.z >= e.z - 6)
            return true;
    }
    return citizen_near(ai, p, 15, 6) != nullptr;
}

static int64_t abs_tick()
{
    return int64_t(*cur_year) * 403200 + *cur_year_tick;
}

bool AI::tag_enemies(color_ostream & out)
{
    bool found = false;
    std::set<int32_t> claimed; // ordinary kill targets already held by a squad
    for (auto id : plotinfo->main.fortress_entity->squads)
    {
        auto squad = df::squad::find(id);
        if (!squad)
        {
            continue;
        }
        Population *pop_ref = &pop;
        AI *ai_ref = this;
        bool hungry = squad_needs_meal(squad);
        // drop targets that are gone, dead or out of reach (they piled up after a battle and
        // flooded the log with "Cannot find unit for squad kill order")
        for (size_t i = 0; i < squad->orders.size(); i++)
        {
            auto kill = virtual_cast<df::squad_order_kill_listst>(squad->orders.at(i));
            if (!kill)
                continue;
            auto & ids = kill->units;
            bool ranged = !squad->ammo.ammunition.empty();
            ids.erase(std::remove_if(ids.begin(), ids.end(), [pop_ref, ai_ref, hungry, ranged, &claimed](int32_t uid) -> bool
            {
                auto t = df::unit::find(uid);
                // marksdwarves keep a flier they can't walk to: they shoot it
                // a caged animal can't be killed: squads stood guard over the
                // cage-trapped beasts by the execution pit for days (Topcloister)
                if (t && (t->flags1.bits.caged || t->flags1.bits.chained))
                    return true;
                if (!t || Units::isDead(t) || (!pop_ref->military_target_reachable(t) && !(ranged && is_flier(t) && pop_ref->military_target_shootable(t))))
                    return true;
                // a hungry or thirsty squad lets go of a flier (not a great
                // beast or an invader) and eats; the fed squads keep it, and
                // it gets it back once fed. Boatsbrands: one giant sparrow
                // circling out of reach above the fort held 6 squads, and 26
                // soldiers went hungry and thirsty
                if (hungry && is_flier(t) && !Units::isGreatDanger(t) && !t->flags1.bits.active_invader && !t->flags1.bits.marauder)
                    return true;
                // every squad keeps a dangerous creature in the fort or by a
                // dwarf, and every crossbow squad a hostile flier over the
                // fort: the one-squad rule below is for harmless wildlife
                if (close_threat(*ai_ref, t) || (ranged && hostile_flier_over_fort(*ai_ref, t)))
                    return false;
                // ordinary wildlife: only near home, and not while the squad starves
                if (ordinary_target(t) && (hungry || !near_fort(*ai_ref, t)))
                    return true;
                if (Units::isAgitated(t) && !near_fort(*ai_ref, t) && !agitated_over_fort(*ai_ref, t))
                    return true;
                // one squad per ordinary target: orders handed out before
                // that rule left 17 squads chasing 3 monkeys
                if (!Units::isGreatDanger(t) && !t->flags1.bits.active_invader && !t->flags1.bits.marauder && !claimed.insert(uid).second)
                    return true;
                return false;
            }), ids.end());
            if (ids.empty())
            {
                vector_erase_at(squad->orders, i);
                i--;
                found = true;
            }
        }
        for (auto order : squad->orders)
        {
            if (auto kill = virtual_cast<df::squad_order_kill_listst>(order))
            {
                for (auto unit_id : kill->units)
                {
                    auto unit = df::unit::find(unit_id);
                    if (unit && std::find(world->units.active.begin(), world->units.active.end(), unit) == world->units.active.end())
                    {
                        found = pop.military_cancel_attack_order(out, unit, "unit no longer active on map") || found;
                    }
                }
            }
        }
    }
    for (auto it = world->units.active.rbegin(); it != world->units.active.rend(); it++)
    {
        df::unit *u = *it;
        df::creature_raw *race = df::creature_raw::find(u->race);
        if (!Units::isDead(u) && Units::getPosition(u).isValid() &&
            !Units::isOwnCiv(u) && Units::getContainer(u) == nullptr && !u->flags1.bits.caged && !u->flags1.bits.chained &&
            !Maps::getTileDesignation(Units::getPosition(u))->bits.hidden)
        {
            if (race && race->flags.is_set(creature_raw_flags::HAS_ANY_MEGABEAST))
            {
                found = pop.military_great_beast(out, u, "primary antagonist: megabeast") || found;
            }
            else if (race && race->flags.is_set(creature_raw_flags::HAS_ANY_SEMIMEGABEAST))
            {
                found = pop.military_great_beast(out, u, "primary antagonist: semi-megabeast") || found;
            }
            else if (race && race->flags.is_set(creature_raw_flags::HAS_ANY_FEATURE_BEAST))
            {
                found = pop.military_great_beast(out, u, "primary antagonist: forgotten beast") || found;
            }
            else if (race && race->flags.is_set(creature_raw_flags::HAS_ANY_TITAN))
            {
                found = pop.military_great_beast(out, u, "primary antagonist: titan") || found;
            }
            else if (race && race->flags.is_set(creature_raw_flags::HAS_ANY_UNIQUE_DEMON))
            {
                found = pop.military_great_beast(out, u, "primary antagonist: demon") || found;
            }
            else if (race && race->flags.is_set(creature_raw_flags::HAS_ANY_DEMON))
            {
                found = pop.military_all_squads_attack_unit(out, u, "antagonist: demon") || found;
            }
            else if (race && race->flags.is_set(creature_raw_flags::HAS_ANY_NIGHT_CREATURE))
            {
                found = pop.military_all_squads_attack_unit(out, u, "antagonist: night creature") || found;
            }
            else if (hostile_flier_over_fort(*this, u))
            {
                // every crossbow squad (military_random_squad_attack_unit),
                // civilians indoors while it lasts
                pop.flier_threat_at = abs_tick();
                found = pop.military_random_squad_attack_unit(out, u, "hostile flier over the fort") || found;
            }
            else if (close_threat(*this, u))
            {
                df::coord p = Units::getPosition(u);
                auto c = citizen_near(*this, p, 15, 3);
                std::string why = in_fort_dug(p) ? "dangerous creature inside the fort" : "dangerous creature close to " + AI::describe_unit(c);
                if (pop.close_threat_at < 0 || abs_tick() - pop.close_threat_at > 1200)
                    debug(out, "[MILITARY] " + why + ": " + AI::describe_unit(u) + stl_sprintf(" at %d,%d,%d: every squad at home, civilians to safety", p.x, p.y, p.z));
                pop.close_threat_at = abs_tick();
                found = pop.military_all_squads_attack_unit(out, u, why) || found;
            }
            else if (Units::isOpposedToLife(u))
            {
                found = pop.military_random_squad_attack_unit(out, u, "undead") || found;
            }
            else if ((u->flags1.bits.active_invader || u->flags1.bits.marauder) && pop.outside_defenses(u))
            {
                // out past the curtain wall: the squads hold inside it (they
                // used to charge out after every siege; 111 of 149 goblin
                // kills at Channelevened were outside the wall). The bunkers'
                // and gate turrets' bolt throwers deal with them out there.
                pop.invaders_far++;
                found = pop.military_cancel_attack_order(out, u, "invader outside the curtain wall: holding inside it") || found;
            }
            else if (u->flags1.bits.active_invader)
            {
                if (invader_close(*this, u))
                    found = pop.military_all_squads_attack_unit(out, u, "active invader (murder ball)") || found;
                else
                    pop.invaders_far++;
            }
            else if (u->flags1.bits.marauder)
            {
                found = pop.military_all_squads_attack_unit(out, u, "marauder (murder ball)") || found;
            }
            else if (u->flags2.bits.underworld)
            {
                found = pop.military_random_squad_attack_unit(out, u, "underworld creature") || found;
            }
            else if (u->flags2.bits.visitor_uninvited)
            {
                found = pop.military_random_squad_attack_unit(out, u, "uninvited visitor") || found;
            }
            else if (agitated_over_fort(*this, u))
            {
                found = pop.military_random_squad_attack_unit(out, u, "agitated creature over the fort") || found;
            }
            else if (auto hunter = is_hunting_target(u))
            {
                found = pop.military_cancel_attack_order(out, u, "hunting target of " + AI::describe_unit(hunter)) || found;
            }
            else if (auto citizen = u->flags2.bits.roaming_wilderness_population_source && near_fort(*this, u) ? is_attacking_citizen(u) : nullptr)
            {
                found = pop.military_random_squad_attack_unit(out, u, "attacking citizen: " + AI::describe_unit(citizen)) || found;
            }
        }
    }
    return found;
}

// "ai threats": what tag_enemies would do about each creature in view right
// now (read-only)
void AI::describe_threats(std::ostream & os)
{
    int64_t now = abs_tick();
    os << "civilian alert: " << (plotinfo->alerts.civ_alert_idx > 0 ? "ON" : "off")
       << "; close threat last seen " << (pop.close_threat_at < 0 ? std::string("never") : stl_sprintf("%lld ticks ago", (long long)(now - pop.close_threat_at)))
       << "; hostile flier last seen " << (pop.flier_threat_at < 0 ? std::string("never") : stl_sprintf("%lld ticks ago", (long long)(now - pop.flier_threat_at))) << "\n";
    int32_t ranged = 0, home = 0;
    for (auto sqid : plotinfo->main.fortress_entity->squads)
        if (auto sq = df::squad::find(sqid))
            if (sq->assigned_army_controller_id == -1)
            {
                home++;
                if (!sq->ammo.ammunition.empty())
                    ranged++;
            }
    os << stl_sprintf("squads at home: %d (with ammo: %d)\n", home, ranged);
    // great beasts (hidden ones too: a dry run of what happens when it shows)
    int32_t armed_ranged = 0;
    for (auto sqid : plotinfo->main.fortress_entity->squads)
        if (auto sq = df::squad::find(sqid))
            if (sq->assigned_army_controller_id == -1 && !sq->ammo.ammunition.empty() && pop.squad_armed(sq))
                armed_ranged++;
    for (auto u : world->units.active)
    {
        if (Units::isDead(u) || Units::isOwnCiv(u) || u->flags1.bits.caged || u->flags1.bits.chained)
            continue;
        auto race = df::creature_raw::find(u->race);
        if (!race || !(race->flags.is_set(creature_raw_flags::HAS_ANY_MEGABEAST) || race->flags.is_set(creature_raw_flags::HAS_ANY_SEMIMEGABEAST) ||
            race->flags.is_set(creature_raw_flags::HAS_ANY_FEATURE_BEAST) || race->flags.is_set(creature_raw_flags::HAS_ANY_TITAN) ||
            race->flags.is_set(creature_raw_flags::HAS_ANY_UNIQUE_DEMON)))
            continue;
        df::coord p = Units::getPosition(u);
        bool hidden = Maps::getTileDesignation(p) && Maps::getTileDesignation(p)->bits.hidden;
        bool wounded = Population::beast_badly_wounded(u);
        bool reach = pop.military_target_reachable(u);
        os << "GREAT BEAST " << AI::describe_unit(u) << stl_sprintf(" at %d,%d,%d%s: blood %d/%d, %d wounds; ", p.x, p.y, p.z, hidden ? " (hidden)" : "",
            u->body.blood_count, u->body.blood_max, int32_t(u->body.wounds.size()))
           << (!reach ? "not reachable: no orders" :
               stl_sprintf("%d crossbow squads shoot it; melee squads ", armed_ranged) + std::string((wounded || armed_ranged == 0) ? (wounded ? "go in (badly wounded)" : "go in (no archers)") : "hold at home until it is badly wounded"))
           << "\n";
    }
    int32_t n = 0;
    for (auto u : world->units.active)
    {
        if (Units::isDead(u) || Units::isOwnCiv(u) || !Units::getPosition(u).isValid() || Maps::getTileDesignation(Units::getPosition(u))->bits.hidden)
            continue;
        bool fl = hostile_flier_over_fort(*this, u), ct = !fl && close_threat(*this, u);
        bool danger = !harmless_guest(u) && dangerous_creature(u);
        if (!fl && !ct && !danger)
            continue;
        df::coord p = Units::getPosition(u);
        int32_t holders = 0;
        for (auto sqid : plotinfo->main.fortress_entity->squads)
            if (auto sq = df::squad::find(sqid))
                for (auto o : sq->orders)
                    if (auto k = strict_virtual_cast<df::squad_order_kill_listst>(o))
                        if (std::find(k->units.begin(), k->units.end(), u->id) != k->units.end())
                            holders++;
        auto c = citizen_near(*this, p, 15, 3);
        os << AI::describe_unit(u) << stl_sprintf(" at %d,%d,%d", p.x, p.y, p.z)
           << ": " << (fl ? "HOSTILE FLIER over the fort -> every crossbow squad + civilian alert" :
                       ct ? "CLOSE THREAT -> every home squad + civilian alert" : "dangerous, not close (normal rules)")
           << (in_fort_dug(p) ? "; in fort-dug space" : "") << (c ? "; a citizen within 15 tiles" : "")
           << (pop.military_target_reachable(u) ? "; reachable" : "; not reachable") << stl_sprintf("; held by %d squads", holders) << "\n";
        n++;
    }
    if (!n)
        os << "no dangerous creature in view\n";
}

df::unit *AI::is_attacking_citizen(df::unit *u)
{
    // Plain loops instead of nested lambdas: MSVC 19.44 fails on the
    // lambda-in-lambda form here with C2011 (lambda class redefinition).
    for (auto act_id : u->activities)
    {
        auto act = df::activity_entry::find(act_id);
        if (!act)
            continue;
        for (auto event : act->events)
        {
            auto conflict = virtual_cast<df::activity_event_conflictst>(event);
            if (!conflict)
                continue;

            df::conflict_sidest *unit_side = nullptr;
            for (auto side : conflict->sides)
            {
                if (std::find(side->unit_ids.begin(), side->unit_ids.end(), u->id) != side->unit_ids.end())
                {
                    unit_side = side;
                    break;
                }
            }
            if (!unit_side)
                continue; // Not in their own fight?

            for (auto enemy_side : unit_side->enemies)
            {
                if (enemy_side->conflict_level < df::conflict_level::Lethal)
                    continue;
                df::conflict_sidest *side = nullptr;
                for (auto s2 : conflict->sides)
                {
                    if (s2->id == enemy_side->id)
                    {
                        side = s2;
                        break;
                    }
                }
                if (!side)
                    continue;
                for (auto enemy_id : side->unit_ids)
                {
                    auto enemy = df::unit::find(enemy_id);
                    if (enemy && Units::isSane(enemy) && Units::isCitizen(enemy))
                        return enemy;
                }
            }
        }
    }
    return nullptr;
}

df::unit *AI::is_hunting_target(df::unit *u)
{
    for (auto c : world->units.active)
    {
        if (Units::isSane(c) && Units::isCitizen(c) && u->job.current_job && u->job.current_job->job_type == job_type::Hunt && c->job.hunt_target == u)
        {
            return c;
        }
    }

    return nullptr;
}

bool AI::is_in_conflict(df::unit *u, std::function<bool(df::activity_event_conflictst *)> filter)
{
    for (auto id : u->activities)
    {
        if (auto act = df::activity_entry::find(id))
        {
            for (auto event : act->events)
            {
                if (auto conflict = virtual_cast<df::activity_event_conflictst>(event))
                {
                    if (!filter || filter(conflict))
                    {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}
