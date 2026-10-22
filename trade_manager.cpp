#include "ai.h"
#include "population.h"
#include "stocks.h"
#include "trade.h"

#include "modules/Items.h"
#include "modules/Materials.h"
#include "modules/Units.h"

#include "df/building_item_role_type.h"
#include "df/building_tradedepotst.h"
#include "df/buildingitemst.h"
#include "df/caravan_state.h"
#include "df/creature_raw.h"
#include "df/entity_position_assignment.h"
#include "df/general_ref.h"
#include "df/entity_raw.h"
#include "df/ethic_response.h"
#include "df/ethic_type.h"
#include "df/historical_entity.h"
#include "df/historical_figure.h"
#include "df/item.h"
#include "df/job.h"
#include "df/plotinfost.h"
#include "df/items_other_id.h"
#include "df/material.h"
#include "df/world.h"

REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

void Population::update_trading(color_ostream & out)
{
    bool any_traders = ai.trade.can_move_goods();

    if (any_traders && did_trade)
    {
        return;
    }

    if (!any_traders)
    {
        did_trade = false;
    }

    if (set_up_trading(out, any_traders))
    {
        if (any_traders)
        {
            ai.debug(out, "[trade] Requested broker at depot.");
        }
        else
        {
            ai.debug(out, "[trade] Dismissed broker from depot: no traders");
        }
        return;
    }

    if (!any_traders)
    {
        return;
    }

    df::caravan_state *caravan = nullptr;
    for (auto it = plotinfo->caravans.begin(); it != plotinfo->caravans.end(); it++)
    {
        if ((*it)->trade_state == df::caravan_state::AtDepot)
        {
            caravan = *it;
        }
        else if ((*it)->trade_state == df::caravan_state::Approaching)
        {
            ai.debug(out, "[trade] Waiting for the traders from " + AI::describe_name(df::historical_entity::find((*it)->entity)->name) + " to arrive at the depot...");
        }
    }

    if (!caravan)
    {
        return;
    }

    auto broker_pos = std::find_if(plotinfo->main.fortress_entity->positions.own.begin(), plotinfo->main.fortress_entity->positions.own.end(), [](df::entity_position *pos) -> bool { return pos->responsibilities[entity_position_responsibility::TRADE]; });
    if (broker_pos == plotinfo->main.fortress_entity->positions.own.end())
    {
        ai.debug(out, "[trade] Could not find broker position!");
        return;
    }

    auto broker_assignment = std::find_if(plotinfo->main.fortress_entity->positions.assignments.begin(), plotinfo->main.fortress_entity->positions.assignments.end(), [broker_pos](df::entity_position_assignment *asn) -> bool { return asn->position_id == (*broker_pos)->id; });
    if (broker_assignment == plotinfo->main.fortress_entity->positions.assignments.end())
    {
        ai.debug(out, "[trade] Could not find broker assignment!");
        return;
    }

    df::unit *broker = nullptr;

    for (auto j = world->jobs.list.next; j; j = j->next)
    {
        if (j->item->job_type == job_type::TradeAtDepot)
        {
            for (auto ref : j->item->general_refs)
            {
                if (ref->getType() == general_ref_type::UNIT_WORKER)
                {
                    broker = ref->getUnit();
                    if (broker)
                    {
                        break;
                    }
                }
            }
            if (broker)
            {
                break;
            }
        }
    }

    if (!broker)
    {
        df::historical_figure *broker_hf = df::historical_figure::find((*broker_assignment)->histfig);
        if (!broker_hf)
        {
            ai.debug(out, "[trade] Could not find broker!");
            return;
        }

        broker = df::unit::find(broker_hf->unit_id);
        if (!broker)
        {
            ai.debug(out, "[trade] Could not find broker unit!");
            return;
        }

        if (!broker->job.current_job || broker->job.current_job->job_type != job_type::TradeAtDepot)
        {
            ai.debug(out, "[trade] Waiting for the broker to do " + std::string(ENUM_ATTR(pronoun_type, posessive, broker->sex)) + " job: " + AI::describe_unit(broker) + " (currently: " + AI::describe_job(broker) + ") " + AI::describe_room(ai.find_room_at(Units::getPosition(broker))));
            if (caravan->time_remaining < 1000 && set_up_trading(out, true, true))
            {
                ai.debug(out, "[trade] Broker took too long. Allowing any dwarf to trade this season.");
            }
            return;
        }
    }

    room *depot = ai.find_room(room_type::tradedepot, [broker](room *r) -> bool { return r->include(Units::getPosition(broker)); });
    if (!depot)
    {
        ai.debug(out, "[trade] Broker en route to depot: " + AI::describe_unit(broker) + " (Currently at " + AI::describe_room(ai.find_room_at(Units::getPosition(broker))) + ")");
        return;
    }

    int32_t waiting_for_items = 0;
    for (auto j = world->jobs.list.next; j; j = j->next)
    {
        if (j->item->job_type == job_type::BringItemToDepot)
        {
            waiting_for_items++;
        }
    }

    if (waiting_for_items)
    {
        if (caravan->time_remaining < 1000)
        {
            ai.debug(out, stl_sprintf("[trade] Waiting for %d more items to arrive at the depot, but time is running out. Trading with what we have.", waiting_for_items));
        }
        else
        {
            ai.debug(out, stl_sprintf("[trade] Waiting for %d more items to arrive at the depot.", waiting_for_items));
            return;
        }
    }

    if (perform_trade(out))
    {
        // In v50+ the barter must be finished by the player, so the broker
        // stays requested at the depot until the caravan leaves (at which
        // point !any_traders dismisses them above).
        did_trade = true;
    }
}

