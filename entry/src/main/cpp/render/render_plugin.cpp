// CuraHarmony 3D model preview: XComponent surface + EGL + OpenGL ES 3.0.
//
// The library is loaded by the XComponent (libraryname: 'render'), so it receives the native
// surface and touch events directly and drives the camera itself. Nothing is imported from ArkTS,
// which avoids the double-module-load pitfall of also importing the render library on the UI side.

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <ace/xcomponent/native_interface_xcomponent.h>

// hilog's OH_LOG_* macros use LOG_TAG as the log tag, so it must be defined before the header is
// included; naming a variable LOG_TAG would otherwise collide with the macro.
#define LOG_TAG "CuraRender"
#include <hilog/log.h>

#include <napi/native_api.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include "render_math.h"

namespace
{

using namespace curaharmony;

// The XComponent covers the model area; the mesh is picked up from the application sandbox where the
// ArkTS side materialises the bundled test model. The XComponent cannot receive a path from ArkTS
// (the render library is loaded by the framework, not imported), so the sandbox directory is probed
// from the known stage-model layouts. On HarmonyOS the stage sandbox of a module lives under
// <base>/haps/<module>/files, which is why the module segment is part of the first candidate.
const char *FILES_DIR_CANDIDATES[] = {
    "/data/storage/el2/base/haps/entry/files",
    "/data/storage/el2/base/files",
};

std::string filesDir()
{
    for (const char *candidate : FILES_DIR_CANDIDATES)
    {
        if (access(candidate, F_OK) == 0)
        {
            return std::string(candidate);
        }
    }
    return std::string(FILES_DIR_CANDIDATES[0]);
}

std::string meshPath()
{
    return filesDir() + "/cube.stl";
}

std::string renderLogPath()
{
    return filesDir() + "/render.log";
}

// Appends to a sandbox log file (the UI shows its tail) in addition to hilog.
void writeRenderLog(const std::string &message)
{
    FILE *file = std::fopen(renderLogPath().c_str(), "a");
    if (file != nullptr)
    {
        std::fputs(message.c_str(), file);
        std::fputc('\n', file);
        std::fclose(file);
    }
    OH_LOG_INFO(LOG_APP, "%{public}s", message.c_str());
}

struct MeshData
{
    std::vector<float> vertices; // interleaved position(3) + normal(3)
    Vec3 min{};
    Vec3 max{};
    float radius{ 1.0F };
    bool loaded{ false };
};

// ---------------------------------------------------------------------------------------------
// STL loading
// ---------------------------------------------------------------------------------------------

void generateCube(MeshData &mesh, const float size)
{
    const Vec3 corners[8] = {
        { 0.0F, 0.0F, 0.0F }, { size, 0.0F, 0.0F }, { size, size, 0.0F }, { 0.0F, size, 0.0F },
        { 0.0F, 0.0F, size }, { size, 0.0F, size }, { size, size, size }, { 0.0F, size, size },
    };
    const int faces[12][3] = {
        { 0, 3, 2 }, { 0, 2, 1 }, { 4, 5, 6 }, { 4, 6, 7 }, { 0, 1, 5 }, { 0, 5, 4 },
        { 1, 2, 6 }, { 1, 6, 5 }, { 2, 3, 7 }, { 2, 7, 6 }, { 3, 0, 4 }, { 3, 4, 7 },
    };

    mesh.vertices.clear();
    mesh.min = corners[0];
    mesh.max = corners[0];
    for (const auto &face : faces)
    {
        const Vec3 a = corners[face[0]];
        const Vec3 b = corners[face[1]];
        const Vec3 c = corners[face[2]];
        const Vec3 normal = normalize(cross(b - a, c - a));
        const Vec3 triangle[3] = { a, b, c };
        for (const Vec3 &vertex : triangle)
        {
            mesh.vertices.insert(mesh.vertices.end(), { vertex.x, vertex.y, vertex.z, normal.x, normal.y, normal.z });
            mesh.min.x = std::fmin(mesh.min.x, vertex.x);
            mesh.min.y = std::fmin(mesh.min.y, vertex.y);
            mesh.min.z = std::fmin(mesh.min.z, vertex.z);
            mesh.max.x = std::fmax(mesh.max.x, vertex.x);
            mesh.max.y = std::fmax(mesh.max.y, vertex.y);
            mesh.max.z = std::fmax(mesh.max.z, vertex.z);
        }
    }
    mesh.radius = std::fmax(std::fmax(mesh.max.x - mesh.min.x, mesh.max.y - mesh.min.y), mesh.max.z - mesh.min.z);
    mesh.loaded = true;
}

bool loadBinaryStl(const std::vector<unsigned char> &data, MeshData &mesh)
{
    if (data.size() < 84)
    {
        return false;
    }
    uint32_t triangle_count = 0;
    std::memcpy(&triangle_count, data.data() + 80, sizeof(triangle_count));
    if (data.size() < 84 + static_cast<size_t>(triangle_count) * 50)
    {
        return false;
    }

    mesh.vertices.clear();
    mesh.vertices.reserve(static_cast<size_t>(triangle_count) * 18);
    bool first = true;
    for (uint32_t index = 0; index < triangle_count; ++index)
    {
        const unsigned char *record = data.data() + 84 + static_cast<size_t>(index) * 50;
        float values[12];
        std::memcpy(values, record, sizeof(values)); // 1 normal + 3 vertices (facet attribute ignored)
        for (int vertex = 0; vertex < 3; ++vertex)
        {
            const float x = values[3 + vertex * 3 + 0];
            const float y = values[3 + vertex * 3 + 1];
            const float z = values[3 + vertex * 3 + 2];
            mesh.vertices.insert(mesh.vertices.end(), { x, y, z, values[0], values[1], values[2] });
            if (first)
            {
                mesh.min = Vec3{ x, y, z };
                mesh.max = Vec3{ x, y, z };
                first = false;
            }
            mesh.min.x = std::fmin(mesh.min.x, x);
            mesh.min.y = std::fmin(mesh.min.y, y);
            mesh.min.z = std::fmin(mesh.min.z, z);
            mesh.max.x = std::fmax(mesh.max.x, x);
            mesh.max.y = std::fmax(mesh.max.y, y);
            mesh.max.z = std::fmax(mesh.max.z, z);
        }
    }
    mesh.radius = std::fmax(std::fmax(mesh.max.x - mesh.min.x, mesh.max.y - mesh.min.y), mesh.max.z - mesh.min.z);
    mesh.loaded = ! mesh.vertices.empty();
    return mesh.loaded;
}

bool loadAsciiStl(const std::string &text, MeshData &mesh)
{
    std::vector<Vec3> vertices;
    size_t position = 0;
    bool first = true;
    while ((position = text.find("vertex", position)) != std::string::npos)
    {
        float x = 0.0F;
        float y = 0.0F;
        float z = 0.0F;
        if (std::sscanf(text.c_str() + position, "vertex %f %f %f", &x, &y, &z) == 3)
        {
            const Vec3 vertex{ x, y, z };
            vertices.push_back(vertex);
            if (first)
            {
                mesh.min = vertex;
                mesh.max = vertex;
                first = false;
            }
            mesh.min.x = std::fmin(mesh.min.x, x);
            mesh.min.y = std::fmin(mesh.min.y, y);
            mesh.min.z = std::fmin(mesh.min.z, z);
            mesh.max.x = std::fmax(mesh.max.x, x);
            mesh.max.y = std::fmax(mesh.max.y, y);
            mesh.max.z = std::fmax(mesh.max.z, z);
        }
        position += 6;
    }

    if (vertices.size() < 3)
    {
        return false;
    }

    mesh.vertices.clear();
    mesh.vertices.reserve(vertices.size() * 6);
    for (size_t index = 0; index + 2 < vertices.size(); index += 3)
    {
        const Vec3 normal = normalize(cross(vertices[index + 1] - vertices[index], vertices[index + 2] - vertices[index]));
        for (int corner = 0; corner < 3; ++corner)
        {
            const Vec3 &vertex = vertices[index + static_cast<size_t>(corner)];
            mesh.vertices.insert(mesh.vertices.end(), { vertex.x, vertex.y, vertex.z, normal.x, normal.y, normal.z });
        }
    }
    mesh.radius = std::fmax(std::fmax(mesh.max.x - mesh.min.x, mesh.max.y - mesh.min.y), mesh.max.z - mesh.min.z);
    mesh.loaded = true;
    return true;
}

void loadMesh(const std::string &path, MeshData &mesh)
{
    FILE *file = std::fopen(path.c_str(), "rb");
    if (file == nullptr)
    {
        OH_LOG_WARN(LOG_APP, "%{public}s: mesh not found at %{public}s, using built-in cube", LOG_TAG, path.c_str());
        generateCube(mesh, 20.0F);
        return;
    }

    std::fseek(file, 0, SEEK_END);
    const long length = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    if (length <= 0)
    {
        std::fclose(file);
        generateCube(mesh, 20.0F);
        return;
    }

    std::vector<unsigned char> data(static_cast<size_t>(length));
    const size_t read = std::fread(data.data(), 1, data.size(), file);
    std::fclose(file);
    data.resize(read);

    // ASCII STL starts with "solid" and has no binary triangle count; binary files are detected by
    // the size relationship instead of the header, which is not reliable.
    const bool looks_ascii = data.size() > 5 && std::memcmp(data.data(), "solid", 5) == 0;
    bool ok = false;
    if (looks_ascii && read >= 84)
    {
        uint32_t triangle_count = 0;
        std::memcpy(&triangle_count, data.data() + 80, sizeof(triangle_count));
        const size_t expected = 84 + static_cast<size_t>(triangle_count) * 50;
        if (expected == read)
        {
            ok = loadBinaryStl(data, mesh);
        }
    }
    if (! ok && looks_ascii)
    {
        ok = loadAsciiStl(std::string(data.begin(), data.end()), mesh);
    }
    if (! ok)
    {
        ok = loadBinaryStl(data, mesh);
    }
    if (! ok)
    {
        OH_LOG_WARN(LOG_APP, "%{public}s: could not parse %{public}s, using built-in cube", LOG_TAG, path.c_str());
        generateCube(mesh, 20.0F);
    }
    else
    {
        OH_LOG_INFO(LOG_APP, "%{public}s: loaded %{public}zu vertices from %{public}s", LOG_TAG, mesh.vertices.size() / 6, path.c_str());
    }
}

// ---------------------------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------------------------

GLuint compileShader(GLenum type, const char *source)
{
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled == GL_FALSE)
    {
        char log[512];
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        OH_LOG_ERROR(LOG_APP, "%{public}s: shader compile failed: %{public}s", LOG_TAG, log);
    }
    return shader;
}

