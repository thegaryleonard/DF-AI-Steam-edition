// Direct creation of zones, locations and stockpiles for Dwarf Fortress v50+.
//
// In DF 0.47, df-ai created these through the (keyboard-driven) designation
// menus. DF v50+ replaced those menus with a mouse interface, so df-ai now
// builds the game objects directly, the same way DFHack's quickfort does.

#include "ai.h"

#include <algorithm>
#include <set>
#include "debug.h"
#include "plan.h"

#include "modules/Buildings.h"
#include "modules/Maps.h"
#include "modules/World.h"

#include "df/abstract_building_guildhallst.h"
#include "df/abstract_building_hospitalst.h"
#include "df/abstract_building_inn_tavernst.h"
#include "df/abstract_building_libraryst.h"
#include "df/abstract_building_templest.h"
#include "df/building_civzonest.h"
#include "df/world.h"
#include "df/buildings_other_id.h"
#include "df/tiletype.h"
#include "df/building_stockpilest.h"
#include "df/entity_site_link.h"
#include "df/historical_entity.h"
#include "df/language_handlerst.h"
#include "df/language_name.h"
#include "df/language_word_table.h"
#include "df/stockpile_settings.h"
#include "df/world_site.h"

REQUIRE_GLOBAL(world);
REQUIRE_GLOBAL(cur_year_tick);

df::building_civzonest *Plan::create_zone(color_ostream & out, df::civzone_type type, df::coord min, df::coord max, const std::function<bool(df::coord)> & include)
{
    if (min.x > max.x)
        std::swap(min.x, max.x);
    if (min.y > max.y)
        std::swap(min.y, max.y);

    auto bld = virtual_cast<df::building_civzonest>(Buildings::allocInstance(min, building_type::Civzone, type));
    if (!bld)
    {
        ai.debug(out, "[ERROR] could not allocate " + enum_item_key(type) + " zone");
        return nullptr;
    }

    df::coord2d size(max.x - min.x + 1, max.y - min.y + 1);
    Buildings::setSize(bld, size);

    if (include)
    {
        delete[] bld->room.extents;
        bld->room.extents = new df::building_extents_type[size.x * size.y]();
        bld->room.x = min.x;
        bld->room.y = min.y;
        bld->room.width = size.x;
        bld->room.height = size.y;
        for (int16_t dx = 0; dx < size.x; dx++)
        {
            for (int16_t dy = 0; dy < size.y; dy++)
            {
                bool in = include(df::coord(min.x + dx, min.y + dy, min.z));
                bld->room.extents[dx + size.x * dy] = in ? building_extents_type::Stockpile : building_extents_type::None;
            }
        }
    }

    if (!Buildings::constructAbstract(bld))
    {
        ai.debug(out, "[ERROR] could not place " + enum_item_key(type) + " zone at " + stl_sprintf("(%d, %d, %d)", min.x, min.y, min.z));
        // not deleted: DFHack 53.14+ refuses to free pool-allocated game objects
        return nullptr;
    }

    bld->spec_sub_flag.bits.active = 1;

    switch (type)
    {
    case civzone_type::Pen:
        bld->zone_settings.pen.flags.bits.check_occupants = 1;
        break;
    case civzone_type::Pond:
        bld->zone_settings.pond.flag.bits.keep_filled = 1;
        break;
    case civzone_type::PlantGathering:
        // no tree climbing: pickers get stranded in tree crowns and die of
        // thirst up there (fallen fruit is still gathered)
        bld->zone_settings.gather.flags.bits.pick_trees = 0;
        bld->zone_settings.gather.flags.bits.pick_shrubs = 1;
        bld->zone_settings.gather.flags.bits.gather_fallen = 1;
        break;
    case civzone_type::ArcheryRange:
        bld->zone_settings.archery.dir_x = 1;
        bld->zone_settings.archery.dir_y = 0;
        break;
    case civzone_type::Tomb:
        bld->zone_settings.tomb.flags.bits.no_pets = 1;
        bld->zone_settings.tomb.flags.bits.no_citizens = 0;
        break;
    default:
        break;
    }

    Buildings::notifyCivzoneModified(bld);

    return bld;
}

static void generate_location_name(df::language_name & name, df::language_name_type type, std::mt19937 & rng)
{
    name.type = type;
    name.has_name = true;
    name.language = 0;
    for (auto & w : name.words)
    {
        w = -1;
    }
    for (auto & p : name.parts_of_speech)
    {
        p = part_of_speech::Noun;
    }

    // Same word table quickfort uses for location names.
    auto & table = world->raws.language.word_table[0][35];
    auto & adjectives = table.words[language_word_table_index::Adjectives];
    auto & thex = table.words[language_word_table_index::TheX];
    if (!adjectives.empty())
    {
        name.words[language_name_component::FirstAdjective] = adjectives.at(std::uniform_int_distribution<size_t>(0, adjectives.size() - 1)(rng));
        name.parts_of_speech[language_name_component::FirstAdjective] = part_of_speech::Adjective;
    }
    if (!thex.empty())
    {
        name.words[language_name_component::TheX] = thex.at(std::uniform_int_distribution<size_t>(0, thex.size() - 1)(rng));
    }
}

