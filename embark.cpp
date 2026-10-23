// Automatic world generation and embarking for DF v50+ (53.x).
//
// The 0.47 implementation (git 701ea36:embark.cpp) drove keyboard menus that
// no longer exist: most SETUP_* / embark keys are gone from interface_key, and
// the title / world-gen / embark screens are mouse-first. This version is a
// small state machine run from an onupdate callback. On each step it looks at
// the current DF viewscreen, and per screen it either
//  - edits screen / interface fields directly (help popups, site location,
//    world size), or
//  - sets the screen's selection field and feeds a real interface_key that
//    exists in df/interface_key.h (SELECT, MENU_CONFIRM).
// It never feeds mouse input. Each action is followed by a settle delay, a
// bounded number of retries and a timeout; on failure it logs one line and
// stops for good (until the plugin is re-enabled).

#include "config.h"
#include "ai.h"
#include "embark.h"
#include "event_manager.h"

#include "modules/Gui.h"
#include "modules/Maps.h"
#include "modules/Translation.h"
#include "modules/World.h"

#include "df/gamest.h"
#include "df/help_context_type.h"
#include "df/help_interfacest.h"
#include "df/main_choice_type.h"
#include "df/main_interface.h"
#include "df/options_interfacest.h"
#include "df/name_creator_interfacest.h"
#include "df/image_creator_interfacest.h"
#include "df/region_headerst.h"
#include "df/region_map_entry.h"
#include "df/viewscreen_adopt_regionst.h"
#include "df/viewscreen_choose_game_typest.h"
#include "df/viewscreen_choose_start_sitest.h"
#include "df/viewscreen_dwarfmodest.h"
#include "df/viewscreen_export_regionst.h"
#include "df/viewscreen_game_cleanerst.h"
#include "df/viewscreen_initial_prepst.h"
#include "df/viewscreen_loadgamest.h"
#include "df/viewscreen_new_regionst.h"
#include "df/viewscreen_savegamest.h"
#include "df/viewscreen_setupdwarfgamest.h"
#include "df/viewscreen_titlest.h"
#include "df/viewscreen_update_regionst.h"
#include "df/world.h"
#include "df/world_data.h"
#include "df/world_generatorst.h"
#include "df/world_region.h"

#include <chrono>
#include <random>

REQUIRE_GLOBAL(game);
REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

extern std::unique_ptr<AI> dwarfAI;

// ---------------------------------------------------------------------------
// Configuration. These belong in config.h/config.cpp; until they are added
// there they are compile-time constants. The feature defaults to OFF.
// ---------------------------------------------------------------------------
namespace
{
    // Settings live in dfhack-config/df-ai.json (see config.cpp).
#define CFG_RANDOM_EMBARK (config.random_embark)
#define CFG_RANDOM_EMBARK_WORLD (config.random_embark_world.c_str())
#define CFG_WORLD_SIZE (config.world_size)
#define CFG_EMBARK_WIDTH (config.embark_width)
#define CFG_EMBARK_HEIGHT (config.embark_height)
}

namespace
{
    typedef std::chrono::steady_clock clock_type;

    // Act on at most one frame out of this many: screens change between frames.
    const int32_t FRAMES_PER_STEP = 5;

    // Timeouts (seconds).
    const int64_t TIMEOUT_SCREEN_ACTION = 30;     // an interactive screen must react to us
    const int64_t TIMEOUT_RAW_LOAD = 5 * 60;      // new_region raw loading
    const int64_t TIMEOUT_WORLD_GEN = 90 * 60;    // full world generation
    const int64_t TIMEOUT_TRANSITION = 30 * 60;   // loading/saving/updating-world screens
    const int64_t TIMEOUT_UNKNOWN_SCREEN = 120;   // a screen we do not know about
    const int64_t SETTLE_SECONDS = 2;             // wait after an action before judging it
    const int32_t MAX_ACTIONS_PER_SCREEN = 4;

    enum class State
    {
        Idle,
        Running,
        Done,
        Failed,
    };

    struct Driver
    {
        State state = State::Idle;
        OnupdateCallback *handle = nullptr;
        int32_t frame = 0;

        // tracking of the current screen visit
        const void *screen_type = nullptr;
        clock_type::time_point screen_since;
        clock_type::time_point last_action;
        int32_t actions = 0;   // actions taken during this screen visit
        int32_t substep = 0;   // screen-specific progress
        clock_type::time_point last_progress_log;

