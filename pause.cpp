#include "ai.h"
#include "camera.h"
#include "plan.h"

#include "modules/Gui.h"
#include "modules/Screen.h"

#include "df/d_init.h"
#include "df/report.h"
#include "modules/World.h"

#include "df/popup_message.h"
#include "df/world.h"

REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(cur_year_tick);
REQUIRE_GLOBAL(d_init);
REQUIRE_GLOBAL(pause_state);
REQUIRE_GLOBAL(world);

void AI::unpause()
{
    // Popup announcements ("mega" announcements) are dismissed by sending the
    // close key to the main fortress screen. Each key closes at most one popup.
    for (size_t n = world->status.popups.size(), tries = n + 1; n && tries--; )
    {
        if (auto top = Gui::getDFViewscreen(true))
        {
            std::set<df::interface_key> keys{ interface_key::CLOSE_MEGA_ANNOUNCEMENT };
            top->feed(&keys);
        }
        size_t m = world->status.popups.size();
        if (m >= n)
            break; // the key didn't close anything; don't keep pressing it
        n = m;
    }
    World::SetPauseState(false);
    ignore_pause(last_good_x, last_good_y, last_good_z);
}

void AI::handle_pause_event(color_ostream & out, df::report *announce)
{
    // unsplit announce text
    std::string fulltext = announce->text;
    auto idx = std::find(world->status.announcements.rbegin(), world->status.announcements.rend(), announce);
    while (announce->flags.bits.continuation)
    {
        idx++;
        if (idx == world->status.announcements.rend())
            break;
        announce = *idx;
        fulltext = announce->text + " " + fulltext;
    }
    if (announce->repeat_count)
    {
        fulltext += stl_sprintf(" x%d", announce->repeat_count + 1);
    }
    debug(out, "pause: " + fulltext);

    switch (announce->type)
    {
    case announcement_type::MEGABEAST_ARRIVAL:
    {
        if (!tag_enemies(out))
        {
            debug(out, "[ERROR] could not find megabeast");
        }
        break;
    }
    case announcement_type::UNDEAD_ATTACK:
        if (!tag_enemies(out))
        {
            debug(out, "[ERROR] could not find enemy combatants");
        }
        break;
    case announcement_type::BERSERK_CITIZEN:
    case announcement_type::CAVE_COLLAPSE:
        break;
    case announcement_type::DIG_CANCEL_DAMP:
    case announcement_type::DIG_CANCEL_WARM:
        ignore_pause(last_good_x, last_good_y, last_good_z);
        break;
    case announcement_type::BIRTH_CITIZEN:
    case announcement_type::BIRTH_ANIMAL:
        break;
    case announcement_type::D_MIGRANTS_ARRIVAL:
    case announcement_type::D_MIGRANT_ARRIVAL:
    case announcement_type::MIGRANT_ARRIVAL:
    case announcement_type::NOBLE_ARRIVAL:
    case announcement_type::FORT_POSITION_SUCCESSION:
        plan.make_map_walkable(out); // just in case we missed a frozen river or something during setup
        break;
    case announcement_type::DIPLOMAT_ARRIVAL:
    case announcement_type::LIAISON_ARRIVAL:
    case announcement_type::CARAVAN_ARRIVAL:
    case announcement_type::TRADE_DIPLOMAT_ARRIVAL:
    case announcement_type::STRANGE_MOOD:
    case announcement_type::MOOD_BUILDING_CLAIMED:
    case announcement_type::ARTIFACT_BEGUN:
    case announcement_type::MADE_ARTIFACT:
    case announcement_type::FEATURE_DISCOVERY:
    case announcement_type::STRUCK_DEEP_METAL:
    case announcement_type::TRAINING_FULL_REVERSION:
    case announcement_type::NAMED_ARTIFACT:
        break;
    default:
    {
        const static std::string prefix("AMBUSH");
        std::string type(ENUM_KEY_STR(announcement_type, announce->type));
        if (std::mismatch(prefix.begin(), prefix.end(), type.begin()).first == prefix.end())
        {
            debug(out, "pause: an ambush!");
            if (!tag_enemies(out))
            {
                debug(out, "[ERROR] could not find enemy combatants");
            }
        }
        else
        {
            debug(out, "pause: unhandled pausing event " + type);
            // return;
        }
        break;
    }
    }

    if (d_init->announcements.flags[announce->type].bits.DO_MEGA)
    {
        timeout_sameview([this](color_ostream &) { unpause(); });
    }
    else
    {
        unpause();
    }
}

void AI::statechanged(color_ostream & out, state_change_event st)
{
    // automatically unpause the game (only for game-generated pauses)
    if (st == SC_PAUSED)
    {
        auto la = std::find_if(world->status.announcements.rbegin(), world->status.announcements.rend(), [](df::report *a) -> bool
        {
            return d_init->announcements.flags[a->type].bits.PAUSE;
        });

        if (la != world->status.announcements.rend())
        {
            if ((*la)->year == *cur_year && (*la)->time == *cur_year_tick)
            {
                last_pause_id = (*la)->id;
                last_pause_repeats = (*la)->repeat_count;
                handle_pause_event(out, *la);
                return;
            }
            if ((*la)->id == last_pause_id && (*la)->repeat_count != last_pause_repeats)
            {
                last_pause_repeats = (*la)->repeat_count;
                handle_pause_event(out, *la);
                return;
            }
        }

        if (!config.allow_pause)
        {
            unpause();
        }
        debug(out, "pause without an event");
    }
    else if (st == SC_VIEWSCREEN_CHANGED)
    {
        // In DF v50+, diplomat meetings, sieges and similar events are shown
        // inside the main fortress screen rather than as separate viewscreens.
        // If one of those leaves the game paused, the "df-ai unpause" watcher
        // closes it after a few seconds.
        df::viewscreen *curview = Gui::getCurViewscreen(true);
        if (auto hack = dfhack_viewscreen::try_cast(curview))
        {
            std::string focus = hack->getFocusString();
            if (focus == "lua/warn-starving" || focus == "lua/status_overlay")
            {
                debug(out, "dismissing DFHack dialog " + focus);
                Screen::dismiss(hack);
            }
            else if (seen_focus.insert(focus).second)
            {
                debug(out, "paused in DFHack viewscreen " + focus);
            }
        }
    }
}