int32_t Plan::create_location(color_ostream & out, df::building_civzonest *zone, location_type::type type, int32_t data1, int32_t data2)
{
    auto site = df::world_site::find(World::GetCurrentSiteId());
    if (!site || !zone)
    {
        ai.debug(out, "[ERROR] cannot create location: no current site or zone");
        return -1;
    }

    df::abstract_building *loc = nullptr;
    df::language_name *name = nullptr;
    df::abstract_building_contents *contents = nullptr;
    df::language_name_type name_type = language_name_type::Figure;

    switch (type)
    {
    case location_type::tavern:
    {
        auto tavern = df::allocate<df::abstract_building_inn_tavernst>();
        name = &tavern->name;
        contents = &tavern->contents;
        name_type = language_name_type::FoodStore;
        contents->desired_goblets = 10;
        contents->desired_instruments = 5;
        contents->need_more.bits.goblets = 1;
        contents->need_more.bits.instruments = 1;
        loc = tavern;
        break;
    }
    case location_type::library:
    {
        auto library = df::allocate<df::abstract_building_libraryst>();
        name = &library->name;
        contents = &library->contents;
        name_type = language_name_type::Library;
        contents->desired_paper = 10;
        contents->need_more.bits.paper = 1;
        loc = library;
        break;
    }
    case location_type::temple:
    {
        auto temple = df::allocate<df::abstract_building_templest>();
        name = &temple->name;
        contents = &temple->contents;
        name_type = language_name_type::Temple;
        contents->desired_instruments = 5;
        contents->need_more.bits.instruments = 1;
        if (data1 == -1)
        {
            // dedicated to no deity in particular
            temple->deity_type = religious_practice_type::NONE;
            temple->deity_data.Religion = -1;
        }
        else
        {
            temple->deity_type = df::religious_practice_type(data1);
            if (temple->deity_type == religious_practice_type::RELIGION_ENID)
            {
                temple->deity_data.Religion = data2;
            }
            else
            {
                temple->deity_data.Deity = data2;
            }
        }
        loc = temple;
        break;
    }
    case location_type::guildhall:
    {
        auto guildhall = df::allocate<df::abstract_building_guildhallst>();
        name = &guildhall->name;
        contents = &guildhall->contents;
        name_type = language_name_type::Guildhall;
        contents->profession = df::profession(data1);
        loc = guildhall;
        break;
    }
    case location_type::_location_type_count:
        break;
    }

    if (!loc)
    {
        return -1;
    }

    generate_location_name(*name, name_type, ai.rng);

    loc->id = site->next_building_id++;
    loc->site_id = site->id;
    loc->pos = site->pos;
    loc->site_owner_id = -1;
    for (auto link : site->entity_links)
    {
        auto ent = df::historical_entity::find(link->entity_id);
        if (ent && ent->type == historical_entity_type::SiteGovernment)
        {
            loc->site_owner_id = ent->id;
            break;
        }
    }
    // Citizens and long-term residents only by default: visitors drink the stock
    // and bring vampires, werecreatures and thieves (Blind's guide, docs/blind).
    // Population::update_locations then opens ONE tavern to visitors.
    loc->flags.set(abstract_building_flags::VISITORS_ALLOWED, false);
    loc->flags.set(abstract_building_flags::NON_CITIZENS_ALLOWED, true);
    loc->flags.set(abstract_building_flags::MEMBERS_ONLY, false);
    contents->building_ids.push_back(zone->id);

    site->buildings.push_back(loc);

    zone->site_id = site->id;
    zone->location_id = loc->id;
    // re-file the zone under its new location
    zone->uncategorize();
    zone->categorize(true);

    return loc->id;
}

int32_t Plan::create_hospital(color_ostream & out, df::building_civzonest *zone)
{
    auto site = df::world_site::find(World::GetCurrentSiteId());
    if (!site || !zone)
    {
        return -1;
    }

    auto hospital = df::allocate<df::abstract_building_hospitalst>();
    generate_location_name(hospital->name, language_name_type::Hospital, ai.rng);
    auto & c = hospital->contents;
    c.desired_splints = 10;
    c.desired_thread = 75000;
    c.desired_cloth = 50000;
    c.desired_crutches = 10;
    c.desired_powder = 750;
    c.desired_buckets = 5;
    c.desired_soap = 750;
    c.need_more.bits.splints = 1;
    c.need_more.bits.thread = 1;
    c.need_more.bits.cloth = 1;
    c.need_more.bits.crutches = 1;
    c.need_more.bits.powder = 1;
    c.need_more.bits.buckets = 1;
    c.need_more.bits.soap = 1;

    hospital->id = site->next_building_id++;
    hospital->site_id = site->id;
    hospital->pos = site->pos;
    hospital->site_owner_id = -1;
    for (auto link : site->entity_links)
    {
        auto ent = df::historical_entity::find(link->entity_id);
        if (ent && ent->type == historical_entity_type::SiteGovernment)
        {
            hospital->site_owner_id = ent->id;
            break;
        }
    }
    hospital->flags.set(abstract_building_flags::VISITORS_ALLOWED, false);
    hospital->flags.set(abstract_building_flags::NON_CITIZENS_ALLOWED, true);
    c.building_ids.push_back(zone->id);
    site->buildings.push_back(hospital);

    zone->site_id = site->id;
    zone->location_id = hospital->id;
    zone->uncategorize();
    zone->categorize(true);

    return hospital->id;
}

