cmake_minimum_required(VERSION 3.24)

project(gav_monado_poc LANGUAGES C CXX OBJCXX)

if(NOT APPLE)
    message(FATAL_ERROR "gav-monado-poc currently targets macOS only")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

option(GAV_ENABLE_YTDLP "Enable URL playback through yt-dlp" OFF)

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

find_package(Python3 COMPONENTS Interpreter REQUIRED)

find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(AVFAUDIO_FRAMEWORK AVFAudio REQUIRED)
find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
find_library(COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(CORETEXT_FRAMEWORK CoreText REQUIRED)
find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(GAMECONTROLLER_FRAMEWORK GameController REQUIRED)

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

set(GAV_GENERATED_PLAYER "${CMAKE_CURRENT_BINARY_DIR}/player_projection_features.mm")
add_custom_command(
    OUTPUT "${GAV_GENERATED_PLAYER}"
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/generate_openxr_player.py"
            "${CMAKE_CURRENT_SOURCE_DIR}/player_projection.mm"
            "${GAV_GENERATED_PLAYER}"
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/postprocess_openxr_player.py"
            "${GAV_GENERATED_PLAYER}"
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/add_ui_overlay.py"
            "${GAV_GENERATED_PLAYER}"
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/player_projection.mm"
        "${CMAKE_CURRENT_SOURCE_DIR}/generate_openxr_player.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/postprocess_openxr_player.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/add_ui_overlay.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/ui_overlay.h"
    VERBATIM
)
set_source_files_properties("${GAV_GENERATED_PLAYER}" PROPERTIES GENERATED TRUE)

add_executable(gav-monado-poc
    "${GAV_GENERATED_PLAYER}"
    controller_input.mm
    media_input.mm
    ambisonic_audio.mm
    ui_overlay.mm
)
configure_openxr_metal_target(gav-monado-poc)
target_include_directories(gav-monado-poc PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(gav-monado-poc PRIVATE
    GAV_ENABLE_YTDLP=$<BOOL:${GAV_ENABLE_YTDLP}>
)
target_link_libraries(gav-monado-poc PRIVATE
    ${AVFOUNDATION_FRAMEWORK}
    ${AVFAUDIO_FRAMEWORK}
    ${AUDIOTOOLBOX_FRAMEWORK}
    ${COREAUDIO_FRAMEWORK}
    ${COREVIDEO_FRAMEWORK}
    ${COREMEDIA_FRAMEWORK}
    ${COREGRAPHICS_FRAMEWORK}
    ${CORETEXT_FRAMEWORK}
    ${QUARTZCORE_FRAMEWORK}
    ${GAMECONTROLLER_FRAMEWORK}
)

if(GAV_ENABLE_YTDLP)
    message(STATUS "GAV yt-dlp URL support: enabled (yt-dlp must be available at runtime)")
else()
    message(STATUS "GAV yt-dlp URL support: disabled")
endif()

add_executable(gav-monado-projection-test projection_test.mm)
configure_openxr_metal_target(gav-monado-projection-test)

add_executable(gav-monado-quad-test quad_test.mm)
configure_openxr_metal_target(gav-monado-quad-test)
