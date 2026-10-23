#include "ai.h"
#include "config.h"
#include "population.h"

#include "modules/Gui.h"
#include "modules/Items.h"
#include "modules/Maps.h"
#include "modules/Screen.h"
#include "modules/Units.h"
#include "modules/World.h"

#include "df/building_civzonest.h"
#include "df/crime.h"
#include "df/crime_type.h"
#include "df/gamest.h"
#include "df/info_interfacest.h"
#include "df/justice_interfacest.h"
#include "df/punishment.h"
#include "df/viewscreen.h"
#include "df/widget_tabs.h"
#include "df/widget_container.h"
#include "df/widget_scroll_rows.h"
#include "df/widget_unit_list.h"
#include "df/widget_unit_portrait.h"
#include "df/general_ref_contains_itemst.h"
#include "df/general_ref_contains_unitst.h"
#include "df/item.h"
#include "df/items_other_id.h"
#include "df/plotinfost.h"
#include "df/world.h"

REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(cur_year_tick);
REQUIRE_GLOBAL(game);
REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

// Convicting criminals (DF v50+).
//
// DF 0.47 convicted through viewscreen_justicest. In v50+ the justice screen is
// part of game->main_interface.info (justice_interfacest + a widget tree), and
// conviction is performed by DF's own UI code (it fills
// justice.convict_crime / convict_lawaction itself), so we drive that UI with
// real interface keys over several ticks instead of guessing at the data DF
// writes:
//
//   1. feed D_JUSTICE to the fortress viewscreen (opens Info > Justice; DFHack
//      opens the nobles screen the same way with D_NOBLES),
//   2. make sure the "Open cases" tab is showing,
//   3. feed JUSTICE_CONVICT (opens the "Convict" suspect list for the selected
//      case; verified through justice.convict_crime and the "Convict" widget
//      that Gui::getFocusStrings uses for "dwarfmode/Info/JUSTICE/Convicting"),
//   4. put the unit list cursor (widget_unit_list::cursor_idx) on the culprit
//      and feed SELECT -- this is exactly the input DFHack's `confirm` plugin
//      intercepts as "convict the unit at cursor_idx",
//   5. if DFHack's confirmation dialog appeared, accept it with SELECT,
//   6. verify crime->accused now names the culprit, then close the menu again
//      with LEAVESCREEN (falling back to clearing info.open).
//
// Any unexpected state aborts the attempt, logs once, marks the crime so it
// is never retried, and still closes the menu.

namespace
{
    enum class ConvictStep
    {
        WaitOpen,
        PressConvict,
        WaitList,
        SelectUnit,
        WaitResult,
        Close,
    };

    struct ConvictionAttempt
    {
        ConvictStep step = ConvictStep::WaitOpen;
        int32_t ticks = 0;
        int32_t step_ticks = 0;
        int32_t target_crime = -1;
        int32_t crime_id = -1;
        int32_t criminal_id = -1;
        size_t punishments_before = 0;
        bool tried_tab_switch = false;
        bool accepted_dialog = false;
        int32_t leave_presses = 0;
        std::string description;
    };

    OnupdateCallback *conviction_handle = nullptr;
    ConvictionAttempt conviction;
    std::set<int32_t> conviction_failed;
    std::set<int32_t> conviction_logged;
    std::vector<std::string> conviction_log;

    void feed_key(df::viewscreen *screen, df::interface_key key)
    {
        if (!screen)
        {
            return;
        }
        std::set<df::interface_key> keys{ key };
        screen->feed(&keys);
    }

    // The DF viewscreen is on top (no DFHack screen/dialog covering it).
    bool df_screen_on_top()
    {
        auto df_screen = Gui::getDFViewscreen(true);
        return df_screen && Gui::getCurViewscreen(true) == df_screen;
    }

    bool top_is_dfhack_dialog()
    {
        auto top = Gui::getCurViewscreen(true);
        if (!top || !dfhack_viewscreen::is_instance(top))
        {
            return false;
        }
        for (auto & focus : Gui::getFocusStrings(top))
        {
            if (focus.rfind("dfhack/MessageBox", 0) == 0)
            {
                return true;
            }
        }
        return false;
    }

    bool justice_open()
    {
        return game->main_interface.info.open && game->main_interface.info.current_mode == info_interface_mode_type::JUSTICE;
    }

