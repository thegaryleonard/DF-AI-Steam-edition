// dfai_portrait: build Dwarf Fortress's own unit portrait (the 96x96 bust
// from the unit sheet) on request, so the stream broadsheet can show it.
//
// DF builds a portrait only while the unit sheet is drawn. Its render code
// does exactly:
//     if (u->portrait_texpos == 0 || u->flags4.portrait_must_be_refreshed)
//         build_unit_portrait(u);
// This plugin calls that same internal function. It is not exported, so the
// address is specific to one DF build: it is checked against the function's
// first bytes and the plugin refuses to call anything that doesn't match.
// Call build() from a render pass (an overlay widget's render), the same
// context DF itself uses.
//
// Lua: require('plugins.dfai_portrait').build(unit_id) -> portrait texpos or 0
//      require('plugins.dfai_portrait').status()        -> "ok" or why not

#include "Core.h"
#include "Console.h"
#include "DataDefs.h"
#include "Export.h"
#include "LuaTools.h"
#include "MemAccess.h"
#include "PluginManager.h"
#include "PluginLua.h"
#include "VersionInfo.h"

#include "df/unit.h"
#include "df/unit_flags4.h"

#include <cstring>
#include <string>

using namespace DFHack;

DFHACK_PLUGIN("dfai_portrait");

namespace
{
    struct KnownBuild
    {
        const char *version;      // VersionInfo::getVersion()
        uintptr_t address;        // unrebased (image base 0x140000000)
        unsigned char prologue[16];
    };

    // DF 53.16 Steam win64: callers at 0x14015a5a6, 0x14026f429 (unit sheet render)
    const KnownBuild BUILDS[] = {
        {"v0.53.16 win64 STEAM", 0x1401b9a20,
         {0x48, 0x89, 0x5c, 0x24, 0x10, 0x48, 0x89, 0x6c, 0x24, 0x18, 0x48, 0x89, 0x74, 0x24, 0x20, 0x57}},
        // DF 53.17: callers at 0x14015bc46, 0x140273359 (+5 more); same body
        {"v0.53.17 win64 STEAM", 0x1401bc220,
         {0x48, 0x89, 0x5c, 0x24, 0x10, 0x48, 0x89, 0x6c, 0x24, 0x18, 0x48, 0x89, 0x74, 0x24, 0x20, 0x57}},
    };

    typedef void (*build_fn)(df::unit *);
    build_fn builder = nullptr;
    std::string why = "not checked yet";

    void resolve()
    {
        builder = nullptr;
        auto vinfo = Core::getInstance().vinfo;
        if (!vinfo)
        {
            why = "no version info";
            return;
        }
        std::string ver = vinfo->getVersion();
        for (auto & b : BUILDS)
        {
            if (ver != b.version)
                continue;
            uintptr_t addr = b.address + vinfo->getRebaseDelta();
            if (std::memcmp(reinterpret_cast<const void *>(addr), b.prologue, sizeof(b.prologue)) != 0)
            {
                why = "function bytes don't match at the expected address (" + ver + ")";
                return;
            }
            builder = reinterpret_cast<build_fn>(addr);
            why = "ok";
            return;
        }
        why = "unknown DF build " + ver;
    }

    int32_t build(int32_t unit_id)
    {
        if (!builder)
            return 0;
        auto u = df::unit::find(unit_id);
        if (!u)
            return 0;
        if (u->portrait_texpos == 0 || u->flags4.bits.portrait_must_be_refreshed)
            builder(u);
        return u->portrait_texpos;
    }

    std::string status()
    {
        return why;
    }
}

DFHACK_PLUGIN_LUA_FUNCTIONS {
    DFHACK_LUA_FUNCTION(build),
    DFHACK_LUA_FUNCTION(status),
    DFHACK_LUA_END
};

DFhackCExport command_result plugin_init(color_ostream & out, std::vector<PluginCommand> &)
{
    resolve();
    out.print("dfai_portrait: %s\n", why.c_str());
    return CR_OK;
}

DFhackCExport command_result plugin_shutdown(color_ostream &)
{
    builder = nullptr;
    return CR_OK;
}
