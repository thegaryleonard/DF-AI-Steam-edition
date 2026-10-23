#include "ai.h"
#include "embark.h"
#include "debug.h"
#include "population.h"
#include "plan.h"
#include "plan_setup.h"
#include "stocks.h"
#include "camera.h"
#include "trade.h"

#include "modules/Gui.h"
#include "modules/Screen.h"

#include "modules/Maps.h"
#include "modules/World.h"

#include "df/enabler.h"
#include "df/popup_message.h"
#include "df/world.h"

REQUIRE_GLOBAL(enabler);
REQUIRE_GLOBAL(pause_state);
REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

AI::AI() :
    rng{ 0 },
    logger{ "df-ai.log", std::ios::out | std::ios::app },
    eventsJson{},
    pop{ *this },
    plan{ *this },
    stocks{ *this },
    camera{ *this },
    trade{ *this },
    pause_onupdate{ nullptr },
    tag_enemies_onupdate{ nullptr },
    announcements_onupdate{ nullptr },
    seen_focus{},
    seen_cvname{ "viewscreen_dwarfmodest" },
    last_good_x{ -1 },
    last_good_y{ -1 },
    last_good_z{ -1 },
    last_pause_id{ -1 },
    last_pause_repeats{ 0 },
    skip_persist{ false },
    last_announcement_id{ -1 }
{
    Gui::getViewCoords(last_good_x, last_good_y, last_good_z);
}

AI::~AI()
{
}

bool AI::is_dwarfmode_viewscreen()
{
    // df-ai no longer drives the UI, so this only checks that a fortress is
    // loaded and the player is looking at the plain map (no popups/menus).
    if (!World::isFortressMode() || !Maps::IsValid())
        return false;
    if (!world->status.popups.empty())
        return false;
    return Gui::matchFocusString("dwarfmode/Default", Gui::getDFViewscreen(true));
}

command_result AI::startup(color_ostream & out)
{
    command_result res = CR_OK;
    if (!config.manage_labors.empty())
    {
        // labormanager was not ported to v50+; autolabor works with work details turned off.
        std::string labor_plugin = config.manage_labors == "labormanager" ? "autolabor" : config.manage_labors;
        if (Core::getInstance().runCommand(out, "enable " + labor_plugin) != CR_OK)
        {
            debug(out, "could not enable " + labor_plugin + "; dwarves will use the game's work details instead");
        }
        else if (labor_plugin == "autolabor")
        {
            Core::getInstance().runCommand(out, "autolabor PLANT 5 200");
            Core::getInstance().runCommand(out, "autolabor HERBALIST 1 3");
        }
    }
    // New forts open with tutorial popups that block df-ai's "plain map" checks.
    embark::hide_tutorials(out);

    // DFHack's autotraining adds and removes squad members on its own, which
    // fights df-ai's military management (dismissals undone every day,
    // recruits vanishing). df-ai runs the military, so turn it off.
    {

        if (Core::getInstance().runCommand(out, "disable autotraining") == CR_OK)
        {
            debug(out, "disabled DFHack autotraining (df-ai manages squads itself)");
        }
    }
    if (res == CR_OK)
        res = pop.startup(out);
    if (res == CR_OK)
        res = plan.startup(out);
    if (res == CR_OK)
        res = stocks.startup(out);
    if (res == CR_OK)
        res = camera.startup(out);
    return res;
}

void AI::abandon(color_ostream & out)
{
    // The v50+ abandon flow is a mouse-driven menu that df-ai cannot operate.
    out << "df-ai: abandoning a fortress automatically is not supported in this version of Dwarf Fortress." << std::endl;
}

void AI::timeout_sameview(int32_t seconds, std::function<void(color_ostream &)> cb)
{
    // allow exclusive views to unpause the game
    if (events.has_exclusive())
    {
        cb(Core::getInstance().getConsole());
        return;
    }

    df::viewscreen *curscreen = Gui::getCurViewscreen(true);
    std::string name("unknown viewscreen");
    if (auto hack = dfhack_viewscreen::try_cast(curscreen))
    {
        name = "dfhack/" + hack->getFocusString();
    }
    else if (auto ident = virtual_identity::get(curscreen))
    {
        name = ident->getName();
    }
    int32_t *counter = new int32_t(enabler->fps * seconds);

    events.onupdate_register_once("timeout_sameview on " + name, [this, curscreen, counter, cb](color_ostream & out) -> bool
    {
        if (Gui::getCurViewscreen(true) != curscreen)
        {
            delete counter;
            return true;
        }

        if (--*counter <= 0)
        {
            delete counter;
            cb(out);
            return true;
        }
        return false;
    });
}