    df::widget_container *justice_tabs()
    {
        return virtual_cast<df::widget_container>(Gui::getWidget(&game->main_interface.info.justice, "Tabs"));
    }

    std::string visible_justice_tab()
    {
        auto tabs = justice_tabs();
        if (!tabs)
        {
            return std::string();
        }
        for (auto & child : tabs->children)
        {
            if (child && child->flag.bits.VISIBILITY_VISIBLE)
            {
                return child->name;
            }
        }
        return std::string();
    }

    df::widget_container *open_cases_right_panel()
    {
        auto tabs = justice_tabs();
        if (!tabs)
        {
            return nullptr;
        }
        auto open_cases = virtual_cast<df::widget_container>(Gui::getWidget(tabs, "Open cases"));
        if (!open_cases)
        {
            return nullptr;
        }
        return virtual_cast<df::widget_container>(Gui::getWidget(open_cases, "Right panel"));
    }

    // Same test Gui::getFocusStrings uses for "dwarfmode/Info/JUSTICE/Convicting".
    df::widget_unit_list *convict_list()
    {
        auto right_panel = open_cases_right_panel();
        if (!right_panel || right_panel->children.size() < 2 || !right_panel->children[1] || right_panel->children[1]->name != "Convict")
        {
            return nullptr;
        }
        return virtual_cast<df::widget_unit_list>(Gui::getWidget(right_panel, "Convict"));
    }

    // Row index of the unit in the conviction list, found the same way the
    // DFHack `confirm` plugin reads the unit under cursor_idx:
    // Convict > "Unit List" > child 1 (scroll rows) > row > child 0 (portrait).
    int32_t find_convict_row(df::widget_unit_list *list, df::unit *unit)
    {
        auto unit_list = virtual_cast<df::widget_container>(Gui::getWidget(list, "Unit List"));
        if (!unit_list)
        {
            return -1;
        }
        auto rows = virtual_cast<df::widget_container>(Gui::getWidget(unit_list, size_t(1)));
        if (!rows)
        {
            return -1;
        }
        for (size_t i = 0; i < rows->children.size(); i++)
        {
            auto row = virtual_cast<df::widget_container>(rows->children[i].get());
            if (!row)
            {
                continue;
            }
            auto portrait = virtual_cast<df::widget_unit_portrait>(Gui::getWidget(row, size_t(0)));
            if (portrait && portrait->u == unit)
            {
                return int32_t(i);
            }
        }
        return -1;
    }

    bool crime_awaits_conviction(df::crime *crime)
    {
        return crime && crime->flags.bits.needs_trial && crime->accused == -1 && df::unit::find(crime->criminal) && crime->site == plotinfo->site_id;
    }

    void conviction_fail(const std::string & why)
    {
        for (int32_t id : { conviction.target_crime, conviction.crime_id })
        {
            if (id != -1)
            {
                conviction_failed.insert(id);
            }
        }
        if (conviction_logged.insert(conviction.crime_id != -1 ? conviction.crime_id : conviction.target_crime).second)
        {
            conviction_log.push_back("[Crime] [ERROR] Could not convict " + conviction.description + ": " + why + ". Not retrying this case.");
        }
        conviction.step = ConvictStep::Close;
        conviction.step_ticks = 0;
    }

    void conviction_next(ConvictStep step)
    {
        conviction.step = step;
        conviction.step_ticks = 0;
    }

