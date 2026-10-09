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
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <sys/stat.h>
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

// How often the render loop wakes up to look for a freshly imported mesh while the scene is static.
constexpr int RELOAD_POLL_MS = 300;

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

std::string viewModePath()
{
    return filesDir() + "/view_mode";
}

std::string plateSizePath()
{
    return filesDir() + "/plate_size";
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

// Change stamp of the mesh file. The renderer cannot be driven from ArkTS (the library is loaded by
// the XComponent, not imported), so the render loop polls the file's mtime and reloads when the
// ArkTS side overwrites cube.stl with an imported model.
struct FileStamp
{
    long long seconds{ 0 };
    long long nanoseconds{ 0 };
    bool valid{ false };
};

FileStamp fileStamp(const std::string &path)
{
    struct stat info;
    if (stat(path.c_str(), &info) != 0)
    {
        return FileStamp{};
    }
    return FileStamp{ static_cast<long long>(info.st_mtim.tv_sec), static_cast<long long>(info.st_mtim.tv_nsec), true };
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
// Indexed drawing
// ---------------------------------------------------------------------------------------------

// Welds duplicated (position, normal) pairs from the triangle soup into an index buffer. STL stores
// each triangle standalone, so coplanar facets repeat their vertices; merging them cuts the vertex
// count (and VBO size) without changing the flat-shaded look, because vertices shared by facets with
// different normals are deliberately NOT merged.
bool buildIndexedMesh(const std::vector<float> &vertices, std::vector<float> &welded, std::vector<unsigned int> &indices)
{
    const size_t vertex_count = vertices.size() / 6;
    if (vertex_count == 0)
    {
        return false;
    }

    std::map<std::array<int, 6>, unsigned int> unique;
    welded.clear();
    indices.clear();
    indices.reserve(vertex_count);
    welded.reserve(vertices.size());

    for (size_t i = 0; i < vertex_count; ++i)
    {
        const float *v = vertices.data() + i * 6;
        const std::array<int, 6> key{
            static_cast<int>(std::lround(v[0] * 1000.0F)),
            static_cast<int>(std::lround(v[1] * 1000.0F)),
            static_cast<int>(std::lround(v[2] * 1000.0F)),
            static_cast<int>(std::lround(v[3] * 1000.0F)),
            static_cast<int>(std::lround(v[4] * 1000.0F)),
            static_cast<int>(std::lround(v[5] * 1000.0F)),
        };
        const auto found = unique.find(key);
        if (found != unique.end())
        {
            indices.push_back(found->second);
        }
        else
        {
            const unsigned int index = static_cast<unsigned int>(welded.size() / 6);
            unique.emplace(key, index);
            welded.insert(welded.end(), { v[0], v[1], v[2], v[3], v[4], v[5] });
            indices.push_back(index);
        }
    }

    // Only use the indexed path when welding actually removed a meaningful amount of data.
    return welded.size() / 6 < vertex_count * 9 / 10;
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
    std::condition_variable wake;
    bool dirty{ true }; // set when the frame must be redrawn (interaction, resize, reload)

    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    EGLConfig config = nullptr;

    GLuint mesh_program = 0;
    GLuint line_program = 0;
    GLuint mesh_vao = 0;
    GLuint mesh_vbo = 0;
    GLuint mesh_ebo = 0;
    GLuint grid_vao = 0;
    GLuint grid_vbo = 0;
    GLsizei mesh_vertex_count = 0;
    GLsizei mesh_index_count = 0;
    bool mesh_indexed{ false };
    GLsizei grid_vertex_count = 0;
    GLint mesh_mvp_location = -1;
    GLint mesh_color_location = -1;
    GLint line_mvp_location = -1;
    GLint line_color_location = -1;

    MeshData mesh;
    Vec3 mesh_offset{};   // moves the model so it sits on the build plate and is centred
    float mesh_scale = 1.0F;
    FileStamp mesh_stamp{}; // mtime of the mesh file last loaded
    Vec3 plate_offset{};    // model position on the build plate (world XY, mm)
    float plate_width = 200.0F;
    float plate_depth = 200.0F;
    FileStamp plate_stamp{}; // mtime of the plate-size file last loaded

    // Mesh parsing runs on a worker thread so a large model cannot stall the render loop or the UI.
    std::thread parse_thread;
    bool parse_running{ false };
    bool has_pending{ false };
    MeshData pending_mesh;
    FileStamp pending_stamp{};

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
    float last_center_x = 0.0F;
    float last_center_y = 0.0F;
    bool translate_mode{ false }; // single-pointer drag moves the model instead of orbiting
};

Renderer g_renderer;

// Default camera distance so the whole build plate fits in view.
float defaultCameraDistance(const Renderer &renderer)
{
    return std::fmax(160.0F, std::fmax(renderer.plate_width, renderer.plate_depth) * 0.95F);
}

// Reads the build-plate size written by the ArkTS layer ("<width> <depth>" in mm). Invalid or
// missing content keeps the current value, so a partially typed number cannot collapse the plate.
void readPlateSize(Renderer &renderer)
{
    FILE *file = std::fopen(plateSizePath().c_str(), "rb");
    if (file == nullptr)
    {
        return;
    }
    char buffer[64] = {};
    const size_t read = std::fread(buffer, 1, sizeof(buffer) - 1, file);
    std::fclose(file);
    if (read == 0)
    {
        return;
    }
    float width = 0.0F;
    float depth = 0.0F;
    if (std::sscanf(buffer, "%f %f", &width, &depth) == 2 && width >= 10.0F && depth >= 10.0F)
    {
        renderer.plate_width = std::fmin(width, 1000.0F);
        renderer.plate_depth = std::fmin(depth, 1000.0F);
    }
}

// Builds (or rebuilds) the build-plate grid for the current plate size. Reusing the VAO/VBO makes it
// safe to call again when the user changes the printer dimensions.
void buildGrid(Renderer &renderer)
{
    const float half_x = renderer.plate_width * 0.5F;
    const float half_y = renderer.plate_depth * 0.5F;
    const float step = 10.0F;
    std::vector<float> lines;
    for (float x = -half_x; x <= half_x + 0.5F; x += step)
    {
        lines.insert(lines.end(), { x, -half_y, 0.0F, x, half_y, 0.0F });
    }
    for (float y = -half_y; y <= half_y + 0.5F; y += step)
    {
        lines.insert(lines.end(), { -half_x, y, 0.0F, half_x, y, 0.0F });
    }
    renderer.grid_vertex_count = static_cast<GLsizei>(lines.size() / 3);

    if (renderer.grid_vao == 0)
    {
        glGenVertexArrays(1, &renderer.grid_vao);
    }
    if (renderer.grid_vbo == 0)
    {
        glGenBuffers(1, &renderer.grid_vbo);
    }
    glBindVertexArray(renderer.grid_vao);
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

    // Weld duplicated vertices and draw with an index buffer when that saves a meaningful amount of
    // data; otherwise keep the plain triangle soup.
    std::vector<float> welded;
    std::vector<unsigned int> indices;
    const bool indexed = buildIndexedMesh(renderer.mesh.vertices, welded, indices);
    const std::vector<float> &vertex_data = indexed ? welded : renderer.mesh.vertices;

    glBindVertexArray(renderer.mesh_vao);
    glBindBuffer(GL_ARRAY_BUFFER, renderer.mesh_vbo);
    glBufferData(
        GL_ARRAY_BUFFER,
        static_cast<GLsizeiptr>(vertex_data.size() * sizeof(float)),
        vertex_data.data(),
        GL_STATIC_DRAW);
    const GLsizei stride = 6 * sizeof(float);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride, nullptr);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, stride, reinterpret_cast<const void *>(3 * sizeof(float)));

    renderer.mesh_indexed = indexed;
    if (indexed)
    {
        if (renderer.mesh_ebo == 0)
        {
            glGenBuffers(1, &renderer.mesh_ebo);
        }
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, renderer.mesh_ebo);
        glBufferData(
            GL_ELEMENT_ARRAY_BUFFER,
            static_cast<GLsizeiptr>(indices.size() * sizeof(unsigned int)),
            indices.data(),
            GL_STATIC_DRAW);
        renderer.mesh_index_count = static_cast<GLsizei>(indices.size());
    }
    glBindVertexArray(0);

    renderer.mesh_vertex_count = static_cast<GLsizei>(vertex_data.size() / 6);

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
    renderer.distance = defaultCameraDistance(renderer);
    renderer.plate_offset = Vec3{};
}

