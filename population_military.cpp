#include "ai.h"
#include <fstream>
#include "exclusive_callback.h"
#include "population.h"
#include "plan.h"
#include "debug.h"

#include "modules/Items.h"
#include "modules/Military.h"
#include "modules/Maps.h"
#include "modules/Units.h"

#include "df/entity_material_category.h"
#include "df/entity_position.h"
#include "df/entity_position_assignment.h"
#include "df/entity_uniform.h"
#include "df/entity_uniform_item.h"
#include "df/equip_infost.h"
#include "df/historical_entity.h"
#include "df/historical_figure.h"
#include "df/histfig_entity_link_positionst.h"
#include "df/history_event_add_hf_entity_linkst.h"
#include "df/item_weaponst.h"
#include "df/itemdef_ammost.h"
#include "df/itemdef_weaponst.h"
#include "df/job.h"
#include "df/job_list_link.h"
#include "df/military_routinest.h"
#include "df/alert_state_infost.h"
#include "df/squad_routine_schedulest.h"
#include "df/occupation.h"
#include "df/squad.h"
#include "df/creature_raw.h"
#include "df/caste_raw.h"
#include "df/squad_ammo_spec.h"
#include "df/job_skill.h"
#include "df/job_skill_class.h"
#include "df/unit_soul.h"
#include "df/unit_skill.h"
#include "df/squad_order_kill_listst.h"
#include "df/unit_wound.h"
#include "df/squad_barracks_infost.h"
#include "df/squad_position_equipmentst.h"
#include "df/squad_order_movest.h"
#include "df/squad_position.h"
#include "df/squad_uniform_spec.h"
#include "df/plotinfost.h"
#include "df/uniform_category.h"
#include "df/unit_misc_trait.h"
#include "df/world.h"
#include "df/squad_barracks_infost.h"
#include "df/civzone_type.h"
#include "df/buildings_other_id.h"
#include "df/squad_use_flags.h"
#include "df/building_civzonest.h"
#include "df/alert_statest.h"
#include "df/burrow.h"
#include "df/weapon_flags.h"
#include "df/squad_schedule_entry.h"
#include "df/squad_schedule_order.h"
#include "df/squad_schedulest.h"
#include "df/squad_order_trainst.h"
#include "df/squad_month_positionst.h"
#include "df/unit_relationship_type.h"
#include "df/unit_inventory_item.h"
#include "stocks.h"

REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(cur_year_tick);
REQUIRE_GLOBAL(hist_event_next_id);
REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

// A squad's name for the log: DF 53 squads usually have no translated name,
// so the log read "Ordering squad  to kill": use the alias, else the name,
// else what the game shows ("Kivish's Squad", after the leader).
static std::string squad_label(df::squad *squad)
{
    if (!squad)
        return "a squad";
    if (!squad->alias.empty())
        return squad->alias;
    std::string nm = AI::describe_name(squad->name, true);
    if (!nm.empty())
        return nm;
    for (auto pos : squad->positions)
    {
        if (!pos || pos->occupant == -1)
            continue;
        auto hf = df::historical_figure::find(pos->occupant);
        if (hf && !hf->name.first_name.empty())
        {
            std::string first = hf->name.first_name;
            first[0] = toupper(first[0]);
            return first + "'s Squad";
        }
    }
    return "squad " + std::to_string(squad->id);
}

// In DF 0.47 these exclusive callbacks drove the military screen with
// simulated keypresses. In v50+ they edit squads directly through DFHack's
// Military module and the underlying structures.
class MilitarySetupExclusive : public ExclusiveCallback
{
protected:
    AI & ai;
    std::list<int32_t> units;

    typedef typename std::vector<df::unit *>::const_iterator unit_iterator;
    MilitarySetupExclusive(AI & ai, const std::string & description, unit_iterator begin, unit_iterator end) : ExclusiveCallback(description, 2), ai(ai), units()
    {
        for (auto it = begin; it != end; it++)
        {
            units.push_back((*it)->id);
        }
    }
    virtual void Run(color_ostream & out)
    {
        if (!plotinfo->main.fortress_entity)
        {
            return;
        }

        while (!units.empty())
        {
            Run(out, units.front());

            units.pop_front();
        }
    }
    virtual void Run(color_ostream & out, int32_t unit_id) = 0;

    static df::unit *position_unit(df::squad_position *pos)
    {
        if (!pos)
        {
            return nullptr;
        }
        auto fig = df::historical_figure::find(pos->occupant);
        return fig ? df::unit::find(fig->unit_id) : nullptr;
    }

    static void flag_equipment_update(df::squad *squad)
    {
        df::equipment_update update;
        update.bits.weapon = 1;
        update.bits.armor = 1;
        update.bits.shoes = 1;
        update.bits.shield = 1;
        update.bits.helm = 1;
        update.bits.gloves = 1;
        update.bits.ammo = 1;
        update.bits.pants = 1;
        update.bits.backpack = 1;
        update.bits.quiver = 1;
        update.bits.flask = 1;
        if (squad)
        {
            squad->ammo.update.whole |= update.whole;
        }
        plotinfo->equipment.update.whole |= update.whole;
    }

public:
    class Draft;
    class Dismiss;
    class UnequipTool;
};

class MilitarySetupExclusive::Draft : public MilitarySetupExclusive
{
public:
    Draft(AI & ai, unit_iterator begin, unit_iterator end) : MilitarySetupExclusive(ai, "military - draft", begin, end)
    {
    }

    static int32_t count_members(df::squad *squad)
    {
        return int32_t(std::count_if(squad->positions.begin(), squad->positions.end(), [](df::squad_position *pos) -> bool { return pos && pos->occupant != -1; }));
    }

    df::squad *find_good_squad(int32_t squad_size)
    {
        for (auto sqid : plotinfo->main.fortress_entity->squads)
        {
            auto squad = df::squad::find(sqid);
            if (squad && squad->entity_id == plotinfo->main.fortress_entity->id && count_members(squad) < std::min(squad_size, int32_t(squad->positions.size())))
            {
                return squad;
            }
        }

        return nullptr;
    }

    // Find (or create) a squad-leading position assignment that has no squad
    // yet. Returns nullptr if nobody can appoint a new squad leader.
    df::entity_position_assignment *find_vacant_squad_assignment(color_ostream & out)
    {
        auto entity = plotinfo->main.fortress_entity;

        for (auto asn : entity->positions.assignments)
        {
            if (asn->squad_id != -1)
            {
                continue;
            }
            auto pos = binsearch_in_vector(entity->positions.own, asn->position_id);
            if (pos && pos->squad_size > 0)
            {
                return asn;
            }
        }

        // No vacant squad slot. Create a new assignment for a squad-leading
        // position that is filled "as needed" (eg. militia captain), provided
        // that whoever appoints that position is present.
        for (size_t i = 0; i < entity->positions.own.size(); i++)
        {
            auto pos = entity->positions.own.at(i);
            if (pos->squad_size <= 0 || pos->number != -1)
            {
                continue;
            }

            bool can_appoint = pos->appointed_by.empty();
            for (auto appointer_id : pos->appointed_by)
            {
                for (auto asn : entity->positions.assignments)
                {
                    if (asn->position_id == appointer_id && asn->histfig != -1)
                    {
                        can_appoint = true;
                        break;
                    }
                }
            }
            if (!can_appoint)
            {
                continue;
            }

            df::entity_position_assignment *model = nullptr;
            for (auto asn : entity->positions.assignments)
            {
                if (asn->position_id == pos->id)
                {
                    model = asn;
                    break;
                }
            }

            auto asn = new df::entity_position_assignment();
            asn->id = entity->positions.next_assignment_id++;
            asn->position_id = pos->id;
            asn->position_vector_idx = int32_t(i);
            if (model)
            {
                asn->flags = model->flags;
            }
            else
            {
                asn->flags.set(entity_position_profile_flags::active);
            }
            entity->positions.assignments.push_back(asn);

            ai.debug(out, "Created new " + pos->name[0] + " position for a new squad.");
            return asn;
        }

        return nullptr;
    }

    // Make the unit the leader (position 0) of the squad by appointing it to
    // the squad's leading noble position, as the military screen would.
    bool appoint_leader(color_ostream & out, df::squad *squad, df::unit *u)
    {
        auto entity = plotinfo->main.fortress_entity;
        auto hf = df::historical_figure::find(u->hist_figure_id);
        if (!hf || u->military.squad_id != -1)
        {
            return false;
        }

        df::entity_position_assignment *asn = nullptr;
        size_t asn_idx = 0;
        for (size_t i = 0; i < entity->positions.assignments.size(); i++)
        {
            if (entity->positions.assignments.at(i)->id == squad->leader_assignment)
            {
                asn = entity->positions.assignments.at(i);
                asn_idx = i;
                break;
            }
        }
        if (!asn)
        {
            ai.debug(out, "[ERROR] Cannot find leader assignment for squad " + squad_label(squad));
            return false;
        }

        if (squad->positions.empty())
        {
            return false;
        }

        auto old_hf = df::historical_figure::find(asn->histfig);
        if (old_hf && old_hf->died_year == -1)
        {
            // The position already has a living holder (eg. an existing
            // militia commander): seat them instead of replacing them.
            auto holder = df::unit::find(old_hf->unit_id);
            if (holder && holder->military.squad_id == -1 && Units::isAlive(holder))
            {
                auto pos = squad->positions.at(0);
                if (!pos)
                {
                    pos = squad->positions.at(0) = df::allocate<df::squad_position>();
                }
                pos->occupant = old_hf->id;
                holder->military.squad_id = squad->id;
                holder->military.squad_position = 0;
                flag_equipment_update(squad);
                ai.debug(out, "Seating existing " + AI::describe_unit(holder) + " as leader of " + squad_label(squad));
            }
            return false;
        }

        if (old_hf)
        {
            for (size_t j = 0; j < old_hf->entity_links.size(); j++)
            {
                auto link = virtual_cast<df::histfig_entity_link_positionst>(old_hf->entity_links.at(j));
                if (link && link->assignment_id == asn->id && link->entity_id == entity->id)
                {
                    vector_erase_at(old_hf->entity_links, j);
                    // not freed: DFHack 53.14+ refuses to free pool-allocated game objects
                    break;
                }
            }
            asn->histfig2 = old_hf->id;
        }

        asn->histfig = hf->id;

        auto link = df::allocate<df::histfig_entity_link_positionst>();
        link->entity_id = entity->id;
        link->link_strength = 100;
        link->assignment_id = asn->id;
        link->assignment_vector_idx = int32_t(asn_idx);
        link->start_year = *cur_year;
        hf->entity_links.push_back(link);

        auto event = df::allocate<df::history_event_add_hf_entity_linkst>();
        event->year = *cur_year;
        event->seconds = *cur_year_tick;
        event->id = (*hist_event_next_id)++;
        event->civ = entity->id;
        event->histfig = hf->id;
        event->link_type = histfig_entity_link_type::POSITION;
        event->position_id = asn->position_id;
        event->appointer_hfid = -1;
        event->promise_to_hfid = -1;
        world->history.events.push_back(event);

        auto pos = squad->positions.at(0);
        if (!pos)
        {
            pos = squad->positions.at(0) = df::allocate<df::squad_position>();
        }
        pos->occupant = hf->id;

        u->military.squad_id = squad->id;
        u->military.squad_position = 0;

        flag_equipment_update(squad);

        return true;
    }

