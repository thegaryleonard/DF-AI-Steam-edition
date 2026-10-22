#include "ai.h"
#include "stocks.h"
#include "event_manager.h"

#include <algorithm>

#include "modules/Materials.h"

#include "df/itemdef_ammost.h"
#include "df/itemdef_toolst.h"
#include "df/itemdef_trapcompst.h"
#include "df/itemdef_weaponst.h"
#include "df/manager_order.h"
#include "df/manager_order_template.h"
#include "df/tool_uses.h"
#include "df/workquota_frequency_type.h"
#include "df/world.h"

REQUIRE_GLOBAL(world);

// return the number of current manager orders that share the same material (leather, cloth)
// ignore inorganics, ignore order
int32_t Stocks::count_manager_orders_matcat(const df::job_material_category & matcat, df::job_type order)
{
    int32_t cnt = 0;
    for (auto mo : world->manager_orders.all)
    {
        if (mo->material_category.whole == matcat.whole && mo->job_type != order)
        {
            cnt += mo->amount_left;
        }
    }
    events.each_exclusive<ManagerOrderExclusive>([&cnt, matcat, order](const ManagerOrderExclusive *excl) -> bool
    {
        if (excl->tmpl.material_category.whole == matcat.whole && excl->tmpl.job_type != order)
        {
            cnt += excl->amount;
        }

        return false;
    });

    return cnt;
}

template<typename T>
static bool template_equals(const T *a, const df::manager_order_template *b)
{
    if (a->job_type != b->job_type)
        return false;
    if (a->reaction_name != b->reaction_name)
        return false;
    if (a->item_type != b->item_type)
        return false;
    if (a->item_subtype != b->item_subtype)
        return false;
    if (a->mat_type != b->mat_type)
        return false;
    if (a->mat_index != b->mat_index)
        return false;
    if (a->specflag.whole != b->specflag.whole)
        return false;
    if (a->specdata.hist_figure_id != b->specdata.hist_figure_id)
        return false;
    if (a->material_category.whole != b->material_category.whole)
        return false;
    return true;
}

int32_t Stocks::count_manager_orders(color_ostream &, const df::manager_order_template & tmpl)
{
    int32_t amount = 0;

    for (auto mo : world->manager_orders.all)
    {
        if (template_equals(mo, &tmpl))
        {
            amount += mo->amount_left;
        }
    }
    events.each_exclusive<ManagerOrderExclusive>([&amount, tmpl](const ManagerOrderExclusive *excl) -> bool
    {
        if (template_equals(&excl->tmpl, &tmpl))
        {
            amount += excl->amount;
        }

        return false;
    });

    return amount;
}

// Create a manager order directly (DF v50+ no longer has the keyboard-driven
// job manager screens). If an identical order exists that has not been
// started yet, its quantity is increased instead of adding a duplicate.
static void create_manager_order(AI & ai, color_ostream & out, const df::manager_order_template & tmpl, int32_t amount)
{
    if (amount <= 0)
    {
        return;
    }

    const int32_t max_amount = 9999;

    for (auto mo : world->manager_orders.all)
    {
        if (template_equals(mo, &tmpl) && mo->amount_left == mo->amount_total && mo->frequency == workquota_frequency_type::OneTime && mo->amount_total < max_amount)
        {
            int32_t total = std::min(int32_t(mo->amount_total) + amount, max_amount);
            mo->amount_left = int16_t(total);
            mo->amount_total = int16_t(total);
            ai.debug(out, stl_sprintf("add_manager_order(%d) %s (merged into order #%d)", amount, AI::describe_job(&tmpl).c_str(), mo->id));
            return;
        }
    }

    auto order = new df::manager_order();
    order->id = world->manager_orders.manager_order_next_id++;
    order->job_type = tmpl.job_type;
    order->reaction_name = tmpl.reaction_name;
    order->item_type = tmpl.item_type;
    order->item_subtype = tmpl.item_subtype;
    order->mat_type = tmpl.mat_type;
    order->mat_index = tmpl.mat_index;
    order->specflag = tmpl.specflag;
    order->specdata = tmpl.specdata;
    order->material_category = tmpl.material_category;
    order->art_spec.type = tmpl.art_specifier;
    order->art_spec.id = tmpl.art_specifier_id1;
    order->art_spec.subid = tmpl.art_specifier_id2;
    int16_t qty = int16_t(std::min(amount, max_amount));
    order->amount_left = qty;
    order->amount_total = qty;
    order->frequency = workquota_frequency_type::OneTime;
    world->manager_orders.all.push_back(order);

    ai.debug(out, stl_sprintf("add_manager_order(%d) %s (order #%d)", int32_t(qty), AI::describe_job(&tmpl).c_str(), order->id));
}

ManagerOrderExclusive::ManagerOrderExclusive(AI & ai, const df::manager_order_template & tmpl, int32_t amount)
    : ExclusiveCallback{ "add_manager_order: " + AI::describe_job(&tmpl) },
    ai(ai),
    tmpl(tmpl),
    amount(amount),
    search_word()
{
}

void ManagerOrderExclusive::Run(color_ostream & out)
{
    create_manager_order(ai, out, tmpl, amount);
}

void Stocks::add_manager_order(color_ostream & out, const df::manager_order_template & tmpl, int32_t amount)
{
    std::ofstream discard;
    add_manager_order(out, tmpl, amount, discard);
}

void Stocks::add_manager_order(color_ostream & out, const df::manager_order_template & tmpl, int32_t amount, std::ostream & reason)
{
    if (amount <= 0)
    {
        return;
    }

    int32_t already_queued = count_manager_orders(out, tmpl);
    amount -= already_queued;

    if (already_queued && amount < 5)
    {
        amount = 0;
    }

    if (amount <= 0)
    {
        reason << "already have manager order: " << AI::describe_job(&tmpl) << " (" << already_queued << " remaining)";
        return;
    }

    reason << "queued manager order (" << amount << "): " << AI::describe_job(&tmpl);
    create_manager_order(ai, out, tmpl, amount);
}