// Map df-ai stockpile types onto DFHack's library of stockpile presets
// (hack/data/stockpiles/*.dfstock), which the "stockpiles" plugin applies.
static const char *stockpile_preset(stockpile_type::type type)
{
    switch (type)
    {
    case stockpile_type::food: return "cat_food";
    case stockpile_type::furniture: return "cat_furniture";
    case stockpile_type::wood: return "cat_wood";
    case stockpile_type::stone: return "cat_stone";
    case stockpile_type::refuse: return "cat_refuse";
    case stockpile_type::animals: return "cat_animals";
    case stockpile_type::corpses: return "cat_corpses";
    case stockpile_type::gems: return "cat_gems";
    case stockpile_type::finished_goods: return "cat_finished_goods";
    case stockpile_type::cloth: return "cat_cloth";
    case stockpile_type::bars_blocks: return "cat_bars_blocks";
    case stockpile_type::leather: return "cat_leather";
    case stockpile_type::ammo: return "cat_ammo";
    case stockpile_type::armor: return "cat_armor";
    case stockpile_type::weapons: return "cat_weapons";
    case stockpile_type::coins: return "cat_coins";
    case stockpile_type::sheets: return "cat_sheets";
    case stockpile_type::fresh_raw_hide: return "cat_refuse";
    case stockpile_type::_stockpile_type_count: break;
    }
    return "cat_food";
}

template<typename T>
static void clear_list(std::vector<T> & v)
{
    std::fill(v.begin(), v.end(), T());
}

static void apply_stockpile_disable(df::stockpile_settings & s, df::stockpile_list list)
{
    switch (list)
    {
    case stockpile_list::FoodMeat: clear_list(s.food.meat); break;
    case stockpile_list::FoodFish: clear_list(s.food.fish); break;
    case stockpile_list::FoodUnpreparedFish: clear_list(s.food.unprepared_fish); break;
    case stockpile_list::FoodEgg: clear_list(s.food.egg); break;
    case stockpile_list::FoodPlants: clear_list(s.food.plants); break;
    case stockpile_list::FoodDrinkPlant: clear_list(s.food.drink_plant); break;
    case stockpile_list::FoodDrinkAnimal: clear_list(s.food.drink_animal); break;
    case stockpile_list::FoodCheesePlant: clear_list(s.food.cheese_plant); break;
    case stockpile_list::FoodCheeseAnimal: clear_list(s.food.cheese_animal); break;
    case stockpile_list::FoodSeeds: clear_list(s.food.seeds); break;
    case stockpile_list::FoodLeaves: clear_list(s.food.leaves); break;
    case stockpile_list::FoodMilledPlant: clear_list(s.food.powder_plant); break;
    case stockpile_list::FoodBoneMeal: clear_list(s.food.powder_creature); break;
    case stockpile_list::FoodFat: clear_list(s.food.glob); break;
    case stockpile_list::FoodPaste: clear_list(s.food.glob_paste); break;
    case stockpile_list::FoodPressedMaterial: clear_list(s.food.glob_pressed); break;
    case stockpile_list::FoodExtractPlant: clear_list(s.food.liquid_plant); break;
    case stockpile_list::FoodExtractAnimal: clear_list(s.food.liquid_animal); break;
    case stockpile_list::FoodMiscLiquid: clear_list(s.food.liquid_misc); break;
    case stockpile_list::RefuseItems: clear_list(s.refuse.type); break;
    case stockpile_list::RefuseCorpses: clear_list(s.refuse.corpses); break;
    case stockpile_list::RefuseParts: clear_list(s.refuse.body_parts); break;
    case stockpile_list::RefuseSkulls: clear_list(s.refuse.skulls); break;
    case stockpile_list::RefuseBones: clear_list(s.refuse.bones); break;
    case stockpile_list::RefuseShells: clear_list(s.refuse.shells); break;
    case stockpile_list::RefuseTeeth: clear_list(s.refuse.teeth); break;
    case stockpile_list::RefuseHorns: clear_list(s.refuse.horns); break;
    case stockpile_list::RefuseHair: clear_list(s.refuse.hair); break;
    case stockpile_list::StoneOres: clear_list(s.ore.mats); break;
    case stockpile_list::StoneEconomic:
    case stockpile_list::StoneOther:
    case stockpile_list::StoneClay:
        // v50 merged these into a single material list; leave enabled.
        break;
    default:
        break;
    }
}