// Starts an off-thread parse of the mesh file. The worker publishes through the renderer's pending
// slot and never touches GL: only the render thread uploads buffers.
void startMeshParse(Renderer &renderer, const std::string &path, const FileStamp &stamp)
{
    if (renderer.parse_running)
    {
        // Already parsing; the poll below will pick up any newer file once this one lands.
        return;
    }
    if (renderer.parse_thread.joinable())
    {
        // The previous worker has published and is finishing; it needs no lock to exit.
        renderer.parse_thread.join();
    }

    renderer.parse_running = true;
    renderer.parse_thread = std::thread([&renderer, path, stamp]() {
        MeshData parsed;
        loadMesh(path, parsed);
        {
            std::lock_guard<std::mutex> lock(renderer.mutex);
            renderer.pending_mesh = std::move(parsed);
            renderer.pending_stamp = stamp;
            renderer.has_pending = true;
            renderer.parse_running = false;
            renderer.dirty = true;
        }
        renderer.wake.notify_one();
    });
}

// Called from the render loop (GL context current) when the mesh file changed on disk: parsing is
// handed to a worker thread so a large model does not block rendering.
void reloadMeshIfChanged(Renderer &renderer)
{
    const FileStamp stamp = fileStamp(meshPath());
    if (! stamp.valid)
    {
        return;
    }
    if (stamp.seconds == renderer.mesh_stamp.seconds && stamp.nanoseconds == renderer.mesh_stamp.nanoseconds)
    {
        return;
    }

    startMeshParse(renderer, meshPath(), stamp);
}

