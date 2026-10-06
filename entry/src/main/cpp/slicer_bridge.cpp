#include "slicer_bridge.h"

#include <csetjmp>
#include <cstdlib>
#include <string>
#include <vector>

#include <spdlog/spdlog.h>

#include "Application.h"

namespace curaharmony
{
namespace
{

// CuraEngine signals fatal situations (malformed arguments, missing settings, ...) by calling
// std::exit(). Inside a HarmonyOS application that would tear down the whole process, so the bridge
// interposes exit() and unwinds back into runSlice() instead. The slice then fails gracefully and the
// UI can report an error. The jump buffer is thread local because slicing runs on a worker thread.
thread_local std::jmp_buf g_abort_jump;
thread_local bool g_abort_armed = false;

} // namespace
} // namespace curaharmony

// Interposed exit(). The CMake target links the library with -Bsymbolic-functions so that references
// made from within libcuraslicer.so (including CuraEngine) bind to this definition, while the rest of
// the process keeps using the C library's exit().
extern "C" void exit(int status)
{
    if (curaharmony::g_abort_armed)
    {
        curaharmony::g_abort_armed = false;
        std::longjmp(curaharmony::g_abort_jump, status == 0 ? 1 : status);
    }
    _Exit(status);
}

namespace curaharmony
{

int runSlice(const SliceRequest &request)
{
    const int abort_status = setjmp(g_abort_jump);
    if (abort_status != 0)
    {
        g_abort_armed = false;
        spdlog::error("CuraHarmony: CuraEngine aborted the slice (status {})", abort_status);
        return abort_status;
    }

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
    g_abort_armed = true;
    cura::Application::getInstance().run(arguments.size(), argv.data());
    g_abort_armed = false;
    spdlog::info("CuraHarmony: slice finished");
    return 0;
}

} // namespace curaharmony