// DF v50+ removed the keyboard-driven depot screens (viewscreen_dwarfmodest
// building job menu, viewscreen_layer_assigntradest, viewscreen_tradelistst),
// so the trader request and the "bring goods" list are now handled by
// writing the depot flags directly and creating BringItemToDepot jobs through
// Items::markForTrade, the same way DFHack's caravan/movegoods tool does.
static df::building_tradedepotst *find_ready_depot(AI & ai)
{
    room *r = ai.find_room(room_type::tradedepot);
    if (!r)
    {
        return nullptr;
    }
    df::building_tradedepotst *bld = virtual_cast<df::building_tradedepotst>(r->dfbuilding());
    if (!bld || bld->getBuildStage() < bld->getMaxBuildStage())
    {
        return nullptr;
    }
    for (auto job : bld->jobs)
    {
        if (job->job_type == job_type::DestroyBuilding)
        {
            return nullptr;
        }
    }
    return bld;
}

static bool is_tradeable_candidate(df::item *item)
{
    if (!item)
    {
        return false;
    }

    auto & flags = item->flags.bits;
    if (flags.hostile || flags.removed || flags.dead_dwarf || flags.spider_web ||
        flags.construction || flags.encased || flags.murder || flags.trader ||
        flags.owned || flags.garbage_collect || flags.on_fire || flags.forbid ||
        flags.in_job || flags.in_building || flags.in_inventory || flags.artifact)
    {
        return false;
    }

    // Rejects items held by units or buildings, assigned to jobs, or banned
    // by export mandates (including the contents of containers).
    return Items::canTradeWithContents(item);
}

static size_t mark_goods_for_trade(color_ostream & out, AI & ai, df::building_tradedepotst *bld)
{
    size_t checked = 0;
    size_t marked = 0;

    for (auto item : world->items.other[items_other_id::IN_PLAY])
    {
        if (!is_tradeable_candidate(item))
        {
            continue;
        }

        checked++;

        if (!ai.stocks.willing_to_trade_item(out, item))
        {
            continue;
        }

        if (Items::markForTrade(item, bld))
        {
            marked++;
            ai.debug(out, "[trade] Bringing item to trade depot: " + AI::describe_item(item));
        }
        else
        {
            ai.debug(out, "[trade] Failed to mark item for trade: " + AI::describe_item(item));
        }
    }

    ai.debug(out, stl_sprintf("[trade] Checked %zu possible trade items, marked %zu for the depot.", checked, marked));

    return marked;
}

