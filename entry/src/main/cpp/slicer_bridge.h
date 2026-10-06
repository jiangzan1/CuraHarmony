// CuraHarmony slice bridge.
//
// CuraEngine documents that Application::run() may only be called once per process ("it has
// side-effects on static fields across the application"), and slicing twice in the same process
// crashes. HarmonyOS therefore runs every slice in a fresh native child process
// (OH_Ability_StartNativeChildProcess), which mirrors how desktop Cura drives CuraEngine as a
// subprocess. The request is passed as a line based payload in `entryParams` and the result is
// reported back through a small status file next to the G-code.

#ifndef CURA_HARMONY_SLICER_BRIDGE_H
#define CURA_HARMONY_SLICER_BRIDGE_H

#include <string>
#include <vector>

namespace curaharmony
{

struct SliceRequest
{
    std::string settings_json_path;
    std::vector<std::string> model_paths;
    std::string output_gcode_path;
    //! File that receives every CuraEngine log line, so a crash still leaves a readable trace.
    std::string log_path;
    //! Setting overrides, each formatted as "key=value", applied on top of the profile via -s.
    std::vector<std::string> overrides;
};

//! Runs one slice synchronously in the current process.
//! Must be called from a worker thread: CuraEngine is CPU bound.
int runSlice(const SliceRequest &request, std::string &error_message);

//! Runs one slice in a dedicated native child process and waits for it to finish.
//! Returns 0 on success; on failure `error_message` receives the last CuraEngine log line.
//! Falls back to runSlice() when the device does not support native child processes.
int runSliceInChildProcess(const SliceRequest &request, std::string &error_message);

//! Line based serialisation shared by the parent and the child process.
std::string encodeRequest(const SliceRequest &request);
bool decodeRequest(const std::string &payload, SliceRequest &request);
//! Status file written by the child: "code=<exit code>" followed by the last engine message.
std::string statusPathFor(const SliceRequest &request);

} // namespace curaharmony

#endif // CURA_HARMONY_SLICER_BRIDGE_H