    // Returns true when the attempt is over (the callback unregisters itself).
    bool conviction_tick(color_ostream &)
    {
        conviction.ticks++;
        conviction.step_ticks++;

        if (!World::isFortressMode() || !Maps::IsValid())
        {
            // fortress unloaded mid-attempt: nothing left to close
            conviction_handle = nullptr;
            return true;
        }

        if (conviction.step != ConvictStep::Close && conviction.ticks > 300)
        {
            conviction_fail("timed out");
        }

        switch (conviction.step)
        {
        case ConvictStep::WaitOpen:
        {
            if (!justice_open())
            {
                if (conviction.step_ticks > 10)
                {
                    conviction_fail("D_JUSTICE did not open the justice menu");
                }
                return false;
            }
            std::string tab = visible_justice_tab();
            if (tab == "Open cases")
            {
                conviction_next(ConvictStep::PressConvict);
                return false;
            }
            if (tab.empty())
            {
                // widgets may not be built until DF has run the menu once
                if (conviction.step_ticks > 10)
                {
                    conviction_fail("justice menu widgets not found");
                }
                return false;
            }
            if (!conviction.tried_tab_switch)
            {
                conviction.tried_tab_switch = true;
                conviction.step_ticks = 0;
                game->main_interface.info.justice.current_mode = justice_interface_mode_type::OPEN_CASES;
                if (auto tabs = virtual_cast<df::widget_tabs>(justice_tabs()))
                {
                    auto label = std::find(tabs->tab_labels.begin(), tabs->tab_labels.end(), "Open cases");
                    if (label != tabs->tab_labels.end())
                    {
                        tabs->cur_idx = size_t(label - tabs->tab_labels.begin());
                    }
                }
                return false;
            }
            if (conviction.step_ticks > 10)
            {
                conviction_fail("could not switch the justice menu to open cases (showing " + tab + ")");
            }
            return false;
        }
        case ConvictStep::PressConvict:
            if (!justice_open() || !df_screen_on_top())
            {
                conviction_fail("justice menu was closed or covered");
                return false;
            }
            feed_key(Gui::getDFViewscreen(true), interface_key::JUSTICE_CONVICT);
            conviction_next(ConvictStep::WaitList);
            return false;
        case ConvictStep::WaitList:
        {
            if (!justice_open())
            {
                conviction_fail("justice menu was closed");
                return false;
            }
            auto & convict_crime = game->main_interface.info.justice.convict_crime;
            if (!convict_list() || convict_crime.empty())
            {
                if (conviction.step_ticks > 10)
                {
                    conviction_fail("JUSTICE_CONVICT did not open the list of suspects");
                }
                return false;
            }
            // DF convicts for the case selected in the menu. Prefer the crime
            // we came for; otherwise handle whichever case DF has selected,
            // using the same culprit choice (crime->criminal).
            df::crime *chosen = nullptr;
            for (auto c : convict_crime)
            {
                if (c && c->id == conviction.target_crime && crime_awaits_conviction(c))
                {
                    chosen = c;
                    break;
                }
            }
            if (!chosen)
            {
                for (auto c : convict_crime)
                {
                    if (crime_awaits_conviction(c) && !conviction_failed.count(c->id))
                    {
                        chosen = c;
                        break;
                    }
                }
            }
            if (!chosen)
            {
                conviction_fail("the selected case is not one the AI can solve");
                return false;
            }
            df::unit *criminal = df::unit::find(chosen->criminal);
            conviction.crime_id = chosen->id;
            conviction.criminal_id = criminal->id;
            if (chosen->id != conviction.target_crime)
            {
                conviction.description = AI::describe_unit(criminal) + " of " + enum_item_key(chosen->mode);
            }
            conviction_next(ConvictStep::SelectUnit);
            return false;
        }
        case ConvictStep::SelectUnit:
        {
            auto list = convict_list();
            df::unit *criminal = df::unit::find(conviction.criminal_id);
            if (!justice_open() || !list || !criminal || !df_screen_on_top())
            {
                conviction_fail("list of suspects was closed");
                return false;
            }
            int32_t row = find_convict_row(list, criminal);
            if (row < 0)
            {
                // rows can be built over several frames
                if (conviction.step_ticks > 10)
                {
                    conviction_fail("culprit is not on the list of suspects");
                }
                return false;
            }
            conviction.punishments_before = plotinfo->punishments.size();
            list->cursor_idx = row;
            feed_key(Gui::getDFViewscreen(true), interface_key::SELECT);
            conviction_next(ConvictStep::WaitResult);
            return false;
        }
        case ConvictStep::WaitResult:
        {
            df::crime *crime = df::crime::find(conviction.crime_id);
            if (crime && crime->accused == conviction.criminal_id)
            {
                conviction_log.push_back(stl_sprintf("[Crime] Convicted %s (punishment records: %zu -> %zu).", conviction.description.c_str(), conviction.punishments_before, plotinfo->punishments.size()));
                conviction_next(ConvictStep::Close);
                return false;
            }
            if (!conviction.accepted_dialog && top_is_dfhack_dialog())
            {
                // DFHack's `confirm` asks "Are you sure you want to convict...";
                // its accept key is SELECT.
                conviction.accepted_dialog = true;
                conviction.step_ticks = 0;
                feed_key(Gui::getCurViewscreen(true), interface_key::SELECT);
                return false;
            }
            if (conviction.step_ticks > 10)
            {
                conviction_fail(crime ? "selecting the culprit did not convict them" : "the crime disappeared");
            }
            return false;
        }
        case ConvictStep::Close:
            if (top_is_dfhack_dialog() && conviction.step_ticks < 5)
            {
                // a confirmation dialog raised by our input is still up: cancel it
                feed_key(Gui::getCurViewscreen(true), interface_key::LEAVESCREEN);
                return false;
            }
            if (game->main_interface.info.open)
            {
                if (conviction.leave_presses < 6 && df_screen_on_top())
                {
                    conviction.leave_presses++;
                    feed_key(Gui::getDFViewscreen(true), interface_key::LEAVESCREEN);
                    return false;
                }
                game->main_interface.info.justice.convicting = false;
                game->main_interface.info.open = false;
            }
            conviction_handle = nullptr;
            return true;
        }
        return false;
    }
}