    virtual void Run(color_ostream & out, int32_t unit_id)
    {
        auto u = df::unit::find(unit_id);
        if (!u || u->military.squad_id != -1)
        {
            return;
        }

        int32_t num_soldiers = int32_t(units.size());
        int32_t num_squads = 0;
        for (auto sqid : plotinfo->main.fortress_entity->squads)
        {
            if (auto squad = df::squad::find(sqid))
            {
                num_soldiers += count_members(squad);
                num_squads++;
            }
        }

        int32_t squad_size = 10;
        if (num_soldiers < 4 * 8)
            squad_size = 8;
        if (num_soldiers < 4 * 6)
            squad_size = 6;
        if (num_soldiers < 3 * 4)
            squad_size = 4;

        df::squad *selected_squad = find_good_squad(squad_size);

        if (!selected_squad)
        {
            ai.debug(out, "Creating new squad...");

            auto asn = find_vacant_squad_assignment(out);
            if (!asn)
            {
                ai.debug(out, "[ERROR] We have no military commander and nobody is able to appoint one.");
                return;
            }

            selected_squad = Military::makeSquad(asn->id);
            if (!selected_squad)
            {
                ai.debug(out, "[ERROR] Failed to create a new squad.");
                return;
            }

            ApplyUniform(out, selected_squad, SelectOrCreateUniform(out, size_t(num_squads)));
        }

        ai.debug(out, "Selecting squad: " + AI::describe_name(selected_squad->name, true));

        bool has_leader = false;
        if (!selected_squad->positions.empty())
        {
            auto leader = position_unit(selected_squad->positions.at(0));
            has_leader = leader && Units::isAlive(leader);
        }

        if (!has_leader)
        {
            if (!ai.pop.resident.count(unit_id))
            {
                if (appoint_leader(out, selected_squad, u))
                {
                    ai.debug(out, "Recruiting new squad leader: " + AI::describe_unit(u));
                    return;
                }
            }
            else
            {
                // Mercenaries can't lead squads.
                // Move an existing citizen soldier into this squad as the leader.
                bool reassigned = false;
                for (auto sqid : plotinfo->main.fortress_entity->squads)
                {
                    auto squad = df::squad::find(sqid);
                    if (!squad || squad == selected_squad)
                    {
                        continue;
                    }

                    for (auto pos : squad->positions)
                    {
                        auto other = position_unit(pos);
                        if (!other || ai.pop.resident.count(other->id) || other->military.squad_position == 0)
                        {
                            continue;
                        }

                        ai.debug(out, "Reassigning " + AI::describe_unit(other) + " from " + squad_label(squad) + " to lead new squad " + AI::describe_name(selected_squad->name, true));
                        Military::removeFromSquad(other->id);
                        reassigned = appoint_leader(out, selected_squad, other);
                        break;
                    }

                    if (reassigned)
                    {
                        break;
                    }
                }

                if (!reassigned)
                {
                    ai.debug(out, "[WARNING] Could not find an existing soldier to lead squad: " + AI::describe_name(selected_squad->name, true));
                }
            }
        }

        // Military::addToSquad cannot fill the leader slot and does not
        // bounds-check its automatic slot search, so pick a slot ourselves.
        int32_t free_slot = -1;
        for (size_t i = 1; i < selected_squad->positions.size(); i++)
        {
            auto pos = selected_squad->positions.at(i);
            if (!pos || pos->occupant == -1)
            {
                free_slot = int32_t(i);
                break;
            }
        }

        if (free_slot != -1 && Military::addToSquad(unit_id, selected_squad->id, free_slot))
        {
            ai.debug(out, "Recruiting new squad member: " + AI::describe_unit(u));
        }
        else
        {
            ai.debug(out, "Failed to recruit " + AI::describe_unit(u) + ": no free position in " + AI::describe_name(selected_squad->name, true));
        }
    }

    df::entity_uniform *SelectOrCreateUniform(color_ostream & out, size_t existing_squad_count)
    {
        auto entity = plotinfo->main.fortress_entity;
        bool ranged = existing_squad_count % 3 == 1;

        df::uniform_indiv_choice indiv_choice;
        if (ranged)
        {
            indiv_choice.bits.ranged = 1;
        }
        else
        {
            indiv_choice.bits.melee = 1;
        }

        auto check_uniform_item = [](df::entity_uniform *u, df::uniform_category cat, df::item_type item_type, df::entity_material_category mat_class = entity_material_category::Armor, df::uniform_indiv_choice indiv_choice = df::uniform_indiv_choice()) -> bool
        {
            return u->uniform_item_types[cat].size() == 1 && u->uniform_item_types[cat].at(0) == item_type && u->uniform_item_info[cat].size() == 1 && u->uniform_item_info[cat].at(0)->material_class == mat_class && u->uniform_item_info[cat].at(0)->indiv_choice.whole == indiv_choice.whole;
        };

        auto selected = std::find_if(entity->uniforms.begin(), entity->uniforms.end(), [&](df::entity_uniform *u) -> bool
        {
            return u->flags.bits.exact_matches && !u->flags.bits.replace_clothing &&
                check_uniform_item(u, uniform_category::body, item_type::ARMOR) &&
                check_uniform_item(u, uniform_category::head, item_type::HELM) &&
                check_uniform_item(u, uniform_category::pants, item_type::PANTS) &&
                check_uniform_item(u, uniform_category::gloves, item_type::GLOVES) &&
                check_uniform_item(u, uniform_category::shoes, item_type::SHOES) &&
                check_uniform_item(u, uniform_category::shield, item_type::SHIELD) &&
                check_uniform_item(u, uniform_category::weapon, item_type::WEAPON, entity_material_category::None, indiv_choice);
        });

        if (selected != entity->uniforms.end())
        {
            ai.debug(out, "Selected uniform for squad: " + (*selected)->name);
            return *selected;
        }

        auto uniform = new df::entity_uniform();
        uniform->id = entity->next_uniform_id++;
        uniform->type = entity_uniform_type::None;
        uniform->name = ranged ? "Heavy ranged" : "Heavy melee";
        uniform->flags.bits.exact_matches = 1;
        uniform->flags.bits.replace_clothing = 0;

        auto add_uniform_part = [&](df::uniform_category cat, df::item_type type)
        {
            auto info = new df::entity_uniform_item();
            info->mattype = -1;
            info->matindex = -1; // default 0 = one specific material; nothing matched
            if (type == item_type::WEAPON)
            {
                info->material_class = entity_material_category::None;
                info->indiv_choice = indiv_choice;
            }
            else
            {
                info->material_class = entity_material_category::Armor;
            }
            uniform->uniform_item_types[cat].push_back(type);
            uniform->uniform_item_subtypes[cat].push_back(-1);
            uniform->uniform_item_info[cat].push_back(info);
        };

        add_uniform_part(uniform_category::body, item_type::ARMOR);
        add_uniform_part(uniform_category::head, item_type::HELM);
        add_uniform_part(uniform_category::pants, item_type::PANTS);
        add_uniform_part(uniform_category::gloves, item_type::GLOVES);
        add_uniform_part(uniform_category::shoes, item_type::SHOES);
        add_uniform_part(uniform_category::shield, item_type::SHIELD);
        add_uniform_part(uniform_category::weapon, item_type::WEAPON);

        entity->uniforms.push_back(uniform);

        ai.debug(out, ranged ? "Created new uniform for ranged squad." : "Created new uniform for melee squad.");

        return uniform;
    }

    // Copy an entity uniform template into every position of a squad, which
    // is what selecting a uniform when creating a squad does in the game.
    void ApplyUniform(color_ostream & out, df::squad *squad, df::entity_uniform *uniform)
    {
        if (!uniform)
        {
            return;
        }

        bool ranged = false;

        for (auto pos : squad->positions)
        {
            if (!pos)
            {
                continue;
            }

            FOR_ENUM_ITEMS(uniform_category, cat)
            {
                // DF 53 added NONE = -1 to this enum; it is not a valid array index.
                if (cat < 0)
                    continue;
                auto & specs = pos->equipment.uniform[cat];
                if (!specs.empty())
                {
                    // don't touch a uniform that was already set up
                    continue;
                }

                for (size_t i = 0; i < uniform->uniform_item_types[cat].size(); i++)
                {
                    auto info = vector_get(uniform->uniform_item_info[cat], i);
                    auto spec = new df::squad_uniform_spec();
                    spec->item = -1;
                    spec->item_type = uniform->uniform_item_types[cat].at(i);
                    spec->item_subtype = vector_get(uniform->uniform_item_subtypes[cat], i, int16_t(-1));
                    if (info)
                    {
                        spec->material_class = info->material_class;
                        spec->mattype = info->mattype;
                        spec->matindex = info->mattype == -1 ? -1 : info->matindex;
                        spec->color = info->item_color;
                        spec->indiv_choice = info->indiv_choice;
                        if (info->indiv_choice.bits.ranged)
                        {
                            ranged = true;
                        }
                    }
                    specs.push_back(spec);
                }
            }

            pos->equipment.flags = uniform->flags;
        }

        // Metal bolts are for killing, bone and wood bolts for training (user).
        // Squads set up before that rule had one any-material spec for both:
        // swap it for the split ones.
        if (ranged && squad->ammo.ammunition.size() == 1 && squad->ammo.ammunition[0]->material_class == entity_material_category::None)
        {
            delete squad->ammo.ammunition[0];
            squad->ammo.ammunition.clear();
        }
        if (ranged && squad->ammo.ammunition.empty())
        {
            // Give marksdwarves some bolts: metal to fight with, bone and wood to train with.
            int16_t bolt_subtype = -1;
            for (auto subtype : plotinfo->main.fortress_entity->resources.ammo_type)
            {
                auto def = df::itemdef_ammost::find(subtype);
                if (def && def->ammo_class == "BOLT")
                {
                    bolt_subtype = subtype;
                    break;
                }
            }

            if (bolt_subtype != -1)
            {
                auto spec = [&](df::entity_material_category mat, int32_t amount, bool combat)
                {
                    auto ammo = new df::squad_ammo_spec();
                    ammo->item_type = item_type::AMMO;
                    ammo->item_subtype = bolt_subtype;
                    ammo->material_class = mat;
                    ammo->amount = amount;
                    ammo->flags.bits.use_combat = combat;
                    ammo->flags.bits.use_training = !combat;
                    squad->ammo.ammunition.push_back(ammo);
                };
                spec(entity_material_category::AmmoMetal, 300, true);
                spec(entity_material_category::Bone, 200, false);
                spec(entity_material_category::Wood, 200, false);
            }
        }

        flag_equipment_update(squad);

        ai.debug(out, "Assigned uniform " + uniform->name + " to squad " + squad_label(squad));
    }

    static bool compare(const df::unit *a, const df::unit *b)
    {
        return Population::unit_totalxp(a) < Population::unit_totalxp(b);
    }
};

class MilitarySetupExclusive::Dismiss : public MilitarySetupExclusive
{
public:
    Dismiss(AI & ai, unit_iterator begin, unit_iterator end) : MilitarySetupExclusive(ai, "military - dismiss", begin, end)
    {
    }

    virtual void Run(color_ostream & out, int32_t unit_id)
    {
        auto u = df::unit::find(unit_id);
        if (!u)
        {
            return;
        }

        auto squad = df::squad::find(u->military.squad_id);
        if (!squad)
        {
            ai.debug(out, "[ERROR] Cannot find squad for unit: " + AI::describe_unit(u));
            return;
        }

        if (!Military::removeFromSquad(unit_id) && u->military.squad_id != -1)
        {
            ai.debug(out, "[ERROR] Cannot remove unit from squad: " + AI::describe_unit(u));
            return;
        }

        flag_equipment_update(squad);

        ai.debug(out, "Dismissed " + AI::describe_unit(u) + " from " + squad_label(squad));
    }