        // world folder chosen / generated during this run
        std::string world_folder;
        std::string world_name;
        bool generated_world = false;

        std::mt19937 rng{ std::random_device{}() };
    };

    Driver drv;

    void log(color_ostream & out, const std::string & msg)
    {
        if (dwarfAI)
        {
            dwarfAI->debug(out, "embark: " + msg);
        }
        else
        {
            out << "AI: embark: " << msg << std::endl;
        }
    }

    int64_t seconds_since(clock_type::time_point t)
    {
        return std::chrono::duration_cast<std::chrono::seconds>(clock_type::now() - t).count();
    }

    void stop(color_ostream & out, State st, const std::string & why)
    {
        drv.state = st;
        if (st == State::Failed)
        {
            log(out, "giving up: " + why + " (finish this step by hand; df-ai takes over once the fortress map is loaded)");
        }
        else
        {
            log(out, why);
        }
        // The callback returns true right after this, which unregisters it.
        drv.handle = nullptr;
    }

    void feed(df::viewscreen *screen, df::interface_key key)
    {
        std::set<df::interface_key> keys{ key };
        screen->feed(&keys);
    }

    // Returns true when the previous action on this screen is still settling.
    bool settling()
    {
        return drv.actions > 0 && seconds_since(drv.last_action) < SETTLE_SECONDS;
    }

    // Records an action. Returns false (and fails) if too many were taken.
    bool take_action(color_ostream & out, const std::string & what)
    {
        if (drv.actions >= MAX_ACTIONS_PER_SCREEN)
        {
            stop(out, State::Failed, "the screen did not react after " + stl_sprintf("%d", drv.actions) + " attempts (last: " + what + ")");
            return false;
        }
        drv.actions++;
        drv.last_action = clock_type::now();
        log(out, what);
        return true;
    }

    // Close tutorial / help popups by data (cf. hide-tutorials.lua close_help).
    void close_embark_help(color_ostream & out)
    {
        auto & help = game->main_interface.help;
        if (!help.open)
        {
            return;
        }
        if (help.context == df::help_context_type::EMBARK_TUTORIAL_CHOICE ||
            help.context == df::help_context_type::EMBARK_MESSAGE ||
            help.context == df::help_context_type::NONE)
        {
            log(out, "closing help popup " + enum_item_key(help.context));
            help.open = false;
        }
    }

    // cf. hide-tutorials.lua hide_all_popups (fortress mode).
    void hide_fortress_popups()
    {
        FOR_ENUM_ITEMS(help_context_type, ctx)
        {
            std::string key = enum_item_key(ctx);
            if (key.compare(0, 6, "POPUP_") != 0)
            {
                continue;
            }
            insert_into_vector(plotinfo->tutorial_seen, ctx);
            insert_into_vector(plotinfo->tutorial_hide, ctx);
        }
        plotinfo->flags.bits.need_to_do_tutorial = false;
    }

    std::string wanted_world()
    {
        if (!drv.world_folder.empty())
        {
            return drv.world_folder;
        }
        if (!drv.world_name.empty())
        {
            return drv.world_name;
        }
        return CFG_RANDOM_EMBARK_WORLD;
    }

    int32_t find_menu_line(df::viewscreen_titlest *view, df::main_choice_type choice)
    {
        for (size_t i = 0; i < view->menu_line_id.size(); i++)
        {
            if (view->menu_line_id.at(i) == choice)
            {
                return int32_t(i);
            }
        }
        return -1;
    }

    int32_t find_region(df::viewscreen_titlest *view, const std::string & folder)
    {
        for (size_t i = 0; i < view->region_choice.size(); i++)
        {
            auto r = view->region_choice.at(i);
            if (r && r->filename_noext == folder)
            {
                return int32_t(i);
            }
        }
        if (drv.world_name.empty())
        {
            return -1;
        }
        for (size_t i = 0; i < view->region_choice.size(); i++)
        {
            auto r = view->region_choice.at(i);
            if (r && (r->display_name == drv.world_name || Translation::translateName(&r->name, false) == drv.world_name))
            {
                return int32_t(i);
            }
        }
        return -1;
    }

