// dfai_missions: create fortress-mode world missions without the world screen
// (DF 53.16 win64 STEAM). UNTESTED SKETCH - see NOTES.md next to this file.
//
// Replicates exactly what viewscreen_worldst::feed (0x1401d3ac0) writes when the
// player clicks a mission button (0x1401d4cd0..0x1401d5166) and then clicks a
// squad row (0x1401d5f15..0x1401d616a) / messenger row (0x1401d64d0..0x1401d65c2)
// / diplomacy topic row (0x1401d5591..0x1401d570d).
//
// Native calls (both pure data, no UI, no rendering):
//   army_controller* alloc_army_controller()            0x14013e720 (pool alloc,
//       assigns id = army_controller_next_id++, pushes into world.army_controllers.all)
//   void army_controller_set_goal(army_controller*, int) 0x1400fe960 (frees old
//       goal data, operator-new's + initialises the goal struct, sets ac->goal)
// Everything else is plain field writes. Call from the game thread (Lua function
// from dfhack-run / a timer, or plugin_onupdate) while a fort is loaded.
//
// Lua: local m = require('plugins.dfai_missions')
//   m.status()                                   -> "ok" or why not
//   m.tribute(site_id, "85,86", true)            -> new army_controller id or -1
//   m.messenger(site_id, epp_id, "15,16")        -> new army_controller id or -1
//   m.cancel(ac_id)                              -> true/false

#include "Core.h"
#include "Console.h"
#include "DataDefs.h"
#include "Export.h"
#include "LuaTools.h"
#include "MiscUtils.h"
#include "PluginManager.h"
#include "PluginLua.h"
#include "VersionInfo.h"

#include "df/army_controller.h"
#include "df/army_controller_goal_site_invasionst.h"
#include "df/ac_goal_diplomacyst.h"
#include "df/entity_entity_link.h"
#include "df/entity_position_assignment.h"
#include "df/global_objects.h"
#include "df/entity_site_link.h"
#include "df/historical_entity.h"
#include "df/historical_figure.h"
#include "df/meeting_topic.h"
#include "df/plotinfost.h"
#include "df/squad.h"
#include "df/squad_order_raid_sitest.h"
#include "df/squad_position.h"
#include "df/unit.h"
#include "df/world.h"
#include "df/world_site.h"

#include <cstring>
#include <sstream>
#include <string>
#include <vector>

using namespace DFHack;

DFHACK_PLUGIN("dfai_missions");
REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);
REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(cur_year_tick);

namespace
{
    struct Fn
    {
        uintptr_t address; // unrebased, image base 0x140000000
        unsigned char prologue[16];
    };
    const char *BUILD = "v0.53.16 win64 STEAM";
    const Fn ALLOC_AC = {0x14013e720, {0x40, 0x53, 0x48, 0x83, 0xec, 0x20, 0xe8, 0xe5, 0x2b, 0x00, 0x00, 0x48, 0x8b, 0x0d, 0x6e, 0xdb}};
    const Fn SET_GOAL = {0x1400fe960, {0x48, 0x89, 0x5c, 0x24, 0x20, 0x56, 0x48, 0x83, 0xec, 0x20, 0x8b, 0x81, 0x38, 0x01, 0x00, 0x00}};
    const Fn DELETE_AC = {0x14013e7a0, {0x40, 0x56, 0x48, 0x83, 0xec, 0x20, 0x48, 0x89, 0x6c, 0x24, 0x38, 0x48, 0x8b, 0xf1, 0x48, 0x8b}};

    typedef df::army_controller *(*alloc_ac_fn)();
    typedef void (*set_goal_fn)(df::army_controller *, int32_t);
    typedef void (*delete_ac_fn)(df::army_controller *);
    alloc_ac_fn alloc_ac = nullptr;
    set_goal_fn set_goal = nullptr;
    delete_ac_fn delete_ac = nullptr;
    std::string why = "not checked yet";

