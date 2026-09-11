cmake_minimum_required(VERSION 3.24)

project(gav_monado_poc LANGUAGES C CXX OBJCXX)

if(NOT APPLE)
    message(FATAL_ERROR "gav-monado-poc currently targets macOS only")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(OPENXR_BUILD_DIR "" CACHE PATH "Path to an existing Khronos OpenXR build tree")
set(OPENXR_SDK_SOURCE "" CACHE PATH "Optional path to a Khronos OpenXR-SDK or OpenXR-SDK-Source checkout")

find_package(OpenXR CONFIG QUIET)

if(NOT TARGET OpenXR::openxr_loader AND OPENXR_BUILD_DIR)
    find_path(OPENXR_INCLUDE_DIR
        NAMES openxr/openxr.h
        PATHS "${OPENXR_BUILD_DIR}/include"
        NO_DEFAULT_PATH
    )
    find_library(OPENXR_LOADER_LIBRARY
        NAMES openxr_loader
        PATHS "${OPENXR_BUILD_DIR}/src/loader"
        NO_DEFAULT_PATH
    )

    if(OPENXR_INCLUDE_DIR AND OPENXR_LOADER_LIBRARY)
        add_library(OpenXR::openxr_loader SHARED IMPORTED)
        set_target_properties(OpenXR::openxr_loader PROPERTIES
            IMPORTED_LOCATION "${OPENXR_LOADER_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${OPENXR_INCLUDE_DIR}"
        )
        message(STATUS "Using existing OpenXR build: ${OPENXR_BUILD_DIR}")
    endif()
endif()

if(NOT TARGET OpenXR::openxr_loader AND OPENXR_SDK_SOURCE)
    if(NOT EXISTS "${OPENXR_SDK_SOURCE}/CMakeLists.txt")
        message(FATAL_ERROR
            "OPENXR_SDK_SOURCE='${OPENXR_SDK_SOURCE}' has no top-level CMakeLists.txt. "
            "For the already-working hello_xr build, use -DOPENXR_BUILD_DIR=/private/tmp/OpenXR-SDK-build instead.")
    endif()

    set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(BUILD_CONFORMANCE_TESTS OFF CACHE BOOL "" FORCE)
    set(BUILD_API_LAYERS OFF CACHE BOOL "" FORCE)
    add_subdirectory("${OPENXR_SDK_SOURCE}" "${CMAKE_BINARY_DIR}/openxr-sdk" EXCLUDE_FROM_ALL)
endif()

if(NOT TARGET OpenXR::openxr_loader)
    message(FATAL_ERROR
        "OpenXR loader not found. For this Mac setup use "
        "-DOPENXR_BUILD_DIR=/private/tmp/OpenXR-SDK-build")
endif()

find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)

function(configure_openxr_metal_target target)
    target_compile_definitions(${target} PRIVATE
        XR_USE_GRAPHICS_API_METAL
        XR_EXTENSION_PROTOTYPES
    )

    target_compile_options(${target} PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    )

    target_link_libraries(${target} PRIVATE
        OpenXR::openxr_loader
        ${FOUNDATION_FRAMEWORK}
        ${METAL_FRAMEWORK}
    )
endfunction()

add_executable(gav-monado-poc main.mm)
configure_openxr_metal_target(gav-monado-poc)
target_link_libraries(gav-monado-poc PRIVATE
    ${AVFOUNDATION_FRAMEWORK}
    ${COREVIDEO_FRAMEWORK}
    ${COREMEDIA_FRAMEWORK}
    ${COREGRAPHICS_FRAMEWORK}
    ${QUARTZCORE_FRAMEWORK}
)

add_executable(gav-monado-projection-test projection_test.mm)
configure_openxr_metal_target(gav-monado-projection-test)

add_executable(gav-monado-quad-test quad_test.mm)
configure_openxr_metal_target(gav-monado-quad-test)