df::building_stockpilest *Plan::create_stockpile(color_ostream & out, room *r)
{
    auto bld = virtual_cast<df::building_stockpilest>(Buildings::allocInstance(r->min, building_type::Stockpile));
    if (!bld)
    {
        return nullptr;
    }
    df::coord size = r->size();
    Buildings::setSize(bld, df::coord2d(size.x, size.y));
    if (!Buildings::constructAbstract(bld))
    {
        // not deleted: DFHack 53.14+ refuses to free pool-allocated game objects
        return nullptr;
    }

    // Start from DFHack's preset for the whole category...
    std::string cmd = stl_sprintf("stockpiles import %s --stockpile %d --mode set", stockpile_preset(r->stockpile_type), bld->id);
    if (Core::getInstance().runCommand(out, cmd) != CR_OK)
    {
        ai.debug(out, "[ERROR] failed to apply stockpile settings: " + cmd);
    }

    // ...then apply the room's restrictions directly.
    auto & s = bld->settings;
    if (r->stockpile_type == stockpile_type::fresh_raw_hide)
    {
        for (auto list : { stockpile_list::RefuseItems, stockpile_list::RefuseCorpses, stockpile_list::RefuseParts, stockpile_list::RefuseSkulls, stockpile_list::RefuseBones, stockpile_list::RefuseShells, stockpile_list::RefuseTeeth, stockpile_list::RefuseHorns, stockpile_list::RefuseHair })
        {
            apply_stockpile_disable(s, list);
        }
        s.refuse.fresh_raw_hide = true;
        s.refuse.rotten_raw_hide = false;
    }
    else
    {
        for (auto disable : r->stock_disable)
        {
            apply_stockpile_disable(s, disable);
        }

        // The old "specific" toggles flipped a category-specific option
        // that "permit all" had turned on.
        switch (r->stockpile_type)
        {
        case stockpile_type::food:
            if (r->stock_specific1)
                s.food.prepared_meals = false;
            break;
        case stockpile_type::refuse:
            if (r->stock_specific1)
                s.refuse.fresh_raw_hide = false;
            if (r->stock_specific2)
                s.refuse.rotten_raw_hide = false;
            break;
        case stockpile_type::animals:
            if (r->stock_specific1)
                s.animals.empty_cages = false;
            if (r->stock_specific2)
                s.animals.empty_traps = false;
            break;
        default:
            break;
        }
    }

    return bld;
}

df::civzone_type Plan::room_zone_type(room *r, furniture *f)
{
    switch (r->type)
    {
    case room_type::bedroom:
        return civzone_type::Bedroom;
    case room_type::nobleroom:
        switch (r->nobleroom_type)
        {
        case nobleroom_type::tomb:
            return civzone_type::Tomb;
        case nobleroom_type::dining:
            return civzone_type::DiningHall;
        case nobleroom_type::office:
            return civzone_type::Office;
        case nobleroom_type::bedroom:
        case nobleroom_type::_nobleroom_type_count:
            break;
        }
        return civzone_type::Bedroom;
    case room_type::dininghall:
        return civzone_type::DiningHall;
    case room_type::barracks:
        if (f && f->type == layout_type::archery_target)
            return civzone_type::ArcheryRange;
        return civzone_type::Barracks;
    case room_type::jail:
        return civzone_type::Dungeon;
    case room_type::cemetery:
        return civzone_type::Tomb;
    default:
        return civzone_type::MeetingHall;
    }
}

df::building_civzonest *Plan::make_room_zone(color_ostream & out, room *r, furniture *f)
{
    if (auto existing = virtual_cast<df::building_civzonest>(df::building::find(r->zone_id)))
    {
        return existing;
    }

    df::civzone_type type = room_zone_type(r, f);
    df::building_civzonest *zone;
    if (type == civzone_type::Tomb && f)
    {
        // each coffin gets its own tomb
        df::coord t = r->min + f->pos;
        zone = create_zone(out, type, t, t);
    }
    else
    {
        zone = create_zone(out, type, r->min, r->max, [r](df::coord t) -> bool { return r->include(t); });
    }

    if (zone && type == civzone_type::ArcheryRange && f)
    {
        // archers stand on the far side of the room from the target
        zone->zone_settings.archery.dir_x = 0;
        zone->zone_settings.archery.dir_y = f->pos.y > 2 ? 1 : -1;
    }

    if (zone)
    {
        r->zone_id = zone->id;
        ai.debug(out, "created " + enum_item_key(type) + " zone for " + AI::describe_room(r));
    }
    return zone;
}

void Plan::remove_room_zone(color_ostream & out, room *r)
{
    if (auto zone = df::building::find(r->zone_id))
    {
        Buildings::deconstruct(zone);
    }
    r->zone_id = -1;
}