    void *check(const Fn &f, intptr_t delta)
    {
        uintptr_t a = f.address + delta;
        if (std::memcmp(reinterpret_cast<const void *>(a), f.prologue, sizeof(f.prologue)) != 0)
            return nullptr;
        return reinterpret_cast<void *>(a);
    }

    void resolve()
    {
        alloc_ac = nullptr; set_goal = nullptr; delete_ac = nullptr;
        auto vinfo = Core::getInstance().vinfo;
        if (!vinfo) { why = "no version info"; return; }
        if (vinfo->getVersion() != BUILD) { why = "unknown DF build " + vinfo->getVersion(); return; }
        intptr_t d = vinfo->getRebaseDelta();
        alloc_ac = reinterpret_cast<alloc_ac_fn>(check(ALLOC_AC, d));
        set_goal = reinterpret_cast<set_goal_fn>(check(SET_GOAL, d));
        delete_ac = reinterpret_cast<delete_ac_fn>(check(DELETE_AC, d));
        why = (alloc_ac && set_goal && delete_ac) ? "ok" : "function bytes don't match";
    }

    // ---- helpers mirroring DF internals -------------------------------------

    // 0x1409b4e70: first entity_site_link with flags bit0 set, link type 0, end -1
    df::historical_entity *site_government(df::world_site *s)
    {
        for (auto l : s->entity_links)
            if (l->flags.bits.residence && (int)l->type == 0 && l->start_hr == -1) // DF: +0x1c bit0, +0x10 == 0, +0x14 == -1
                return df::historical_entity::find(l->entity_id);
        return nullptr;
    }
    // 0x14093ce30: walk entity_links (type 0 = PARENT) up to a Civilization
    df::historical_entity *civ_of(df::historical_entity *e)
    {
        for (int guard = 0; e && guard < 8; ++guard)
        {
            if (e->type == df::historical_entity_type::Civilization)
                return e;
            df::historical_entity *up = nullptr;
            for (auto l : e->entity_links)
                if ((int)l->type == 0 && (up = df::historical_entity::find(l->target)))
                    break;
            if (!up) return e; // DF returns the last entity reached
            e = up;
        }
        return e;
    }
    // positions with a responsibility whose holder is on the map (ctor 0x1401bc430)
    df::historical_figure *present_holder(df::historical_entity *e, df::entity_position_responsibility r)
    {
        if (!e) return nullptr;
        for (auto epp : e->assignments_by_type[r])
        {
            auto hf = df::historical_figure::find(epp->histfig);
            if (!hf) continue;
            auto u = df::unit::find(hf->unit_id);
            if (!u) continue;
            if (u->flags1.bits.inactive || u->flags1.bits.left) continue; // 0x102
            if (!u->flags1.bits.important_historical_figure) continue;     // sign bit test
            return hf;
        }
        return nullptr;
    }
    // world-screen LOCKED_IN rule (ctor 0x1401bcb79 / 0x1401bcad5): locked unless the
    // holder's unit is on the map (exists, !inactive, !left, important_historical_figure)
    bool hf_present(int32_t hfid)
    {
        auto hf = df::historical_figure::find(hfid);
        auto u = hf ? df::unit::find(hf->unit_id) : nullptr;
        return u && !u->flags1.bits.inactive && !u->flags1.bits.left && u->flags1.bits.important_historical_figure;
    }
    bool squad_locked(df::squad *sq) // only the leader slot (positions[0]) is checked
    {
        if (sq->positions.empty() || sq->positions[0]->occupant == -1) return false;
        return !hf_present(sq->positions[0]->occupant);
    }
    int smm(int a, int b) { return ((a + b) >> 1) * 3 + 1; }

    void clear_squad_orders(df::squad *sq) // 0x1400ff870(sq, true)
    {
        for (auto o : sq->orders) delete o;
        sq->orders.clear();
        for (auto p : sq->positions)
        {
            for (auto o : p->orders) delete o;
            p->orders.clear();
        }
    }

