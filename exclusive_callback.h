#pragma once

#include "dfhack_shared.h"

#include <string>

// In DF 0.47, df-ai drove the game by feeding simulated keypresses into
// viewscreens from inside a coroutine. Dwarf Fortress v50+ (the Steam
// release) replaced nearly all of those viewscreens with a mouse-driven
// interface, so that approach no longer works.
//
// An ExclusiveCallback is now simply a unit of work that must not overlap
// with other AI updates. It runs synchronously, once, on the tick it is
// scheduled, and changes game state directly through DFHack APIs.
class ExclusiveCallback
{
public:
    ExclusiveCallback(const std::string & description, size_t wait_multiplier = 1);
    virtual ~ExclusiveCallback();

    virtual bool SuppressStateChange(color_ostream &, state_change_event) { return false; }
    virtual void Run(color_ostream & out) = 0;

    const std::string description;
};