    static bool compare(const df::unit *a, const df::unit *b)
    {
        return Population::unit_totalxp(a) > Population::unit_totalxp(b);
    }
};

class MilitarySetupExclusive::UnequipTool : public MilitarySetupExclusive
{
public:
    UnequipTool(AI & ai, unit_iterator begin, unit_iterator end) : MilitarySetupExclusive(ai, "military - unequip tool", begin, end)
    {
    }

    virtual void Run(color_ostream & out, int32_t unit_id)
    {
        auto u = df::unit::find(unit_id);
        if (!u)
        {
            return;
        }

        auto squad = df::squad::find(u->military.squad_id);
        if (!squad)
        {
            ai.debug(out, "[ERROR] Cannot find squad for unit: " + AI::describe_unit(u));
            return;
        }

        auto position = vector_get(squad->positions, size_t(u->military.squad_position));
        if (!position || position->occupant != u->hist_figure_id)
        {
            ai.debug(out, "[ERROR] Cannot find unit in squad: " + AI::describe_unit(u));
            return;
        }

        for (auto spec : position->equipment.uniform[uniform_category::weapon])
        {
            for (size_t i = 0; i < spec->assigned.size(); i++)
            {
                auto item_id = spec->assigned.at(i);
                auto weapon = virtual_cast<df::item_weaponst>(df::item::find(item_id));

                if (!weapon)
                {
                    continue;
                }
                if (weapon->subtype->flags.is_set(weapon_flags::TRAINING))
                {
                    continue;
                }
                if (weapon->subtype->skill_melee != job_skill::AXE && weapon->subtype->skill_melee != job_skill::MINING)
                {
                    continue;
                }

                int16_t replacement = SelectReplacementWeaponType(out);
                if (replacement == -1)
                {
                    ai.debug(out, "Cannot confiscate " + AI::describe_item(weapon) + " from " + AI::describe_unit(u) + ": no replacement weapon type.");
                    continue;
                }

                ai.debug(out, "Confiscating " + AI::describe_item(weapon) + " from " + AI::describe_unit(u) + ": item needed for civilian labor.");

                // Same steps as DFHack's gui/choose-weapons script.
                spec->item = -1;
                spec->item_type = item_type::WEAPON;
                spec->item_subtype = replacement;
                spec->indiv_choice.whole = 0;

                vector_erase_at(spec->assigned, i);
                i--;
                erase_from_vector(position->equipment.assigned_items, item_id);
                if (erase_from_vector(plotinfo->equipment.items_assigned[item_type::WEAPON], item_id))
                {
                    insert_into_vector(plotinfo->equipment.items_unassigned[item_type::WEAPON], item_id);
                }
                plotinfo->equipment.update.bits.weapon = 1;
                u->uniform.pickup_flags.bits.update = 1;
            }
        }
    }

    int16_t SelectReplacementWeaponType(color_ostream & out)
    {
        int16_t best = -1;
        int32_t best_score = 0;
        std::string name;

        // Weapon types our civilization can make, rather than the list from
        // the (removed) military equipment screen. These are never foreign.
        for (auto subtype : plotinfo->main.fortress_entity->resources.weapon_type)
        {
            auto def = df::itemdef_weaponst::find(subtype);
            if (!def)
            {
                continue;
            }
            if (def->skill_ranged != job_skill::NONE)
            {
                continue;
            }
            if (def->skill_melee == job_skill::AXE || def->skill_melee == job_skill::MINING)
            {
                continue;
            }
            if (def->flags.is_set(weapon_flags::TRAINING))
            {
                continue;
            }

            int32_t score = 0;
            auto & in_stock_map = ai.stocks.count_subtype[stock_item::weapon_melee];
            auto in_stock = in_stock_map.find(subtype);
            if (in_stock != in_stock_map.end())
            {
                score = in_stock->second.first;
            }
            score = (score + 1) * 2;
            if (best_score < score)
            {
                best = subtype;
                best_score = score;
                name = def->name;
            }
        }

        if (best != -1)
        {
            ai.debug(out, "Assigning weapon type " + name + " instead.");
        }

        return best;
    }
};

// DF 53 did not hand weapons to some df-ai squads (8 soldiers fought a
// forgotten beast barehanded with 8 free maces in the stockpile). Assign a
// free weapon directly, the way the squad equipment screen does.
// the soldier can fight with this weapon: it exists, is a real weapon (not
// a training one), and nobody else holds it (a dead soldier's hand, a goblin)
static bool weapon_usable_by(df::item *it, df::unit *u)
{
    auto w = virtual_cast<df::item_weaponst>(it);
    if (!w || !w->subtype || w->flags.bits.garbage_collect || w->flags.bits.removed)
        return false;
    if (w->subtype->flags.is_set(weapon_flags::TRAINING))
        return false;
    df::item *outer = w;
    df::unit *h = Items::getHolderUnit(w);
    if (!h)
        if (auto c = Items::getContainer(w))
            h = Items::getHolderUnit(c), outer = c;
    if (!h || h == u)
        return true;
    // a hauler carrying it (to the soldier or a stockpile) doesn't count
    for (auto inv : h->inventory)
        if (inv && inv->item == outer && inv->mode == df::inv_item_role_type::Hauled)
            return !Units::isDead(h);
    return false;
}

// a weapon in hand, or one assigned that the soldier can go and fetch
static bool soldier_armed(df::squad_position *pos, df::unit *u)
{
    for (auto inv : u->inventory)
        if (inv && inv->mode == df::inv_item_role_type::Weapon && weapon_usable_by(inv->item, u))
            return true;
    for (auto spec : pos->equipment.uniform[uniform_category::weapon])
        for (auto id : spec->assigned)
            if (weapon_usable_by(df::item::find(id), u))
                return true;
    return false;
}

static df::unit *position_unit_on_map(df::squad_position *pos)
{
    if (!pos || pos->occupant == -1)
        return nullptr;
    auto hf = df::historical_figure::find(pos->occupant);
    auto u = hf ? df::unit::find(hf->unit_id) : nullptr;
    if (!u || !Units::isActive(u) || Units::isDead(u) || u->flags1.bits.inactive)
        return nullptr;
    return u;
}

// Divedfountain: 55 of the 95 dwarves killed by a goblin siege were Recruits
// and Wrestlers sent into the fight with no weapon at all. A squad goes into
// a fight only when half or more of its members on the map have a weapon
// (in hand or assigned); otherwise it shelters with the civilians until armed.
bool Population::squad_armed(df::squad *sq)
{
    if (!sq)
        return false;
    int32_t n = 0, armed = 0;
    for (auto pos : sq->positions)
    {
        auto u = position_unit_on_map(pos);
        if (!u)
            continue;
        n++;
        if (soldier_armed(pos, u))
            armed++;
    }
    return n == 0 || armed * 2 >= n;
}

// soldiers on the map with no weapon to fight with (trade buys this many)
int32_t dfai_unarmed_soldiers()
{
    int32_t n = 0;
    auto fe = plotinfo->main.fortress_entity;
    if (!fe)
        return 0;
    for (auto sqid : fe->squads)
        if (auto sq = df::squad::find(sqid))
            for (auto pos : sq->positions)
                if (auto u = position_unit_on_map(pos))
                    if (!soldier_armed(pos, u))
                        n++;
    return n;
}

void Population::arm_soldiers(color_ostream & out)
{
    auto & eq = plotinfo->equipment;
    auto & unassigned = eq.items_unassigned[item_type::WEAPON];
    bool changed = false;
    for (auto squad : world->squads.all)
    {
        if (!squad || squad->entity_id != plotinfo->group_id)
            continue;
        for (auto pos : squad->positions)
        {
            if (!pos || pos->occupant == -1)
                continue;
            df::unit *soldier = position_unit_on_map(pos);
            bool shield = !pos->equipment.uniform[uniform_category::shield].empty();
            for (auto spec : pos->equipment.uniform[uniform_category::weapon])
            {
                // a weapon that is gone or in someone else's hands (a dead
                // soldier's, a goblin's) is no weapon: drop it so a free one
                // can be given
                if (soldier)
                {
                    for (size_t i = 0; i < spec->assigned.size(); i++)
                    {
                        int32_t id = spec->assigned[i];
                        df::item *it = df::item::find(id);
                        if (it && weapon_usable_by(it, soldier))
                            continue;
                        vector_erase_at(spec->assigned, i);
                        i--;
                        erase_from_vector(pos->equipment.assigned_items, id);
                        if (erase_from_vector(eq.items_assigned[item_type::WEAPON], id) && it)
                            insert_into_vector(unassigned, id);
                        ai.debug(out, stl_sprintf("[MILITARY] dropped weapon %d from the uniform of ", id) + AI::describe_unit(soldier) + (it ? ": " + AI::describe_item(it) + " is in someone else's hands" : std::string(": it is gone")));
                        changed = true;
                    }
                }
                if (!spec->assigned.empty())
                    continue;
                bool want_ranged = spec->indiv_choice.bits.ranged;
                df::item *pick = nullptr;
                for (auto id : unassigned)
                {
                    auto w = virtual_cast<df::item_weaponst>(df::item::find(id));
                    if (!w || !w->subtype)
                        continue;
                    auto & f = w->flags.bits;
                    if (f.forbid || f.foreign || f.trader || f.in_job || f.owned || f.removed || f.garbage_collect)
                        continue;
                    // weapons in a stockpile bin count (38 maces sat in bins);
                    // held ones don't
                    if (f.in_inventory && (Items::getHolderUnit(w) || !Stocks::is_item_free(w)))
                        continue;
                    // too big to wield, or two-handed for a dwarf with a shield
                    // in the uniform
                    if (soldier && (w->subtype->minimum_size > soldier->body.size_info.size_cur ||
                        (shield && w->subtype->two_handed > soldier->body.size_info.size_cur)))
                        continue;
                    if (w->subtype->flags.is_set(weapon_flags::TRAINING))
                        continue;
                    // leave picks and axes for miners and woodcutters
                    if (w->subtype->skill_melee == job_skill::MINING || w->subtype->skill_melee == job_skill::AXE)
                        continue;
                    if (spec->item_subtype != -1 && w->subtype->subtype != spec->item_subtype)
                        continue;
                    bool is_ranged = w->subtype->skill_ranged != job_skill::NONE;
                    if (spec->item_subtype == -1 && is_ranged != want_ranged)
                        continue;
                    pick = w;
                    break;
                }
                if (!pick)
                    continue;
                spec->assigned.push_back(pick->id);
                pos->equipment.assigned_items.push_back(pick->id);
                erase_from_vector(unassigned, pick->id);
                insert_into_vector(eq.items_assigned[item_type::WEAPON], pick->id);
                if (auto hf = df::historical_figure::find(pos->occupant))
                {
                    if (auto u = df::unit::find(hf->unit_id))
                    {
                        u->uniform.pickup_flags.bits.update = 1;
                        ai.debug(out, "[MILITARY] gave " + AI::describe_item(pick) + " to " + AI::describe_unit(u));
                    }
                }
                changed = true;
            }
        }
    }
    if (changed)
        eq.update.bits.weapon = 1;
}

