#include "ai.h"
#include "camera.h"
#include "plan.h"
#include "population.h"

#include "modules/Gui.h"
#include "modules/Job.h"
#include "modules/Translation.h"
#include "modules/Units.h"

#include "df/activity_entry.h"
#include "df/activity_event.h"
#include "df/activity_event_participants.h"
#include "df/history_event.h"
#include "df/history_event_context.h"
#include "df/interface_button_building_new_jobst.h"
#include "df/item.h"
#include "df/job.h"
#include "df/manager_order.h"
#include "df/manager_order_template.h"
#include "df/report.h"
#include "df/world.h"

REQUIRE_GLOBAL(cur_year);
REQUIRE_GLOBAL(cur_year_tick);
REQUIRE_GLOBAL(world);

static void replace_all(std::string & str, const std::string & from, const std::string & to)
{
    size_t pos = 0;
    while ((pos = str.find(from, pos)) != std::string::npos)
    {
        str.replace(pos, from.length(), to);
        pos += to.length();
    }
}

std::string html_escape(const std::string & str)
{
    std::string escaped(str);
    replace_all(escaped, "&", "&amp;");
    replace_all(escaped, "<", "&lt;");
    replace_all(escaped, ">", "&gt;");
    replace_all(escaped, "\n", "<br/>");
    return DF2UTF(escaped);
}

std::string AI::timestamp(int32_t y, int32_t t)
{
    if (y == 0 && t == 0)
    {
        // split up to avoid trigraphs
        return "?????" "-" "??" "-" "??" ":" "????";
    }
    if (t == -1)
    {
        // split up to avoid trigraphs
        return stl_sprintf("%05d-" "??" "-" "??" ":" "????", y);
    }
    return stl_sprintf("%05d-%02d-%02d:%04d",
        y,                    // year
        t / 50 / 24 / 28 + 1, // month
        t / 50 / 24 % 28 + 1, // day
        t % (24 * 50));       // time
}

std::string AI::timestamp()
{
    return timestamp(*cur_year, *cur_year_tick);
}

std::string AI::describe_item(df::item *i)
{
    if (!i)
    {
        return "(unknown item)";
    }

    std::string s;
    i->getItemDescription(&s, 0);
    return s;
}

std::string AI::describe_name(const df::language_name & name, bool in_english, bool only_last_part)
{
    std::string s = Translation::translateName(&name, in_english, only_last_part);
    return Translation::capitalize(s);
}

std::string AI::describe_unit(df::unit *u, bool html)
{
    // Unknown Unit
    if (!u)
    {
        if (html)
        {
            return "<i>(unknown unit)</i>";
        }
        return "(unknown unit)";
    }

    // Name, curse name, and profession
    std::string s = Units::getReadableName(u);
    if (html)
    {
        s = html_escape(s);
        if (u->hist_figure_id != -1)
        {
            s = stl_sprintf("<a href=\"fig-%d\">", u->hist_figure_id) + s + "</a>";
        }
    }
    return s;
}

std::string AI::describe_job(const df::job *job)
{
    if (!job)
    {
        return "(unknown job)";
    }
    return Job::getName(const_cast<df::job *>(job));
}

std::string AI::describe_job(const df::manager_order *job)
{
    if (!job)
    {
        return "(unknown job)";
    }
    return Job::getManagerOrderName(const_cast<df::manager_order *>(job));
}

std::string AI::describe_job(const df::manager_order_template *job)
{
    if (!job)
    {
        return "(unknown job)";
    }

    std::string desc;
    auto button = df::allocate<df::interface_button_building_new_jobst>();
    button->mstring = job->reaction_name;
    button->jobtype = job->job_type;
    button->itemtype = job->item_type;
    button->subtype = job->item_subtype;
    button->material = job->mat_type;
    button->matgloss = job->mat_index;
    button->specflag = job->specflag;
    button->job_item_flag = job->material_category;
    button->specdata = job->specdata;
    button->text(&desc);
    delete button;
    return desc;
}

std::string AI::describe_job(const df::unit *u)
{
    if (u->job.current_job != nullptr)
    {
        return describe_job(u->job.current_job);
    }

    std::string s;
    for (auto act : world->activities.all)
    {
        for (auto e : act->events)
        {
            if (auto p = e->getParticipantInfo())
            {
                if (std::find(p->units.begin(), p->units.end(), u->id) != p->units.end())
                {
                    std::string name;
                    e->getName(u->id, &name);
                    if (!s.empty())
                    {
                        s += " / ";
                    }
                    s += name;
                }
            }
        }
    }
    return s;
}

std::string AI::describe_event(df::history_event *event)
{
    if (!event)
    {
        return "(unknown event)";
    }

    df::history_event_context context;
    std::string str;
    event->getSentence(&str, &context, true, false);
    return str;
}

void AI::write_df(std::ostream & out, const std::string & str, const std::string & newline, const std::string & suffix, std::function<std::string(const std::string &)> translate)
{
    size_t pos = 0;
    for (;;)
    {
        size_t end = str.find('\n', pos);
        if (end == std::string::npos)
        {
            out << translate(str.substr(pos)) << suffix;
            break;
        }
        out << translate(str.substr(pos, end - pos)) << newline;
        pos = end + 1;
    }
    out.flush();
}

void AI::debug(color_ostream & out, const std::string & str)
{
    std::string ts = timestamp();

    if (config.write_console)
    {
        write_df(out, "AI: " + ts + " " + str, "\n", "\n", [](const std::string & in) -> std::string { return DF2CONSOLE(in); });
    }
    if (config.write_log)
    {
        write_df(logger, ts + " " + str, "\n                 ");
    }
}

void AI::event(const std::string & name, const Json::Value & payload)
{
    if (!eventsJson.is_open())
    {
        return;
    }

    Json::Value wrapper(Json::objectValue);
    wrapper["unix"] = Json::LargestInt(time(nullptr));
    wrapper["year"] = Json::Int(*cur_year);
    wrapper["tick"] = Json::Int(*cur_year_tick);
    wrapper["name"] = name;
    wrapper["payload"] = payload;
    eventsJson << wrapper << std::endl;
}

std::string AI::status()
{
    if (is_embarking())
    {
        return "(embarking)";
    }

    std::ostringstream str;
    str << "Plan: " << plan.status() << "\n";
    str << "Pop: " << pop.status() << "\n";
    str << "Stocks: " << stocks.status() << "\n";
    str << "Camera: " << camera.status() << "\n";
    str << "Event: " << events.status();
    return str.str();
}

template<typename M>
static void report_section(std::ostringstream & out, const std::string & name, M & module, bool html)
{
    if (html)
    {
        out << "<h1 id=\"" << html_escape(name) << "\">" << html_escape(name) << "</h1>";
    }
    else
    {
        out << "# " << name << "\n";
    }
    module.report(out, html);
    if (!html)
    {
        out << "\n";
    }
}

std::string AI::report(bool html)
{
    if (is_embarking())
    {
        if (html)
        {
            return "<i>Report is not available during embark.</i>";
        }
        return "";
    }

    std::ostringstream str;
    report_section(str, "Plan", plan, html);
    report_section(str, "Population", pop, html);
    report_section(str, "Stocks", stocks, html);
    report_section(str, "Events", events, html);
    return str.str();
}

void AI::watch_announcements()
{
    // Previously mirrored announcements into the lockstep overlay, which no
    // longer exists. Kept as a hook for future use.
    if (!world->status.announcements.empty())
    {
        last_announcement_id = world->status.announcements.back()->id;
    }
}