GLuint createProgram(const char *vertex_source, const char *fragment_source)
{
    const GLuint vertex = compileShader(GL_VERTEX_SHADER, vertex_source);
    const GLuint fragment = compileShader(GL_FRAGMENT_SHADER, fragment_source);
    const GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    return program;
}

const char *MESH_VERTEX_SHADER = R"(#version 300 es
layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aNormal;
uniform mat4 uMvp;
out vec3 vNormal;
void main()
{
    vNormal = aNormal;
    gl_Position = uMvp * vec4(aPosition, 1.0);
}
)";

const char *MESH_FRAGMENT_SHADER = R"(#version 300 es
precision mediump float;
in vec3 vNormal;
uniform vec4 uColor;
out vec4 fragColor;
void main()
{
    vec3 normal = normalize(vNormal);
    float diffuse = max(dot(normal, normalize(vec3(0.45, 0.35, 0.82))), 0.0);
    fragColor = vec4(uColor.rgb * (0.32 + 0.68 * diffuse), uColor.a);
}
)";

const char *LINE_VERTEX_SHADER = R"(#version 300 es
layout(location = 0) in vec3 aPosition;
uniform mat4 uMvp;
void main()
{
    gl_Position = uMvp * vec4(aPosition, 1.0);
}
)";

const char *LINE_FRAGMENT_SHADER = R"(#version 300 es
precision mediump float;
uniform vec4 uColor;
out vec4 fragColor;
void main()
{
    fragColor = uColor;
}
)";