// Megabeasts, forgotten beasts and invaders: send civilians indoors with a
// civilian alert (a "Safety" burrow flood-filled over the indoor fort), and
// lift it once nothing dangerous has been reachable for a while. A forgotten
// beast killed ~24 civilians caught outdoors in Quakefocus.
// Invaders or a great danger on the map: every squad goes on the "Ready"
// routine (on duty, in uniform: off-duty soldiers had been fighting goblins
// bare-handed while 60 weapons sat in the stockpiles), equipment is
// re-assigned, and squads with no one to kill yet muster at the fort entrance.
// When the map has been quiet for a while, everyone goes back to training.
// our "muster at the gate" orders: a plain move order to the fort entrance
static bool is_muster(AI & ai, df::squad_order_movest *mv)
{
    return mv && ai.plan.entrance() && mv->pos == ai.plan.entrance()->pos();
}

static int32_t routine_named(const char *name)
{
    auto & rs = plotinfo->alerts.routines;
    for (size_t i = 0; i < rs.size(); i++)
        if (rs[i] && rs[i]->name == name)
            return int32_t(i);
    return -1;
}

static void request_equipment(df::squad *squad)
{
    df::equipment_update update;
    update.whole = 0;
    update.bits.weapon = update.bits.armor = update.bits.shoes = update.bits.shield = 1;
    update.bits.helm = update.bits.gloves = update.bits.ammo = update.bits.pants = 1;
    update.bits.backpack = update.bits.quiver = update.bits.flask = 1;
    if (squad)
        squad->ammo.update.whole |= update.whole;
    plotinfo->equipment.update.whole |= update.whole;
}

// Archery ranges go to the squads that shoot (user request: an archery range
// for the marksdwarves). df-ai gave each range to whichever squad got the
// barracks it belongs to: squad 95 (no crossbows) had one while the two
// crossbow squads (9 each) had none, and nobody practised. Once a game day,
// every squad with 3+ ranged weapons assigned also gets training rights on
// the range nearest its barracks (DF lets squads share a zone).
// the walkable area most of the fort's citizens are in. Asking only the first
// citizen gave the wrong answer whenever that one dwarf stood somewhere cut
// off (Topcloister: squads spent days on kill orders for agitated animals on
// a hillside no dwarf could reach)
static uint16_t fort_walk_group(const std::set<int32_t> & citizen)
{
    static int32_t cached_tick = -1, cached_year = -1;
    static uint16_t cached = 0;
    if (cached_tick == *cur_year_tick && cached_year == *cur_year)
        return cached;
    std::map<uint16_t, int32_t> counts;
    int32_t seen = 0;
    for (auto id : citizen)
    {
        auto c = df::unit::find(id);
        if (!c || !Units::isActive(c) || Units::isDead(c))
            continue;
        uint16_t g = Maps::getWalkableGroup(Units::getPosition(c));
        if (g)
            counts[g]++;
        if (++seen >= 40)
            break;
    }
    uint16_t best = 0;
    int32_t bn = 0;
    for (auto & kv : counts)
        if (kv.second > bn)
            best = kv.first, bn = kv.second;
    cached_tick = *cur_year_tick;
    cached_year = *cur_year;
    cached = best;
    return best;
}

// on open ground outside the curtain wall's ring (underground counts as in:
// something that got under the fort is the army's business)
bool Population::outside_defenses(df::unit *u)
{
    if (!defense_min.isValid() || !defense_max.isValid())
        return false;
    df::coord p = Units::getPosition(u);
    df::tile_designation *td = Maps::getTileDesignation(p);
    if (!td || !td->bits.outside)
        return false;
    if (std::abs(p.z - defense_min.z) > 8)
        return false;
    return p.x <= defense_min.x || p.x >= defense_max.x || p.y <= defense_min.y || p.y >= defense_max.y;
}

bool Population::military_target_reachable(df::unit *u)
{
    uint16_t fg = fort_walk_group(citizen);
    if (!fg)
        return true;
    return Maps::getWalkableGroup(Units::getPosition(u)) == fg;
}

// a flier the marksdwarves can shoot: over (or near) ground the fort walks on,
// at most 10 levels above it
bool Population::military_target_shootable(df::unit *u)
{
    uint16_t fg = fort_walk_group(citizen);
    if (!fg)
        return true;
    df::coord p = Units::getPosition(u);
    for (int16_t dz = 0; dz <= 10; dz++)
        for (int16_t dx = -4; dx <= 4; dx++)
            for (int16_t dy = -4; dy <= 4; dy++)
                if (p.z - dz >= 0 && Maps::getWalkableGroup(df::coord(p.x + dx, p.y + dy, p.z - dz)) == fg)
                    return true;
    return false;
}

static void ranged_squads_to_ranges(AI & ai, color_ostream & out)
{
    static int32_t last_day = -1;
    int32_t day = *cur_year * 1000 + *cur_year_tick / 1200;
    if (day == last_day)
        return;
    last_day = day;

    std::vector<df::building_civzonest *> ranges;
    for (auto b : world->buildings.other[buildings_other_id::ACTIVITY_ZONE])
    {
        auto z = virtual_cast<df::building_civzonest>(b);
        if (z && z->type == civzone_type::ArcheryRange && z->spec_sub_flag.bits.active)
            ranges.push_back(z);
    }
    auto fe = plotinfo->main.fortress_entity;
    if (ranges.empty() || !fe)
        return;

    for (auto sqid : fe->squads)
    {
        auto sq = df::squad::find(sqid);
        if (!sq)
            continue;
        int32_t ranged = 0;
        for (auto pos : sq->positions)
        {
            if (!pos)
                continue;
            for (auto iid : pos->equipment.assigned_items)
            {
                auto w = virtual_cast<df::item_weaponst>(df::item::find(iid));
                if (w && w->subtype && w->subtype->skill_ranged != job_skill::NONE)
                {
                    ranged++;
                    break;
                }
            }
        }
        if (ranged < 3)
            continue;
        // already training on a range?
        bool has = false;
        df::coord home;
        for (auto rm : sq->rooms)
        {
            auto z = virtual_cast<df::building_civzonest>(df::building::find(rm->building_id));
            if (!z)
                continue;
            if (z->type == civzone_type::ArcheryRange && rm->mode.bits.train)
                has = true;
            if (z->type == civzone_type::Barracks && !home.isValid())
                home = df::coord(z->centerx, z->centery, z->z);
        }
        if (has)
            continue;
        df::building_civzonest *best = nullptr;
        int32_t best_d = 0;
        for (auto z : ranges)
        {
            int32_t d = home.isValid() ? std::abs(z->centerx - home.x) + std::abs(z->centery - home.y) + 4 * std::abs(z->z - home.z) : 0;
            if (!best || d < best_d)
            {
                best = z;
                best_d = d;
            }
        }
        df::squad_use_flags flags;
        flags.whole = 0;
        flags.bits.train = 1;
        Military::updateRoomAssignments(sq->id, best->id, flags);
        std::string nm = !sq->alias.empty() ? sq->alias : AI::describe_name(sq->name, true);
        if (nm.empty())
            nm = stl_sprintf("squad %d", sq->id);
        ai.debug(out, stl_sprintf("[MILITARY] %s (%d crossbows/bows) trains on the archery range %d", nm.c_str(), ranged, best->id));
    }
}

void Population::battle_stations(color_ostream & out, bool danger, size_t cap)
{
    auto fe = plotinfo->main.fortress_entity;
    if (!fe)
        return;
    int32_t ready = routine_named("Ready"), train = routine_named("Staggered training");
    if (danger)
    {
        battle_quiet = 0;
        int32_t off = routine_named("Off duty");
        size_t called = 0; // soldiers called out so far (cap: 0 = every squad)
        for (auto sqid : fe->squads)
        {
            auto sq = df::squad::find(sqid);
            if (!sq || sq->assigned_army_controller_id != -1)
                continue; // away on a mission
            if (cap && called >= cap)
                continue; // enough squads for one creature: the rest keep working
            if (!squad_armed(sq))
            {
                // no weapons: off duty, so the civilian alert takes them into
                // the Safety burrow, and no kill or muster orders
                if (off >= 0)
                    sq->cur_routine_idx = off;
                for (size_t i = 0; i < sq->orders.size(); i++)
                {
                    auto o = sq->orders[i];
                    if (strict_virtual_cast<df::squad_order_kill_listst>(o) || is_muster(ai, strict_virtual_cast<df::squad_order_movest>(o)))
                    {
                        vector_erase_at(sq->orders, i);
                        i--;
                    }
                }
                request_equipment(sq);
                if (sheltering.insert(sq->id).second)
                    ai.debug(out, "[MILITARY] " + squad_label(sq) + " has no weapons: off duty, sheltering with the civilians until armed");
                continue;
            }
            if (sheltering.erase(sq->id))
                ai.debug(out, "[MILITARY] " + squad_label(sq) + " is armed again: back to the fight");
            called += size_t(std::count_if(sq->positions.begin(), sq->positions.end(), [](df::squad_position *p) { return p && p->occupant != -1; }));
            if (ready >= 0 && sq->cur_routine_idx != ready)
            {
                sq->cur_routine_idx = ready;
                request_equipment(sq);
            }
            bool has_kill = false;
            df::squad_order_movest *muster = nullptr;
            size_t muster_i = 0;
            for (size_t i = 0; i < sq->orders.size(); i++)
            {
                if (strict_virtual_cast<df::squad_order_kill_listst>(sq->orders[i]))
                    has_kill = true;
                else if (auto mv = strict_virtual_cast<df::squad_order_movest>(sq->orders[i]))
                    if (is_muster(ai, mv)) { muster = mv; muster_i = i; }
            }
            if (!has_kill && !muster && ai.plan.entrance())
            {
                auto mv = df::allocate<df::squad_order_movest>();
                mv->year = *cur_year;
                mv->year_tick = *cur_year_tick;
                mv->pos = ai.plan.entrance()->pos();
                mv->point_id = -1;
                sq->orders.push_back(mv);
            }
            else if (has_kill && muster)
            {
                vector_erase_at(sq->orders, muster_i); // engage: the muster is over
            }
        }
        if (!battle_mode)
        {
            battle_mode = true;
            ai.debug(out, stl_sprintf("[MILITARY] battle stations: %s on the Ready routine in full uniform%s", cap ? stl_sprintf("squads with about %d soldiers", int(cap)).c_str() : "every squad", invaders_far ? stl_sprintf(", mustering at the gate while %d invaders approach", invaders_far).c_str() : ""));
        }
        return;
    }
    if (++battle_quiet < 8)
        return;
    // quiet: back to training (also catches a battle interrupted by a reload)
    bool any = false;
    for (auto sqid : fe->squads)
    {
        auto sq = df::squad::find(sqid);
        if (!sq)
            continue;
        if (ready >= 0 && train >= 0 && (sq->cur_routine_idx == ready || (sheltering.count(sq->id) && sq->cur_routine_idx == 0)))
        {
            sq->cur_routine_idx = train;
            any = true;
        }
        for (size_t i = 0; i < sq->orders.size(); i++)
        {
            auto mv = strict_virtual_cast<df::squad_order_movest>(sq->orders[i]);
            if (is_muster(ai, mv))
            {
                vector_erase_at(sq->orders, i);
                i--;
                any = true;
            }
        }
    }
    if (battle_mode || any)
        ai.debug(out, "[MILITARY] stand down: squads back to staggered training");
    battle_mode = false;
    sheltering.clear();
}

