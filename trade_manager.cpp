#include "ai.h"
#include "population.h"
#include "stocks.h"
#include "trade.h"

#include "modules/Items.h"
#include "modules/Job.h"
#include "modules/Materials.h"
#include "modules/Units.h"

#include "df/gamest.h"
#include "df/main_interface.h"
#include "df/unit.h"
#include "df/unit_inventory_item.h"

#include "df/building_item_role_type.h"
#include "df/building_tradedepotst.h"
#include "df/buildingitemst.h"
#include "df/caravan_state.h"
#include "df/creature_raw.h"
#include "df/entity_position_assignment.h"
#include "df/general_ref.h"
#include "df/general_ref_building_holderst.h"
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

REQUIRE_GLOBAL(game);
REQUIRE_GLOBAL(plotinfo);
REQUIRE_GLOBAL(world);

static df::building_tradedepotst *find_ready_depot(AI & ai);

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

    df::building_tradedepotst *depot_bld = find_ready_depot(ai);
    df::coord broker_at = Units::getPosition(broker);
    bool at_depot = depot_bld && broker_at.z == depot_bld->z &&
        broker_at.x >= depot_bld->x1 && broker_at.x <= depot_bld->x2 &&
        broker_at.y >= depot_bld->y1 && broker_at.y <= depot_bld->y2;
    if (!at_depot)
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
        // Either the barter was applied (and the broker dismissed), or it
        // could not be done and the goods stay at the depot for the player.
        // Either way, don't try again until this caravan has left.
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
    return ai.trade.find_depot();
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

// In DF 53 the "request trader" button sets trader_requested AND puts a
// TradeAtDepot job on the depot; the broker only goes when that job exists.
// Keep the job in sync with the flag (cf. DFHack's caravan.lua, which removes it).
static bool sync_trade_job(df::building_tradedepotst *bld, bool want)
{
    df::job *existing = nullptr;
    for (auto job : bld->jobs)
    {
        if (job->job_type == job_type::TradeAtDepot)
        {
            existing = job;
            break;
        }
    }
    if (want && !existing)
    {
        if (bld->jobs.size() >= 10)
            return false;
        auto ref = df::allocate<df::general_ref_building_holderst>();
        ref->building_id = bld->id;
        auto job = df::allocate<df::job>();
        job->job_type = job_type::TradeAtDepot;
        job->pos = df::coord(bld->centerx, bld->centery, bld->z);
        job->general_refs.push_back(ref);
        bld->jobs.push_back(job);
        Job::linkIntoWorld(job);
        return true;
    }
    if (!want && existing)
    {
        Job::removeJob(existing);
        return true;
    }
    return false;
}