    // Selects menu line idx and feeds SELECT, refusing to ever activate Quit.
    bool select_title_line(color_ostream & out, df::viewscreen_titlest *view, int32_t idx, const std::string & what)
    {
        if (idx < 0 || size_t(idx) >= view->menu_line_id.size() || view->menu_line_id.at(idx) == df::main_choice_type::Quit)
        {
            stop(out, State::Failed, "title menu line for " + what + " is not available");
            return false;
        }
        if (!take_action(out, "title: choosing \"" + what + "\""))
        {
            return false;
        }
        view->selected = idx;
        feed(view, df::interface_key::SELECT);
        return true;
    }

    void step_title(color_ostream & out, df::viewscreen_titlest *view)
    {
        if (view->managing_mods || game->main_interface.settings.open || view->deleting_region || view->deleting_savegame_game || view->deleting_savegame_world)
        {
            if (seconds_since(drv.screen_since) > TIMEOUT_SCREEN_ACTION)
            {
                stop(out, State::Failed, "title screen is showing a sub-menu (mods/settings/delete) that df-ai does not drive");
            }
            return;
        }
        if (drv.substep == 0 && view->mode != df::title_mode_type::MAIN_MENU)
        {
            if (seconds_since(drv.screen_since) > TIMEOUT_SCREEN_ACTION)
            {
                stop(out, State::Failed, "title screen is in mode " + enum_item_key(view->mode) + " (the continue-game lists), not the main menu");
            }
            return;
        }
        if (settling())
        {
            return;
        }

        std::string folder = wanted_world();
        int32_t region_idx = folder.empty() ? -1 : find_region(view, folder);

        if (drv.substep == 0)
        {
            if (region_idx >= 0 || (!folder.empty() && view->region_choice.empty() && find_menu_line(view, df::main_choice_type::Start) >= 0))
            {
                drv.substep = 1;
                select_title_line(out, view, find_menu_line(view, df::main_choice_type::Start), "Start new game");
                return;
            }
            if (!folder.empty())
            {
                log(out, "no world saved in folder \"" + folder + "\"; creating a new world instead");
            }
            if (drv.generated_world)
            {
                stop(out, State::Failed, "a world was generated but cannot be found in the title screen's world list");
                return;
            }
            drv.substep = 10;
            select_title_line(out, view, find_menu_line(view, df::main_choice_type::NewWorld), "Create new world");
            return;
        }

        if (drv.substep == 1)
        {
            if (region_idx < 0)
            {
                stop(out, State::Failed, "world \"" + folder + "\" is not in the title screen's world list");
                return;
            }
            // After "Start new game" DF lists the worlds (region_choice); the
            // highlighted world is assumed to be selected_r.
            if (!take_action(out, "title: choosing world \"" + folder + "\""))
            {
                return;
            }
            drv.substep = 3;
            view->selected_r = region_idx;
            feed(view, df::interface_key::SELECT);
            return;
        }

        // substep 3 (start) or 10 (new world): we already chose; the screen
        // should change. If it does not, give up.
        if (seconds_since(drv.last_action) > TIMEOUT_SCREEN_ACTION)
        {
            stop(out, State::Failed, "title screen did not leave after choosing a menu item");
        }
    }

    void step_choose_game_type(color_ostream & out, df::viewscreen_choose_game_typest *view)
    {
        if (settling())
        {
            return;
        }
        if (drv.actions > 0)
        {
            if (seconds_since(drv.last_action) > TIMEOUT_SCREEN_ACTION)
            {
                stop(out, State::Failed, "game type screen did not accept fortress mode");
            }
            return;
        }
        if (view->gametypes.empty() || view->gametypes.at(0) != df::game_type::DWARF_MAIN)
        {
            stop(out, State::Failed, "game type screen: fortress mode is not the first (default) choice");
            return;
        }
        if (take_action(out, "game type: choosing fortress mode"))
        {
            feed(view, df::interface_key::SELECT);
        }
    }

