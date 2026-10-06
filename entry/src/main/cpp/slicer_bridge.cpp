#include "slicer_bridge.h"

#include <csetjmp>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

#include <spdlog/sinks/base_sink.h>
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

std::mutex g_log_mutex;
std::string g_last_message;
std::ofstream g_log_file;
bool g_log_file_open = false;

//! Records the most recent log line and mirrors it to the sandbox log file, so that a failed slice
//! can report CuraEngine's own diagnostic and a crash still leaves a readable trace.
class CapturingSink final : public spdlog::sinks::base_sink<std::mutex>
{
protected:
    void sink_it_(const spdlog::details::log_msg &msg) override
    {
        spdlog::memory_buf_t formatted;
        formatter_->format(msg, formatted);
        const std::string text(formatted.data(), formatted.size());
        std::lock_guard<std::mutex> lock(g_log_mutex);
        g_last_message = text;
        if (g_log_file_open)
        {
            g_log_file << text << '\n';
            g_log_file.flush();
        }
    }

    void flush_() override
    {
    }
};

void installCapturingSink()
{
    static bool installed = false;
    if (installed)
    {
        return;
    }
    installed = true;
    if (auto *logger = spdlog::default_logger_raw(); logger != nullptr)
    {
        logger->sinks().push_back(std::make_shared<CapturingSink>());
    }
}

std::string takeLastMessage()
{
    std::lock_guard<std::mutex> lock(g_log_mutex);
    std::string message = g_last_message;
    g_last_message.clear();
    return message;
}

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

int runSlice(const SliceRequest &request, std::string &error_message)
{
    installCapturingSink();
    (void)takeLastMessage();

    {
        std::lock_guard<std::mutex> lock(g_log_mutex);
        if (g_log_file_open)
        {
            g_log_file.close();
        }
        g_log_file_open = false;
        if (! request.log_path.empty())
        {
            g_log_file.open(request.log_path, std::ios::out | std::ios::trunc);
            g_log_file_open = g_log_file.is_open();
        }
    }

    const int abort_status = setjmp(g_abort_jump);
    if (abort_status != 0)
    {
        g_abort_armed = false;
        error_message = takeLastMessage();
        spdlog::error("CuraHarmony: CuraEngine aborted the slice (status {})", abort_status);
        return abort_status;
    }

    // CuraEngine is invoked exactly like its command line front-end:
    //   CuraEngine slice -j <settings.json> -l <model> [-l <model> ...] -o <output.gcode>
    // The argv strings must stay alive for the whole call because Application keeps a pointer to them.
    std::vector<std::string> arguments;
    arguments.reserve(6 + 2 * request.model_paths.size() + 2 * request.overrides.size());
    arguments.emplace_back("CuraEngine");
    arguments.emplace_back("slice");
    // Several settings in Cura's definitions are both a value and a parent of child settings (for
    // example roofing_layer_count). By default CommandLine::loadJSONSettings() recurses into the
    // children and then skips the parent's own default_value, which makes CuraEngine abort later on
    // with "Trying to retrieve setting with no value given". This flag makes it read both.
    arguments.emplace_back("--force-read-parent");
    arguments.emplace_back("-j");
    arguments.push_back(request.settings_json_path);
    // Overrides must be applied while the global stack is still the active one, i.e. before -l
    // switches the active stack to the mesh.
    for (const std::string &override_setting : request.overrides)
    {
        arguments.emplace_back("-s");
        arguments.push_back(override_setting);
    }
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
