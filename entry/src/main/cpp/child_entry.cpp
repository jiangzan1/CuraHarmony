// Entry point executed inside the CuraEngine child process.
//
// HarmonyOS loads libcuraslicer.so into a fresh process, resolves "SliceMain" by name, calls it with
// the arguments handed to OH_Ability_StartNativeChildProcess, and destroys the process once this
// function returns. Running each slice in its own process is what keeps CuraEngine's singleton state
// (Application::run() may only be called once per process) from breaking on the second slice.

#include <AbilityKit/native_child_process.h>

#include <fstream>
#include <string>

#include <spdlog/spdlog.h>

#include "slicer_bridge.h"

extern "C" void SliceMain(NativeChildProcess_Args args)
{
    curaharmony::SliceRequest request;
    if (args.entryParams == nullptr || ! curaharmony::decodeRequest(std::string(args.entryParams), request))
    {
        spdlog::error("CuraHarmony: child process received an invalid slice request");
        return;
    }

    std::string message;
    const int result = curaharmony::runSlice(request, message);

    // Publish the outcome for the parent process: "code=<n>" followed by the last engine message.
    std::ofstream status(curaharmony::statusPathFor(request), std::ios::out | std::ios::trunc);
    if (status.is_open())
    {
        status << "code=" << result << "\n" << message << "\n";
        status.flush();
    }
    spdlog::info("CuraHarmony: child slice finished with code {}", result);
}
