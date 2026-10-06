#include "slicer_bridge.h"

#include <AbilityKit/native_child_process.h>

#include <chrono>
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
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

std::string encodeRequest(const SliceRequest &request)
{
    std::string payload = "CURA1\n";
    payload += request.settings_json_path + "\n";
    payload += request.output_gcode_path + "\n";
    payload += request.log_path + "\n";
    payload += std::to_string(request.model_paths.size()) + "\n";
    for (const std::string &model_path : request.model_paths)
    {
        payload += model_path + "\n";
    }
    payload += std::to_string(request.overrides.size()) + "\n";
    for (const std::string &override_setting : request.overrides)
    {
        payload += override_setting + "\n";
    }
    return payload;
}

bool decodeRequest(const std::string &payload, SliceRequest &request)
{
    std::vector<std::string> lines;
    std::string current;
    for (const char character : payload)
    {
        if (character == '\n')
        {
            lines.push_back(current);
            current.clear();
        }
        else if (character != '\r')
        {
            current.push_back(character);
        }
    }
    if (! current.empty())
    {
        lines.push_back(current);
    }

    if (lines.size() < 5 || lines[0] != "CURA1")
    {
        return false;
    }

    size_t index = 1;
    request.settings_json_path = lines[index++];
    request.output_gcode_path = lines[index++];
    request.log_path = lines[index++];

    const size_t model_count = static_cast<size_t>(std::strtoul(lines[index++].c_str(), nullptr, 10));
    if (index + model_count > lines.size())
    {
        return false;
    }
    request.model_paths.clear();
    for (size_t model_index = 0; model_index < model_count; ++model_index)
    {
        request.model_paths.push_back(lines[index++]);
    }

    if (index >= lines.size())
    {
        return false;
    }
    const size_t override_count = static_cast<size_t>(std::strtoul(lines[index++].c_str(), nullptr, 10));
    if (index + override_count > lines.size())
    {
        return false;
    }
    request.overrides.clear();
    for (size_t override_index = 0; override_index < override_count; ++override_index)
    {
        request.overrides.push_back(lines[index++]);
    }
    return true;
}

std::string statusPathFor(const SliceRequest &request)
{
    return request.output_gcode_path + ".status";
}

namespace
{

bool readFileIfNonEmpty(const std::string &path, std::string &content)
{
    std::ifstream file(path, std::ios::binary);
    if (! file)
    {
        return false;
    }
    std::ostringstream buffer;
    buffer << file.rdbuf();
    content = buffer.str();
    return ! content.empty();
}

} // namespace

int runSliceInChildProcess(const SliceRequest &request, std::string &error_message)
{
    const std::string status_path = statusPathFor(request);
    // A stale status file from a previous run would make the poll below succeed immediately.
    std::remove(status_path.c_str());

    const std::string payload = encodeRequest(request);

    NativeChildProcess_Args args;
    std::memset(&args, 0, sizeof(args));
    args.entryParams = const_cast<char *>(payload.c_str());
    NativeChildProcess_Options options;
    std::memset(&options, 0, sizeof(options));
    // The child must share the sandbox so it can read the model/profile and write the G-code.
    options.isolationMode = NCP_ISOLATION_MODE_NORMAL;

    int32_t pid = 0;
    const Ability_NativeChildProcess_ErrCode start_code = OH_Ability_StartNativeChildProcess("libcuraslicer.so:SliceMain", args, options, &pid);
    if (start_code != NCP_NO_ERROR)
    {
        // 801 (NCP_ERR_NOT_SUPPORTED) on devices without the capability: degrade to an in-process
        // slice, which works once per application launch.
        spdlog::warn("CuraHarmony: native child process unavailable (code {}), slicing in-process", static_cast<int>(start_code));
        return runSlice(request, error_message);
    }

    constexpr int POLL_MS = 200;
    constexpr int TIMEOUT_MS = 300000;
    for (int waited_ms = 0; waited_ms < TIMEOUT_MS; waited_ms += POLL_MS)
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(POLL_MS));
        std::string content;
        if (! readFileIfNonEmpty(status_path, content))
        {
            continue;
        }

        int result = -1;
        std::string message;
        std::istringstream stream(content);
        std::string first_line;
        std::getline(stream, first_line);
        const size_t equals = first_line.find('=');
        if (equals != std::string::npos)
        {
            result = static_cast<int>(std::strtol(first_line.substr(equals + 1).c_str(), nullptr, 10));
        }
        std::string rest;
        std::getline(stream, rest);
        message = rest;

        if (result != 0)
        {
            error_message = message;
        }
        return result;
    }

    error_message = "切片子进程超时";
    return -1;
}

} // namespace curaharmony
