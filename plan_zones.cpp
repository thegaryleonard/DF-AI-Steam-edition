// Direct creation of zones, locations and stockpiles for Dwarf Fortress v50+.
//
// In DF 0.47, df-ai created these through the (keyboard-driven) designation
// menus. DF v50+ replaced those menus with a mouse interface, so df-ai now
// builds the game objects directly, the same way DFHack's quickfort does.

#include "ai.h"
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
#include "df/building_stockpilest.h"
#include "df/entity_site_link.h"
#include "df/historical_entity.h"
#include "df/language_handlerst.h"
#include "df/language_name.h"
#include "df/language_word_table.h"
#include "df/stockpile_settings.h"
#include "df/world_site.h"

REQUIRE_GLOBAL(world);

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
        bld->zone_settings.gather.flags.bits.pick_trees = 1;
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
    // Citizens and long-term residents only: visitors drink the tavern's stock and
    // bring vampires, werecreatures and thieves (Blind's guide, docs/blind).
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
