#include "ai.h"

#include <algorithm>
#include "population.h"
#include "plan.h"

#include "modules/Buildings.h"
#include "modules/Units.h"

#include "df/building_civzonest.h"
#include "df/building_nest_boxst.h"
#include "df/items_other_id.h"
#include "df/tiletype.h"
#include "df/civzone_type.h"
#include "df/tool_uses.h"
#include "df/itemdef_toolst.h"
#include "df/item_toolst.h"
#include "modules/Maps.h"
#include "df/caste_raw.h"
#include "df/caste_raw_flags.h"
#include "df/general_ref_type.h"
#include "df/creature_raw.h"
#include "df/general_ref_building_civzone_assignedst.h"
#include "df/item_eggst.h"
#include "df/manager_order.h"
#include "df/manager_order_template.h"
#include "df/training_assignment.h"
#include "df/plotinfost.h"
#include "df/unit_misc_trait.h"
#include "df/unit_relationship_type.h"
#include "df/unit_wound.h"
#include "df/unit_wound_layerst.h"
#include "df/shearable_tissue_layerst.h"
#include "df/buildingitemst.h"
#include "df/animal_training_infost.h"
#include "df/buildings_other_id.h"
#include "df/world.h"

REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

// Nest boxes in the indoor pasture (user request): once an underground pen
// exists, keep about one nest box per three tame egg-laying hens in it (1-6),
// placed against the pen's walls so they don't block the grazing floor. One
// box per call; boxes under construction count, so it never over-places.
static void place_indoor_nest_boxes(AI & ai, color_ostream & out)
{
    int hens = 0;
    for (auto u : world->units.active)
    {
        if (Units::isActive(u) && Units::isTame(u) && Units::isEggLayer(u) && Units::isFemale(u) && !Units::isCitizen(u))
            hens++;
    }
    if (!hens)
        return;
    int want = std::max(1, std::min(6, (hens + 2) / 3));

    for (auto bld : world->buildings.other[buildings_other_id::ACTIVITY_ZONE])
    {
        auto zone = virtual_cast<df::building_civzonest>(bld);
        if (!zone || zone->type != civzone_type::Pen)
            continue;
        df::coord mid((zone->x1 + zone->x2) / 2, (zone->y1 + zone->y2) / 2, zone->z);
        auto mdes = Maps::getTileDesignation(mid);
        if (!mdes || mdes->bits.outside)
            continue;

        int have = 0;
        for (auto nb : world->buildings.other[buildings_other_id::NEST_BOX])
        {
            if (nb->z == zone->z && nb->centerx >= zone->x1 && nb->centerx <= zone->x2 && nb->centery >= zone->y1 && nb->centery <= zone->y2)
                have++;
        }
        if (have >= want)
            continue;

        df::item *box = nullptr;
        for (auto item : world->items.other[items_other_id::TOOL])
        {
            auto tool = virtual_cast<df::item_toolst>(item);
            if (!tool || !tool->subtype)
                continue;
            auto & uses = tool->subtype->tool_use;
            if (std::find(uses.begin(), uses.end(), tool_uses::NEST_BOX) == uses.end())
                continue;
            auto & f = item->flags.bits;
            if (f.forbid || f.dump || f.in_job || f.owned || f.trader || f.foreign || f.construction || f.in_building || f.removed || f.garbage_collect || f.hidden || f.in_inventory)
                continue;
            box = item;
            break;
        }
        if (!box)
            return; // stocks keeps one spare nest box made; try again next time

        // a free floor tile inside the pen with a wall next to it
        df::coord spot;
        for (int16_t y = zone->y1; y <= zone->y2 && !spot.isValid(); y++)
        {
            for (int16_t x = zone->x1; x <= zone->x2 && !spot.isValid(); x++)
            {
                df::coord t(x, y, zone->z);
                auto tt = Maps::getTileType(t);
                auto occ = Maps::getTileOccupancy(t);
                auto des = Maps::getTileDesignation(t);
                if (!tt || !occ || !des || des->bits.flow_size || occ->bits.building != tile_building_occ::None || !Buildings::containsTile(zone, df::coord2d(x, y)))
                    continue;
                if (ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *tt)) != tiletype_shape_basic::Floor)
                    continue;
                bool walled = false;
                for (int16_t d = 0; d < 4 && !walled; d++)
                {
                    df::coord n = t + df::coord(d == 0 ? 1 : d == 1 ? -1 : 0, d == 2 ? 1 : d == 3 ? -1 : 0, 0);
                    auto nt = Maps::getTileType(n);
                    walled = nt && ENUM_ATTR(tiletype_shape, basic_shape, ENUM_ATTR(tiletype, shape, *nt)) == tiletype_shape_basic::Wall;
                }
                if (walled)
                    spot = t;
            }
        }
        if (!spot.isValid())
            continue;

        df::building *nb = Buildings::allocInstance(spot, building_type::NestBox);
        Buildings::setSize(nb, df::coord(1, 1, 1));
        std::vector<df::item *> items{box};
        if (Buildings::constructWithItems(nb, items))
            ai.debug(out, stl_sprintf("[PETS] nest box %d/%d in the indoor pasture at (%d, %d, %d)", have + 1, want, spot.x, spot.y, spot.z));
        return;
    }
}