static void flush_conviction_log(color_ostream & out, AI & ai)
{
    for (auto & line : conviction_log)
    {
        ai.debug(out, line);
    }
    conviction_log.clear();
}

static void start_conviction(color_ostream & out, AI & ai, df::crime *crime, df::unit *criminal, const std::string & accusation)
{
    if (conviction_handle || conviction_failed.count(crime->id) || crime->site != plotinfo->site_id)
    {
        return;
    }
    // Only take over the UI when the player is looking at the plain map.
    if (game->main_interface.info.open || !AI::is_dwarfmode_viewscreen() || !df_screen_on_top())
    {
        return;
    }

    conviction = ConvictionAttempt();
    conviction.target_crime = crime->id;
    conviction.description = AI::describe_unit(criminal) + " of " + accusation;
    ai.debug(out, "[Crime] Convicting " + conviction.description + ".");

    feed_key(Gui::getDFViewscreen(true), interface_key::D_JUSTICE);
    conviction_handle = events.onupdate_register_once("df-ai convict criminal", conviction_tick);
}

void Population::update_caged(color_ostream & out)
{
    int32_t count = 0;
    for (auto it = world->items.other[items_other_id::CAGE].begin(); it != world->items.other[items_other_id::CAGE].end(); it++)
    {
        df::item *cage = *it;
        if (!cage->flags.bits.on_ground)
        {
            bool ignore = true;
            if (cage->flags.bits.forbid && !cage->flags.bits.trader)
            {
                for (auto ref : cage->general_refs)
                {
                    auto bld = ref->getBuilding();
                    if (ref->getType() == general_ref_type::BUILDING_HOLDER && bld && bld->getType() == building_type::TradeDepot)
                    {
                        ignore = false;
                        break;
                    }
                }
            }
            if (ignore)
            {
                continue;
            }
        }
        for (auto ref = cage->general_refs.begin(); ref != cage->general_refs.end(); ref++)
        {
            if (virtual_cast<df::general_ref_contains_itemst>(*ref))
            {
                df::item *i = (*ref)->getItem();
                if (i->flags.bits.dump && !i->flags.bits.forbid)
                {
                    continue;
                }
                count++;
                i->flags.bits.dump = 1;
                i->flags.bits.forbid = 0;
            }
            else if (virtual_cast<df::general_ref_contains_unitst>(*ref))
            {
                df::unit *u = (*ref)->getUnit();
                if (Units::isOwnCiv(u))
                {
                    room *r = ai.find_room(room_type::releasecage, [](room *r) -> bool { return r->status >= room_status::finished; });
                    if (r)
                    {
                        for (auto f : r->layout)
                        {
                            if (f->type == layout_type::lever && f->bld_id != -1)
                            {
                                ai.plan.add_task(task_type::rescue_caged, r, f, cage->id);
                                break;
                            }
                        }
                    }
                }
                else
                {
                    size_t waiting_items = 0;

                    for (auto ii : u->inventory)
                    {
                        if (Items::getOwner(ii->item))
                        {
                            continue;
                        }
                        waiting_items++;
                        if (ii->item->flags.bits.dump && !ii->item->flags.bits.forbid)
                        {
                            continue;
                        }
                        count++;
                        ii->item->flags.bits.dump = 1;
                        ii->item->flags.bits.forbid = 0;
                        ai.debug(out, "pop: marked item " + AI::describe_item(ii->item) + " for dumping");
                    }

                    if (!waiting_items)
                    {
                        room *r = ai.find_room(room_type::pitcage, [](room *r) -> bool { return r->dfbuilding(); });
                        if (r && AI::spiral_search(r->pos(), 1, 1, [cage](df::coord t) -> bool { return t == cage->pos; }).isValid())
                        {
                            assign_unit_to_zone(u, virtual_cast<df::building_civzonest>(r->dfbuilding()));
                            ai.debug(out, "pop: marked " + AI::describe_unit(u) + " for pitting");
                            military_random_squad_attack_unit(out, u, "just in case pitting fails");
                        }
                        else
                        {
                            military_cancel_attack_order(out, u, "caged, but not in place for pitting");
                        }
                    }
                    else
                    {
                        ai.debug(out, stl_sprintf("pop: waiting for %s to be stripped for pitting (%zu items remain)", AI::describe_unit(u).c_str(), waiting_items));
                        military_cancel_attack_order(out, u, "caged, but not ready for pitting");
                    }
                }
            }
        }
    }
    if (count > 0)
    {
        ai.debug(out, stl_sprintf("pop: dumped %d items from cages", count));
    }
}

