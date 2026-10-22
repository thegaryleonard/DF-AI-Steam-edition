#include "dfhack_shared.h"
#include "config.h"
#include "debug.h"

#include <algorithm>
#include <fstream>

#include "json/json.h"

Config config;
DebugCategoryConfig debug_category_config;

static std::string config_name()
{
    return (Core::getInstance().getConfigPath() / "df-ai.json").string();
}

Config::Config() :
    write_console(true),
    write_log(true),
    camera(true),
    manage_labors("autolabor"),
    manage_nobles(true),
    cancel_announce(0),
    allow_pause(true)
{
}

void Config::load(color_ostream & out)
{
    std::ifstream f(config_name());
    if (f.good())
    {
        try
        {
            Json::Value v(Json::objectValue);
            f >> v;

            if (v.isMember("write_console"))
            {
                write_console = v["write_console"].asBool();
            }
            else if (v.isMember("debug"))
            {
                write_console = v["debug"].asBool();
            }
            if (v.isMember("write_log"))
            {
                write_log = v["write_log"].asBool();
            }
            if (v.isMember("camera"))
            {
                camera = v["camera"].asBool();
            }
            if (v.isMember("manage_labors"))
            {
                if (v["manage_labors"].isBool())
                {
                    if (v["manage_labors"].asBool())
                    {
                        manage_labors = "autolabor";
                    }
                    else
                    {
                        manage_labors = "";
                    }
                }
                else
                {
                    manage_labors = v["manage_labors"].asString();
                }
            }
            if (v.isMember("manage_nobles"))
            {
                manage_nobles = v["manage_nobles"].asBool();
            }
            if (v.isMember("cancel_announce"))
            {
                cancel_announce = v["cancel_announce"].asInt();
            }
            if (v.isMember("allow_pause"))
            {
                allow_pause = v["allow_pause"].asBool();
            }
            if (v.isMember("plan_verbosity"))
            {
                debug_category_config.blueprint = v["plan_verbosity"].asInt();
                if (debug_category_config.blueprint < 0)
                {
                    debug_category_config.blueprint = 0;
                }
            }
#define DFAI_DEBUG_CATEGORY(x) \
            if (v.isMember(#x "_debug")) \
            { \
                debug_category_config.x = v[#x "_debug"].isBool() ? \
                    (v[#x "_debug"].asBool() ? 1 : 0) : \
                    v[#x "_debug"].asInt(); \
                if (debug_category_config.x < 0) \
                { \
                    out << "AI warning: debug levels cannot be negative (" #x << " level was set to " << debug_category_config.x << ")" << std::endl; \
                    debug_category_config.x = 0; \
                } \
                if (DFAI_IS_RELEASE && debug_category_config.x > 3) \
                { \
                    out << "AI warning: debug levels higher than 3 are not supported in release builds (" #x << " level is set to " << debug_category_config.x << ")" << std::endl; \
                } \
            } \
            else \
            { \
                debug_category_config.x = 0; \
            }
DFAI_DEBUG_CATEGORIES
#undef DFAI_DEBUG_CATEGORY
        }
        catch (Json::Exception & ex)
        {
            out << "AI: loading config failed: " << ex.what() << std::endl;
        }
    }
}

template<typename T>
inline void setComment(Json::Value & value, const T & t, const std::string & comment, Json::CommentPlacement placement = Json::commentBefore)
{
    value = t;
    value.setComment(comment, placement);
}

void Config::save(color_ostream & out)
{
    Json::Value v(Json::objectValue);
    setComment(v["write_console"], write_console, "// true or false: should the AI say what it's thinking in the DFHack console?");
    setComment(v["write_log"], write_log, "// true or false: should the AI say what it's thinking in df-ai.log?");
    setComment(v["camera"], camera, "// true or false: should the AI automatically follow dwarves it thinks are interesting?");
    setComment(v["manage_labors"], manage_labors, "// the name of a DFHack plugin that manages labors, in quotes, or \"\" for no automated labor management. \"autolabor\" is supported (labormanager has not been updated for Dwarf Fortress v50+).");
    setComment(v["manage_nobles"], manage_nobles, "// true or false: should the AI assign administrators in the fortress?");
    setComment(v["cancel_announce"], Json::Int(cancel_announce), "// how many job cancellation notices to show. 0: none, 1: some, 2: most, 3: all");
    setComment(v["allow_pause"], allow_pause, "// true or false: should df-ai allow the game to be paused?");

#define DFAI_DEBUG_CATEGORY(x) \
    if (!DFAI_IS_RELEASE || debug_category_config.x) \
        setComment(v[#x "_debug"], debug_category_config.x, "// hidden option; writes a LOT of information to df-ai-debug.log");
DFAI_DEBUG_CATEGORIES
#undef DFAI_DEBUG_CATEGORY

    std::ofstream f(config_name(), std::ofstream::trunc);
    f << v;
    if (f.fail())
    {
        out << "failed to write " << config_name() << std::endl;
    }
}