    df::army_controller *new_ac(df::world_site *target, df::army_controller_goal_type goal)
    {
        auto fe = plotinfo->main.fortress_entity;
        auto ac = alloc_ac();                        // id set, in world.army_controllers.all
        ac->entity_id = fe->id;
        ac->flag.bits.civ_rep = true;               // |= 8
        set_goal(ac, goal);
        ac->year = *cur_year;
        ac->year_tick = *cur_year_tick;
        ac->site_id = target->id;
        ac->pos_x = smm(target->global_min_x, target->global_max_x);
        ac->pos_y = smm(target->global_min_y, target->global_max_y);
        ac->master_id = ac->id;
        ac->parent_id = -1;
        ac->commander_hf = -1;
        insert_into_vector(fe->army_controllers, &df::army_controller::id, ac); // 0x1400b9fa0
        return ac;
    }

    std::vector<int32_t> parse_ids(const std::string &s)
    {
        std::vector<int32_t> v; std::stringstream ss(s); std::string t;
        while (std::getline(ss, t, ',')) if (!t.empty()) v.push_back(std::stoi(t));
        return v;
    }

    // ---- Lua API --------------------------------------------------------------

    int32_t tribute(int32_t site_id, std::string squad_ids, bool ongoing)
    {
        if (why != "ok" || !plotinfo->main.fortress_entity || !plotinfo->main.fortress_site) return -1;
        auto target = df::world_site::find(site_id);
        if (!target || target == plotinfo->main.fortress_site) return -1;
        auto fe = plotinfo->main.fortress_entity;
        auto civ = civ_of(site_government(target));
        auto ourciv = df::historical_entity::find(plotinfo->civ_id);
        if (civ == ourciv) return -1;                                   // OWN_CIV
        auto mil = present_holder(fe, df::entity_position_responsibility::MILITARY_GOALS);
        auto civmil = present_holder(ourciv, df::entity_position_responsibility::MILITARY_GOALS);
        if (!mil) return -1;                                            // NO_MILITARY_GOALS_HF
        // (INACCESSIBLE check needs world_data path_map from the world screen; see NOTES)

        auto ac = new_ac(target, df::army_controller_goal_type::SITE_INVASION);
        auto d = ac->data.goal_site_invasion;
        auto fs = plotinfo->main.fortress_site;
        d->source_abs_smm_x = smm(fs->global_min_x, fs->global_max_x);
        d->source_abs_smm_y = smm(fs->global_min_y, fs->global_max_y);
        d->invasion_intent = civ ? df::invasion_intent_type::RAID : df::invasion_intent_type::EXPLORE;
        d->flag.bits.FREE_OWN_CAPTIVES = d->flag.bits.FREE_OTHER_CAPTIVES = true;
        d->flag.bits.TAKE_ARTIFACTS = d->flag.bits.TAKE_ITEMS = d->flag.bits.STEAL_LIVESTOCK = true;
        d->invasion_stage = (df::invasion_stage_type)1;
        ac->percentage_pop = 0;
        ac->number_pop = 0;
        ac->master_hf = (civmil ? civmil : mil)->id;
        // the "Demand tribute" option rows (feed 0x1401d5c97 / 0x1401d5cc4)
        if (civ)
        {
            d->invasion_intent = df::invasion_intent_type::DEMAND_TRIBUTE;
            d->flag.bits.DEMAND_TRIBUTE_ONE_TIME = !ongoing;
            d->flag.bits.DEMAND_TRIBUTE_ONGOING = ongoing;
            d->flag.bits.DEMAND_SURRENDER_AND_MAYBE_LEAVE = false;
        }
        // squad rows (feed 0x1401d5f15)
        for (int32_t sid : parse_ids(squad_ids))
        {
            auto sq = df::squad::find(sid);
            if (!sq || sq->entity_id != fe->id || sq->assigned_army_controller_id == ac->id || squad_locked(sq)) continue;
            clear_squad_orders(sq);
            if (sq->assigned_army_controller_id != -1)
            {
                if (auto old = df::army_controller::find(sq->assigned_army_controller_id))
                    erase_from_vector(old->assigned_squads, sq->id);
                sq->assigned_army_controller_id = -1;
            }
            auto o = df::allocate<df::squad_order_raid_sitest>();       // real DF vtable via symbols.xml
            o->issuer_hf = -1; o->recipient_hf = -1;
            o->year = *cur_year; o->year_tick = *cur_year_tick;
            o->origin_army_controller = ac->id;
            o->flags.whole = 0;
            o->site_id = ac->site_id;
            o->exit_point.x = o->exit_point.y = o->exit_point.z = -30000;
            sq->orders.push_back(o);
            insert_into_vector(ac->assigned_squads, sq->id);
            sq->assigned_army_controller_id = ac->id;
        }
        return ac->id;
    }