// Indoor pasture: move tame animals from df-ai's surface pastures into the
// indoor pen, a few per call, while its grass can feed them (grazers up to
// one per 8 grass tiles, at least 4; non-grazers always). Owned pets stay.
static void fill_indoor_pasture(AI & ai, Population & pop, color_ostream & out)
{
    auto zone = ai.plan.indoor_pasture_zone();
    if (!zone)
        return;
    int grass = 0;
    for (int16_t x = zone->x1; x <= zone->x2; x++)
        for (int16_t y = zone->y1; y <= zone->y2; y++)
            if (!Buildings::containsTile(zone, df::coord2d(x, y)))
                continue;
            else if (auto tt = Maps::getTileType(df::coord(x, y, zone->z)))
            {
                auto tm = ENUM_ATTR(tiletype, material, *tt);
                if (tm == tiletype_material::GRASS_LIGHT || tm == tiletype_material::GRASS_DARK || tm == tiletype_material::GRASS_DRY)
                    grass++;
            }
    int grazers = 0;
    for (auto id : zone->assigned_units)
        if (auto u = df::unit::find(id))
            if (auto c = Units::getCasteRaw(u))
                if (c->flags.is_set(caste_raw_flags::GRAZER))
                    grazers++;
    int cap = std::max(4, grass / 8);
    int moved = 0;
    for (auto u : world->units.active)
    {
        if (moved >= 5)
            break;
        if (!Units::isActive(u) || !Units::isTame(u) || Units::isCitizen(u) || Units::isMerchant(u) || u->flags1.bits.caged || u->civ_id != plotinfo->civ_id)
            continue;
        if (u->relationship_ids[unit_relationship_type::PetOwner] != -1)
            continue;
        auto ref = Units::getGeneralRef(u, general_ref_type::BUILDING_CIVZONE_ASSIGNED);
        if (!ref)
            continue; // only animals df-ai has already put out to pasture
        auto bld = ref->getBuilding();
        if (bld == zone)
            continue;
        auto r = ai.find_room(room_type::pasture, [bld](room *r_) -> bool { return r_->dfbuilding() == bld; });
        if (!r)
            continue; // a pit, pond or someone's own zone
        auto c = Units::getCasteRaw(u);
        bool grazer = c && c->flags.is_set(caste_raw_flags::GRAZER);
        if (grazer && grazers >= cap)
            continue;
        r->users.erase(u->id);
        pop.assign_unit_to_zone(u, zone);
        if (grazer)
            grazers++;
        moved++;
    }
    if (moved)
        ai.debug(out, stl_sprintf("[PASTURE] moved %d animals into the indoor pasture (%d grass tiles, %d grazers)", moved, grass, grazers));
}

