// CuraHarmony slice bridge: drives the in-process CuraEngine instead of spawning a child process
// (HarmonyOS application sandboxes do not allow executing bundled binaries).

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
    //! Optional: file that receives every CuraEngine log line. Kept in the sandbox so a crash still
    //! leaves a readable trace behind.
    std::string log_path;
};

//! Runs one slice synchronously. Returns 0 on success, non-zero otherwise.
//! On failure, `error_message` receives the last CuraEngine log line, which normally names the
//! offending setting. Must be called from a worker thread: CuraEngine is CPU bound.
int runSlice(const SliceRequest &request, std::string &error_message);

} // namespace curaharmony

#endif // CURA_HARMONY_SLICER_BRIDGE_H