bool Population::set_up_trading(color_ostream & out, bool should_be_trading, bool allow_any_dwarf)
{
    df::building_tradedepotst *bld = find_ready_depot(ai);
    if (!bld)
    {
        return false;
    }
    if (bld->trade_flags.bits.trader_requested && sync_trade_job(bld, should_be_trading))
    {
        ai.debug(out, should_be_trading ? "[trade] Added missing TradeAtDepot job for the broker." : "[trade] Removed TradeAtDepot job.");
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
        sync_trade_job(bld, should_be_trading);

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

// DF v50+ has no keyboard-operable fortress trade screen: the trade_interfacest
// (game->main_interface.trade) Trade/Offer/Seize buttons are mouse-only, and
// df::interface_key has no fortress trade key (A_BARTER_TRADE belongs to the
// adventure-mode barter screen). DFHack's own confirm specs intercept those
// buttons via _MOUSE_L only. So df-ai performs the barter by applying its
// effect to the game data directly:
//
//  - goods the merchants unloaded sit in the depot's contained_items with
//    item.flags.trader set ("NOTYOURS"); buying one clears that flag (and marks
//    it foreign, "NONWEALTH" = imported). Bought items inside a merchant
//    container are taken out with Items::moveToBuilding so the merchants do
//    not pack them up again.
//  - fort goods given in exchange get flags.trader set, which is what makes
//    them the merchants' property (it is the flag DFHack's autodump clears to
//    "take back" trader goods); the merchants pack them up when they leave.
//
// The goods are chosen with the same logic as the 0.47 trade screen code
// (Stocks::want_trader_item / want_trader_item_more / willing_to_trade_item,
// prices from Trade::item_or_container_price_for_caravan), and the barter is
// only applied if our offer is worth at least TRADE_MARGIN_NUM/DEN of what we
// take, measured both with df-ai's price helper and with DFHack's
// Items::getValue(item, caravan) (the value the DFHack trade overlay shows).
// Only whole stacks change hands; merchant animals (caged units) are never
// bought or sold.

// TODO: move to config (requested option "direct_trade", default true).
#define DIRECT_TRADE_ENABLED (config.direct_trade)

// The 0.47 code offered 110% of the request first and added up to 20% more
// when the merchant refused; without haggling, always pay the upper bound.
static const int32_t TRADE_MARGIN_NUM = 6;
static const int32_t TRADE_MARGIN_DEN = 5;

static bool contains_unit(df::item *item)
{
    if (Items::getGeneralRef(item, general_ref_type::CONTAINS_UNIT))
    {
        return true;
    }
    std::vector<df::item *> contents;
    Items::getContainedItems(item, &contents);
    for (auto c : contents)
    {
        if (contains_unit(c))
        {
            return true;
        }
    }
    return false;
}

// Mirrors scripts/internal/caravan/common.lua get_perceived_value.
// Weight of an item and everything inside it (bins, barrels, bags).
static int64_t item_weight(df::item *item)
{
    // same rough measure on both sides of the deal, so only the ratio matters
    int64_t w = (int64_t(item->getBaseWeight()) * std::max(1, item->getStackSize())) >> std::max(0, item->getWeightShiftBits());
    std::vector<df::item *> contents;
    Items::getContainedItems(item, &contents);
    for (auto c : contents)
    {
        w += item_weight(c);
    }
    return w;
}

static int32_t perceived_value(df::item *item, df::caravan_state *caravan)
{
    int32_t value = Items::getValue(item, caravan);
    std::vector<df::item *> contents;
    Items::getContainedItems(item, &contents);
    for (auto c : contents)
    {
        value += perceived_value(c, caravan);
    }
    return value;
}

static void set_trader_flag_recursive(df::item *item, bool trader)
{
    item->flags.bits.trader = trader;
    if (!trader)
    {
        item->flags.bits.foreign = true;
    }
    std::vector<df::item *> contents;
    Items::getContainedItems(item, &contents);
    for (auto c : contents)
    {
        set_trader_flag_recursive(c, trader);
    }
}

static bool trader_flag_is_recursive(df::item *item, bool trader)
{
    if (bool(item->flags.bits.trader) != trader)
    {
        return false;
    }
    std::vector<df::item *> contents;
    Items::getContainedItems(item, &contents);
    for (auto c : contents)
    {
        if (!trader_flag_is_recursive(c, trader))
        {
            return false;
        }
    }
    return true;
}

static bool any_refused_or_mandated(df::historical_entity *entity, df::item *item)
{
    if (caravan_refuses_item(entity, item) || !Items::checkMandates(item))
    {
        return true;
    }
    std::vector<df::item *> contents;
    Items::getContainedItems(item, &contents);
    for (auto c : contents)
    {
        if (any_refused_or_mandated(entity, c))
        {
            return true;
        }
    }
    return false;
}

// Matches the "traders ready" test in DFHack's notify (internal/notify) and
// timestream plugins: a caravan is still unloading while any of its
// merchants carries trade goods.
static bool caravan_still_unloading(df::caravan_state *caravan)
{
    for (auto unit : world->units.active)
    {
        if (unit->civ_id != caravan->entity || !Units::isMerchant(unit))
        {
            continue;
        }
        for (auto inv : unit->inventory)
        {
            if (inv->item && inv->item->flags.bits.trader)
            {
                return true;
            }
        }
    }
    return false;
}

static bool usable_depot_item(df::item *item)
{
    auto & flags = item->flags.bits;
    // No in_building check: on DF 53 every item stored in the depot (trader goods
    // and ours) has in_building set; callers already require a TEMP depot item.
    return !(flags.in_job || flags.removed || flags.garbage_collect || flags.artifact || flags.owned || flags.on_fire) && item->specific_refs.empty();
}

class PerformTradeExclusive : public ExclusiveCallback
{
public:
    enum result_t
    {
        RETRY,
        DONE,
        FAILED,
    };

    PerformTradeExclusive(AI & ai, df::caravan_state *caravan, df::building_tradedepotst *bld) : ExclusiveCallback{ "perform trade", 2 }, ai(ai), caravan(caravan), bld(bld), result(RETRY)
    {
    }

    virtual void Run(color_ostream & out);

private:
    AI & ai;
    df::caravan_state *caravan;
    df::building_tradedepotst *bld;
    result_t result;

    struct good_t
    {
        df::item *item;
        df::item *container; // merchant container the item is in, if any
        int32_t price;
    };

    friend class Population;
};

void PerformTradeExclusive::Run(color_ostream & out)
{
    df::historical_entity *entity = df::historical_entity::find(caravan->entity);
    df::creature_raw *creature = entity ? df::creature_raw::find(entity->race) : nullptr;
    std::string from = entity ? AI::describe_name(entity->name) : std::string("an unknown civilization");

    if (game->main_interface.trade.open)
    {
        ai.debug(out, "[trade] The trade screen is open; leaving the barter to the player for now.");
        result = RETRY;
        return;
    }

    if (caravan_still_unloading(caravan))
    {
        ai.debug(out, "[trade] Waiting for the traders from " + from + " to unload.");
        result = RETRY;
        return;
    }

    if (!ai.trade.can_trade())
    {
        ai.debug(out, "[trade] Broker is not ready at the depot yet.");
        result = RETRY;
        return;
    }

    if (!DIRECT_TRADE_ENABLED)
    {
        ai.debug(out, "[trade] Automatic trading is disabled; goods are waiting at the depot for the player.");
        result = FAILED;
        return;
    }

    // Item lists, as the trade screen would build them.
    std::vector<good_t> trader_goods;
    std::vector<good_t> fort_goods;
    for (auto bi : bld->contained_items)
    {
        df::item *item = bi->item;
        if (!item || bi->use_mode != df::building_item_role_type::TEMP || !usable_depot_item(item))
        {
            continue;
        }

        if (item->flags.bits.trader)
        {
            std::vector<df::item *> contents;
            Items::getContainedItems(item, &contents);
            if (contents.empty())
            {
                trader_goods.push_back(good_t{ item, nullptr, 0 });
            }
            else
            {
                for (auto c : contents)
                {
                    if (c->flags.bits.trader && usable_depot_item(c))
                    {
                        trader_goods.push_back(good_t{ c, item, 0 });
                    }
                }
            }
        }
        else
        {
            if (item->getType() == item_type::BIN && !Items::getGeneralRef(item, general_ref_type::CONTAINS_ITEM))
            {
                continue;
            }
            if (contains_unit(item) || any_refused_or_mandated(entity, item) || !ai.stocks.willing_to_trade_item(out, item))
            {
                continue;
            }
            int32_t price = ai.trade.item_or_container_price_for_caravan(item, caravan, entity, creature, item->getStackSize(), caravan->buy_prices, caravan->sell_prices);
            if (price > 0)
            {
                fort_goods.push_back(good_t{ item, nullptr, price });
            }
        }
    }

    ai.debug(out, stl_sprintf("[trade] Scanning %zu goods offered by the traders from ", trader_goods.size()) + from + "...");

    // What do we want?
    std::vector<good_t> want;
    std::vector<df::item *> want_items;
    for (auto & g : trader_goods)
    {
        if (contains_unit(g.item))
        {
            continue;
        }
        if (ai.stocks.want_trader_item(out, g.item, want_items))
        {
            g.price = ai.trade.item_or_container_price_for_caravan(g.item, caravan, entity, creature, g.item->getStackSize(), caravan->buy_prices, caravan->sell_prices);
            want.push_back(g);
            want_items.push_back(g.item);
        }
    }
    std::stable_sort(want.begin(), want.end(), [this](const good_t & a, const good_t & b) -> bool
    {
        return ai.stocks.want_trader_item_more(a.item, b.item);
    });

    // Budget in the caravan's own valuation, the same one the final check uses.
    int64_t max_offer_value = 0;
    for (auto & g : fort_goods)
    {
        max_offer_value += perceived_value(g.item, caravan);
    }
    ai.debug(out, stl_sprintf("[trade] We have %d dorfbux (as the traders value them) of items we're willing to trade.", int32_t(max_offer_value)));

    // Choose what to request.
    std::vector<good_t> request;
    int32_t request_value = 0;
    int32_t request_pv = 0;
    for (auto & g : want)
    {
        if (g.price <= 0)
        {
            continue;
        }
        int32_t g_pv = perceived_value(g.item, caravan);
        if (((int64_t(request_pv) + g_pv) * TRADE_MARGIN_NUM + TRADE_MARGIN_DEN - 1) / TRADE_MARGIN_DEN > max_offer_value) // rounded up, as the final check is
        {
            ai.debug(out, "[trade] Cannot afford item, skipping: " + AI::describe_item(g.item));
            continue;
        }
        request_pv += g_pv;
        request_value += g.price;
        request.push_back(g);
        ai.debug(out, "[trade] Requesting item: " + AI::describe_item(g.item));
    }

    if (request.empty())
    {
        ai.debug(out, "[trade] Nothing we want and can afford from " + from + "; goods stay at the depot for the player.");
        result = FAILED;
        return;
    }

    // Choose what to offer using the caravan's own valuation (perceived_value):
    // picking by our price and only checking perceived value at the end made
    // offers fall just short (requested 1252, offered 1159) and nothing traded.
    int32_t dfhack_request = 0;
    for (auto & g : request)
    {
        dfhack_request += perceived_value(g.item, caravan);
    }
    // the wish list was picked by our prices; at the merchants' prices plus
    // their margin it can be out of reach of everything we own (Spring 133:
    // request 7386, our whole stock 8863, nothing traded). Trim the least
    // wanted requests until the deal is affordable.
    {
        int64_t total_offer = 0;
        for (auto & g : fort_goods)
        {
            int32_t pv = perceived_value(g.item, caravan);
            if (pv > 0)
                total_offer += pv;
        }
        size_t before = request.size();
        while (!request.empty() && (int64_t(dfhack_request) * TRADE_MARGIN_NUM + TRADE_MARGIN_DEN - 1) / TRADE_MARGIN_DEN > total_offer)
        {
            dfhack_request -= perceived_value(request.back().item, caravan);
            request_value -= request.back().price;
            request.pop_back();
        }
        if (request.size() != before)
            ai.debug(out, stl_sprintf("[trade] Trimmed the request by %d items to %d (they value it at %d; everything we offer is worth %d to them).", int32_t(before - request.size()), int32_t(request.size()), dfhack_request, int32_t(total_offer)));
        if (request.empty())
        {
            ai.debug(out, "[trade] Nothing we can afford at their prices from " + from + "; goods stay at the depot for the player.");
            result = FAILED;
            return;
        }
    }
    int64_t pv_target = (int64_t(dfhack_request) * TRADE_MARGIN_NUM + TRADE_MARGIN_DEN - 1) / TRADE_MARGIN_DEN;
    // Be generous (user: "just give traders extra stuff to make them happy.
    // gems are valuable and light, they love that. whatever you have a ton
    // of. the goal is for them to leave happy, not to strike a great deal").
    // Merchant profit also sets next year's trade sentiment.
    int64_t pv_minimum = pv_target;
    if (max_offer_value >= int64_t(dfhack_request) * 4)
        pv_target = int64_t(dfhack_request) * 3;
    else if (max_offer_value >= int64_t(dfhack_request) * 5 / 2)
        pv_target = int64_t(dfhack_request) * 2;
    else if (max_offer_value >= int64_t(dfhack_request) * 3 / 2)
        pv_target = std::max(pv_target, int64_t(dfhack_request) * 7 / 5);
    // ...but only what they can carry: the gifts may weigh no more than what
    // they hand over plus a margin (their animals were carrying it in).
    int64_t carry_cap = 0;
    for (auto & g : request)
        carry_cap += item_weight(g.item);
    carry_cap = carry_cap * 3 / 2 + 200;
    // how many of the same kind we hold: piles of it are the first to go
    std::map<std::pair<int32_t, int32_t>, int32_t> copies;
    for (auto & g : fort_goods)
        copies[std::make_pair(int32_t(g.item->getType()), int32_t(g.item->getMaterial()))]++;
    std::vector<std::pair<int32_t, good_t>> offer_sorted;
    for (auto & g : fort_goods)
    {
        int32_t pv = perceived_value(g.item, caravan);
        if (pv > 0)
        {
            offer_sorted.push_back(std::make_pair(pv, g));
        }
    }
    // the part that pays for the request: most valuable first, as before
    std::stable_sort(offer_sorted.begin(), offer_sorted.end(), [](const std::pair<int32_t, good_t> & x, const std::pair<int32_t, good_t> & y) -> bool { return x.first > y.first; });
    std::vector<std::pair<int32_t, good_t>> chosen;
    std::vector<std::pair<int32_t, good_t>> rest;
    int64_t dfhack_offer = 0;
    int64_t offer_weight = 0;
    for (auto & pg : offer_sorted)
    {
        if (dfhack_offer >= pv_minimum)
        {
            rest.push_back(pg);
            continue;
        }
        chosen.push_back(pg);
        dfhack_offer += pg.first;
        offer_weight += item_weight(pg.second.item);
    }
    // the extras (added to the trade, not given as gifts): value per unit of weight (cut gems first), times how much of
    // it we have lying around
    auto gift_score = [&](const std::pair<int32_t, good_t> & x) -> double
    {
        double w = double(std::max<int64_t>(1, item_weight(x.second.item)));
        double score = double(x.first) / w;
        auto t = x.second.item->getType();
        if (t == item_type::SMALLGEM || t == item_type::GEM)
            score *= 4;
        int32_t n = copies[std::make_pair(int32_t(t), int32_t(x.second.item->getMaterial()))];
        return score * std::min(4.0, 1.0 + n / 5.0);
    };
    std::stable_sort(rest.begin(), rest.end(), [&](const std::pair<int32_t, good_t> & x, const std::pair<int32_t, good_t> & y) -> bool { return gift_score(x) > gift_score(y); });
    int32_t gifts = 0;
    for (auto & pg : rest)
    {
        if (dfhack_offer >= pv_target)
            break;
        int64_t w = item_weight(pg.second.item);
        if (offer_weight + w > carry_cap)
            continue;
        chosen.push_back(pg);
        dfhack_offer += pg.first;
        offer_weight += w;
        gifts++;
    }
    if (gifts)
        ai.debug(out, stl_sprintf("[trade] Adding %d extra items to our side of the trade to keep the traders happy (offer %d for a request they value at %d).", gifts, int32_t(dfhack_offer), dfhack_request));
    if (dfhack_offer < pv_target && dfhack_offer >= pv_minimum)
    {
        pv_target = dfhack_offer; // as generous as their packs allow
    }
    // then drop items that are not needed to stay over the target
    for (auto it = chosen.end(); it != chosen.begin(); )
    {
        --it;
        if (dfhack_offer - it->first >= pv_target)
        {
            dfhack_offer -= it->first;
            it = chosen.erase(it);
        }
    }
    if (dfhack_offer < pv_target)
    {
        ai.debug(out, stl_sprintf("[trade] Could not put together an offer the traders accept (they value our request at %d, our best offer at %d). Goods stay at the depot for the player.", dfhack_request, int32_t(dfhack_offer)));
        result = FAILED;
        return;
    }
    std::vector<good_t> offer;
    int32_t offer_value = 0;
    for (auto & pg : chosen)
    {
        offer.push_back(pg.second);
        offer_value += pg.second.price;
    }

    for (auto & g : offer)
    {
        ai.debug(out, "[trade] Offering item: " + AI::describe_item(g.item));
    }
    ai.debug(out, stl_sprintf("[trade] Requested: %d Offered: %d (Items::getValue: %d / %d)", request_value, offer_value, dfhack_request, int32_t(dfhack_offer)));

    // Apply the barter. Take purchased items out of merchant containers first;
    // if that fails for an item, it is simply not bought (and the offer is
    // re-checked below).
    std::vector<df::item *> bought;
    int32_t bought_value = 0;
    for (auto & g : request)
    {
        if (g.container)
        {
            if (!Items::moveToBuilding(g.item, bld, df::building_item_role_type::TEMP) || Items::getContainer(g.item) || Items::getHolderBuilding(g.item) != bld)
            {
                ai.debug(out, "[trade] Could not take item out of the merchants' container, not buying it: " + AI::describe_item(g.item));
                continue;
            }
        }
        bought.push_back(g.item);
        bought_value += g.price;
    }

    if (bought.empty())
    {
        ai.debug(out, "[trade] Could not take any of the requested goods. Goods stay at the depot for the player.");
        result = FAILED;
        return;
    }

    // If some requested items could not be taken, give less in return.
    if (bought_value < request_value)
    {
        int32_t new_target = bought_value * TRADE_MARGIN_NUM / TRADE_MARGIN_DEN + 1;
        for (auto it = offer.end(); it != offer.begin(); )
        {
            --it;
            if (offer_value - it->price >= new_target)
            {
                offer_value -= it->price;
                it = offer.erase(it);
            }
        }
    }

    for (auto item : bought)
    {
        set_trader_flag_recursive(item, false);
    }
    for (auto & g : offer)
    {
        set_trader_flag_recursive(g.item, true);
    }

    // Verify that the goods changed sides.
    bool ok = true;
    for (auto item : bought)
    {
        if (!trader_flag_is_recursive(item, false))
        {
            ok = false;
        }
    }
    for (auto & g : offer)
    {
        if (!trader_flag_is_recursive(g.item, true))
        {
            ok = false;
        }
    }

    if (!ok)
    {
        ai.debug(out, "[trade] Barter with " + from + " did not apply cleanly; please check the depot.");
        result = FAILED;
        return;
    }

    for (auto item : bought)
    {
        ai.debug(out, "[trade] Bought item: " + AI::describe_item(item));
    }
    ai.debug(out, stl_sprintf("[trade] Traded %zu stacks worth %d dorfbux for %zu stacks worth %d dorfbux with ", offer.size(), offer_value, bought.size(), bought_value) + from + ".");
    result = DONE;
}

bool Population::perform_trade(color_ostream & out)
{
    df::building_tradedepotst *bld = find_ready_depot(ai);
    if (!bld)
    {
        return false;
    }

    df::caravan_state *caravan = nullptr;
    size_t at_depot = 0;
    for (auto c : plotinfo->caravans)
    {
        if (c->trade_state == df::caravan_state::AtDepot && c->time_remaining > 0)
        {
            at_depot++;
            if (!caravan)
            {
                caravan = c;
            }
        }
    }

    if (!caravan)
    {
        return false;
    }

    // Items carry no link to the caravan that owns them, so with two caravans
    // at the depot we cannot tell whose goods are whose.
    if (at_depot > 1)
    {
        ai.debug(out, "[trade] More than one caravan is at the depot; leaving the trade to the player.");
        return true;
    }

    if (caravan->flags.bits.tribute || caravan->flags.bits.offended || caravan->flags.bits.greatly_offended || caravan->flags.bits.seized)
    {
        ai.debug(out, "[trade] This caravan will not trade; leaving any goods at the depot.");
        return true;
    }

    // Runs synchronously; there is no trade screen to wait for.
    PerformTradeExclusive trade(ai, caravan, bld);
    trade.Run(out);

    switch (trade.result)
    {
    case PerformTradeExclusive::RETRY:
        return false;
    case PerformTradeExclusive::FAILED:
        // Logged once by Run; the goods and the broker stay at the depot for
        // the player until the caravan leaves.
        return true;
    case PerformTradeExclusive::DONE:
        if (set_up_trading(out, false))
        {
            ai.debug(out, "[trade] Dismissed broker from depot: finished trade");
        }
        return true;
    }

    return true;
}