struct Renderer
{
    std::mutex mutex;
    std::atomic<bool> running{ false };
    std::thread thread;

    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    EGLConfig config = nullptr;

    GLuint mesh_program = 0;
    GLuint line_program = 0;
    GLuint mesh_vao = 0;
    GLuint mesh_vbo = 0;
    GLuint grid_vao = 0;
    GLuint grid_vbo = 0;
    GLsizei mesh_vertex_count = 0;
    GLsizei grid_vertex_count = 0;

    MeshData mesh;
    Vec3 mesh_offset{};   // moves the model so it sits on the build plate and is centred
    float mesh_scale = 1.0F;

    int surface_width = 1;
    int surface_height = 1;

    // Camera
    float yaw_degrees = 35.0F;
    float pitch_degrees = 28.0F;
    float distance = 120.0F;
    Vec3 target{ 0.0F, 0.0F, 10.0F };

    // Touch state
    float last_touch_x = 0.0F;
    float last_touch_y = 0.0F;
    float last_pinch_distance = 0.0F;
};

Renderer g_renderer;

void buildGrid(Renderer &renderer)
{
    // A simple build plate: 200 x 200 mm outline plus 10 mm grid lines.
    const float half = 100.0F;
    const float step = 10.0F;
    std::vector<float> lines;
    for (float offset = -half; offset <= half + 0.5F; offset += step)
    {
        lines.insert(lines.end(), { offset, -half, 0.0F, offset, half, 0.0F });
        lines.insert(lines.end(), { -half, offset, 0.0F, half, offset, 0.0F });
    }
    renderer.grid_vertex_count = static_cast<GLsizei>(lines.size() / 3);

    glGenVertexArrays(1, &renderer.grid_vao);
    glBindVertexArray(renderer.grid_vao);
    glGenBuffers(1, &renderer.grid_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, renderer.grid_vbo);
    glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(lines.size() * sizeof(float)), lines.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), nullptr);
    glBindVertexArray(0);
}