void Population::civilian_alert(color_ostream & out, bool danger)
{
    static int quiet_checks = 0;
    auto & alerts = plotinfo->alerts;
    if (!danger)
    {
        if (alerts.civ_alert_idx > 0 && ++quiet_checks >= 8)
        {
            alerts.civ_alert_idx = 0;
            ai.debug(out, "[MILITARY] danger gone: civilian alert lifted");
        }
        return;
    }
    quiet_checks = 0;
    if (alerts.civ_alert_idx > 0)
        return;

    // find or create the Safety burrow
    df::burrow *safety = nullptr;
    for (auto b : plotinfo->burrows.list)
    {
        if (b && b->name == "Safety")
            safety = b;
    }
    if (!safety)
    {
        safety = df::allocate<df::burrow>();
        safety->id = plotinfo->burrows.next_id++;
        safety->name = "Safety";
        safety->tile = 8;
        safety->fg_color = 7;
        safety->bg_color = 0;
        plotinfo->burrows.list.push_back(safety);
    }

    // (re)flood the indoor fort from a citizen standing inside, so the
    // burrow keeps up with new digging
    df::unit *seed = nullptr;
    for (auto id : citizen)
    {
        auto u = df::unit::find(id);
        auto d = u ? Maps::getTileDesignation(u->pos) : nullptr;
        if (d && !d->bits.outside && !d->bits.flow_size)
        {
            seed = u;
            break;
        }
    }
    if (seed)
    {
        std::ofstream discard;
        color_ostream_wrapper discard_wrapper(discard);
        Core::getInstance().runCommand(discard_wrapper, stl_sprintf("burrow tiles flood-add Safety -c %d,%d,%d", seed->pos.x, seed->pos.y, seed->pos.z));

        // The 3D flood follows stairs down to the mines and caverns, which is
        // exactly where forgotten beasts come from: 15 dwarves died inside
        // the "Safety" burrow 30 levels below the living quarters. Keep only
        // the levels from 4 below the lowest bedroom up.
        int16_t lowest = 0x7fff;
        ai.find_room(room_type::bedroom, [&lowest](room *r) -> bool
        {
            if (r->min.z < lowest)
                lowest = r->min.z;
            return false; // visit them all
        });
        if (lowest != 0x7fff && lowest > 4)
        {
            Core::getInstance().runCommand(discard_wrapper, stl_sprintf("burrow tiles box-remove Safety 0,0,0 %d,%d,%d",
                world->map.x_count - 1, world->map.y_count - 1, lowest - 5));
        }
    }

    // find or create the alert that uses it
    int32_t idx = -1;
    for (size_t i = 0; i < alerts.list.size(); i++)
    {
        auto a = alerts.list[i];
        if (a && a->name == "Civilian alert")
            idx = int32_t(i);
    }
    if (idx == -1)
    {
        auto a = df::allocate<df::alert_statest>();
        a->id = alerts.next_id++;
        a->name = "Civilian alert";
        alerts.list.push_back(a);
        idx = int32_t(alerts.list.size() - 1);
    }
    auto a = alerts.list[idx];
    if (std::find(a->burrows.begin(), a->burrows.end(), safety->id) == a->burrows.end())
        a->burrows.push_back(safety->id);

    alerts.civ_alert_idx = idx;
    ai.debug(out, "[MILITARY] danger on the map: civilian alert, everyone into the Safety burrow");
}

bool Population::is_doctor(df::unit *u)
{
    for (auto occ : u->occupations)
    {
        if (occ && occ->type == occupation_type::DOCTOR)
            return true;
    }
    return false;
}

// A parent carries their baby into battle (and babies die there).
bool Population::carries_baby(df::unit *u)
{
    for (auto other : world->units.active)
    {
        if (other && Units::isBaby(other) && Units::isAlive(other) &&
            (other->relationship_ids[unit_relationship_type::Mother] == u->id || other->relationship_ids[unit_relationship_type::Father] == u->id))
            return true;
    }
    return false;
}

// Training rotates through every squad over the year. Squads are split into
// G groups (G = number of squads, at least 2, at most 4); group k trains in
// the months m with m % G == k, so each squad trains 12/G months spread over
// the year and only about 1/G of the army trains at a time while the rest
// works. Squads sharing a barracks get different groups where possible, so a
// barracks holds one training squad at a time. This rewrites each fort
// squad's "Staggered training" routine and puts off-duty squads with a
// barracks on it.
void Population::schedule_training(color_ostream & out)
{
    auto entity = plotinfo->main.fortress_entity;
    if (!entity)
        return;

    int32_t routine_idx = -1;
    auto & routines = plotinfo->alerts.routines;
    for (size_t i = 0; i < routines.size(); i++)
    {
        if (routines.at(i)->name == "Staggered training")
            routine_idx = int32_t(i);
    }
    if (routine_idx == -1 && routines.size() > 1)
        routine_idx = 1;
    if (routine_idx == -1)
        return;

    std::vector<df::squad *> squads;
    for (auto sqid : entity->squads)
    {
        auto squad = df::squad::find(sqid);
        if (!squad || size_t(routine_idx) >= squad->schedule.routine.size())
            continue;
        if (std::none_of(squad->positions.begin(), squad->positions.end(), [](df::squad_position *p) { return p && p->occupant != -1; }))
            continue;
        squads.push_back(squad);
    }
    if (squads.empty())
        return;
    std::sort(squads.begin(), squads.end(), [](df::squad *a, df::squad *b) { return a->id < b->id; });

    int32_t groups = std::min(std::max(int32_t(squads.size()), int32_t(2)), int32_t(4));

    auto barracks_of = [](df::squad *squad) -> int32_t
    {
        for (auto r : squad->rooms)
        {
            auto z = virtual_cast<df::building_civzonest>(df::building::find(r->building_id));
            if (z && z->type == civzone_type::Barracks)
                return z->id;
        }
        return -1;
    };

    std::map<int32_t, std::vector<int32_t>> taken_by_barracks; // barracks -> groups already training there
    std::vector<int32_t> group_load(groups, 0);
    for (size_t k = 0; k < squads.size(); k++)
    {
        auto squad = squads.at(k);
        int32_t bar = barracks_of(squad);

        // least-loaded group that no other squad in this barracks uses
        int32_t group = -1;
        auto & taken = taken_by_barracks[bar];
        if (int32_t(taken.size()) >= groups)
            taken.clear();
        for (int32_t g = 0; g < groups; g++)
        {
            if (bar != -1 && std::find(taken.begin(), taken.end(), g) != taken.end())
                continue;
            if (group == -1 || group_load.at(g) < group_load.at(group))
                group = g;
        }
        if (group == -1)
            group = int32_t(k % groups);
        taken.push_back(group);
        group_load.at(group)++;

        auto rt = squad->schedule.routine.at(routine_idx);
        int32_t members = int32_t(squad->positions.size());

        // guard duty: in a month it doesn't train, a squad may stand guard at
        // one of the posts. Each month the posts go to different squads in
        // turn, so every post has a guard most months and the duty rotates.
        int32_t N = int32_t(squads.size()), G = int32_t(guard_posts.size());
        auto guard_post = [&](int32_t m) -> int32_t
        {
            if (G == 0 || m % groups == group)
                return -1;
            // the year moves it on, so with more squads than months every
            // squad takes its turn over the years
            int32_t slot = int32_t((k + size_t(m) + size_t(12 * std::max(*cur_year, int32_t(0)))) % size_t(N));
            return slot < G ? slot : -1;
        };

        bool already = true;
        for (int32_t m = 0; m < 12; m++)
        {
            bool want = m % groups == group;
            int32_t post = guard_post(m);
            auto & orders = rt->month[m].orders;
            bool has = orders.size() == 1 && orders.at(0) && strict_virtual_cast<df::squad_order_trainst>(orders.at(0)->order);
            df::squad_order_movest *mv = orders.size() == 1 && orders.at(0) ? strict_virtual_cast<df::squad_order_movest>(orders.at(0)->order) : nullptr;
            if (want)
            {
                if (!has)
                    already = false;
            }
            else if (post != -1)
            {
                if (!mv || mv->pos != guard_posts.at(post))
                    already = false;
            }
            else if (!orders.empty())
                already = false;
        }

        if (!already)
        {
            std::vector<df::squad_schedule_order *> spare;
            for (int32_t m = 0; m < 12; m++)
            {
                auto & orders = rt->month[m].orders;
                for (auto o : orders)
                {
                    if (o && strict_virtual_cast<df::squad_order_trainst>(o->order))
                        spare.push_back(o);
                }
                orders.clear(); // other orders are dropped (not freed: pool-allocated)
                for (auto a : rt->month[m].order_assignments)
                {
                    if (a)
                        a->assigned_order_idx = -1;
                }
            }
            for (int32_t m = 0; m < 12; m++)
            {
                int32_t post = guard_post(m);
                if (post != -1)
                {
                    auto o = df::allocate<df::squad_schedule_order>();
                    auto mv = df::allocate<df::squad_order_movest>();
                    mv->year = *cur_year;
                    mv->year_tick = *cur_year_tick;
                    mv->pos = guard_posts.at(post);
                    mv->point_id = -1;
                    o->order = mv;
                    o->positions.resize(squad->positions.size(), false);
                    rt->month[m].orders.push_back(o);
                    continue;
                }
                if (m % groups != group)
                    continue;
                df::squad_schedule_order *o = nullptr;
                if (!spare.empty())
                {
                    o = spare.back();
                    spare.pop_back();
                }
                else
                {
                    o = df::allocate<df::squad_schedule_order>();
                    auto train = df::allocate<df::squad_order_trainst>();
                    train->year = *cur_year;
                    train->year_tick = *cur_year_tick;
                    o->order = train;
                    o->positions.resize(squad->positions.size(), false);
                }
                rt->month[m].orders.push_back(o);
            }
            std::string months;
            for (int32_t m = 0; m < 12; m++)
                months += m % groups == group ? 'T' : guard_post(m) != -1 ? 'G' : '.';
            ai.debug(out, stl_sprintf("[MILITARY] training rotation: squad %d %s: group %d of %d, months %s", squad->id, squad_label(squad).c_str(), group + 1, groups, months.c_str()));
        }
        for (int32_t m = 0; m < 12; m++)
        {
            for (auto o : rt->month[m].orders)
            {
                // the whole squad trains; four stand guard (the rest work)
                if (o)
                    o->min_count = strict_virtual_cast<df::squad_order_movest>(o->order) ? std::min(members, int32_t(4)) : members;
            }
        }

        if (squad->cur_routine_idx == 0 && bar != -1 && !sheltering.count(squad->id))
        {
            squad->cur_routine_idx = routine_idx;
            ai.debug(out, stl_sprintf("[MILITARY] squad %d put on the training rotation", squad->id));
        }
    }
}

