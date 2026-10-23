#pragma once

#include "dfhack_shared.h"

// Automatic world generation / embark driver for DF v50+.
//
// A state machine driven by an onupdate callback (one step every few frames).
// Every step checks which screen DF is on, acts at most once per "phase" by
// editing screen fields and/or feeding a real interface_key, and gives up with
// a log line when a phase does not finish before its timeout.
namespace embark
{
    // Start the driver if automatic embarking is enabled and it is not already
    // running (or has not given up). Safe to call repeatedly.
    void start(color_ostream & out);

    // True while the driver is navigating the pre-game screens. The "df-ai
    // start" hook waits for this to become false before taking over.
    bool is_busy();

    // Forget a previous failure so start() may try again (called when the
    // plugin is re-enabled).
    void reset_failure();

    // Whether automatic embarking is configured on (restart after the world
    // unloads only makes sense when it is).
    bool enabled();

    // Close the fortress help panel and mark every fortress tutorial popup as
    // seen/hidden, so a new fort doesn't sit behind tutorial popups.
    void hide_tutorials(color_ostream & out);
}
