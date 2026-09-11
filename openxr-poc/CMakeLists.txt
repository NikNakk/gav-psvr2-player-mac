cmake_minimum_required(VERSION 3.24)

project(gav_monado_poc LANGUAGES C CXX OBJCXX)

if(NOT APPLE)
    message(FATAL_ERROR "gav-monado-poc currently targets macOS only")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(OPENXR_SDK_SOURCE "" CACHE PATH "Path to a Khronos OpenXR-SDK-Source checkout")
if(NOT OPENXR_SDK_SOURCE AND DEFINED ENV{OPENXR_SDK_SOURCE})
    set(OPENXR_SDK_SOURCE "$ENV{OPENXR_SDK_SOURCE}")
endif()

find_package(OpenXR CONFIG QUIET)

if(NOT TARGET OpenXR::openxr_loader)
    if(NOT OPENXR_SDK_SOURCE)
        message(FATAL_ERROR
            "OpenXR loader not found. Re-run CMake with "
            "-DOPENXR_SDK_SOURCE=/path/to/OpenXR-SDK-Source")
    endif()

    set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(BUILD_CONFORMANCE_TESTS OFF CACHE BOOL "" FORCE)
    set(BUILD_API_LAYERS OFF CACHE BOOL "" FORCE)
    add_subdirectory("${OPENXR_SDK_SOURCE}" "${CMAKE_BINARY_DIR}/openxr-sdk" EXCLUDE_FROM_ALL)
endif()

find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)

add_executable(gav-monado-poc main.mm)

target_compile_definitions(gav-monado-poc PRIVATE
    XR_USE_GRAPHICS_API_METAL
    XR_EXTENSION_PROTOTYPES
)

target_compile_options(gav-monado-poc PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
)

target_link_libraries(gav-monado-poc PRIVATE
    OpenXR::openxr_loader
    ${FOUNDATION_FRAMEWORK}
    ${AVFOUNDATION_FRAMEWORK}
    ${COREVIDEO_FRAMEWORK}
    ${COREMEDIA_FRAMEWORK}
    ${COREGRAPHICS_FRAMEWORK}
    ${QUARTZCORE_FRAMEWORK}
    ${METAL_FRAMEWORK}
)