    void step_new_region(color_ostream & out, df::viewscreen_new_regionst *view)
    {
        auto & status = world->worldgen_status;

        game->main_interface.help.open = false; // cf. hide-tutorials.lua: close_help() on new_region

        if (view->raw_load)
        {
            if (seconds_since(drv.screen_since) > TIMEOUT_RAW_LOAD)
            {
                stop(out, State::Failed, "world generation: raw loading did not finish");
            }
            return;
        }
        if (view->doing_mods || view->doing_params)
        {
            if (seconds_since(drv.screen_since) > TIMEOUT_SCREEN_ACTION)
            {
                stop(out, State::Failed, std::string("world generation is on the ") + (view->doing_mods ? "mod list" : "advanced parameters") + " screen, which df-ai does not drive");
            }
            return;
        }
        if (view->abort_world_gen_dialogue || view->reject_dialogue || view->confirming_abort_save)
        {
            stop(out, State::Failed, "world generation is showing a dialog (abort/reject); not answering it automatically");
            return;
        }
        if (settling())
        {
            return;
        }

        if (view->doing_simple_params)
        {
            int32_t want = std::min(std::max(CFG_WORLD_SIZE, int32_t(0)), int32_t(4));
            if (view->simple_world_size != want)
            {
                log(out, stl_sprintf("world generation: setting world size %d -> %d", view->simple_world_size, want));
                view->simple_world_size = want;
            }
            df::interface_key key = drv.actions % 2 == 0 ? df::interface_key::MENU_CONFIRM : df::interface_key::SELECT;
            if (take_action(out, "world generation: starting (" + enum_item_key(key) + ")"))
            {
                drv.substep = 1;
                feed(view, key);
            }
            return;
        }

        if (status.state != df::world_generatorst::Done)
        {
            if (seconds_since(drv.screen_since) > TIMEOUT_WORLD_GEN)
            {
                stop(out, State::Failed, "world generation did not finish in time");
                return;
            }
            if (seconds_since(drv.last_progress_log) >= 30)
            {
                drv.last_progress_log = clock_type::now();
                log(out, "world generation in progress: " + enum_item_key(status.state));
            }
            return;
        }

        // Generation finished; accept the world.
        if (drv.substep < 2)
        {
            drv.substep = 2;
            drv.actions = 0;
        }
        if (!world->cur_savegame.save_dir.empty())
        {
            drv.world_folder = world->cur_savegame.save_dir;
        }
        if (world->world_data)
        {
            drv.world_name = Translation::translateName(&world->world_data->name, false);
        }
        drv.generated_world = true;
        df::interface_key key = drv.actions % 2 == 0 ? df::interface_key::SELECT : df::interface_key::MENU_CONFIRM;
        if (take_action(out, "world generation finished (folder \"" + drv.world_folder + "\"); accepting (" + enum_item_key(key) + ")"))
        {
            feed(view, key);
        }
    }

    bool good_site(df::world_data *wd, int x, int y)
    {
        auto & rme = wd->region_map[x][y];
        if (rme.flags.is_set(df::region_map_entry_flags::has_site) || rme.flags.is_set(df::region_map_entry_flags::is_lake))
        {
            return false;
        }
        if (!rme.sites.empty())
        {
            return false;
        }
        if (rme.elevation < 100 || rme.elevation >= 150)
        {
            return false; // ocean or mountain
        }
        if (rme.savagery >= 66 || rme.evilness >= 66)
        {
            return false;
        }
        auto region = df::world_region::find(rme.region_id);
        if (!region)
        {
            return false;
        }
        switch (region->type)
        {
            case df::world_region_type::Ocean:
            case df::world_region_type::Lake:
            case df::world_region_type::Glacier:
            case df::world_region_type::Mountains:
                return false;
            default:
                return true;
        }
    }

