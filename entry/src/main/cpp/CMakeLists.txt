# CuraHarmony native build root.
# M1: NAPI connectivity stub. CuraEngine + vendored dependencies are added in later steps.

cmake_minimum_required(VERSION 3.5.0)
project(CuraHarmony CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})

add_library(curaslicer SHARED
        napi_init.cpp
)

target_include_directories(curaslicer PRIVATE
        ${NATIVE_ROOT}
)

target_link_libraries(curaslicer PUBLIC libace_napi.z.so)