    int32_t messenger(int32_t site_id, int32_t epp_id, std::string topics)
    {
        if (why != "ok" || !plotinfo->main.fortress_entity || !plotinfo->main.fortress_site) return -1;
        auto target = df::world_site::find(site_id);
        if (!target || target == plotinfo->main.fortress_site) return -1;
        auto fe = plotinfo->main.fortress_entity;
        auto civ = civ_of(site_government(target));
        auto ourciv = df::historical_entity::find(plotinfo->civ_id);
        if (!civ || civ == ourciv) return -1;                           // NO_CIV / OWN_CIV
        auto meet = present_holder(fe, df::entity_position_responsibility::MEET_WORKERS);
        if (!meet) return -1;                                           // NO_MEET_WORKERS_HF
        df::entity_position_assignment *epp = nullptr;
        for (auto e : fe->assignments_by_type[df::entity_position_responsibility::DELIVER_MESSAGES])
            if (e->id == epp_id && e->histfig != -1 && hf_present(e->histfig)) epp = e;
        if (!epp) return -1;

        auto ac = new_ac(target, df::army_controller_goal_type::DIPLOMACY);
        auto d = ac->data.goal_diplomacy;
        auto fs = plotinfo->main.fortress_site;
        d->source_abs_smm_x = smm(fs->global_min_x, fs->global_max_x);
        d->source_abs_smm_y = smm(fs->global_min_y, fs->global_max_y);
        ac->master_hf = meet->id;
        for (int32_t t : parse_ids(topics))                             // topic rows
        {
            d->topic.push_back((df::meeting_topic)t);
            d->topic_id1.push_back(civ->id);
            d->topic_id2.push_back(-1);
        }
        // messenger row (feed 0x1401d6572)
        ac->assigned_epp_entity_id.push_back(fe->id);
        ac->assigned_epp_epp_id.push_back(epp->id);
        epp->assigned_army_controller_id = ac->id;
        return ac->id;
    }

    bool cancel(int32_t ac_id)
    {
        if (why != "ok") return false;
        auto ac = df::army_controller::find(ac_id);
        if (!ac || ac->entity_id != plotinfo->group_id) return false;
        for (int32_t sid : ac->assigned_squads)
            if (auto sq = df::squad::find(sid))
            {
                clear_squad_orders(sq);
                sq->assigned_army_controller_id = -1;
            }
        if (auto fe = plotinfo->main.fortress_entity)
            for (auto e : fe->assignments_by_type[df::entity_position_responsibility::DELIVER_MESSAGES])
                if (e->assigned_army_controller_id == ac->id) e->assigned_army_controller_id = -1;
        delete_ac(ac); // 0x14013e7a0: delete_me flag, frees goal data, unlinks from entity + world lists
        return true;
    }

    std::string status() { return why; }
}

DFHACK_PLUGIN_LUA_FUNCTIONS {
    DFHACK_LUA_FUNCTION(status),
    DFHACK_LUA_FUNCTION(tribute),
    DFHACK_LUA_FUNCTION(messenger),
    DFHACK_LUA_FUNCTION(cancel),
    DFHACK_LUA_END
};

DFhackCExport command_result plugin_init(color_ostream &out, std::vector<PluginCommand> &)
{
    resolve();
    out.print("dfai_missions: %s\n", why.c_str());
    return CR_OK;
}

DFhackCExport command_result plugin_shutdown(color_ostream &)
{
    alloc_ac = nullptr; set_goal = nullptr; delete_ac = nullptr;
    return CR_OK;
}