void Population::update_pets(color_ostream & out)
{
    ai.plan.update_indoor_pasture(out);
    fill_indoor_pasture(ai, *this, out);
    place_indoor_nest_boxes(ai, out);

    if (!ai.plan.pastures_ready(out))
    {
        // will check next time
        return;
    }

    int32_t needmilk = 0;
    int32_t needshear = 0;
    for (auto mo : world->manager_orders.all)
    {
        if (mo->job_type == job_type::MilkCreature)
        {
            needmilk -= mo->amount_left;
        }
        else if (mo->job_type == job_type::ShearCreature)
        {
            needshear -= mo->amount_left;
        }
    }

    std::map<df::caste_raw *, std::set<std::pair<int32_t, df::unit *>>> forSlaughter;

    std::map<int32_t, pet_flags> np = pet;
    for (auto it : pet_check)
    {
        np[it]; // make sure existing pasture assignments are checked
    }
    pet_check.clear();
    for (auto u : world->units.active)
    {
        df::creature_raw *race = df::creature_raw::find(u->race);
        df::caste_raw *cst = race->caste[u->caste];

        if (cst->flags.is_set(caste_raw_flags::CAN_LEARN))
        {
            continue;
        }

        if (u->flags1.bits.inactive || u->flags1.bits.merchant || u->flags1.bits.forest || u->flags2.bits.visitor || u->flags2.bits.slaughter)
        {
            continue;
        }

        if (u->flags1.bits.caged && u->civ_id == -1 && u->cultural_identity == -1 && u->training_level == animal_training_level::WildUntamed)
        {
            // train any caught wild animals
            if (!df::training_assignment::find(u->id))
            {
                auto asn = df::allocate<df::training_assignment>();
                asn->animal_id = u->id;
                asn->trainer_id = -1;
                asn->flags.whole = 0;
                asn->flags.bits.any_trainer = true;
                insert_into_vector(plotinfo->training.training_assignments, &df::training_assignment::animal_id, asn);
            }

            continue;
        }

        if (!Units::isOwnCiv(u) || Units::isOwnGroup(u) || Units::isOwnRace(u) || u->cultural_identity != -1)
        {
            continue;
        }

        int32_t age = days_since(u->birth_year, u->birth_time);

        if (u->training_level > animal_training_level::SemiWild && u->training_level < animal_training_level::Domesticated)
        {
            u->flags2.bits.slaughter = 1;
            ai.debug(out, stl_sprintf("marked %dy%dm%dd old %s:%s for slaughter (trained wild animal)", age / 12 / 28, (age / 28) % 12, age % 28, race->creature_id.c_str(), cst->caste_id.c_str()));
            continue;
        }

        if (pet.count(u->id))
        {
            // v50: caste_raw::body_size_2 is gone; treat an adult that has
            // reached its base body size as full grown.
            if (Units::isAdult(u) && u->body.size_info.size_cur >= u->body.size_info.size_base && // full grown
                u->profession != profession::TRAINED_HUNTER && // not trained
                u->profession != profession::TRAINED_WAR && // not trained
                u->relationship_ids[unit_relationship_type::Pet] == -1) // not owned
            {
                if (std::find_if(u->body.wounds.begin(), u->body.wounds.end(), [](df::unit_wound *w) -> bool { return std::find_if(w->parts.begin(), w->parts.end(), [](df::unit_wound_layerst *p) -> bool { return p->flags2.bits.gelded; }) != w->parts.end(); }) != u->body.wounds.end() || cst->sex == pronoun_type::it)
                {
                    // animal can't reproduce, can't work, and will provide maximum butchering reward. kill it.
                    u->flags2.bits.slaughter = true;
                    ai.debug(out, stl_sprintf("marked %dy%dm%dd old %s:%s for slaughter (can't reproduce)", age / 12 / 28, (age / 28) % 12, age % 28, race->creature_id.c_str(), cst->caste_id.c_str()));
                    continue;
                }

                forSlaughter[cst].insert(std::make_pair(age, u));
            }

            if (pet.at(u->id).bits.milkable && !Units::isBaby(u) && !Units::isChild(u))
            {
                bool have = false;
                for (auto mt : u->status.misc_traits)
                {
                    if (mt->id == misc_trait_type::MilkCounter)
                    {
                        have = true;
                        break;
                    }
                }
                if (!have)
                {
                    needmilk++;
                }
            }

            if (pet.at(u->id).bits.shearable && !Units::isBaby(u) && !Units::isChild(u))
            {
                bool found = false;
                for (auto stl : cst->shearable_tissue_layer)
                {
                    for (auto bpi : stl->bp_modifiers_idx)
                    {
                        if (u->appearance.bp_modifiers[bpi] >= stl->length)
                        {
                            needshear++;
                            found = true;
                            break;
                        }
                    }
                    if (found)
                        break;
                }
            }

            np.erase(u->id);
            continue;
        }

        pet_flags flags;
        flags.bits.milkable = 0;
        flags.bits.shearable = 0;
        flags.bits.hunts_vermin = 0;
        flags.bits.trainable = 0;
        flags.bits.grazer = 0;
        flags.bits.lays_eggs = 0;

        if (cst->flags.is_set(caste_raw_flags::MILKABLE))
        {
            flags.bits.milkable = 1;
        }

        if (!cst->shearable_tissue_layer.empty())
        {
            flags.bits.shearable = 1;
        }

        if (cst->flags.is_set(caste_raw_flags::HUNTS_VERMIN))
        {
            flags.bits.hunts_vermin = 1;
        }

        if (cst->flags.is_set(caste_raw_flags::TRAINABLE_HUNTING) || cst->flags.is_set(caste_raw_flags::TRAINABLE_WAR))
        {
            flags.bits.trainable = 1;
        }

        if (cst->flags.is_set(caste_raw_flags::GRAZER))
        {
            flags.bits.grazer = 1;

            if (auto bld = virtual_cast<df::building_civzonest>(ai.plan.getpasture(out, u->id)))
            {
                assign_unit_to_zone(u, bld);
                // TODO monitor grass levels
            }
            else if (u->relationship_ids[df::unit_relationship_type::Pet] == -1 && !cst->flags.is_set(caste_raw_flags::CAN_LEARN))
            {
                // TODO slaughter best candidate, keep this one
                u->flags2.bits.slaughter = 1;
                ai.debug(out, stl_sprintf("marked %dy%dm%dd old %s:%s for slaughter (no pasture)", age / 12 / 28, (age / 28) % 12, age % 28, race->creature_id.c_str(), cst->caste_id.c_str()));
            }
        }

        if (cst->flags.is_set(caste_raw_flags::LAYS_EGGS))
        {
            flags.bits.lays_eggs = 1;
        }

        pet[u->id] = flags;
    }

    for (auto p : np)
    {
        ai.plan.freepasture(out, p.first);
        pet.erase(p.first);
    }

    for (auto & cst : forSlaughter)
    {
        // we have reproductively viable animals, but there are more than 3 of
        // this sex (full-grown). kill the oldest ones for meat/leather/bones.

        if (cst.second.size() > 3)
        {
            // remove the youngest 3
            auto it = cst.second.begin();
            std::advance(it, 3);
            cst.second.erase(cst.second.begin(), it);

            for (auto it : cst.second)
            {
                int32_t age = it.first;
                df::unit *u = it.second;
                df::creature_raw *race = df::creature_raw::find(u->race);
                u->flags2.bits.slaughter = 1;
                ai.debug(out, stl_sprintf("marked %dy%dm%dd old %s:%s for slaughter (too many adults)", age / 12 / 28, (age / 28) % 12, age % 28, race->creature_id.c_str(), cst.first->caste_id.c_str()));
            }
        }
    }

    if (needmilk > 0)
    {
        df::manager_order_template tmpl;
        tmpl.job_type = job_type::MilkCreature;
        tmpl.mat_index = -1;

        ai.stocks.add_manager_order(out, tmpl, std::min(needmilk, 30));
    }

    if (needshear > 0)
    {
        df::manager_order_template tmpl;
        tmpl.job_type = job_type::ShearCreature;
        tmpl.mat_index = -1;

        ai.stocks.add_manager_order(out, tmpl, std::min(needshear, 30));
    }

    for (auto bld : world->buildings.other[buildings_other_id::NEST_BOX])
    {
        auto box = virtual_cast<df::building_nest_boxst>(bld);
        if (!box || box->getBuildStage() != box->getMaxBuildStage())
        {
            continue;
        }

        if (box->claimed_by == -1)
        {
            continue;
        }

        for (auto item : box->contained_items)
        {
            if (auto egg = virtual_cast<df::item_eggst>(item->item))
            {
                if (egg->egg_flags.bits.fertile)
                {
                    // baby chicks are preferable over cooked eggs.
                    egg->flags.bits.forbid = true;
                }
            }
        }
    }
}