void uploadMesh(Renderer &renderer)
{
    if (renderer.mesh_vao == 0)
    {
        glGenVertexArrays(1, &renderer.mesh_vao);
    }
    if (renderer.mesh_vbo == 0)
    {
        glGenBuffers(1, &renderer.mesh_vbo);
    }

    glBindVertexArray(renderer.mesh_vao);
    glBindBuffer(GL_ARRAY_BUFFER, renderer.mesh_vbo);
    glBufferData(
        GL_ARRAY_BUFFER,
        static_cast<GLsizeiptr>(renderer.mesh.vertices.size() * sizeof(float)),
        renderer.mesh.vertices.data(),
        GL_STATIC_DRAW);
    const GLsizei stride = 6 * sizeof(float);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride, nullptr);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, stride, reinterpret_cast<const void *>(3 * sizeof(float)));
    glBindVertexArray(0);

    renderer.mesh_vertex_count = static_cast<GLsizei>(renderer.mesh.vertices.size() / 6);

    // Centre the model on the plate, drop it onto z = 0 and normalise its size for a stable camera.
    const Vec3 size{
        renderer.mesh.max.x - renderer.mesh.min.x,
        renderer.mesh.max.y - renderer.mesh.min.y,
        renderer.mesh.max.z - renderer.mesh.min.z,
    };
    const float largest = std::fmax(std::fmax(size.x, size.y), size.z);
    renderer.mesh_scale = largest > 0.0F ? 80.0F / largest : 1.0F;
    renderer.mesh_offset = Vec3{
        -(renderer.mesh.min.x + renderer.mesh.max.x) * 0.5F,
        -(renderer.mesh.min.y + renderer.mesh.max.y) * 0.5F,
        -renderer.mesh.min.z,
    };
    renderer.target = Vec3{ 0.0F, 0.0F, 80.0F * 0.5F * (size.z / (largest > 0.0F ? largest : 1.0F)) };
    renderer.distance = 190.0F;
}