void Population::update_military(color_ostream & out)
{
    bool need_pick = false, need_axe = false;
    for (auto job : world->jobs.list)
    {
        if (!ENUM_ATTR(job_type, is_designation, job->job_type))
        {
            continue;
        }

        if (ENUM_ATTR(job_type, skill, job->job_type) == job_skill::MINING)
        {
            need_pick = true;
        }
        else if (ENUM_ATTR(job_type, skill, job->job_type) == job_skill::WOODCUTTING)
        {
            need_axe = true;
        }

        if (need_pick && need_axe)
        {
            break;
        }
    }

    if (need_pick && ai.stocks.count_free.count(stock_item::pick) && ai.stocks.count_free.at(stock_item::pick) != 0)
    {
        need_pick = false;
    }
    if (need_axe && ai.stocks.count_free.count(stock_item::axe) && ai.stocks.count_free.at(stock_item::axe) != 0)
    {
        need_axe = false;
    }

    if (need_pick || need_axe)
    {
        for (auto u : world->units.active)
        {
            if (!Units::isCitizen(u) || !Units::isAdult(u) || !Units::isAlive(u) || !Units::isSane(u))
            {
                continue;
            }

            if (u->military.squad_id != -1)
            {
                continue;
            }

            if (u->status.labors[unit_labor::MINE] && std::any_of(u->inventory.begin(), u->inventory.end(), [](df::unit_inventory_item *item) -> bool { return item->item->isWeapon() && item->item->getMeleeSkill() == job_skill::MINING && virtual_cast<df::item_weaponst>(item->item)->subtype->flags.is_set(weapon_flags::TRAINING); }))
            {
                need_pick = false;
            }

            if (u->status.labors[unit_labor::CUTWOOD] && std::any_of(u->inventory.begin(), u->inventory.end(), [](df::unit_inventory_item *item) -> bool { return item->item->isWeapon() && item->item->getMeleeSkill() == job_skill::AXE && virtual_cast<df::item_weaponst>(item->item)->subtype->flags.is_set(weapon_flags::TRAINING); }))
            {
                need_axe = false;
            }

            if (!need_pick && !need_axe)
            {
                break;
            }
        }
    }

    if (need_pick || need_axe)
    {
        std::vector<df::unit *> confiscate_weapons_from;

        for (auto m : military)
        {
            auto u = df::unit::find(m.first);
            if (!u || !Units::isCitizen(u) || AI::is_in_conflict(u))
            {
                continue;
            }

            if (std::any_of(u->inventory.begin(), u->inventory.end(), [&](df::unit_inventory_item *item) -> bool { return item->item->isWeapon() && ((need_axe && item->item->getMeleeSkill() == job_skill::AXE) || (need_pick && item->item->getMeleeSkill() == job_skill::MINING)) && !virtual_cast<df::item_weaponst>(item->item)->subtype->flags.is_set(weapon_flags::TRAINING); }))
            {
                confiscate_weapons_from.push_back(u);
            }
        }

        if (!confiscate_weapons_from.empty())
        {
            events.queue_exclusive(std::make_unique<MilitarySetupExclusive::UnequipTool>(ai, confiscate_weapons_from.begin(), confiscate_weapons_from.end()));
        }
    }

    std::vector<df::unit *> soldiers;
    std::vector<df::unit *> want_draft;
    std::vector<df::unit *> draft_pool;

    for (auto u : world->units.active)
    {
        if (Units::isCitizen(u))
        {
            for (auto trait : u->status.misc_traits)
            {
                if (trait->id == misc_trait_type::Migrant)
                {
                    // wait until new arrival status is cleared to do next update.
                    return;
                }
            }
            if (u->military.squad_id == -1)
            {
                if (military.erase(u->id))
                {
                    ai.plan.freesoldierbarrack(out, u->id);
                }
                std::vector<Units::NoblePosition> positions;
                // nobles fight too (their duties fit the off-duty months),
                // except the ones whose job takes them away from a fight:
                // the chief medical dwarf, messengers, the broker
                bool noble_stays_out = false;
                if (Units::getNoblePositions(&positions, u))
                {
                    for (auto & pos : positions)
                    {
                        const std::string & code = pos.position->code;
                        if (code == "CHIEF_MEDICAL_DWARF" || code == "MESSENGER" ||
                            code == "MONARCH" || code == "BARON" || code == "COUNT" || code == "DUKE" ||
                            // the ones dismissed further down (manager, bookkeeper, broker):
                            // drafting them would only loop draft/dismiss
                            pos.position->responsibilities[entity_position_responsibility::ACCOUNTING] ||
                            pos.position->responsibilities[entity_position_responsibility::MANAGE_PRODUCTION] ||
                            pos.position->responsibilities[entity_position_responsibility::TRADE])
                            noble_stays_out = true;
                    }
                }
                // nobody in a breakdown: a tantrum, rage, despair or stupor
                // (dfai-tantrum-guard takes such soldiers OUT of their squads;
                // this keeps them from being drafted back until they calm down)
                auto sm = u->counters.soldier_mood;
                bool breakdown = sm == soldier_mood_type::Tantrum || sm == soldier_mood_type::Enraged ||
                    sm == soldier_mood_type::Depressed || sm == soldier_mood_type::Oblivious;
                if (!Units::isChild(u) && !Units::isBaby(u) && u->mood == mood_type::None && !noble_stays_out && !breakdown &&
                    !u->status.labors[unit_labor::MINE] && !u->status.labors[unit_labor::CUTWOOD] && !u->status.labors[unit_labor::HUNT] &&
                    Units::isSane(u) && !is_doctor(u) && !carries_baby(u))
                {
                    draft_pool.push_back(u);
                }
            }
            else
            {
                if (!military.count(u->id))
                {
                    military[u->id] = u->military.squad_id;
                    ai.plan.getsoldierbarrack(out, u->id);
                }

                std::vector<Units::NoblePosition> positions;
                if (Units::getNoblePositions(&positions, u))
                {
                    for (auto & pos : positions)
                    {
                        if (pos.position->responsibilities[entity_position_responsibility::ACCOUNTING] ||
                            pos.position->responsibilities[entity_position_responsibility::MANAGE_PRODUCTION] ||
                            pos.position->responsibilities[entity_position_responsibility::TRADE])
                        {
                            std::vector<df::unit *> dismiss;
                            dismiss.push_back(u);
                            events.queue_exclusive(std::make_unique<MilitarySetupExclusive::Dismiss>(ai, dismiss.begin(), dismiss.end()));
                            break;
                        }
                    }
                }

                auto squad = df::squad::find(u->military.squad_id);
                if (squad && (u->military.squad_position != 0 || std::find_if(squad->positions.begin(), squad->positions.end(), [u](df::squad_position *pos) -> bool
                {
                    if (!pos || pos->occupant == u->hist_figure_id)
                    {
                        return false;
                    }
                    auto occupant = df::historical_figure::find(pos->occupant);
                    if (!occupant)
                    {
                        return false;
                    }
                    auto occupant_unit = df::unit::find(occupant->unit_id);
                    return occupant_unit && Units::isAlive(occupant_unit);
                }) == squad->positions.end()))
                {
                    // Only allow removing squad leaders if they are the only one in the squad.
                    soldiers.push_back(u);
                }
            }
        }
        else if (resident.count(u->id))
        {
            if (u->military.squad_id == -1)
            {
                if (military.erase(u->id))
                {
                    ai.plan.freesoldierbarrack(out, u->id);
                }

                // Soldier residents should be recruited into the military.
                if (Units::isSane(u) && std::find_if(u->occupations.begin(), u->occupations.end(), [](df::occupation *occ) -> bool { return occ->type == occupation_type::MERCENARY; }) != u->occupations.end())
                {
                    want_draft.push_back(u);
                }
            }
            else if (!military.count(u->id))
            {
                military[u->id] = u->military.squad_id;
                ai.plan.getsoldierbarrack(out, u->id);
            }
        }
    }

    size_t max_military = citizen.size() * military_min / 100;
    size_t min_military = citizen.size() * military_max / 100;
    // A grown fort (20+ citizens, the point where the standing orders start)
    // drafts everyone who can and should fight: adults who aren't nobles,
    // doctors, miners/woodcutters/hunters (their tools are their weapons),
    // parents of babies, moody or insane. Training rotates (schedule_training),
    // so most soldiers work on any given month.
    bool everyone_fights = citizen.size() >= 20;
    size_t citizen_military = std::count_if(military.begin(), military.end(), [this](const std::pair<const int32_t, int32_t> & member) -> bool
    {
        return citizen.count(member.first);
    });

    // Never thin the army while something hostile that can reach the fort
    // is on the map: each death lowers the quota, and df-ai dismissed three
    // soldiers in the middle of a forgotten beast attack. (Underworld demons
    // behind solid rock are unreachable and don't count.)
    bool under_attack = false;
    bool great_danger = false;
    df::unit *anchor = nullptr;
    for (auto id : citizen)
    {
        anchor = df::unit::find(id);
        if (anchor)
            break;
    }
    if (anchor)
    {
        for (auto u : world->units.active)
        {
            if (u && Units::isAlive(u) && Units::isDanger(u) && !u->flags1.bits.caged && !u->flags1.bits.inactive &&
                Maps::canWalkBetween(anchor->pos, u->pos))
            {
                under_attack = true;
                if (Units::isGreatDanger(u) || u->flags1.bits.active_invader)
                {
                    great_danger = true;
                    break;
                }
            }
        }
    }
    // a dangerous creature in the fort or by a dwarf, or a hostile flier
    // over it (tag_enemies, every 200 ticks): civilians to the Safety burrow
    // while it lasts; a close threat also puts the squads on Ready
    int64_t now_tick = int64_t(*cur_year) * 403200 + *cur_year_tick;
    if (now_tick < close_threat_at || now_tick < flier_threat_at)
        close_threat_at = flier_threat_at = -1; // a reload went back in time
    bool close_threat = close_threat_at >= 0 && now_tick - close_threat_at <= 600;
    bool flier_threat = flier_threat_at >= 0 && now_tick - flier_threat_at <= 600;
    // the whole fort under arms from 100 citizens (see below); then a lone
    // creature by a dwarf calls out only the first squads, about 30% of the
    // fort, so the rest keep farming and brewing. Sieges, megabeasts and
    // forgotten beasts still call every squad.
    size_t best_fighters = std::max<size_t>(10, citizen.size() * 30 / 100);
    bool full_militia = everyone_fights && (citizen.size() >= 100 ||
        (citizen.size() >= 90 && citizen_military > best_fighters + 5));
    bool all_hands = great_danger || invaders_far > 0;
    civilian_alert(out, great_danger || close_threat || flier_threat);
    battle_stations(out, all_hands || close_threat, full_militia && !all_hands ? best_fighters : 0);
    ranged_squads_to_ranges(ai, out);
    invaders_far = 0;

    // A grown fort is a militia (user: "ensure everyone is in a squad and
    // gets rotated through training regularly" - Divedfountain was about to
    // fall to waves of invaders with 11 of 26 under arms). Everyone the draft
    // pool allows joins; schedule_training spreads the squads over up to 4
    // groups, so at most about a quarter of them train in a month and the
    // rest work. (It used to be 40%: Hammerfaiths drafted 49 of 58 with no
    // rotation and had nobody free for its mason jobs.)
    // ...but not everyone (user: "only draft fighters (not everyone)": at
    // Channelevened the whole militia mustered for every siege and 149 died
    // to goblins). The army is the fort's best fighters, about 30% of it
    // (at least 10): the most combat skill joins first, and the least
    // skilled go back to their trades when it's quiet, a few at a time.
    if (everyone_fights)
    {
        auto combat = [](df::unit *u) -> int32_t
        {
            int32_t s = 0;
            if (auto soul = u->status.current_soul)
                for (auto sk : soul->skills)
                {
                    auto cls = ENUM_ATTR(job_skill, type, sk->id);
                    if (cls == job_skill_class::MilitaryWeapon || cls == job_skill_class::MilitaryAttack ||
                        cls == job_skill_class::MilitaryUnarmed || cls == job_skill_class::MilitaryDefense)
                        s += sk->rating;
                }
            return s;
        };
        size_t target = best_fighters;
        // From 100 citizens the whole fort is under arms (user: "once
        // population hits 100 everyone should be in a squad and rotated for
        // training and armor"): everyone the draft pool allows, still
        // rotated by schedule_training (about a quarter trains in a month)
        // and armed by arm_soldiers. The pool keeps out who must not fight.
        // It stays a full militia down to 90 citizens, so a few deaths
        // around 100 don't dismiss and redraft half the fort.
        // ...except a civilian crew for the tool jobs: squad members won't
        // pick up a pick, axe or crossbow for work, and dfai-toollabor gives
        // mining, woodcutting and hunting to civilians only. Boatsbrands
        // drafted 170 of 183: 13 civilians left (mostly children and
        // nobles), no wood, so no charcoal, ash, lye, soap or metal armor,
        // and the well shaft never dug. About 8% (at least 8) of the
        // fort's able adults stay civilians; the least skilled soldiers go
        // back first.
        // The crew counts the civilians who already hold a tool labor (they
        // are outside the draft pool), so a dismissed dwarf who takes up a
        // pick doesn't shrink the pool and set off another round of
        // dismissals.
        if (full_militia)
        {
            size_t crew = std::max<size_t>(8, citizen.size() * 8 / 100);
            size_t tool_civilians = 0;
            for (auto id : citizen)
            {
                auto u = df::unit::find(id);
                if (u && u->military.squad_id == -1 && Units::isAdult(u) &&
                    (u->status.labors[unit_labor::MINE] || u->status.labors[unit_labor::CUTWOOD] || u->status.labors[unit_labor::HUNT]))
                    tool_civilians++;
            }
            size_t short_by = crew > tool_civilians ? crew - tool_civilians : 0;
            size_t eligible = citizen_military + draft_pool.size();
            target = std::max(best_fighters, eligible > short_by ? eligible - short_by : size_t(0));
        }
        if (citizen_military < target && !draft_pool.empty())
        {
            std::sort(draft_pool.begin(), draft_pool.end(), [&](df::unit *a, df::unit *b) { return combat(a) > combat(b); });
            auto mid = draft_pool.begin() + std::min(target - citizen_military, draft_pool.size());
            want_draft.insert(want_draft.end(), draft_pool.begin(), mid);
        }
        else if (citizen_military > target && !under_attack && !battle_mode && !soldiers.empty())
        {
            std::sort(soldiers.begin(), soldiers.end(), [&](df::unit *a, df::unit *b) { return combat(a) < combat(b); });
            auto mid = soldiers.begin() + std::min(std::min(citizen_military - target, soldiers.size()), size_t(4));
            ai.debug(out, stl_sprintf("[MILITARY] army of %d is over its %d best fighters: %d of the least skilled go back to their trades",
                int(citizen_military), int(target), int(mid - soldiers.begin())));
            events.queue_exclusive(std::make_unique<MilitarySetupExclusive::Dismiss>(ai, soldiers.begin(), mid));
        }
    }
    else if (citizen_military > max_military && !under_attack)
    {
        auto mid = soldiers.begin() + std::min(citizen_military - max_military, soldiers.size());
        std::partial_sort(soldiers.begin(), mid, soldiers.end(), &MilitarySetupExclusive::Dismiss::compare);
        events.queue_exclusive(std::make_unique<MilitarySetupExclusive::Dismiss>(ai, soldiers.begin(), mid));
    }
    else if (citizen_military < min_military)
    {
        auto mid = draft_pool.begin() + std::min(max_military - citizen_military, draft_pool.size());
        std::partial_sort(draft_pool.begin(), mid, draft_pool.end(), &MilitarySetupExclusive::Draft::compare);
        want_draft.insert(want_draft.end(), draft_pool.begin(), mid);
    }

    if (!want_draft.empty())
    {
        events.queue_exclusive(std::make_unique<MilitarySetupExclusive::Draft>(ai, want_draft.begin(), want_draft.end()));
    }

    arm_soldiers(out);
    schedule_training(out);

    // Every squad needs a Barracks zone to train in: squads whose only room
    // was an archery range never trained (most soldiers had combat skill 0-4
    // and 6 raw recruits died to one forgotten beast). Share a barracks.
    {
        std::vector<df::building_civzonest *> barracks;
        for (auto b : world->buildings.other[buildings_other_id::ACTIVITY_ZONE])
        {
            auto z = virtual_cast<df::building_civzonest>(b);
            if (z && z->type == civzone_type::Barracks && z->spec_sub_flag.bits.active)
                barracks.push_back(z);
        }
        size_t i = 0;
        for (auto squad : world->squads.all)
        {
            if (barracks.empty())
                break;
            if (!squad || squad->entity_id != plotinfo->group_id)
                continue;
            bool has = false;
            for (auto r : squad->rooms)
            {
                auto z = virtual_cast<df::building_civzonest>(df::building::find(r->building_id));
                if (z && z->type == civzone_type::Barracks)
                    has = true;
            }
            if (has)
                continue;
            auto z = barracks[i++ % barracks.size()];
            df::squad_use_flags flags;
            flags.bits.sleep = 1;
            flags.bits.train = 1;
            flags.bits.indiv_eq = 1;
            flags.bits.squad_eq = 1;
            Military::updateRoomAssignments(squad->id, z->id, flags);
            ai.debug(out, stl_sprintf("[MILITARY] squad %d had no barracks; assigned barracks zone %d", squad->id, z->id));
        }
    }

    // Check barracks construction status.
    ai.find_room(room_type::barracks, [](room *r) -> bool
    {
        if (r->status < room_status::dug)
        {
            return false;
        }

        auto squad = df::squad::find(r->squad_id);
        if (!squad)
        {
            return false;
        }

        auto training_equipment = df::building::find(r->bld_id);
        if (!training_equipment)
        {
            return false;
        }

        if (training_equipment->getBuildStage() < training_equipment->getMaxBuildStage())
        {
            return false;
        }

        // Barracks is ready to train soldiers. Send the squad to training.
        // In v50+ squads follow a routine (plotinfo->alerts.routines, mirrored
        // by squad->schedule.routine); routine 0 is "Off duty".
        if (squad->cur_routine_idx == 0)
        {
            int32_t training_idx = -1;
            auto & routines = plotinfo->alerts.routines;
            for (size_t i = 0; i < routines.size() && i < squad->schedule.routine.size(); i++)
            {
                if (routines.at(i)->name == "Staggered training" || (training_idx == -1 && routines.at(i)->name.find("training") != std::string::npos))
                {
                    training_idx = int32_t(i);
                }
            }
            if (training_idx == -1 && squad->schedule.routine.size() > 1)
            {
                training_idx = 1;
            }
            if (training_idx != -1)
            {
                squad->cur_routine_idx = training_idx;
            }
        }

        return false;
    });
}