void Population::assign_unit_to_zone(df::unit *u, df::building_civzonest *bld)
{
    if (!u || !bld)
    {
        return;
    }

    // Detach from any previously assigned zone (pasture, pit, pond).
    for (size_t i = 0; i < u->general_refs.size(); i++)
    {
        auto ref = virtual_cast<df::general_ref_building_civzone_assignedst>(u->general_refs.at(i));
        if (!ref)
        {
            continue;
        }

        if (ref->building_id == bld->id)
        {
            // already assigned to the correct zone; make sure the zone agrees.
            insert_into_vector(bld->assigned_units, u->id);
            return;
        }

        if (auto old_zone = virtual_cast<df::building_civzonest>(df::building::find(ref->building_id)))
        {
            erase_from_vector(old_zone->assigned_units, u->id);
        }

        vector_erase_at(u->general_refs, i);
        // not freed: DFHack 53.14+ refuses to free pool-allocated game objects
        i--;
    }

    // Same as DFHack's zone plugin: add a civzone-assigned ref to the unit
    // and the unit id to the zone's sorted assigned_units vector. The game
    // creates the job to lead the animal there.
    auto ref = df::allocate<df::general_ref_building_civzone_assignedst>();
    ref->building_id = bld->id;
    u->general_refs.push_back(ref);
    insert_into_vector(bld->assigned_units, u->id);
}
