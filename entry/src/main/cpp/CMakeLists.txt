# CuraHarmony native build root.
# Builds CuraEngine (unmodified, from third_party/CuraEngine) as a static library and links it,
# together with the cross-compiled dependencies, into libcuraslicer.so.

cmake_minimum_required(VERSION 3.5.0)
project(CuraHarmony CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(PROJECT_ROOT ${NATIVE_ROOT}/../../../..)
set(TP ${PROJECT_ROOT}/third_party)
set(DEPS ${TP}/deps)
set(CURAENGINE_ROOT ${TP}/CuraEngine)

if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH arm64-v8a)
endif()
set(INSTALL ${TP}/ohos-install/${OHOS_ARCH})

message(STATUS "CuraHarmony native: OHOS_ARCH=${OHOS_ARCH} install=${INSTALL}")

# ---------------------------------------------------------------------------
# Header-only dependencies and in-tree open-source substitutes.
# ---------------------------------------------------------------------------
set(CURA_HARMONY_INCLUDES
        ${DEPS}/compat/include
        ${DEPS}/range-v3/include
        ${DEPS}/rapidjson/include
        ${DEPS}/stb
        ${DEPS}/spdlog/include
        ${DEPS}/boost
        ${DEPS}/wagyu/include
        ${DEPS}/mapbox-geometry/include
        ${DEPS}/clipper/include
        ${DEPS}/scripta/include
        ${DEPS}/zeus_expected/include
        ${DEPS}/cura-formulae-engine/include
        ${INSTALL}/include
)

# ---------------------------------------------------------------------------
# CuraEngine, compiled as a static library (main.cpp excluded).
# ---------------------------------------------------------------------------
file(GLOB_RECURSE CURAENGINE_SOURCES ${CURAENGINE_ROOT}/src/*.cpp)
list(REMOVE_ITEM CURAENGINE_SOURCES ${CURAENGINE_ROOT}/src/main.cpp)

add_library(curaengine STATIC ${CURAENGINE_SOURCES})
target_include_directories(curaengine PUBLIC ${CURAENGINE_ROOT}/include)
target_include_directories(curaengine SYSTEM PUBLIC ${CURA_HARMONY_INCLUDES})
target_compile_definitions(curaengine PUBLIC
        CURA_ENGINE_VERSION="5.14.0-alpha.0"
        CURA_ENGINE_HASH="741be28"
        ENABLE_THREADING
)
target_compile_options(curaengine PRIVATE -O2 -fPIC -Wno-deprecated-declarations -Wno-unused-parameter)

# ---------------------------------------------------------------------------
# Native slice bridge (NAPI module).
# ---------------------------------------------------------------------------
add_library(curaslicer SHARED
        napi_init.cpp
        slicer_bridge.cpp
)
target_include_directories(curaslicer PRIVATE ${NATIVE_ROOT})
target_include_directories(curaslicer SYSTEM PRIVATE ${CURA_HARMONY_INCLUDES} ${CURAENGINE_ROOT}/include)

target_link_libraries(curaslicer PUBLIC
        curaengine
        ${INSTALL}/lib/libclipper.a
        ${INSTALL}/lib/libboost_regex.a
        ${INSTALL}/lib/libpng.a
        ${INSTALL}/lib/libz.a
        ${INSTALL}/lib/libfmt.a
        ${INSTALL}/lib/libtbb.a
        libace_napi.z.so
)
