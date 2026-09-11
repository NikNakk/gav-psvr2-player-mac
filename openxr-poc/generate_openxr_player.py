#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"generate_openxr_player: {message}")


if len(sys.argv) != 3:
    fail("usage: generate_openxr_player.py INPUT OUTPUT")

input_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
source = input_path.read_text()


def replace_once(needle: str, replacement: str) -> None:
    global source
    count = source.count(needle)
    if count != 1:
        fail(f"expected exactly one source fragment, found {count}: {needle[:100]!r}")
    source = source.replace(needle, replacement, 1)


replace_once(
    '#include <openxr/openxr_platform.h>\n',
    '#include <openxr/openxr_platform.h>\n\n#include "controller_input.h"\n#include "media_input.h"\n',
)

replace_once(
    '''enum ProjectionMode {
    ProjectionFlat = 0,
    ProjectionVR180Equirect = 1,
    ProjectionVR180Fisheye = 2,
};

ProjectionMode projectionModeFromEnvironment()
{
    const char *value = std::getenv("GAV_MONADO_PROJECTION");
    if (!value || !*value || std::strcmp(value, "vr180") == 0 ||
        std::strcmp(value, "equirect") == 0 || std::strcmp(value, "180") == 0) {
        return ProjectionVR180Equirect;
    }
    if (std::strcmp(value, "flat") == 0) {
        return ProjectionFlat;
    }
    if (std::strcmp(value, "fisheye") == 0) {
        return ProjectionVR180Fisheye;
    }
    std::fprintf(stderr,
                 "Unknown GAV_MONADO_PROJECTION='%s'; using vr180/equirect. "
                 "Valid values: vr180, equirect, fisheye, flat.\\n",
                 value);
    return ProjectionVR180Equirect;
}

const char *projectionModeName(ProjectionMode mode)
{
    switch (mode) {
        case ProjectionFlat: return "flat virtual screen";
        case ProjectionVR180Equirect: return "SBS VR180 half-equirectangular";
        case ProjectionVR180Fisheye: return "SBS VR180 equidistant fisheye";
        default: return "unknown";
    }
}
''',
    '''enum ProjectionMode {
    ProjectionFlat = 0,
    ProjectionVR180Equirect = 1,
    ProjectionVR180Fisheye = 2,
    ProjectionEAC360 = 3,
};

ProjectionMode projectionModeFromEnvironment(const std::string &path, bool youtubeEAC)
{
    const char *value = std::getenv("GAV_MONADO_PROJECTION");
    if (value && *value) {
        if (std::strcmp(value, "vr180") == 0 || std::strcmp(value, "equirect") == 0 ||
            std::strcmp(value, "180") == 0) {
            return ProjectionVR180Equirect;
        }
        if (std::strcmp(value, "flat") == 0) {
            return ProjectionFlat;
        }
        if (std::strcmp(value, "fisheye") == 0) {
            return ProjectionVR180Fisheye;
        }
        if (std::strcmp(value, "eac") == 0 || std::strcmp(value, "eac360") == 0 ||
            std::strcmp(value, "youtube360") == 0) {
            return ProjectionEAC360;
        }
        std::fprintf(stderr,
                     "Unknown GAV_MONADO_PROJECTION='%s'; using automatic detection. "
                     "Valid values: vr180, equirect, fisheye, eac360, flat.\\n",
                     value);
    }

    if (youtubeEAC || path.find("EAC360") != std::string::npos ||
        path.find("eac360") != std::string::npos) {
        return ProjectionEAC360;
    }
    return ProjectionVR180Equirect;
}

const char *projectionModeName(ProjectionMode mode)
{
    switch (mode) {
        case ProjectionFlat: return "flat virtual screen";
        case ProjectionVR180Equirect: return "SBS VR180 half-equirectangular";
        case ProjectionVR180Fisheye: return "SBS VR180 equidistant fisheye";
        case ProjectionEAC360: return "YouTube EAC 360";
        default: return "unknown";
    }
}
''',
)

replace_once(
    '''struct ScreenAnchor {
    bool valid{false};
    simd_float3 center{};
    simd_float3 right{};
    simd_float3 up{};
    simd_float3 normal{};
};

struct ScreenUniforms {
''',
    '''struct ScreenAnchor {
    bool valid{false};
    simd_float3 center{};
    simd_float3 right{};
    simd_float3 up{};
    simd_float3 normal{};
};

simd_float3 rotateAroundAxis(simd_float3 v, simd_float3 axis, float radians)
{
    axis = simd_normalize(axis);
    const float c = std::cos(radians);
    const float s = std::sin(radians);
    return v * c + simd_cross(axis, v) * s + axis * simd_dot(axis, v) * (1.0f - c);
}

void tiltAnchor(ScreenAnchor &anchor, float yawRadians, float pitchRadians)
{
    if (!anchor.valid) {
        return;
    }
    if (std::fabs(yawRadians) > 1e-6f) {
        anchor.right = simd_normalize(rotateAroundAxis(anchor.right, anchor.up, yawRadians));
        anchor.normal = simd_normalize(rotateAroundAxis(anchor.normal, anchor.up, yawRadians));
    }
    if (std::fabs(pitchRadians) > 1e-6f) {
        anchor.up = simd_normalize(rotateAroundAxis(anchor.up, anchor.right, pitchRadians));
        anchor.normal = simd_normalize(rotateAroundAxis(anchor.normal, anchor.right, pitchRadians));
    }
}

struct ScreenUniforms {
''',
)