class MilitarySquadAttackExclusive : public ExclusiveCallback
{
    AI & ai;
    std::map<int32_t, std::set<int32_t>> kill_orders;
public:
    MilitarySquadAttackExclusive(AI & ai) : ExclusiveCallback("squad attack updater", 2), ai(ai)
    {
    }

    virtual void Run(color_ostream & out)
    {
        using change_type = Population::squad_order_change;

        kill_orders.clear();

        for (const auto & change : ai.pop.squad_order_changes)
        {
            auto squad = df::squad::find(change.squad_id);
            auto unit = df::unit::find(change.unit_id);
            if (!squad || !unit)
            {
                continue;
            }

            switch (change.type)
            {
            case change_type::kill:
                if (!kill_orders.count(squad->id))
                {
                    std::set<int32_t> units;

                    for (auto order : squad->orders)
                    {
                        if (auto kill = strict_virtual_cast<df::squad_order_kill_listst>(order))
                        {
                            units.insert(kill->units.begin(), kill->units.end());
                        }
                    }

                    if (change.remove == (units.count(unit->id) == 0))
                    {
                        // This won't cause anything to change, so don't set the squad's orders.
                        continue;
                    }

                    kill_orders[squad->id] = units;
                }

                if (change.remove)
                {
                    if (kill_orders.at(squad->id).erase(unit->id))
                    {
                        ai.debug(out, "Cancelling squad order for " + squad_label(squad) + " to kill " + AI::describe_unit(unit) + ": " + change.reason);
                    }
                }
                else
                {
                    if (kill_orders.at(squad->id).insert(unit->id).second)
                    {
                        ai.debug(out, "Ordering squad " + squad_label(squad) + " to kill " + AI::describe_unit(unit) + ": " + change.reason);
                    }
                }
                break;
            }
        }

        ai.pop.squad_order_changes.clear();

        // In DF 0.47 this went through the squads sidebar. In v50+ we edit
        // squad->orders directly: one kill list order per squad holding all
        // of its targets.
        for (auto & kill_orders_squad : kill_orders)
        {
            auto squad = df::squad::find(kill_orders_squad.first);
            if (!squad)
            {
                continue;
            }

            std::vector<int32_t> targets;
            for (auto unit_id : kill_orders_squad.second)
            {
                if (df::unit::find(unit_id))
                {
                    targets.push_back(unit_id);
                }
                else
                {
                    ai.debug(out, "[ERROR] Cannot find unit for squad kill order: " + AI::describe_unit(df::unit::find(unit_id)));
                }
            }

            df::squad_order_kill_listst *kill = nullptr;
            for (size_t i = 0; i < squad->orders.size(); i++)
            {
                auto existing = strict_virtual_cast<df::squad_order_kill_listst>(squad->orders.at(i));
                if (!existing)
                {
                    continue;
                }

                if (!kill && !targets.empty())
                {
                    // reuse the first kill order
                    kill = existing;
                    continue;
                }

                // merge/cancel: remove any other kill order
                vector_erase_at(squad->orders, i);
                // not freed: DFHack 53.14+ refuses to free pool-allocated game objects
                i--;
            }

            if (targets.empty())
            {
                continue;
            }

            if (!kill)
            {
                kill = df::allocate<df::squad_order_kill_listst>();
                kill->year = *cur_year;
                kill->year_tick = *cur_year_tick;
                squad->orders.push_back(kill);
            }

            kill->units = targets;
            kill->histfigs.clear();
            if (targets.size() == 1)
            {
                kill->title = "Kill " + AI::describe_unit(df::unit::find(targets.front()));
            }
            else
            {
                kill->title = stl_sprintf("Kill %zu targets", targets.size());
            }
        }
    }
};

bool squad_needs_meal(df::squad *squad); // military.cpp