// Called from the render loop when the ArkTS side writes a new printer build volume: rebuilds the
// plate grid and re-frames the camera so a change of printer size is visible in the preview.
void reloadPlateIfChanged(Renderer &renderer)
{
    const FileStamp stamp = fileStamp(plateSizePath());
    if (! stamp.valid)
    {
        return;
    }
    if (stamp.seconds == renderer.plate_stamp.seconds && stamp.nanoseconds == renderer.plate_stamp.nanoseconds)
    {
        return;
    }

    readPlateSize(renderer);
    buildGrid(renderer);
    // Deliberately does NOT reset the camera distance: keeping the framing lets the plate visibly
    // grow/shrink on screen instead of zooming out and masking the change.
    renderer.plate_stamp = stamp;
    renderer.dirty = true;
    writeRenderLog("plate resized: " + std::to_string(renderer.plate_width) + " x " + std::to_string(renderer.plate_depth));
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
    glUniformMatrix4fv(renderer.line_mvp_location, 1, GL_FALSE, (projection * view).m);
    glUniform4f(renderer.line_color_location, 0.28F, 0.30F, 0.34F, 1.0F);
    glBindVertexArray(renderer.grid_vao);
    glDrawArrays(GL_LINES, 0, renderer.grid_vertex_count);

    // Model
    if (renderer.mesh_vertex_count > 0)
    {
        // Order matters: the mesh is recentred in its OWN units first, then scaled. Applying the
        // unscaled mesh_offset after the scale would offset imported models (whose coordinates can
        // be large) far off the plate and make them impossible to bring back to the centre.
        const Mat4 model = Mat4::translation(renderer.plate_offset) * Mat4::scale(renderer.mesh_scale) * Mat4::translation(renderer.mesh_offset);
        glUseProgram(renderer.mesh_program);
        glUniformMatrix4fv(renderer.mesh_mvp_location, 1, GL_FALSE, (projection * view * model).m);
        glUniform4f(renderer.mesh_color_location, 0.36F, 0.62F, 0.86F, 1.0F);
        glBindVertexArray(renderer.mesh_vao);
        if (renderer.mesh_indexed)
        {
            glDrawElements(GL_TRIANGLES, renderer.mesh_index_count, GL_UNSIGNED_INT, nullptr);
        }
        else
        {
            glDrawArrays(GL_TRIANGLES, 0, renderer.mesh_vertex_count);
        }
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
        std::unique_lock<std::mutex> lock(renderer.mutex);
        // Redraw only when something changed; the timeout still lets the loop notice a mesh file
        // written by the ArkTS side, so a static scene costs no GPU work instead of a 60 Hz loop.
        renderer.wake.wait_for(lock, std::chrono::milliseconds(RELOAD_POLL_MS), [&renderer] {
            return renderer.dirty || ! renderer.running.load();
        });
        if (! renderer.running.load())
        {
            break;
        }
        if (renderer.display == EGL_NO_DISPLAY || renderer.surface == EGL_NO_SURFACE)
        {
            continue;
        }

        // A worker thread may have finished parsing a new mesh; uploading buffers is render-thread work.
        if (renderer.has_pending)
        {
            renderer.mesh = std::move(renderer.pending_mesh);
            renderer.mesh_stamp = renderer.pending_stamp;
            renderer.has_pending = false;
            uploadMesh(renderer);
            renderer.dirty = true;
            writeRenderLog("mesh applied: vertices=" + std::to_string(renderer.mesh_vertex_count)
                           + " indexed=" + (renderer.mesh_indexed ? "yes" : "no")
                           + " indices=" + std::to_string(renderer.mesh_index_count));
        }

        reloadPlateIfChanged(renderer);
        reloadMeshIfChanged(renderer);
        if (! renderer.dirty)
        {
            continue;
        }

        renderFrame(renderer);
        renderer.dirty = false;
        if (first_frame)
        {
            writeRenderLog("first frame drawn, viewport=" + std::to_string(renderer.surface_width) + "x" + std::to_string(renderer.surface_height));
            first_frame = false;
        }
    }
}

