#include "ai.h"
#include "population.h"
#include "config.h"

#include "modules/Units.h"

#include "df/plotinfost.h"
#include "df/labor_infost.h"
#include "df/work_detail.h"
#include "df/unit.h"
#include "df/unit_labor.h"
#include "df/job_skill.h"

REQUIRE_GLOBAL(plotinfo);

// manage_labors "game" (the default): DFHack's autolabor is worse than the
// game's own labor system (user, 2026-11-14), which already has everybody do
// every job that needs no tool. The jobs that need a role and a tool
// (mining, woodcutting, hunting) are handed out by the dfai-toollabor script:
// civilians only, matched to the picks, axes and crossbows the fort has, and
// kept in the game's Miners, Woodcutters and Hunters work details.
//
// Turning autolabor off doesn't give the labors back: every dwarf keeps the
// set it last chose (at Boatsbrands half the fort could not haul stone), so
// on startup each citizen's labors are reset to what the work details say.

namespace
{
    bool assigned(df::work_detail *wd, int32_t id)
    {
        return std::find(wd->assigned_units.begin(), wd->assigned_units.end(), id) != wd->assigned_units.end();
    }
}

// a citizen's labors as the work details say: a labor in an "everybody"
// detail or in no detail at all is on, one in an "only selected" detail only
// for its members, one in a "nobody" detail off
void Population::apply_work_details(df::unit *u)
{
    if (!u || Units::isChild(u) || Units::isBaby(u))
        return;
    FOR_ENUM_ITEMS(unit_labor, l)
    {
        if (l == unit_labor::NONE)
            continue;
        bool covered = false, on = false;
        for (auto wd : plotinfo->labor_info.work_details)
        {
            if (!wd || !wd->allowed_labors[l])
                continue;
            covered = true;
            switch (wd->flags.bits.mode)
            {
            case work_detail_mode::EverybodyDoesThis:
                on = true;
                break;
            case work_detail_mode::OnlySelectedDoesThis:
                if (assigned(wd, u->id))
                    on = true;
                break;
            default:
                break;
            }
        }
        u->status.labors[l] = covered ? on : true;
    }
}

void Population::game_labors_startup(color_ostream & out)
{
    Core::getInstance().runCommand(out, "disable autolabor");
    size_t n = 0;
    for (auto id : citizen)
    {
        if (auto u = df::unit::find(id))
        {
            apply_work_details(u);
            n++;
        }
    }
    ai.debug(out, stl_sprintf("[LABOR] the game's labor system runs the fort (autolabor off); labors of %zu citizens reset to the work details", n));
}