// ---------------------------------------------------------------------------
// Indoor pasture (user request): as soon as the caverns are open, dig a big
// pasture into underground SOIL near the entrance. Cave grass grows on fresh
// subterranean soil within days, and the herd lives indoors, safe from
// ambushes and weather. Population::update_pets moves the animals in and
// keeps nest boxes there.

df::building_civzonest *Plan::indoor_pasture_zone()
{
    if (indoor_pasture.size() < 6 || indoor_pasture[5] == -1)
        return nullptr;
    auto zone = virtual_cast<df::building_civzonest>(df::building::find(indoor_pasture[5]));
    if (!zone || zone->type != civzone_type::Pen)
    {
        indoor_pasture[5] = -1;
        return nullptr;
    }
    return zone;
}

static bool ip_wall(df::coord t, bool soil_only)
{
    auto tt = Maps::getTileType(t);
    auto des = Maps::getTileDesignation(t);
    if (!tt || !des || des->bits.outside || des->bits.water_table || des->bits.flow_size)
        return false;
    auto m = ENUM_ATTR(tiletype, material, *tt);
    if (ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) != tiletype_shape_basic::Wall)
        return false;
    return soil_only ? m == tiletype_material::SOIL : (m == tiletype_material::SOIL || m == tiletype_material::STONE || m == tiletype_material::MINERAL);
}

static std::set<df::coord> ip_bad_tunnels;

static bool ip_mask_at(const std::vector<int32_t> & ip, const std::string & mask, int16_t x, int16_t y)
{
    int32_t w = ip[2] - ip[0] + 1;
    size_t i = size_t((y - ip[1]) * w + (x - ip[0]));
    return x >= ip[0] && x <= ip[2] && y >= ip[1] && y <= ip[3] && i < mask.size() && mask[i] == '1';
}

// no miner can stand next to any tile still to dig (tunnel or pasture)
static bool ip_dig_unreachable(const std::vector<int32_t> & ip, uint16_t group)
{
    if (!group || ip.size() < 5)
        return false;
    auto near_walkable = [group](df::coord t) -> bool
    {
        for (int16_t dx = -1; dx <= 1; dx++)
            for (int16_t dy = -1; dy <= 1; dy++)
                if (Maps::getWalkableGroup(t + df::coord(dx, dy, 0)) == group)
                    return true;
        return false;
    };
    auto open_work = [&](df::coord t) -> bool
    {
        auto tt = Maps::getTileType(t);
        return tt && ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) == tiletype_shape_basic::Wall && near_walkable(t);
    };
    for (int16_t x = ip[0]; x <= ip[2]; x++)
        for (int16_t y = ip[1]; y <= ip[3]; y++)
            if (open_work(df::coord(x, y, ip[4])))
                return false;
    if (ip.size() == 10)
    {
        df::coord a(ip[6], ip[7], ip[4]), b(ip[8], ip[9], ip[4]);
        for (df::coord t = a;; )
        {
            if (open_work(t))
                return false;
            if (t == b)
                break;
            t.x += (b.x > t.x) - (b.x < t.x);
            t.y += (b.y > t.y) - (b.y < t.y);
        }
    }
    return true;
}