replace_once(
    'fragment float4 videoFragment(VertexOut in [[stage_in]],\n',
    '''// YouTube/FFmpeg Equi-Angular Cubemap (EAC), 3x2 layout.
// Face packing matches FFmpeg v360 prepare_eac_in():
//   top:    LEFT | FRONT | RIGHT
//   bottom: DOWN | BACK  | UP
static float2 projectEAC(float3 w)
{
    // GAV convention: x-right, y-up, -z-forward. Convert to FFmpeg's
    // x-right, y-down, +z-forward cubemap convention first.
    float3 p = float3(w.x, -w.y, -w.z);
    float ax = fabs(p.x), ay = fabs(p.y), az = fabs(p.z);

    float uf = 0.0, vf = 0.0;
    int col = 1, row = 0;
    int rotation = 0;

    if (ax >= ay && ax >= az) {
        if (p.x >= 0.0) {
            uf = -p.z / p.x;
            vf = p.y / p.x;
            col = 2; row = 0;
        } else {
            uf = -p.z / p.x;
            vf = -p.y / p.x;
            col = 0; row = 0;
        }
    } else if (ay >= ax && ay >= az) {
        if (p.y >= 0.0) {
            uf = p.x / p.y;
            vf = -p.z / p.y;
            col = 0; row = 1; rotation = 3;
        } else {
            uf = -p.x / p.y;
            vf = -p.z / p.y;
            col = 2; row = 1; rotation = 3;
        }
    } else {
        if (p.z >= 0.0) {
            uf = p.x / p.z;
            vf = p.y / p.z;
            col = 1; row = 0;
        } else {
            uf = p.x / p.z;
            vf = -p.y / p.z;
            col = 1; row = 1; rotation = 1;
        }
    }

    if (rotation == 1) {
        float t = uf; uf = -vf; vf = t;
    } else if (rotation == 3) {
        float t = -uf; uf = vf; vf = t;
    }

    uf = (2.0 / PI) * atan(uf) + 0.5;
    vf = (2.0 / PI) * atan(vf) + 0.5;
    return float2((uf + float(col)) / 3.0,
                  (vf + float(row)) / 2.0);
}

fragment float4 videoFragment(VertexOut in [[stage_in]],
''',
)

replace_once(
    '    if (projectionMode == 1 || projectionMode == 2) {\n',
    '    if (projectionMode == 1 || projectionMode == 2 || projectionMode == 3) {\n',
)

replace_once(
    '''        const float localForward = dot(ray, forward);

        float2 eyeUV;
''',
    '''        const float localForward = dot(ray, forward);

        if (projectionMode == 3) {
            if (testPattern) {
                return float4(1.0, 0.0, 1.0, 1.0);
            }
            // projectEAC expects the existing GAV direction convention, where
            // forward is -Z. EAC is mono, so both OpenXR eyes sample identically.
            const float3 gavDirection = float3(localX, localY, -localForward);
            return video.sample(smp, projectEAC(gavDirection));
        }

        float2 eyeUV;
''',
)

replace_once(
    '            std::fprintf(stderr, "usage: %s /path/to/video\\n", argv[0]);\n',
    '            std::fprintf(stderr, "usage: %s /path/to/video-or-url\\n", argv[0]);\n',
)

replace_once(
    '        const ProjectionMode projectionMode = projectionModeFromEnvironment();\n',
    '        ProjectionMode projectionMode = ProjectionVR180Equirect;\n',
)

replace_once(
    '''        CVMetalTextureCacheRef textureCache = nullptr;
        CVPixelBufferRef currentPixelBuffer = nullptr;
''',
    '''        CVMetalTextureCacheRef textureCache = nullptr;
        CVPixelBufferRef currentPixelBuffer = nullptr;
        GAVControllerInput *controller = nullptr;
''',
)

replace_once(
    '''            NSString *path = [NSString stringWithUTF8String:argv[1]];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                throw std::runtime_error("Video file does not exist");
            }
            NSURL *url = [NSURL fileURLWithPath:path];
''',
    '''            const GAVResolvedMediaInput resolvedInput = gav_resolve_media_input(argv[1]);
            projectionMode = projectionModeFromEnvironment(resolvedInput.path, resolvedInput.youtubeEAC);
            NSString *path = [NSString stringWithUTF8String:resolvedInput.path.c_str()];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                throw std::runtime_error("Video file does not exist");
            }
            NSURL *url = [NSURL fileURLWithPath:path];
''',
)

