#include "napi/native_api.h"

#include <string>

namespace {
constexpr const char *BRIDGE_NAME = "CuraHarmony native bridge";

napi_value MakeString(napi_env env, const std::string &text)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &result);
    return result;
}
} // namespace

static napi_value Ping(napi_env env, napi_callback_info info)
{
    (void)info;
    return MakeString(env, "pong");
}

static napi_value GetEngineInfo(napi_env env, napi_callback_info info)
{
    (void)info;
    return MakeString(env, std::string(BRIDGE_NAME) + " (M1 stub, no CuraEngine linked yet)");
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "ping", nullptr, Ping, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getEngineInfo", nullptr, GetEngineInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module curaSlicerModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "curaslicer",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterCuraSlicerModule(void)
{
    napi_module_register(&curaSlicerModule);
}