    void step_choose_start_site(color_ostream & out, df::viewscreen_choose_start_sitest *view)
    {
        close_embark_help(out);
        plotinfo->flags.bits.need_to_do_tutorial = false;

        if (game->main_interface.help.open)
        {
            if (seconds_since(drv.screen_since) > TIMEOUT_SCREEN_ACTION)
            {
                stop(out, State::Failed, "embark screen: a help popup (" + enum_item_key(game->main_interface.help.context) + ") stays open");
            }
            return;
        }
        if (view->choosing_civilization || view->choosing_reclaim || view->doing_site_finder)
        {
            if (seconds_since(drv.screen_since) > TIMEOUT_SCREEN_ACTION)
            {
                stop(out, State::Failed, "embark screen is in the civilization/reclaim/site-finder panel, which df-ai does not drive");
            }
            return;
        }
        if (settling())
        {
            return;
        }

        if (drv.substep == 0)
        {
            auto wd = world->world_data;
            if (!wd || !wd->region_map || wd->world_width <= 0 || wd->world_height <= 0)
            {
                if (seconds_since(drv.screen_since) > TIMEOUT_SCREEN_ACTION)
                {
                    stop(out, State::Failed, "embark screen: no world map data");
                }
                return;
            }
            std::vector<df::coord2d> sites;
            for (int x = 0; x < wd->world_width; x++)
            {
                for (int y = 0; y < wd->world_height; y++)
                {
                    if (good_site(wd, x, y))
                    {
                        sites.push_back(df::coord2d(x, y));
                    }
                }
            }
            if (sites.empty())
            {
                stop(out, State::Failed, "embark screen: no acceptable site found (non-ocean/mountain, unsettled, not savage/evil)");
                return;
            }
            df::coord2d pos = sites.at(std::uniform_int_distribution<size_t>(0, sites.size() - 1)(drv.rng));
            int16_t w = std::min(std::max(CFG_EMBARK_WIDTH, int16_t(1)), int16_t(16));
            int16_t h = std::min(std::max(CFG_EMBARK_HEIGHT, int16_t(1)), int16_t(16));
            int16_t x0 = (16 - w) / 2;
            int16_t y0 = (16 - h) / 2;

            log(out, stl_sprintf("embark screen: chose region tile (%d, %d) out of %zu candidates, area %dx%d", pos.x, pos.y, sites.size(), w, h));
            view->location.region_pos = pos;
            view->location.embark_pos_min = df::coord2d(x0, y0);
            view->location.embark_pos_max = df::coord2d(x0 + w - 1, y0 + h - 1);
            view->region_cent_x = pos.x;
            view->region_cent_y = pos.y;
            drv.substep = 1;
            drv.last_action = clock_type::now();
            return;
        }

        if (seconds_since(drv.last_action) < SETTLE_SECONDS)
        {
            return;
        }

        // Verify our location stuck (the screen may rewrite it from the cursor).
        if (drv.substep == 1 && view->location.embark_pos_max.x < view->location.embark_pos_min.x)
        {
            stop(out, State::Failed, "embark screen: the chosen embark area was not kept by the screen");
            return;
        }

        // "Embark!": the confirmation state is choosing_embark (see
        // gui/embark-anywhere.lua); confirm it with SELECT, then MENU_CONFIRM.
        if (!view->choosing_embark)
        {
            if (take_action(out, "embark screen: opening embark confirmation"))
            {
                drv.substep = 2;
                view->choosing_embark = true;
            }
            return;
        }
        df::interface_key key = drv.actions % 2 == 1 ? df::interface_key::SELECT : df::interface_key::MENU_CONFIRM;
        if (take_action(out, "embark screen: confirming embark (" + enum_item_key(key) + ")"))
        {
            feed(view, key);
        }
    }

    void step_setup_dwarf_game(color_ostream & out, df::viewscreen_setupdwarfgamest *view)
    {
        close_embark_help(out);

        auto & mi = game->main_interface;
        if (view->doing_custom_settings || mi.options.open || mi.name_creator.open || mi.image_creator.open || view->viewing_objections || view->saving_profile)
        {
            if (seconds_since(drv.screen_since) > TIMEOUT_SCREEN_ACTION)
            {
                stop(out, State::Failed, "embark preparation screen is showing a sub-panel (settings/name/symbol/objections/profile) that df-ai does not drive");
            }
            return;
        }
        if (view->preparing_map_timer > 0)
        {
            return; // DF is still generating the local map
        }
        if (settling())
        {
            return;
        }

        if (view->initial_selection == 1)
        {
            // "Play now" / "Prepare carefully" / profiles. The default
            // (first) choice is "Play now".
            if (take_action(out, "embark preparation: choosing the default (\"Play now\")"))
            {
                feed(view, df::interface_key::SELECT);
            }
            return;
        }

        // On the prepare-carefully screens (or after "Play now" brought up the
        // final confirmation): open/confirm the embark.
        if (!view->embark_confirmation)
        {
            if (take_action(out, "embark preparation: opening embark confirmation"))
            {
                view->embark_confirmation = true;
            }
            return;
        }
        df::interface_key key = drv.actions % 2 == 0 ? df::interface_key::SELECT : df::interface_key::MENU_CONFIRM;
        if (take_action(out, "embark preparation: confirming embark (" + enum_item_key(key) + ")"))
        {
            feed(view, key);
        }
    }

