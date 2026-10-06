#include "slicer_bridge.h"

#include <spdlog/spdlog.h>

#include <string>
#include <vector>

#include "Application.h"

namespace curaharmony
{

int runSlice(const SliceRequest &request)
{
    // CuraEngine is invoked exactly like its command line front-end:
    //   CuraEngine slice -j <settings.json> -l <model> [-l <model> ...] -o <output.gcode>
    // The argv strings must stay alive for the whole call because Application keeps a pointer to them.
    std::vector<std::string> arguments;
    arguments.reserve(4 + 2 * request.model_paths.size());
    arguments.emplace_back("CuraEngine");
    arguments.emplace_back("slice");
    arguments.emplace_back("-j");
    arguments.push_back(request.settings_json_path);
    for (const std::string &model_path : request.model_paths)
    {
        arguments.emplace_back("-l");
        arguments.push_back(model_path);
    }
    arguments.emplace_back("-o");
    arguments.push_back(request.output_gcode_path);

    std::vector<char *> argv;
    argv.reserve(arguments.size() + 1);
    for (std::string &argument : arguments)
    {
        argv.push_back(argument.data());
    }
    argv.push_back(nullptr);

    spdlog::info("CuraHarmony: slicing {} model(s)", request.model_paths.size());
    cura::Application::getInstance().run(arguments.size(), argv.data());
    spdlog::info("CuraHarmony: slice finished");
    return 0;
}

} // namespace curaharmony
