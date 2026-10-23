#pragma once

#include "dfhack_shared.h"

#include <string>

struct Config
{
    Config();
    void load(color_ostream & out);
    void save(color_ostream & out);
    template<typename T>
    void set(color_ostream & out, T & saved, const T & value)
    {
        if (saved == value)
        {
            return;
        }
        saved = value;
        save(out);
    }
    template<typename T>
    void set(color_ostream & out, volatile T & saved, const T & value)
    {
        set(out, saved, (const volatile T &)value);
    }

    bool write_console;
    bool write_log;
    bool camera;
    std::string manage_labors;
    bool manage_nobles;
    uint8_t cancel_announce;
    bool allow_pause;
    bool direct_trade;
    bool manage_justice;
    bool random_embark;
    std::string random_embark_world;
    int32_t world_size;
    int16_t embark_width;
    int16_t embark_height;
};

extern Config config;