    bool is_transition_screen(df::viewscreen *view)
    {
        return strict_virtual_cast<df::viewscreen_update_regionst>(view) ||
            strict_virtual_cast<df::viewscreen_loadgamest>(view) ||
            strict_virtual_cast<df::viewscreen_adopt_regionst>(view) ||
            strict_virtual_cast<df::viewscreen_export_regionst>(view) ||
            strict_virtual_cast<df::viewscreen_game_cleanerst>(view) ||
            strict_virtual_cast<df::viewscreen_initial_prepst>(view) ||
            strict_virtual_cast<df::viewscreen_savegamest>(view);
    }

    bool step(color_ostream & out)
    {
        if (drv.state != State::Running)
        {
            drv.handle = nullptr;
            return true;
        }
        if (++drv.frame % FRAMES_PER_STEP != 0)
        {
            return false;
        }

        df::viewscreen *view = Gui::getDFViewscreen(true);
        if (!view)
        {
            return false;
        }

        const void *type = virtual_identity::get(view);
        if (type != drv.screen_type)
        {
            drv.screen_type = type;
            drv.screen_since = clock_type::now();
            drv.last_progress_log = drv.screen_since;
            drv.actions = 0;
            drv.substep = 0;
            log(out, "screen: " + (Gui::getFocusStrings(view).empty() ? std::string("?") : Gui::getFocusStrings(view).front()));
        }

        try
        {
            if (strict_virtual_cast<df::viewscreen_dwarfmodest>(view))
            {
                if (World::isFortressMode() && Maps::IsValid())
                {
                    close_embark_help(out);
                    hide_fortress_popups();
                    stop(out, State::Done, "fortress loaded; handing over to df-ai");
                    return true;
                }
                if (seconds_since(drv.screen_since) > TIMEOUT_SCREEN_ACTION)
                {
                    stop(out, State::Failed, "main game screen is up but no fortress map is loaded");
                    return true;
                }
            }
            else if (auto title = strict_virtual_cast<df::viewscreen_titlest>(view))
            {
                step_title(out, title);
            }
            else if (auto gt = strict_virtual_cast<df::viewscreen_choose_game_typest>(view))
            {
                step_choose_game_type(out, gt);
            }
            else if (auto nr = strict_virtual_cast<df::viewscreen_new_regionst>(view))
            {
                step_new_region(out, nr);
            }
            else if (auto cs = strict_virtual_cast<df::viewscreen_choose_start_sitest>(view))
            {
                step_choose_start_site(out, cs);
            }
            else if (auto sd = strict_virtual_cast<df::viewscreen_setupdwarfgamest>(view))
            {
                step_setup_dwarf_game(out, sd);
            }
            else if (is_transition_screen(view))
            {
                if (seconds_since(drv.screen_since) > TIMEOUT_TRANSITION)
                {
                    stop(out, State::Failed, "a loading/saving/world-update screen did not finish in time");
                }
            }
            else if (seconds_since(drv.screen_since) > TIMEOUT_UNKNOWN_SCREEN)
            {
                stop(out, State::Failed, "stuck on a screen df-ai does not know how to handle");
            }
        }
        catch (std::exception & e)
        {
            stop(out, State::Failed, std::string("exception: ") + e.what());
        }

        return drv.state != State::Running;
    }
}

namespace embark
{
    bool enabled()
    {
        return CFG_RANDOM_EMBARK;
    }

    bool is_busy()
    {
        return drv.state == State::Running;
    }

    void reset_failure()
    {
        if (drv.state == State::Failed || drv.state == State::Done)
        {
            drv.state = State::Idle;
        }
    }

    void start(color_ostream & out)
    {
        if (!enabled() || drv.state == State::Running || drv.state == State::Failed)
        {
            return;
        }
        if (World::isFortressMode() && Maps::IsValid())
        {
            return; // a fortress is already loaded; nothing to embark
        }
        if (!strict_virtual_cast<df::viewscreen_titlest>(Gui::getDFViewscreen(true)))
        {
            return; // only take over from the title screen
        }

        drv = Driver();
        drv.state = State::Running;
        drv.screen_since = clock_type::now();
        drv.last_action = drv.screen_since;
        drv.last_progress_log = drv.screen_since;
        log(out, "starting automatic world selection / embark");
        drv.handle = events.onupdate_register_once("df-ai embark", [](color_ostream & out) -> bool { return step(out); });
    }

    void hide_tutorials(color_ostream & out)
    {
        close_embark_help(out);
        hide_fortress_popups();
    }
}