void destroyEgl(Renderer &renderer);

bool initEgl(Renderer &renderer, void *window)
{
    // Make init idempotent: a re-created surface must not leak the previous EGL objects.
    destroyEgl(renderer);
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
    // Resolve the uniforms once instead of every frame.
    renderer.mesh_mvp_location = glGetUniformLocation(renderer.mesh_program, "uMvp");
    renderer.mesh_color_location = glGetUniformLocation(renderer.mesh_program, "uColor");
    renderer.line_mvp_location = glGetUniformLocation(renderer.line_program, "uMvp");
    renderer.line_color_location = glGetUniformLocation(renderer.line_program, "uColor");

    readPlateSize(renderer);
    buildGrid(renderer);
    // The mesh is parsed on a worker thread; the render loop applies it when ready, so a large model
    // cannot delay the first frame. Only the plate is drawn until then.
    startMeshParse(renderer, meshPath(), fileStamp(meshPath()));
    renderer.distance = defaultCameraDistance(renderer);
    renderer.plate_stamp = fileStamp(plateSizePath());
    renderer.dirty = true;
    writeRenderLog("prepared: grid vertices=" + std::to_string(renderer.grid_vertex_count) + ", mesh parsing async");

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

    // A re-created surface can arrive while the previous render thread is still alive. Stop it
    // first: assigning over a joinable std::thread would call std::terminate and kill the app.
    renderer.running.store(false);
    renderer.wake.notify_all();
    if (renderer.thread.joinable())
    {
        renderer.thread.join();
    }
    if (renderer.parse_thread.joinable())
    {
        // The worker only touches CPU memory and the pending slot, so it can be reaped here.
        renderer.parse_thread.join();
    }

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
        renderer.dirty = true;
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
    renderer.dirty = true;
    renderer.wake.notify_one();
}

void OnSurfaceDestroyed(OH_NativeXComponent *component, void *window)
{
    (void)component;
    (void)window;
    OH_LOG_INFO(LOG_APP, "%{public}s: surface destroyed", LOG_TAG);
    Renderer &renderer = g_renderer;
    renderer.running.store(false);
    renderer.wake.notify_all();
    if (renderer.thread.joinable())
    {
        renderer.thread.join();
    }
    if (renderer.parse_thread.joinable())
    {
        renderer.parse_thread.join();
    }
    std::lock_guard<std::mutex> lock(renderer.mutex);
    destroyEgl(renderer);
}