void renderFrame(Renderer &renderer)
{
    glViewport(0, 0, renderer.surface_width, renderer.surface_height);
    glClearColor(0.09F, 0.09F, 0.10F, 1.0F);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);

    const float aspect = renderer.surface_height > 0 ? static_cast<float>(renderer.surface_width) / static_cast<float>(renderer.surface_height) : 1.0F;
    const Mat4 projection = Mat4::perspective(0.9F, aspect, 0.5F, 4000.0F);

    const float yaw = renderer.yaw_degrees * 3.14159265F / 180.0F;
    const float pitch = renderer.pitch_degrees * 3.14159265F / 180.0F;
    const Vec3 eye{
        renderer.target.x + renderer.distance * std::cos(pitch) * std::sin(yaw),
        renderer.target.y + renderer.distance * std::cos(pitch) * std::cos(yaw),
        renderer.target.z + renderer.distance * std::sin(pitch),
    };
    const Mat4 view = Mat4::lookAt(eye, renderer.target, Vec3{ 0.0F, 0.0F, 1.0F });

    // Build plate
    glUseProgram(renderer.line_program);
    glUniformMatrix4fv(glGetUniformLocation(renderer.line_program, "uMvp"), 1, GL_FALSE, (projection * view).m);
    glUniform4f(glGetUniformLocation(renderer.line_program, "uColor"), 0.28F, 0.30F, 0.34F, 1.0F);
    glBindVertexArray(renderer.grid_vao);
    glDrawArrays(GL_LINES, 0, renderer.grid_vertex_count);

    // Model
    if (renderer.mesh_vertex_count > 0)
    {
        const Mat4 model = Mat4::translation(renderer.mesh_offset) * Mat4::scale(renderer.mesh_scale);
        glUseProgram(renderer.mesh_program);
        glUniformMatrix4fv(glGetUniformLocation(renderer.mesh_program, "uMvp"), 1, GL_FALSE, (projection * view * model).m);
        glUniform4f(glGetUniformLocation(renderer.mesh_program, "uColor"), 0.36F, 0.62F, 0.86F, 1.0F);
        glBindVertexArray(renderer.mesh_vao);
        glDrawArrays(GL_TRIANGLES, 0, renderer.mesh_vertex_count);
    }

    glBindVertexArray(0);
    eglSwapBuffers(renderer.display, renderer.surface);
}