replace_once(
    '''            if (projectionMode == ProjectionFlat) {
                std::printf("Flat screen: %.2fm x %.2fm, 2.0m ahead of initial gaze\\n",
                            panelWidth, panelHeight);
            } else {
                std::printf("VR180 centre is anchored to initial gaze; left/right SBS halves feed the corresponding eyes.\\n");
            }
''',
    '''            if (projectionMode == ProjectionFlat) {
                std::printf("Flat screen: %.2fm x %.2fm, 2.0m ahead of initial gaze\\n",
                            panelWidth, panelHeight);
            } else if (projectionMode == ProjectionEAC360) {
                std::printf("EAC360 scene is anchored to initial gaze; both OpenXR eyes sample the mono 3x2 cubemap.\\n");
            } else {
                std::printf("VR180 centre is anchored to initial gaze; left/right SBS halves feed the corresponding eyes.\\n");
            }
''',
)

replace_once(
    '            std::printf("Set GAV_MONADO_PROJECTION=flat|vr180|fisheye to select projection.\\n");\n',
    '            std::printf("Set GAV_MONADO_PROJECTION=flat|vr180|fisheye|eac360 to select projection.\\n");\n',
)

replace_once(
    '''            ScreenAnchor anchor{};
            double lastStatusLog = CACurrentMediaTime();

            while (!exitRequested && !gStopRequested.load()) {
''',
    '''            ScreenAnchor anchor{};
            controller = gav_controller_create();
            double lastStatusLog = CACurrentMediaTime();

            while (!exitRequested && !gStopRequested.load()) {
''',
)

replace_once(
    '''                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.0]];
                }

                XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
''',
    '''                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.0]];
                }

                GAVControllerSnapshot controls{};
                gav_controller_poll(controller, &controls);
                if ((controls.togglePlay & 1) != 0 && playerItem.status == AVPlayerItemStatusReadyToPlay) {
                    if (player.rate > 0.0f) {
                        [player pause];
                        std::printf("[controller] pause\\n");
                    } else {
                        [player play];
                        playerStarted = true;
                        std::printf("[controller] play\\n");
                    }
                }
                if (controls.seekSteps != 0 && playerItem.status == AVPlayerItemStatusReadyToPlay) {
                    const double nowSeconds = CMTimeGetSeconds(player.currentTime);
                    const double targetSeconds = std::max(0.0, nowSeconds + 15.0 * controls.seekSteps);
                    const CMTime targetTime = CMTimeMakeWithSeconds(targetSeconds, 600);
                    [player seekToTime:targetTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                    std::printf("[controller] seek %+.0fs\\n", 15.0 * controls.seekSteps);
                }
                if (controls.volumeSteps != 0) {
                    player.volume = std::clamp(player.volume + 0.05f * controls.volumeSteps, 0.0f, 1.0f);
                    std::printf("[controller] volume %.0f%%\\n", player.volume * 100.0f);
                }
                if (controls.recenter != 0) {
                    anchor.valid = false;
                    std::printf("[controller] recenter requested\\n");
                }

                auto stickAfterDeadZone = [](float value) {
                    constexpr float deadZone = 0.18f;
                    if (std::fabs(value) <= deadZone) return 0.0f;
                    const float scaled = (std::fabs(value) - deadZone) / (1.0f - deadZone);
                    return std::copysign(scaled, value);
                };
                const float stickX = stickAfterDeadZone(controls.rightX);
                const float stickY = stickAfterDeadZone(controls.rightY);
                if (anchor.valid && (stickX != 0.0f || stickY != 0.0f)) {
                    const float yaw = stickX * std::fabs(stickX) * 0.010f;
                    const float pitch = -stickY * std::fabs(stickY) * 0.010f;
                    tiltAnchor(anchor, yaw, pitch);
                }

                XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
''',
)

replace_once(
    '''        } catch (const std::exception &error) {
            std::fprintf(stderr, "gav-monado-poc: %s\\n", error.what());
            if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
            if (textureCache) CFRelease(textureCache);
''',
    '''        } catch (const std::exception &error) {
            std::fprintf(stderr, "gav-monado-poc: %s\\n", error.what());
            if (controller) {
                gav_controller_destroy(controller);
                controller = nullptr;
            }
            if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
            if (textureCache) CFRelease(textureCache);
''',
)

replace_once(
    '''        if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
        if (textureCache) CFRelease(textureCache);
''',
    '''        if (controller) gav_controller_destroy(controller);
        if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
        if (textureCache) CFRelease(textureCache);
''',
)

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(source)