// Drags the model across the build plate. Screen pixels are converted to millimetres at the pivot
// distance and mapped through the camera's screen axes projected onto the Z = 0 plate, so the model
// follows the drag direction.
void moveModelOnPlate(Renderer &renderer, const float screen_dx, const float screen_dy)
{
    const float fov_y = 0.9F;
    const float world_per_pixel = renderer.surface_height > 0
        ? (2.0F * renderer.distance * std::tan(fov_y * 0.5F)) / static_cast<float>(renderer.surface_height)
        : 0.0F;

    const float yaw = renderer.yaw_degrees * 3.14159265F / 180.0F;
    const float pitch = renderer.pitch_degrees * 3.14159265F / 180.0F;
    const Vec3 eye{
        renderer.target.x + renderer.distance * std::cos(pitch) * std::sin(yaw),
        renderer.target.y + renderer.distance * std::cos(pitch) * std::cos(yaw),
        renderer.target.z + renderer.distance * std::sin(pitch),
    };
    const Vec3 forward = normalize(renderer.target - eye);
    const Vec3 right = normalize(cross(forward, Vec3{ 0.0F, 0.0F, 1.0F }));
    const Vec3 up = cross(right, forward);

    const Vec3 right_plate = normalize(Vec3{ right.x, right.y, 0.0F });
    const Vec3 up_plate = normalize(Vec3{ up.x, up.y, 0.0F });
    const Vec3 move = right_plate * (screen_dx * world_per_pixel) + up_plate * (-screen_dy * world_per_pixel);

    // Keep the model within the configured build plate.
    const float limit_x = renderer.plate_width * 0.5F;
    const float limit_y = renderer.plate_depth * 0.5F;
    renderer.plate_offset.x = std::fmax(-limit_x, std::fmin(limit_x, renderer.plate_offset.x + move.x));
    renderer.plate_offset.y = std::fmax(-limit_y, std::fmin(limit_y, renderer.plate_offset.y + move.y));
    renderer.plate_offset.z = 0.0F;
}

// The move/orbit toggle lives in the ArkTS layer, which cannot call into this library directly (the
// XComponent loads it), so the choice is exchanged through a tiny sandbox file. It is read once per
// gesture, when the pointer goes down.
bool readTranslateMode()
{
    FILE *file = std::fopen(viewModePath().c_str(), "rb");
    if (file == nullptr)
    {
        return false;
    }
    char buffer[16] = {};
    const size_t read = std::fread(buffer, 1, sizeof(buffer) - 1, file);
    std::fclose(file);
    return read > 0 && std::strncmp(buffer, "translate", 9) == 0;
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

    // Any interaction changes the camera or the model position, so the next frame must be redrawn.
    // The render thread is parked on the condition variable: marking dirty alone is not enough, it
    // must be woken or the redraw waits for the 300 ms poll timeout (which looks like lag).
    renderer.dirty = true;
    renderer.wake.notify_one();

    if (touch_event.type == OH_NativeXComponent_TouchEventType::OH_NATIVEXCOMPONENT_DOWN)
    {
        renderer.translate_mode = readTranslateMode();
    }

    const float x = touch_event.x;
    const float y = touch_event.y;

    if (touch_event.numPoints >= 2)
    {
        const float x0 = touch_event.touchPoints[0].x;
        const float y0 = touch_event.touchPoints[0].y;
        const float x1 = touch_event.touchPoints[1].x;
        const float y1 = touch_event.touchPoints[1].y;
        const float dx = x0 - x1;
        const float dy = y0 - y1;
        const float pinch = std::sqrt(dx * dx + dy * dy);
        const float center_x = (x0 + x1) * 0.5F;
        const float center_y = (y0 + y1) * 0.5F;
        if (renderer.last_pinch_distance > 0.0F && pinch > 0.0F)
        {
            const float ratio = renderer.last_pinch_distance / pinch;
            renderer.distance = std::fmax(40.0F, std::fmin(900.0F, renderer.distance * ratio));
            // Two-finger drag (centroid movement) slides the model across the build plate.
            moveModelOnPlate(renderer, center_x - renderer.last_center_x, center_y - renderer.last_center_y);
        }
        renderer.last_pinch_distance = pinch;
        renderer.last_center_x = center_x;
        renderer.last_center_y = center_y;
        renderer.last_touch_x = x;
        renderer.last_touch_y = y;
        return;
    }

    renderer.last_pinch_distance = 0.0F;

    if (touch_event.type == OH_NativeXComponent_TouchEventType::OH_NATIVEXCOMPONENT_MOVE)
    {
        const float delta_x = x - renderer.last_touch_x;
        const float delta_y = y - renderer.last_touch_y;
        if (renderer.translate_mode)
        {
            moveModelOnPlate(renderer, delta_x, delta_y);
        }
        else
        {
            renderer.yaw_degrees -= delta_x * 0.18F;
            renderer.pitch_degrees = std::fmax(-85.0F, std::fmin(85.0F, renderer.pitch_degrees + delta_y * 0.18F));
        }
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