void renderLoop()
{
    Renderer &renderer = g_renderer;
    {
        std::lock_guard<std::mutex> lock(renderer.mutex);
        if (eglMakeCurrent(renderer.display, renderer.surface, renderer.surface, renderer.context) != EGL_TRUE)
        {
            writeRenderLog("render loop: eglMakeCurrent failed");
            return;
        }
        writeRenderLog("render loop: context bound, viewport=" + std::to_string(renderer.surface_width) + "x" + std::to_string(renderer.surface_height));
    }

    bool first_frame = true;
    while (renderer.running.load())
    {
        {
            std::lock_guard<std::mutex> lock(renderer.mutex);
            if (renderer.display != EGL_NO_DISPLAY && renderer.surface != EGL_NO_SURFACE)
            {
                renderFrame(renderer);
                if (first_frame)
                {
                    writeRenderLog("first frame drawn, viewport=" + std::to_string(renderer.surface_width) + "x" + std::to_string(renderer.surface_height));
                    first_frame = false;
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
    }
}

bool initEgl(Renderer &renderer, void *window)
{
    renderer.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (renderer.display == EGL_NO_DISPLAY)
    {
        OH_LOG_ERROR(LOG_APP, "%{public}s: eglGetDisplay failed", LOG_TAG);
        return false;
    }
    if (eglInitialize(renderer.display, nullptr, nullptr) != EGL_TRUE)
    {
        OH_LOG_ERROR(LOG_APP, "%{public}s: eglInitialize failed", LOG_TAG);
        return false;
    }

    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE,
        EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE,
        EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,
        8,
        EGL_GREEN_SIZE,
        8,
        EGL_BLUE_SIZE,
        8,
        EGL_ALPHA_SIZE,
        8,
        EGL_DEPTH_SIZE,
        24,
        EGL_NONE,
    };
    EGLint config_count = 0;
    if (eglChooseConfig(renderer.display, config_attributes, &renderer.config, 1, &config_count) != EGL_TRUE || config_count == 0)
    {
        OH_LOG_ERROR(LOG_APP, "%{public}s: eglChooseConfig failed", LOG_TAG);
        return false;
    }

    renderer.surface = eglCreateWindowSurface(renderer.display, renderer.config, reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (renderer.surface == EGL_NO_SURFACE)
    {
        OH_LOG_ERROR(LOG_APP, "%{public}s: eglCreateWindowSurface failed", LOG_TAG);
        return false;
    }

    const EGLint context_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    renderer.context = eglCreateContext(renderer.display, renderer.config, EGL_NO_CONTEXT, context_attributes);
    if (renderer.context == EGL_NO_CONTEXT)
    {
        OH_LOG_ERROR(LOG_APP, "%{public}s: eglCreateContext failed", LOG_TAG);
        return false;
    }

    if (eglMakeCurrent(renderer.display, renderer.surface, renderer.surface, renderer.context) != EGL_TRUE)
    {
        OH_LOG_ERROR(LOG_APP, "%{public}s: eglMakeCurrent failed", LOG_TAG);
        return false;
    }

    renderer.mesh_program = createProgram(MESH_VERTEX_SHADER, MESH_FRAGMENT_SHADER);
    renderer.line_program = createProgram(LINE_VERTEX_SHADER, LINE_FRAGMENT_SHADER);

    loadMesh(meshPath(), renderer.mesh);
    buildGrid(renderer);
    uploadMesh(renderer);
    writeRenderLog("prepared: mesh vertices=" + std::to_string(renderer.mesh_vertex_count) + " grid vertices=" + std::to_string(renderer.grid_vertex_count));

    // The EGL context was created on the callback (UI) thread but is used by the render thread.
    // A context may only be current on one thread at a time, so release it here first.
    eglMakeCurrent(renderer.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    return true;
}

void destroyEgl(Renderer &renderer)
{
    if (renderer.display != EGL_NO_DISPLAY)
    {
        eglMakeCurrent(renderer.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (renderer.context != EGL_NO_CONTEXT)
        {
            eglDestroyContext(renderer.display, renderer.context);
        }
        if (renderer.surface != EGL_NO_SURFACE)
        {
            eglDestroySurface(renderer.display, renderer.surface);
        }
        eglTerminate(renderer.display);
    }
    renderer.display = EGL_NO_DISPLAY;
    renderer.surface = EGL_NO_SURFACE;
    renderer.context = EGL_NO_CONTEXT;
}

// ---------------------------------------------------------------------------------------------
// XComponent callbacks
// ---------------------------------------------------------------------------------------------

void OnSurfaceCreated(OH_NativeXComponent *component, void *window)
{
    writeRenderLog("surface created");
    Renderer &renderer = g_renderer;
    {
        std::lock_guard<std::mutex> lock(renderer.mutex);
        // The initial layout size may not arrive through OnSurfaceChanged, so seed it here; otherwise
        // the viewport would stay at 1x1 and nothing would be visible.
        uint64_t width = 0;
        uint64_t height = 0;
        if (OH_NativeXComponent_GetXComponentSize(component, window, &width, &height) == 0 && width > 0 && height > 0)
        {
            renderer.surface_width = static_cast<int>(width);
            renderer.surface_height = static_cast<int>(height);
        }
        if (! initEgl(renderer, window))
        {
            writeRenderLog("initEgl failed");
            return;
        }
    }
    writeRenderLog("egl ready, starting render thread");
    renderer.running.store(true);
    renderer.thread = std::thread(renderLoop);
}

void OnSurfaceChanged(OH_NativeXComponent *component, void *window)
{
    (void)window;
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    Renderer &renderer = g_renderer;
    std::lock_guard<std::mutex> lock(renderer.mutex);
    renderer.surface_width = static_cast<int>(width);
    renderer.surface_height = static_cast<int>(height);
}

void OnSurfaceDestroyed(OH_NativeXComponent *component, void *window)
{
    (void)component;
    (void)window;
    OH_LOG_INFO(LOG_APP, "%{public}s: surface destroyed", LOG_TAG);
    Renderer &renderer = g_renderer;
    renderer.running.store(false);
    if (renderer.thread.joinable())
    {
        renderer.thread.join();
    }
    std::lock_guard<std::mutex> lock(renderer.mutex);
    destroyEgl(renderer);
}

void DispatchTouchEvent(OH_NativeXComponent *component, void *window)
{
    OH_NativeXComponent_TouchEvent touch_event;
    std::memset(&touch_event, 0, sizeof(touch_event));
    if (OH_NativeXComponent_GetTouchEvent(component, window, &touch_event) != 0)
    {
        return;
    }

    Renderer &renderer = g_renderer;
    std::lock_guard<std::mutex> lock(renderer.mutex);

    if (touch_event.type == OH_NativeXComponent_TouchEventType::OH_NATIVEXCOMPONENT_CANCEL)
    {
        renderer.last_pinch_distance = 0.0F;
        return;
    }

    const float x = touch_event.x;
    const float y = touch_event.y;

    if (touch_event.numPoints >= 2)
    {
        const float dx = touch_event.touchPoints[0].x - touch_event.touchPoints[1].x;
        const float dy = touch_event.touchPoints[0].y - touch_event.touchPoints[1].y;
        const float pinch = std::sqrt(dx * dx + dy * dy);
        if (renderer.last_pinch_distance > 0.0F && pinch > 0.0F)
        {
            const float ratio = renderer.last_pinch_distance / pinch;
            renderer.distance = std::fmax(40.0F, std::fmin(900.0F, renderer.distance * ratio));
        }
        renderer.last_pinch_distance = pinch;
        renderer.last_touch_x = x;
        renderer.last_touch_y = y;
        return;
    }

    renderer.last_pinch_distance = 0.0F;

    if (touch_event.type == OH_NativeXComponent_TouchEventType::OH_NATIVEXCOMPONENT_MOVE)
    {
        const float delta_x = x - renderer.last_touch_x;
        const float delta_y = y - renderer.last_touch_y;
        renderer.yaw_degrees -= delta_x * 0.18F;
        renderer.pitch_degrees = std::fmax(-85.0F, std::fmin(85.0F, renderer.pitch_degrees + delta_y * 0.18F));
    }

    renderer.last_touch_x = x;
    renderer.last_touch_y = y;
}

OH_NativeXComponent_Callback g_callbacks = {
    .OnSurfaceCreated = OnSurfaceCreated,
    .OnSurfaceChanged = OnSurfaceChanged,
    .OnSurfaceDestroyed = OnSurfaceDestroyed,
    .DispatchTouchEvent = DispatchTouchEvent,
};

napi_value Init(napi_env env, napi_value exports)
{
    napi_value export_instance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &export_instance) != napi_ok)
    {
        writeRenderLog("init: no XComponent object in exports");
        return exports;
    }

    OH_NativeXComponent *native_xcomponent = nullptr;
    if (napi_unwrap(env, export_instance, reinterpret_cast<void **>(&native_xcomponent)) != napi_ok || native_xcomponent == nullptr)
    {
        writeRenderLog("init: failed to unwrap XComponent");
        return exports;
    }

    OH_NativeXComponent_RegisterCallback(native_xcomponent, &g_callbacks);
    writeRenderLog("init: XComponent callbacks registered");
    return exports;
}

napi_module renderModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "render",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterRenderModule(void)
{
    writeRenderLog("render.so loaded, registering module");
    napi_module_register(&renderModule);
}