bool Population::military_random_squad_attack_unit(color_ostream & out, df::unit *u, const std::string & reason)
{
    // A flier gets every crossbow squad at home, not one (user: "bolt thrower
    // + archers should be the response for flying things"). Cloisterbolt lost
    // 7 dwarves to giant sparrows, wrens and buzzards while a single squad
    // went after each bird. Squads abroad keep their orders; with no crossbow
    // squad the usual one-squad choice below still applies.
    {
        auto craw = df::creature_raw::find(u->race);
        bool flier = craw && u->caste >= 0 && size_t(u->caste) < craw->caste.size() && craw->caste[u->caste]->flags.is_set(caste_raw_flags::FLIER);
        if (flier && !Units::isOwnCiv(u) && (military_target_reachable(u) || military_target_shootable(u)))
        {
            bool any = false;
            for (auto sqid : plotinfo->main.fortress_entity->squads)
            {
                auto sq = df::squad::find(sqid);
                if (!sq || sq->assigned_army_controller_id != -1 || sq->ammo.ammunition.empty() || !squad_armed(sq))
                    continue;
                // a squad that needs to eat and drink is left out (fliers
                // that aren't great beasts or invaders)
                if (squad_needs_meal(sq) && !Units::isGreatDanger(u) && !u->flags1.bits.active_invader && !u->flags1.bits.marauder)
                    continue;
                bool already = false;
                for (auto it : sq->orders)
                    if (auto so = strict_virtual_cast<df::squad_order_kill_listst>(it))
                        if (std::find(so->units.begin(), so->units.end(), u->id) != so->units.end())
                            already = true;
                for (auto & oc : squad_order_changes)
                    if (oc.squad_id == sqid && oc.unit_id == u->id && !oc.remove)
                        already = true;
                if (already)
                {
                    any = true;
                    continue;
                }
                if (military_squad_attack_unit(out, sq, u, reason))
                    any = true;
            }
            if (any)
                return true;
        }
    }
    // One squad per ordinary target (a monkey that bit a dancer): each new
    // attack used to hand the same animal to the next squad, and all 17
    // squads ended up chasing 3 gray langurs. Great dangers still get more.
    if (!Units::isGreatDanger(u))
    {
        for (auto sqid : plotinfo->main.fortress_entity->squads)
        {
            auto sq = df::squad::find(sqid);
            if (!sq)
                continue;
            for (auto it : sq->orders)
                if (auto so = strict_virtual_cast<df::squad_order_kill_listst>(it))
                    if (std::find(so->units.begin(), so->units.end(), u->id) != so->units.end())
                        return false;
        }
        for (auto & oc : squad_order_changes)
            if (oc.unit_id == u->id && !oc.remove)
                return false;
    }
    // never send a squad after something nobody can walk to: the order never
    // clears and the squad stands at the nearest spot forever (a wild boar on
    // a ledge held one)
    // fliers (an agitated quetzalcoatlus circling the fort) are for the
    // marksdwarves: they can shoot what nobody can walk to
    auto craw = df::creature_raw::find(u->race);
    bool flier = craw && size_t(u->caste) < craw->caste.size() && craw->caste[u->caste]->flags.is_set(caste_raw_flags::FLIER);
    bool have_ranged = false;
    if (flier)
    {
        for (auto sqid : plotinfo->main.fortress_entity->squads)
            if (auto sq = df::squad::find(sqid))
                if (!sq->ammo.ammunition.empty())
                    have_ranged = true;
    }
    if (!military_target_reachable(u) && !(flier && have_ranged && military_target_shootable(u)))
        return false;

    df::squad *squad = nullptr;
    int32_t best = std::numeric_limits<int32_t>::min();
    for (auto sqid : plotinfo->main.fortress_entity->squads)
    {
        df::squad *sq = df::squad::find(sqid);
        if (!sq || !squad_armed(sq))
        {
            continue;
        }

        int32_t score = 0;
        for (auto sp : sq->positions)
        {
            if (sp && sp->occupant != -1)
            {
                score++;
            }
        }
        score -= int32_t(sq->orders.size());
        if (flier)
        {
            // only marksdwarves for a flier
            if (sq->ammo.ammunition.empty())
                continue;
            score += 1000;
        }

        std::set<int32_t> units_to_kill;
        for (auto it : sq->orders)
        {
            if (auto so = strict_virtual_cast<df::squad_order_kill_listst>(it))
            {
                units_to_kill.insert(so->units.begin(), so->units.end());

                for (auto to_kill : so->units)
                {
                    if (u->id == to_kill)
                    {
                        score -= 100000;
                    }
                }
            }
        }

        for (auto oc : squad_order_changes)
        {
            if (oc.squad_id != sqid)
            {
                continue;
            }

            if (oc.type != squad_order_change::kill)
            {
                continue;
            }

            if (oc.unit_id == u->id)
            {
                if (oc.remove)
                {
                    score += 100000;
                }
                else
                {
                    score -= 100000;
                }
            }

            if (oc.remove)
            {
                units_to_kill.erase(oc.unit_id);
            }
            else
            {
                units_to_kill.insert(oc.unit_id);
            }
        }

        score -= 10000 * int32_t(units_to_kill.size());

        if (!squad || best < score)
        {
            squad = sq;
            best = score;
        }
    }
    if (!squad)
    {
        return false;
    }

    return military_squad_attack_unit(out, squad, u, reason);
}

bool Population::military_all_squads_attack_unit(color_ostream & out, df::unit *u, const std::string & reason)
{
    bool any = false;
    if (!military_target_reachable(u))
        return false;
    for (auto sqid : plotinfo->main.fortress_entity->squads)
    {
        auto sq = df::squad::find(sqid);
        // squads abroad on a mission keep their own orders
        if (sq && sq->assigned_army_controller_id == -1 && military_squad_attack_unit(out, sq, u, reason))
            any = true;
    }
    return any;
}

// A beast is "badly wounded" once it has lost 40% of its blood or 3+ body
// parts, or lies unconscious or webbed. The wound count only counts for
// beasts with no blood (stone, metal, ash...): Cloisterbolt's Dush Ostra
// carried 9 old scratches from the caverns at full blood.
bool Population::beast_badly_wounded(df::unit *u)
{
    if (!u)
        return false;
    if (u->counters.unconscious > 0 || u->counters.webbed > 0)
        return true;
    int32_t severed = 0;
    for (auto w : u->body.wounds)
        if (w && w->flags.bits.severed_part)
            severed++;
    if (severed >= 3)
        return true;
    if (u->body.blood_max > 0)
        return int64_t(u->body.blood_count) * 100 < int64_t(u->body.blood_max) * 60;
    return u->body.wounds.size() >= 8;
}

// Forgotten beasts at Cloisterbolt killed ~24 dwarves (one killed 13
// soldiers in 5 game days): every squad, melee first, walked into it one at
// a time (webs, dust, flinging). User: the archers shoot it from safety, the
// melee squads stay behind closed doors until it's badly wounded. So the
// squads with ammunition get the kill order (dfai-archer-posts puts them on
// a post with a clear line of fire when it's near the fort); melee squads
// get it only once the beast is badly wounded, or when no armed squad with
// ammunition is at home (then nobody else can fight it), and any kill order
// they already hold on it is withdrawn while they wait.
bool Population::military_great_beast(color_ostream & out, df::unit *u, const std::string & reason)
{
    if (!military_target_reachable(u))
        return false;
    bool any = false, shooters = false;
    for (auto sqid : plotinfo->main.fortress_entity->squads)
    {
        auto sq = df::squad::find(sqid);
        if (sq && sq->assigned_army_controller_id == -1 && !sq->ammo.ammunition.empty() && squad_armed(sq))
        {
            shooters = true;
            if (military_squad_attack_unit(out, sq, u, reason + " (archers shoot it)"))
                any = true;
        }
    }
    bool wounded = beast_badly_wounded(u);
    bool send_melee = wounded || !shooters;
    int & st = beast_melee[u->id];
    if (send_melee && st != 2)
    {
        ai.debug(out, "[MILITARY] " + AI::describe_unit(u) + (wounded ? " is badly wounded: melee squads go in" : ": no squad with ammunition at home, melee squads go in"));
        st = 2;
    }
    else if (!send_melee && st != 1)
    {
        ai.debug(out, "[MILITARY] " + AI::describe_unit(u) + ": crossbow squads shoot it; melee squads hold at home until it is badly wounded");
        st = 1;
    }
    for (auto sqid : plotinfo->main.fortress_entity->squads)
    {
        auto sq = df::squad::find(sqid);
        if (!sq || sq->assigned_army_controller_id != -1 || !sq->ammo.ammunition.empty())
            continue;
        if (send_melee)
        {
            if (military_squad_attack_unit(out, sq, u, reason + (wounded ? " (badly wounded: melee in)" : " (no archers: melee in)")))
                any = true;
        }
        else
        {
            bool holds = false;
            for (auto o : sq->orders)
                if (auto k = strict_virtual_cast<df::squad_order_kill_listst>(o))
                    if (std::find(k->units.begin(), k->units.end(), u->id) != k->units.end())
                        holds = true;
            if (holds && military_cancel_attack_order(out, sq, u, "great beast: melee holds until it is badly wounded"))
                any = true;
        }
    }
    return any;
}

bool Population::military_squad_attack_unit(color_ostream &, df::squad *squad, df::unit *u, const std::string & reason)
{
    if (Units::isOwnCiv(u))
    {
        return false;
    }
    // squads with no weapons don't get sent to fight (they shelter)
    if (!squad_armed(squad))
    {
        return false;
    }

    auto order_change = std::find_if(squad_order_changes.begin(), squad_order_changes.end(), [squad, u](const squad_order_change & change) -> bool
    {
        return change.type == squad_order_change::kill &&
            change.squad_id == squad->id &&
            change.unit_id == u->id;
    });

    if (order_change != squad_order_changes.end())
    {
        if (order_change->remove)
        {
            squad_order_changes.erase(order_change);
        }
        else
        {
            return false;
        }
    }

    for (auto it : squad->orders)
    {
        if (auto so = strict_virtual_cast<df::squad_order_kill_listst>(it))
        {
            if (std::find(so->units.begin(), so->units.end(), u->id) != so->units.end())
            {
                return false;
            }
        }
    }

    squad_order_change change;
    change.type = squad_order_change::kill;
    change.squad_id = squad->id;
    change.unit_id = u->id;
    change.remove = false;
    change.reason = reason;

    squad_order_changes.push_back(change);

    if (!events.has_exclusive<MilitarySquadAttackExclusive>(true))
    {
        events.queue_exclusive(std::make_unique<MilitarySquadAttackExclusive>(ai));
    }

    return true;
}

bool Population::military_cancel_attack_order(color_ostream & out, df::unit *u, const std::string & reason)
{
    bool any = false;
    for (auto sqid : plotinfo->main.fortress_entity->squads)
    {
        auto sq = df::squad::find(sqid);
        if (sq && military_cancel_attack_order(out, sq, u, reason))
            any = true;
    }
    return any;
}

bool Population::military_cancel_attack_order(color_ostream &, df::squad *squad, df::unit *u, const std::string & reason)
{
    auto order_change = std::find_if(squad_order_changes.begin(), squad_order_changes.end(), [squad, u](const squad_order_change & change) -> bool
    {
        return change.type == squad_order_change::kill &&
            change.squad_id == squad->id &&
            change.unit_id == u->id;
    });

    if (order_change != squad_order_changes.end())
    {
        if (order_change->remove)
        {
            return false;
        }
        else
        {
            squad_order_changes.erase(order_change);
        }
    }

    for (auto it : squad->orders)
    {
        if (auto so = strict_virtual_cast<df::squad_order_kill_listst>(it))
        {
            if (std::find(so->units.begin(), so->units.end(), u->id) == so->units.end())
            {
                return false;
            }
        }
    }

    squad_order_change change;
    change.type = squad_order_change::kill;
    change.squad_id = squad->id;
    change.unit_id = u->id;
    change.remove = true;
    change.reason = reason;

    squad_order_changes.push_back(change);

    if (!events.has_exclusive<MilitarySquadAttackExclusive>(true))
    {
        events.queue_exclusive(std::make_unique<MilitarySquadAttackExclusive>(ai));
    }

    return true;
}
