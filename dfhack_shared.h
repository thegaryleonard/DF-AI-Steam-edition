#pragma once

#include "Core.h"
#include <Console.h>
#include <Export.h>
#include <PluginManager.h>

#include "DataDefs.h"
#include "MiscUtils.h"

// DFHack v50+ headers no longer pull these in transitively.
#include "df/building.h"
#include "df/inorganic_raw.h"
#include "df/item.h"
#include "df/material.h"
#include "df/plant_raw.h"
#include "df/plotinfost.h"
#include "df/tile_designation.h"
#include "df/unit.h"
#include "df/world.h"

#include <map>
#include <memory>
#include <set>
#include <tuple>

#ifdef nullptr
#undef nullptr
#endif

#if defined(__GNUC__) && __cplusplus == 201103L
// GCC does not support std::make_unique on C++11, but MSVC does.
namespace std
{
    // Doesn't support array types correctly, but it's good enough for df-ai's purposes.
    template<typename T, typename... Args>
    std::unique_ptr<T> make_unique(Args&&... args)
    {
        return std::unique_ptr<T>(new T(std::forward<Args>(args)...));
    }
}
#endif

using namespace DFHack;
using namespace df::enums;

#ifdef _WIN32
DFhackDataExport extern DFHack::Plugin *plugin_self;
DFhackDataExport extern std::vector<std::string> *plugin_globals;
#else
extern "C"
{
    extern DFHack::Plugin *plugin_self;
    extern std::vector<std::string> *plugin_globals;
}
#endif
