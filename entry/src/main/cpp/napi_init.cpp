#include "napi/native_api.h"

#include <memory>
#include <string>
#include <vector>

#include "slicer_bridge.h"

namespace
{

constexpr const char *ENGINE_INFO = "CuraHarmony native bridge (CuraEngine 5.14.0-alpha.0, OHOS aarch64)";

napi_value MakeString(napi_env env, const std::string &text)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &result);
    return result;
}

bool ReadString(napi_env env, napi_value value, std::string &out)
{
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string)
    {
        return false;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok)
    {
        return false;
    }
    out.resize(length);
    return napi_get_value_string_utf8(env, value, out.data(), length + 1, &length) == napi_ok;
}

bool ReadStringArray(napi_env env, napi_value value, std::vector<std::string> &out)
{
    bool is_array = false;
    if (napi_is_array(env, value, &is_array) != napi_ok || !is_array)
    {
        return false;
    }
    uint32_t length = 0;
    if (napi_get_array_length(env, value, &length) != napi_ok)
    {
        return false;
    }
    for (uint32_t index = 0; index < length; ++index)
    {
        napi_value element = nullptr;
        if (napi_get_element(env, value, index, &element) != napi_ok)
        {
            return false;
        }
        std::string text;
        if (!ReadString(env, element, text))
        {
            return false;
        }
        out.push_back(text);
    }
    return true;
}

struct SliceContext
{
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    curaharmony::SliceRequest request;
    int result = -1;
    std::string error_message;
};

void ExecuteSlice(napi_env env, void *data)
{
    (void)env;
    SliceContext *context = static_cast<SliceContext *>(data);
    // Each slice runs in its own child process: CuraEngine's Application::run() may only be called
    // once per process, so an in-process second slice would crash.
    context->result = curaharmony::runSliceInChildProcess(context->request, context->error_message);
}

void CompleteSlice(napi_env env, napi_status status, void *data)
{
    SliceContext *context = static_cast<SliceContext *>(data);
    if (status == napi_ok && context->result == 0)
    {
        napi_value value = nullptr;
        napi_create_int32(env, context->result, &value);
        napi_resolve_deferred(env, context->deferred, value);
    }
    else
    {
        std::string message = context->error_message.empty() ? "slice failed (status " + std::to_string(context->result) + ")"
                                                             : context->error_message;
        napi_value text = nullptr;
        napi_create_string_utf8(env, message.c_str(), message.size(), &text);
        napi_value error = nullptr;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, context->deferred, error);
    }
    napi_delete_async_work(env, context->work);
    delete context;
}

napi_value Ping(napi_env env, napi_callback_info info)
{
    (void)info;
    return MakeString(env, "pong");
}

napi_value GetEngineInfo(napi_env env, napi_callback_info info)
{
    (void)info;
    return MakeString(env, ENGINE_INFO);
}

napi_value Slice(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto context = std::make_unique<SliceContext>();
    if (argc < 3 || !ReadString(env, args[0], context->request.settings_json_path) || !ReadStringArray(env, args[1], context->request.model_paths)
        || !ReadString(env, args[2], context->request.output_gcode_path))
    {
        napi_throw_error(env, nullptr, "invalid slice arguments");
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    if (argc >= 4)
    {
        (void)ReadString(env, args[3], context->request.log_path);
    }
    if (argc >= 5)
    {
        (void)ReadStringArray(env, args[4], context->request.overrides);
    }

    napi_value promise = nullptr;
    if (napi_create_promise(env, &context->deferred, &promise) != napi_ok)
    {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    napi_value resource_name = nullptr;
    napi_create_string_utf8(env, "CuraHarmonySlice", NAPI_AUTO_LENGTH, &resource_name);
    SliceContext *raw = context.release();
    if (napi_create_async_work(env, nullptr, resource_name, ExecuteSlice, CompleteSlice, raw, &raw->work) != napi_ok)
    {
        delete raw;
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    napi_queue_async_work(env, raw->work);
    return promise;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "ping", nullptr, Ping, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getEngineInfo", nullptr, GetEngineInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "slice", nullptr, Slice, nullptr, nullptr, nullptr, napi_default, nullptr },
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
