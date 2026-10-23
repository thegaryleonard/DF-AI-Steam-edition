#include "blueprint.h"

#include "modules/Filesystem.h"

template<typename T>
static T *load_json(const std::string & filename, const std::string & type, const std::string & name, std::string & error)
{
    error.clear();
    std::ifstream f(filename);
    Json::Value val;
    Json::CharReaderBuilder b;
    if (Json::parseFromStream(b, f, &val, &error))
    {
        if (f.good())
        {
            if (val.isObject())
            {
                T *t = new T(type, name);
                if (t->apply(val, error))
                {
                    return t;
                }
                delete t;
            }
            else
            {
                error = "must be a JSON object";
            }
        }
        else
        {
            error = "error reading file";
        }
    }
    error = filename + ": " + error;
    return nullptr;
}

template<typename T>
void load_objects(color_ostream & out, const std::string & subtype, std::function<void(const std::string & type, const std::string & name, T *t)> store)
{
    std::string error;
    std::vector<std::filesystem::path> type_paths;
    if (!Filesystem::listdir("df-ai-blueprints/rooms/" + subtype, type_paths))
    {
        for (auto & type_path : type_paths)
        {
            std::string type = type_path.filename().string();
            if (type.find('.') != std::string::npos)
            {
                continue;
            }

            std::vector<std::filesystem::path> name_paths;
            if (!Filesystem::listdir("df-ai-blueprints/rooms/" + subtype + "/" + type, name_paths))
            {
                for (auto & name_path : name_paths)
                {
                    std::string name = name_path.filename().string();
                    auto ext = name.rfind(".json");
                    if (ext == std::string::npos || ext != name.size() - strlen(".json"))
                    {
                        continue;
                    }

                    std::string path = "df-ai-blueprints/rooms/" + subtype + "/" + type + "/" + name;
                    std::string base_name = name.substr(0, ext);

                    if (auto t = load_json<T>(path, type, base_name, error))
                    {
                        store(type, base_name, t);
                    }
                    else
                    {
                        out.printerr("{}\n", error.c_str());
                    }
                }
            }
        }
    }
}

blueprints_t::blueprints_t(color_ostream & out) : is_valid(true)
{
    if (!Filesystem::isdir("df-ai-blueprints"))
    {
        is_valid = false;
        out.printerr("The df-ai-blueprints folder is missing! It ships in the df-ai zip next to the hack folder.\n");
        out.printerr("The df-ai-blueprints folder should be inside {}.\n", Filesystem::getcwd().string());
        return;
    }

    std::map<std::string, std::pair<std::vector<std::pair<std::string, room_template *>>, std::vector<std::pair<std::string, room_instance *>>>> rooms;

    load_objects<room_template>(out, "templates", [&rooms](const std::string & type, const std::string & name, room_template *tmpl)
    {
        rooms[type].first.push_back(std::make_pair(name, tmpl));
    });
    load_objects<room_instance>(out, "instances", [&rooms](const std::string & type, const std::string & name, room_instance *inst)
    {
        rooms[type].second.push_back(std::make_pair(name, inst));
    });

    std::string error;
    for (auto & type : rooms)
    {
        auto & rbs = blueprints[type.first];
        rbs.reserve(type.second.first.size() * type.second.second.size());
        if (type.second.first.empty())
        {
            is_valid = false;
            out.printerr("{}: no templates\n", type.first.c_str());
        }
        if (type.second.second.empty())
        {
            is_valid = false;
            out.printerr("{}: no instances\n", type.first.c_str());
        }
        for (auto tmpl : type.second.first)
        {
            for (auto inst : type.second.second)
            {
                if (inst.second->blacklist.count(tmpl.first))
                {
                    continue;
                }

                room_blueprint *rb = new room_blueprint(tmpl.second, inst.second);
                if (!rb->apply(error))
                {
                    is_valid = false;
                    out.printerr("{} + {}: {}\n", tmpl.first.c_str(), inst.first.c_str(), error.c_str());
                    delete rb;
                    continue;
                }
                if (rb->warn(error))
                {
                    is_valid = false;
                    out.printerr("{} + {}: {}\n", tmpl.first.c_str(), inst.first.c_str(), error.c_str());
                }
                rbs.push_back(rb);
            }
            delete tmpl.second;
        }
        for (auto inst : type.second.second)
        {
            delete inst.second;
        }
    }

    std::vector<std::filesystem::path> name_paths;
    if (!Filesystem::listdir("df-ai-blueprints/plans", name_paths))
    {
        for (auto & name_path : name_paths)
        {
            std::string name = name_path.filename().string();
            auto ext = name.rfind(".json");
            if (ext == std::string::npos || ext != name.size() - strlen(".json"))
            {
                continue;
            }

            std::string path = "df-ai-blueprints/plans/" + name;

            if (auto plan = load_json<blueprint_plan_template>(path, "plan", name.substr(0, ext), error))
            {
                plans[name.substr(0, ext)] = plan;
            }
            else
            {
                is_valid = false;
                out.printerr("{}\n", error.c_str());
            }
        }
    }
}

blueprints_t::~blueprints_t()
{
    for (auto & type : blueprints)
    {
        for (auto rb : type.second)
        {
            delete rb;
        }
    }

    for (auto & plan : plans)
    {
        delete plan.second;
    }
}

void blueprints_t::write_rooms(std::ostream & f)
{
    for (auto & type : blueprints)
    {
        for (auto rb : type.second)
        {
            f << rb->type << " / " << rb->tmpl_name << " / " << rb->name << std::endl;
            rb->write_layout(f);
            f << std::endl;
        }
    }
}