void Population::update_crimes(color_ostream & out)
{
    // check for criminals, log justice updates
    flush_conviction_log(out, ai);

    int32_t not_before_year = last_checked_crime_year;
    int32_t not_before_tick = last_checked_crime_tick;
    last_checked_crime_year = *cur_year;
    last_checked_crime_tick = *cur_year_tick;

    for (auto crime : world->crimes.all)
    {
        if (!crime->flags.bits.discovered || crime->site != plotinfo->site_id)
        {
            continue;
        }

        std::string accusation;
        switch (crime->mode)
        {
        case df::crime_type::ProductionOrderViolation:
            accusation = "violation of a production order";
            break;
        case df::crime_type::ExportViolation:
            accusation = "violation of an export ban";
            break;
        case df::crime_type::JobOrderViolation:
            accusation = "violation of a job order";
            break;
        case df::crime_type::ConspiracyToSlowLabor:
            accusation = "conspiracy to slow labor";
            break;
        case df::crime_type::Murder:
            accusation = "murder";
            break;
        case df::crime_type::DisorderlyBehavior:
            accusation = "disorderly conduct";
            break;
        case df::crime_type::BuildingDestruction:
            accusation = "building destruction";
            break;
        case df::crime_type::Vandalism:
            accusation = "vandalism";
            break;
        case df::crime_type::Theft:
            accusation = "theft";
            break;
        case df::crime_type::Robbery:
            accusation = "robbery";
            break;
        case df::crime_type::BloodDrinking:
            accusation = "vampirism";
            break;
        case df::crime_type::Embezzlement:
            accusation = "embezzlement";
            break;
        case df::crime_type::AttemptedMurder:
            accusation = "attempted murder";
            break;
        case df::crime_type::Kidnapping:
            accusation = "kidnapping";
            break;
        case df::crime_type::AttemptedKidnapping:
            accusation = "attempted kidnapping";
            break;
        case df::crime_type::AttemptedTheft:
            accusation = "attempted theft";
            break;
        case df::crime_type::Treason:
            accusation = "treason";
            break;
        case df::crime_type::Espionage:
            accusation = "espionage";
            break;
        case df::crime_type::Bribery:
            accusation = "bribery";
            break;
        default:
            break;
        }
        if (accusation.empty())
        {
            accusation = enum_item_key(crime->mode);
        }

        df::unit *criminal = df::unit::find(crime->criminal);
        df::unit *convicted = df::unit::find(crime->accused);
        df::unit *victim = df::unit::find(crime->victim);

        std::string with_victim;
        if (victim)
        {
            with_victim = " with " + AI::describe_unit(victim) + " as the victim";
        }

        if (crime->discovered_year > not_before_year || (crime->discovered_year == not_before_year && crime->discovered_time >= not_before_tick))
        {
            ai.debug(out, "[Crime] New crime discovered: " + AI::describe_unit(criminal) + " is accused of " + accusation + with_victim + ".");
        }

        if (config.manage_justice && crime->flags.bits.needs_trial && criminal && !convicted)
        {
            start_conviction(out, ai, crime, criminal, accusation + with_victim);
        }

        if (convicted && !crime->flags.bits.sentenced)
        {
            ai.debug(out, "[Crime] Waiting for sentencing for " + AI::describe_unit(convicted) + ", who was convicted of the crime of " + accusation + with_victim + ".");
        }
    }
}