void Plan::update_indoor_pasture(color_ostream & out)
{
    // a pen the player (or an earlier hand fix) already dug indoors counts
    if (indoor_pasture.empty())
    {
        for (auto bld : world->buildings.other[buildings_other_id::ACTIVITY_ZONE])
        {
            auto zone = virtual_cast<df::building_civzonest>(bld);
            if (!zone || zone->type != civzone_type::Pen)
                continue;
            auto des = Maps::getTileDesignation(df::coord((zone->x1 + zone->x2) / 2, (zone->y1 + zone->y2) / 2, zone->z));
            if (des && !des->bits.outside)
            {
                indoor_pasture = {zone->x1, zone->y1, zone->x2, zone->y2, zone->z, zone->id};
                indoor_pasture_mask.clear();
                ai.debug(out, stl_sprintf("[PASTURE] adopted the existing indoor pasture zone %d", zone->id));
                return;
            }
        }
    }

    if (indoor_pasture.empty())
    {
        if (!fort_entrance)
            return;
        // only once the caverns are open
        if (!ai.find_room(room_type::outpost, [](room *r) -> bool { return r->outpost_type == outpost_type::cavern && r->status != room_status::plan; }))
            return;
        // a 225-tile dig is a big mining job: food first
        if (!food_secure())
            return;

        static int32_t last_try = -1;
        if (last_try != -1 && *cur_year_tick >= last_try && *cur_year_tick - last_try < 12000)
            return; // about every ten days
        last_try = *cur_year_tick;

        // Cave grass only grows on soil, and soil underground is often a thin,
        // ragged layer, so the pasture is whatever connected patch of soil is
        // there (up to 225 tiles, at least 60), not a rectangle. Every tile must
        // be soil with solid wall all round, so digging opens nothing to the
        // sky, water or df-ai's planned rooms (kept 2 tiles away).
        const int16_t R = 45;
        const int16_t W = 2 * R + 1;
        df::coord ent = fort_entrance->min;
        df::coord ref = fort_entrance->max;
        df::coord org(ent.x - R, ent.y - R, 0);
        for (int16_t z = ent.z - 1; z >= ent.z - 10 && z >= 0; z--)
        {
            std::vector<uint8_t> good(size_t(W) * W, 0);
            std::vector<uint8_t> reserved(size_t(W) * W, 0);
            // df-ai keeps its rooms' walls standing (it cancels digging there),
            // so the tunnel may only break into a corridor, never a room
            std::vector<uint8_t> roomring(size_t(W) * W, 0);
            for (auto r : rooms_and_corridors)
            {
                if (r->min.z > z || r->max.z < z)
                    continue;
                if (r->type != room_type::corridor)
                    for (int16_t x = std::max<int16_t>(r->min.x - 1, org.x); x <= std::min<int16_t>(r->max.x + 1, org.x + W - 1); x++)
                        for (int16_t y = std::max<int16_t>(r->min.y - 1, org.y); y <= std::min<int16_t>(r->max.y + 1, org.y + W - 1); y++)
                            roomring[size_t(y - org.y) * W + (x - org.x)] = 1;
                for (int16_t x = std::max<int16_t>(r->min.x - 2, org.x); x <= std::min<int16_t>(r->max.x + 2, org.x + W - 1); x++)
                    for (int16_t y = std::max<int16_t>(r->min.y - 2, org.y); y <= std::min<int16_t>(r->max.y + 2, org.y + W - 1); y++)
                        reserved[size_t(y - org.y) * W + (x - org.x)] = 1;
            }
            for (int16_t y = 1; y < W - 1; y++)
                for (int16_t x = 1; x < W - 1; x++)
                {
                    if (reserved[size_t(y) * W + x])
                        continue;
                    df::coord t(org.x + x, org.y + y, z);
                    if (!ip_wall(t, true))
                        continue;
                    // solid all round, and a solid roof over it and its edge:
                    // the roof is then one slab resting on undug ground.
                    // Machinegems' pastures were dug under a hillside with
                    // nothing checked above; lumps of the hill fell in (12
                    // cave-ins) and down the stair shaft, 9 dwarves crushed
                    bool shell = true;
                    for (int16_t dx = -1; dx <= 1 && shell; dx++)
                        for (int16_t dy = -1; dy <= 1 && shell; dy++)
                            shell = ip_wall(t + df::coord(dx, dy, 0), false) && ip_wall(t + df::coord(dx, dy, 1), false);
                    if (shell)
                        good[size_t(y) * W + x] = 1;
                }

            // keep it blocky: only tiles within one step of a full 3x3 of good
            // soil (no one-tile ribbons along the hillside)
            {
                std::vector<uint8_t> core(good.size(), 0), keep(good.size(), 0);
                for (int16_t y = 1; y < W - 1; y++)
                    for (int16_t x = 1; x < W - 1; x++)
                    {
                        bool all = true;
                        for (int16_t dx = -1; dx <= 1 && all; dx++)
                            for (int16_t dy = -1; dy <= 1 && all; dy++)
                                all = good[size_t(y + dy) * W + (x + dx)] != 0;
                        core[size_t(y) * W + x] = all;
                    }
                for (int16_t y = 1; y < W - 1; y++)
                    for (int16_t x = 1; x < W - 1; x++)
                        if (core[size_t(y) * W + x])
                            for (int16_t dx = -1; dx <= 1; dx++)
                                for (int16_t dy = -1; dy <= 1; dy++)
                                    keep[size_t(y + dy) * W + (x + dx)] = 1;
                good.swap(keep);
            }

            // components; prefer big ones near the fort
            std::vector<uint8_t> seen(size_t(W) * W, 0);
            struct cand { int32_t dist; df::coord seed, tun_a, tun_b; };
            std::vector<cand> cands;
            for (int16_t y = 1; y < W - 1; y++)
                for (int16_t x = 1; x < W - 1; x++)
                {
                    if (!good[size_t(y) * W + x] || seen[size_t(y) * W + x])
                        continue;
                    std::vector<std::pair<int16_t, int16_t>> comp{{x, y}}, stack{{x, y}};
                    seen[size_t(y) * W + x] = 1;
                    while (!stack.empty())
                    {
                        auto c = stack.back();
                        stack.pop_back();
                        static const int16_t D4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                        for (auto & d : D4)
                        {
                            int16_t nx = c.first + d[0], ny = c.second + d[1];
                            if (nx < 1 || ny < 1 || nx >= W - 1 || ny >= W - 1)
                                continue;
                            size_t ni = size_t(ny) * W + nx;
                            if (good[ni] && !seen[ni])
                            {
                                seen[ni] = 1;
                                comp.push_back({nx, ny});
                                stack.push_back({nx, ny});
                            }
                        }
                    }
                    if (comp.size() < 60)
                        continue;
                    // a straight tunnel (up to 12 tiles of solid rock or soil) from an
                    // edge tile of the patch to a fort floor tile walkable from the entrance
                    bool found = false;
                    cand best{-1, df::coord(), df::coord(), df::coord()};
                    for (auto & c : comp)
                    {
                        static const int16_t D4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                        for (auto & d : D4)
                        {
                            int16_t nx = c.first + d[0], ny = c.second + d[1];
                            if (good[size_t(ny) * W + nx])
                                continue; // not an edge in this direction
                            df::coord start(org.x + nx, org.y + ny, z), t = start;
                            for (int step = 0; step < 12; step++)
                            {
                                if (t.x < org.x || t.y < org.y || t.x >= org.x + W || t.y >= org.y + W ||
                                    roomring[size_t(t.y - org.y) * W + (t.x - org.x)] || ip_bad_tunnels.count(t))
                                    break;
                                if (ip_wall(t, false))
                                {
                                    // the tunnel must not run alongside open sky,
                                    // and needs solid ground over it
                                    bool exposed = !ip_wall(t + df::coord(0, 0, 1), false);
                                    for (auto & e : D4)
                                    {
                                        auto nd = Maps::getTileDesignation(t + df::coord(e[0], e[1], 0));
                                        exposed = exposed || !nd || nd->bits.outside || !ip_wall(t + df::coord(e[0], e[1], 1), false);
                                    }
                                    if (exposed)
                                        break;
                                    t = t + df::coord(d[0], d[1], 0);
                                    continue;
                                }
                                auto tt = Maps::getTileType(t);
                                auto des = Maps::getTileDesignation(t);
                                if (step > 0 && tt && des && !des->bits.outside && !des->bits.water_table)
                                {
                                    auto bs = ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt));
                                    if ((bs == tiletype_shape_basic::Floor || bs == tiletype_shape_basic::Stair) && Maps::canWalkBetween(t, ref))
                                    {
                                        int32_t dist = std::abs(t.x - ent.x) + std::abs(t.y - ent.y) + 3 * (ent.z - z) + step * 2;
                                        if (!found || dist < best.dist)
                                        {
                                            best = cand{dist, df::coord(org.x + c.first, org.y + c.second, z), start, t - df::coord(d[0], d[1], 0)};
                                            found = true;
                                        }
                                    }
                                }
                                break;
                            }
                        }
                    }
                    if (found)
                    {
                        best.dist -= int32_t(std::min<size_t>(comp.size(), 225) / 2);
                        cands.push_back(best);
                    }
                }
            if (cands.empty())
                continue;
            std::sort(cands.begin(), cands.end(), [](const cand & a, const cand & b) { return a.dist < b.dist; });
            auto & c = cands.front();

            // grow the pasture from the tunnel mouth, up to 225 tiles (nearest first)
            std::vector<std::pair<int16_t, int16_t>> tiles;
            std::vector<uint8_t> take(size_t(W) * W, 0);
            std::vector<std::pair<int16_t, int16_t>> queue{{int16_t(c.seed.x - org.x), int16_t(c.seed.y - org.y)}};
            take[size_t(queue[0].second) * W + queue[0].first] = 1;
            for (size_t qi = 0; qi < queue.size() && tiles.size() < 225; qi++)
            {
                auto q = queue[qi];
                tiles.push_back(q);
                static const int16_t D4[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                for (auto & d : D4)
                {
                    int16_t nx = q.first + d[0], ny = q.second + d[1];
                    size_t ni = size_t(ny) * W + nx;
                    if (nx >= 1 && ny >= 1 && nx < W - 1 && ny < W - 1 && good[ni] && !take[ni])
                    {
                        take[ni] = 1;
                        queue.push_back({nx, ny});
                    }
                }
            }
            int16_t x1 = W, y1 = W, x2 = -1, y2 = -1;
            for (auto & t : tiles)
            {
                x1 = std::min(x1, t.first); x2 = std::max(x2, t.first);
                y1 = std::min(y1, t.second); y2 = std::max(y2, t.second);
            }
            indoor_pasture = {org.x + x1, org.y + y1, org.x + x2, org.y + y2, z, -1, c.tun_a.x, c.tun_a.y, c.tun_b.x, c.tun_b.y};
            indoor_pasture_mask.assign(size_t(x2 - x1 + 1) * (y2 - y1 + 1), '0');
            for (auto & t : tiles)
            {
                indoor_pasture_mask[size_t(t.second - y1) * (x2 - x1 + 1) + (t.first - x1)] = '1';
                AI::dig_tile(df::coord(org.x + t.first, org.y + t.second, z), tile_dig_designation::Default);
            }
            for (df::coord t = c.tun_a;; )
            {
                AI::dig_tile(t, tile_dig_designation::Default);
                if (t == c.tun_b)
                    break;
                t.x += (c.tun_b.x > t.x) - (c.tun_b.x < t.x);
                t.y += (c.tun_b.y > t.y) - (c.tun_b.y < t.y);
            }
            ai.debug(out, stl_sprintf("[PASTURE] caverns are open: digging a %d-tile indoor pasture in the soil at (%d, %d, %d)-(%d, %d), tunnel from (%d, %d)",
                int(tiles.size()), indoor_pasture[0], indoor_pasture[1], z, indoor_pasture[2], indoor_pasture[3], c.tun_b.x, c.tun_b.y));
            return;
        }
        ai.debug(out, "[PASTURE] no underground soil patch for an indoor pasture near the entrance yet");
        return;
    }

    if (indoor_pasture[5] != -1)
    {
        indoor_pasture_zone();
        return;
    }

    // dug yet? re-designate anything still solid (a reload can drop designations)
    auto ip = indoor_pasture;
    auto & mask = indoor_pasture_mask;
    bool any_mask = mask.find('1') != std::string::npos;
    int solid = 0;
    for (int16_t x = ip[0]; x <= ip[2]; x++)
        for (int16_t y = ip[1]; y <= ip[3]; y++)
        {
            if (any_mask && !ip_mask_at(ip, mask, x, y))
                continue;
            df::coord t(x, y, ip[4]);
            auto tt = Maps::getTileType(t);
            if (tt && ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) == tiletype_shape_basic::Wall)
            {
                solid++;
                auto des = Maps::getTileDesignation(t);
                if (des && des->bits.dig == tile_dig_designation::No)
                    AI::dig_tile(t, tile_dig_designation::Default);
            }
        }
    // and the access tunnel
    if (ip.size() == 10)
    {
        df::coord a(ip[6], ip[7], ip[4]), b(ip[8], ip[9], ip[4]);
        for (df::coord t = a;; )
        {
            auto tt = Maps::getTileType(t);
            if (tt && ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) == tiletype_shape_basic::Wall)
            {
                solid++;
                auto des = Maps::getTileDesignation(t);
                if (des && des->bits.dig == tile_dig_designation::No)
                    AI::dig_tile(t, tile_dig_designation::Default);
            }
            if (t == b)
                break;
            t.x += (b.x > t.x) - (b.x < t.x);
            t.y += (b.y > t.y) - (b.y < t.y);
        }
    }
    // stalled (nobody can reach it, or df-ai keeps cancelling the tunnel)?
    // after ~3 days with no progress, undo it and pick another spot
    static int32_t last_solid = -1, stall_since = -1;
    if (solid && solid != last_solid)
    {
        last_solid = solid;
        stall_since = *cur_year_tick;
    }
    else if (solid && stall_since != -1 && *cur_year_tick < stall_since)
    {
        stall_since = *cur_year_tick; // new year
    }
    else if (solid && stall_since != -1 && *cur_year_tick - stall_since > 3600 && ip_dig_unreachable(ip, fort_group()))
    {
        // a slow dig is not a stuck one: with few miners a 225-tile pasture
        // takes weeks, and dropping it every 3 days left Machinegems with
        // eight half-dug pastures. Only a dig no miner can get to is undone.
        // (the tunnel mouth b is the fort side: reachable means workable)
        for (int16_t x = ip[0]; x <= ip[2]; x++)
            for (int16_t y = ip[1]; y <= ip[3]; y++)
                if (!any_mask || ip_mask_at(ip, mask, x, y))
                    if (auto des = Maps::getTileDesignation(df::coord(x, y, ip[4])))
                        des->bits.dig = tile_dig_designation::No;
        if (ip.size() == 10)
        {
            df::coord a(ip[6], ip[7], ip[4]), b(ip[8], ip[9], ip[4]);
            for (df::coord t = a;; )
            {
                if (auto des = Maps::getTileDesignation(t))
                    des->bits.dig = tile_dig_designation::No;
                ip_bad_tunnels.insert(t);
                if (t == b)
                    break;
                t.x += (b.x > t.x) - (b.x < t.x);
                t.y += (b.y > t.y) - (b.y < t.y);
            }
        }
        ai.debug(out, stl_sprintf("[PASTURE] no miner can reach the indoor pasture dig at (%d, %d, %d); choosing another spot", ip[0], ip[1], ip[4]));
        indoor_pasture.clear();
        indoor_pasture_mask.clear();
        last_solid = stall_since = -1;
        return;
    }
    if (solid)
        return;

    df::coord mn(ip[0], ip[1], ip[4]), mx(ip[2], ip[3], ip[4]);
    std::function<bool(df::coord)> include = nullptr;
    if (any_mask)
        include = [ip, mask](df::coord t) -> bool { return ip_mask_at(ip, mask, t.x, t.y); };
    if (auto zone = create_zone(out, civzone_type::Pen, mn, mx, include))
    {
        indoor_pasture[5] = zone->id;
        ai.debug(out, stl_sprintf("[PASTURE] indoor pasture dug; pen zone %d is open for the herd", zone->id));
    }
}