bool Population::set_up_trading(color_ostream & out, bool should_be_trading, bool allow_any_dwarf)
{
    df::building_tradedepotst *bld = find_ready_depot(ai);
    if (!bld)
    {
        return false;
    }
    bool toggle_restrict = (should_be_trading && allow_any_dwarf && bld->trade_flags.bits.trader_requested && !bld->trade_flags.bits.anyone_can_trade) || (!should_be_trading && bld->trade_flags.bits.anyone_can_trade);
    if (bool(bld->trade_flags.bits.trader_requested) == should_be_trading && !toggle_restrict)
    {
        return false;
    }

    if (toggle_restrict)
    {
        bld->trade_flags.bits.anyone_can_trade = !bld->trade_flags.bits.anyone_can_trade;
    }

    if (bool(bld->trade_flags.bits.trader_requested) != should_be_trading)
    {
        bld->trade_flags.bits.trader_requested = should_be_trading;

        if (should_be_trading)
        {
            if (!bld->accessible)
            {
                ai.debug(out, "[trade] Warning: the trade depot is not marked as wagon-accessible.");
            }
            mark_goods_for_trade(out, ai, bld);
        }
    }

    return true;
}

static bool represents_plant_murder(df::item *item)
{
    // TODO: other items, like soap and certain types of glass, and decorations and containers
    df::material *mat = MaterialInfo(item).material;
    return mat && mat->flags.is_set(material_flags::WOOD);
}

static bool caravan_refuses_item(df::historical_entity *entity, df::item *item)
{
    if (!entity || !entity->entity_raw)
    {
        return false;
    }

    auto plant = entity->entity_raw->ethic[ethic_type::KILL_PLANT];
    if (plant >= ethic_response::MISGUIDED && plant <= ethic_response::UNTHINKABLE && represents_plant_murder(item))
    {
        return true;
    }

    auto animal = entity->entity_raw->ethic[ethic_type::KILL_ANIMAL];
    if (animal >= ethic_response::MISGUIDED && animal <= ethic_response::UNTHINKABLE && item->isAnimalProduct())
    {
        return true;
    }

    return false;
}

// The barter itself happens in the v50 trade interface (trade_interfacest),
// which is mouse-driven and cannot currently be operated by df-ai. This
// callback reports what the AI would have offered so that a human can finish
// the trade, and otherwise does nothing.
class PerformTradeExclusive : public ExclusiveCallback
{
public:
    PerformTradeExclusive(AI & ai, df::caravan_state *caravan) : ExclusiveCallback{ "perform trade", 2 }, ai(ai), caravan(caravan)
    {
    }

    virtual void Run(color_ostream & out);

private:
    AI & ai;
    df::caravan_state *caravan;

    friend class Population;
};

void PerformTradeExclusive::Run(color_ostream & out)
{
    ai.debug(out, "[v50] trading with caravans must be done manually for now; goods have been moved to the depot");

    df::building_tradedepotst *bld = find_ready_depot(ai);
    if (!bld || !caravan)
    {
        return;
    }

    df::historical_entity *entity = df::historical_entity::find(caravan->entity);
    df::creature_raw *creature = entity ? df::creature_raw::find(entity->race) : nullptr;

    int32_t offer_value = 0;
    size_t offer_count = 0;
    for (auto bi : bld->contained_items)
    {
        df::item *item = bi->item;
        if (!item || bi->use_mode != df::building_item_role_type::TEMP)
        {
            continue;
        }
        if (caravan_refuses_item(entity, item))
        {
            continue;
        }
        offer_value += ai.trade.item_or_container_price_for_caravan(item, caravan, entity, creature, item->getStackSize(), caravan->buy_prices, caravan->sell_prices);
        offer_count++;
    }

    ai.debug(out, stl_sprintf("[trade] %zu item stacks worth about %d dorfbux are waiting at the depot for the traders from ", offer_count, offer_value) + (entity ? AI::describe_name(entity->name) : std::string("an unknown civilization")) + ".");
}

bool Population::perform_trade(color_ostream & out)
{
    df::building_tradedepotst *bld = find_ready_depot(ai);
    if (!bld)
    {
        return false;
    }

    df::caravan_state *caravan = nullptr;
    for (auto c : plotinfo->caravans)
    {
        if (c->trade_state == df::caravan_state::AtDepot && c->time_remaining > 0)
        {
            caravan = c;
            break;
        }
    }

    if (!caravan)
    {
        return false;
    }

    // Runs synchronously; there is no trade screen to wait for.
    PerformTradeExclusive(ai, caravan).Run(out);

    return true;
}