static int32_t time_paused = 0;

command_result AI::onupdate_register(color_ostream & out)
{
    command_result res = CR_OK;
    if (res == CR_OK)
        res = pop.onupdate_register(out);
    if (res == CR_OK)
        res = plan.onupdate_register(out);
    if (res == CR_OK)
        res = stocks.onupdate_register(out);
    if (res == CR_OK)
        res = camera.onupdate_register(out);
    if (res == CR_OK)
    {
        time_paused = 0;
        pause_onupdate = events.onupdate_register_once("df-ai unpause", [this](color_ostream &) -> bool
        {
            if (!*pause_state && world->status.popups.empty())
            {
                Gui::getViewCoords(last_good_x, last_good_y, last_good_z);
                time_paused = 0;
                return false;
            }

            time_paused++;

            if (time_paused == enabler->fps * 10)
            {
                timeout_sameview(10, [this](color_ostream &) { unpause(); });
                time_paused = -enabler->fps;
            }

            return false;
        });
        tag_enemies_onupdate = events.onupdate_register("df-ai tag_enemies", 1200, 1200, [this](color_ostream & out) { tag_enemies(out); });
        announcements_onupdate = events.onupdate_register("df-ai announcement watcher", 1, 1, [this](color_ostream &) { watch_announcements(); });
        events.onstatechange_register_once("world unload watcher", [this](color_ostream & out, state_change_event st) -> bool
        {
            if (st == SC_WORLD_UNLOADED)
            {
                debug(out, "world unloaded, disabling self");
                onupdate_unregister(out);
                return true;
            }
            statechanged(out, st);
            return false;
        });
    }
    return res;
}

command_result AI::onupdate_unregister(color_ostream & out)
{
    command_result res = CR_OK;
    if (res == CR_OK)
        res = camera.onupdate_unregister(out);
    if (res == CR_OK)
        res = stocks.onupdate_unregister(out);
    if (res == CR_OK)
        res = plan.onupdate_unregister(out);
    if (res == CR_OK)
        res = pop.onupdate_unregister(out);
    if (res == CR_OK)
    {
        events.onupdate_unregister(pause_onupdate);
        events.onupdate_unregister(tag_enemies_onupdate);
        events.onupdate_unregister(announcements_onupdate);
    }
    return res;
}

command_result AI::persist(color_ostream & out)
{
    command_result res = CR_OK;
    if (skip_persist)
        return res;

    if (res == CR_OK)
        res = plan.persist(out);
    return res;
}

command_result AI::unpersist(color_ostream & out)
{
    command_result res = CR_OK;
    if (res == CR_OK)
        res = plan.unpersist(out);
    return res;
}

bool AI::is_embarking()
{
    return events.has_exclusive<PlanSetup>(true);
}

DFAI_NOINLINE std::ostream & dfai_debug_log()
{
    static std::ofstream log;

    if (DFAI_UNLIKELY(!log.is_open()))
    {
        log.open("df-ai-debug.log", std::ios::out | std::ios::app);
        log << "\n\ndf-ai debug log opened. version information follows:" << std::endl;
        ai_version(log);

        color_ostream_proxy out(Core::getInstance().getConsole());
        out << std::endl;
        out << std::endl;
        out << COLOR_LIGHTRED << "It was inevitable. ";
        out << COLOR_YELLOW << "df-ai has encountered an issue." << std::endl;
        out << "Some information that might help fix this has been written to a file named ";
        out << COLOR_LIGHTCYAN << "df-ai-debug.log";
        out << COLOR_YELLOW << " in your Dwarf Fortress folder." << std::endl;
        out << "If you would like to help, create an issue at https://github.com/BenLubar/df-ai/issues/new (you can drag or copy and paste the log file into the editor)." << std::endl;

#ifndef DFAI_RELEASE
        out << COLOR_LIGHTRED << "If your game crashes after this message, please attach a debugger or use a release mode version of df-ai." << std::endl;
#endif
        out << std::endl;
        out << std::endl;
    }

    return log;
}
