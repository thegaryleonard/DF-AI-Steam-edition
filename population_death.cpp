#include "ai.h"
#include "population.h"
#include "plan.h"
#include "stocks.h"

#include "modules/Units.h"

#include "df/building_civzonest.h"
#include "df/civzone_type.h"
#include "df/buildings_other_id.h"
#include "df/historical_figure.h"
#include "df/history_event_hist_figure_diedst.h"
#include "df/item.h"
#include "df/items_other_id.h"
#include "df/plotinfost.h"
#include "df/world.h"

REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

void Population::deathwatch(color_ostream & out)
{
    if (world->history.events_death.size() == seen_death)
    {
        return;
    }

    auto it = world->history.events_death.begin();
    std::advance(it, seen_death);
    for (; it != world->history.events_death.end(); it++)
    {
        auto d = virtual_cast<df::history_event_hist_figure_diedst>(*it);

        if (!d || d->site != plotinfo->site_id)
        {
            continue;
        }

        ai.debug(out, "[RIP] " + AI::describe_event(d));
    }

    seen_death = world->history.events_death.size();
}

// In DF v50+, coffins no longer own rooms. Burial happens in Tomb civzones
// (which usually contain a coffin). A tomb zone with no assigned unit is
// available for burial; its zone_settings.tomb.flags control whether pets
// and/or citizens may be buried there.
static df::building_civzonest *coffin_tomb_zone(df::building *bld)
{
    for (auto zone : bld->relations)
    {
        if (zone && zone->type == civzone_type::Tomb)
        {
            return zone;
        }
    }
    return nullptr;
}

void Population::update_deads(color_ostream & out)
{
    int32_t want_coffin = 3;
    int32_t want_pet_coffin = 1;

    // A fort member's body lying unburied makes a ghost (and stress, then
    // tantrums). The plans put the cemetery behind the metal industry, and the
    // coffin logic below waits for a dug cemetery, so dig one now if needed.
    // Match by civilization: dead units lose isOwnGroup.
    if (!ai.find_room(room_type::cemetery, [](room *r) -> bool { return r->status != room_status::plan; }))
    {
        bool unburied = false;
        for (auto i : world->items.other[items_other_id::ANY_CORPSE])
        {
            int16_t race = -1, caste = -1;
            df::historical_figure *hf = nullptr;
            df::unit *cu = nullptr;
            i->getCorpseInfo(&race, &caste, &hf, &cu);
            if (hf && hf->civ_id == plotinfo->civ_id && !i->flags.bits.in_building && !i->flags.bits.removed)
            {
                unburied = true;
                break;
            }
        }
        if (unburied)
        {
            if (auto r = ai.find_room(room_type::cemetery, [](room *c) -> bool { return c->status == room_status::plan; }))
            {
                ai.debug(out, "[RIP] a fort member lies unburied and there is no cemetery yet; digging one now");
                ai.plan.wantdig(out, r, -3);
            }
        }
    }

    for (auto u : world->units.all)
    {
        if (u->flags3.bits.ghostly)
        {
            ai.stocks.queue_slab(out, u->hist_figure_id);
        }
        else if (Units::isDead(u) && Units::isOwnGroup(u) && std::find_if(world->buildings.other[buildings_other_id::ZONE_TOMB].begin(), world->buildings.other[buildings_other_id::ZONE_TOMB].end(),
            [u](df::building *b) -> bool
            {
                // don't follow u->owned_buildings: DF leaves dangling pointers there for dead units
                auto zone = virtual_cast<df::building_civzonest>(b);
                return zone && zone->assigned_unit_id == u->id;
            }) != world->buildings.other[buildings_other_id::ZONE_TOMB].end())
        {
            want_coffin++;
        }
    }

    for (auto bld : world->buildings.other[buildings_other_id::COFFIN])
    {
        auto tomb = coffin_tomb_zone(bld);
        if (!tomb)
        {
            // A coffin outside of any tomb zone is still a free coffin as far
            // as the plan is concerned (the plan module is responsible for
            // designating the tomb zone around it).
            want_coffin--;
            continue;
        }

        if (tomb->assigned_unit_id == -1)
        {
            want_coffin--;

            // a free tomb that refuses citizens buries nobody: every free
            // tomb at Channelevened was "no citizens" (quickfort's default),
            // 127 dead lay unburied and the ghosts started killing
            if (tomb->zone_settings.tomb.flags.bits.no_citizens)
            {
                tomb->zone_settings.tomb.flags.bits.no_citizens = 0;
                ai.debug(out, "[RIP] tomb zone #" + std::to_string(tomb->id) + " takes citizens now");
            }

            if (!tomb->zone_settings.tomb.flags.bits.no_pets)
            {
                want_pet_coffin--;
            }
        }
    }

    if (want_coffin > 0)
    {
        // dont dig too early
        if (!ai.find_room(room_type::cemetery, [](room *r) -> bool { return r->status != room_status::plan; }))
        {
            want_coffin = 0;
        }

        // count actually allocated (plan wise) coffin buildings
        ai.find_room(room_type::cemetery, [&want_coffin](room *r) -> bool
        {
            for (auto f : r->layout)
            {
                if (f->type == layout_type::coffin && f->bld_id == -1 && !f->ignore)
                    want_coffin--;
            }
            return want_coffin <= 0;
        });

        for (int32_t i = 0; i < want_coffin; i++)
        {
            ai.plan.getcoffin(out);
        }
    }
    else if (want_pet_coffin > 0)
    {
        for (auto bld : world->buildings.other[buildings_other_id::COFFIN])
        {
            auto tomb = coffin_tomb_zone(bld);
            if (tomb && tomb->assigned_unit_id == -1 && tomb->zone_settings.tomb.flags.bits.no_pets)
            {
                tomb->zone_settings.tomb.flags.bits.no_pets = 0;
                ai.debug(out, "[RIP] allowing pet burials in tomb zone #" + std::to_string(tomb->id));

                // convert at most one per cycle
                break;
            }
        }
    }
}
