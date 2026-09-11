#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"add_ui_overlay: {message}")


if len(sys.argv) != 2:
    fail("usage: add_ui_overlay.py GENERATED_SOURCE")

path = pathlib.Path(sys.argv[1])
source = path.read_text()


def replace_once(needle: str, replacement: str) -> None:
    global source
    count = source.count(needle)
    if count != 1:
        fail(f"expected exactly one source fragment, found {count}: {needle[:120]!r}")
    source = source.replace(needle, replacement, 1)


# UI helper is Objective-C++ and exposes the Metal texture plus controller actions.
replace_once(
    '#include "ambisonic_audio.h"\n',
    '#include "ambisonic_audio.h"\n#include "ui_overlay.h"\n',
)

# Add one compact UI state vector to both the host and Metal uniform structs.
replace_once(
    '    simd_float4 screen; // halfWidth, halfHeight, testPattern, projectionMode\n',
    '    simd_float4 screen; // halfWidth, halfHeight, testPattern, projectionMode\n'
    '    simd_float4 ui;     // visible, NDC half-width, NDC half-height, unused\n',
)
replace_once(
    '    float4 screen;\n};\n\nvertex VertexOut videoVertex',
    '    float4 screen;\n'
    '    float4 ui;\n'
    '};\n\nvertex VertexOut videoVertex',
)

# Bind the UI texture as texture(1). It is intentionally composed inside the
# projection eye shader rather than as XrCompositionLayerQuad: the latter is
# still black on the current macOS Monado path.
replace_once(
    '''fragment float4 videoFragment(VertexOut in [[stage_in]],
                              constant ScreenUniforms &uni [[buffer(0)]],
                              texture2d<float> video [[texture(0)]])''',
    '''fragment float4 videoFragment(VertexOut in [[stage_in]],
                              constant ScreenUniforms &uni [[buffer(0)]],
                              texture2d<float> video [[texture(0)]],
                              texture2d<float> uiTexture [[texture(1)]])''',
)

replace_once(
    '''    const int eye = uni.viewPosition.w > 0.5 ? 1 : 0;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
''',
    '''    const int eye = uni.viewPosition.w > 0.5 ? 1 : 0;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    // First UI pass: a comfortable head-locked 2:1 panel. Keeping this inside
    // the known-good projection layer avoids Monado's currently broken general
    // quad-layer path. A later polish pass can give it GAV's world anchor.
    if (uni.ui.x > 0.5) {
        const float halfW = uni.ui.y;
        const float halfH = uni.ui.z;
        if (fabs(in.ndc.x) <= halfW && fabs(in.ndc.y) <= halfH) {
            const float2 uiUV = float2(0.5 + in.ndc.x / (2.0 * halfW),
                                       0.5 - in.ndc.y / (2.0 * halfH));
            return float4(uiTexture.sample(smp, uiUV).rgb, 1.0);
        }
    }
''',
)

# Thread the UI texture and visibility into renderEye.
replace_once(
    '''               id<MTLTexture> target,
               id<MTLTexture> source,
               const XrView &view,''',
    '''               id<MTLTexture> target,
               id<MTLTexture> source,
               id<MTLTexture> uiTexture,
               bool uiVisible,
               const XrView &view,''',
)
replace_once(
    '    if (anchor.valid && (testPattern || source)) {\n',
    '    if (anchor.valid && (testPattern || source || uiVisible)) {\n',
)
replace_once(
    '''        uni.screen = {
            panelWidth * 0.5f,
            panelHeight * 0.5f,
            testPattern ? 1.0f : 0.0f,
            static_cast<float>(projectionMode),
        };
''',
    '''        uni.screen = {
            panelWidth * 0.5f,
            panelHeight * 0.5f,
            testPattern ? 1.0f : 0.0f,
            static_cast<float>(projectionMode),
        };
        uni.ui = {
            uiVisible ? 1.0f : 0.0f,
            0.78f,
            0.39f,
            0.0f,
        };
''',
)
replace_once(
    '''        [encoder setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        if (source) [encoder setFragmentTexture:source atIndex:0];
''',
    '''        [encoder setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        if (source) [encoder setFragmentTexture:source atIndex:0];
        if (uiTexture) [encoder setFragmentTexture:uiTexture atIndex:1];
''',
)

# Lifetime next to the existing controller/Ambisonic helper objects.
replace_once(
    '''        GAVControllerInput *controller = nullptr;
        GAVAmbisonicAudio *ambisonic = nullptr;
''',
    '''        GAVControllerInput *controller = nullptr;
        GAVAmbisonicAudio *ambisonic = nullptr;
        GAVUIOverlay *uiOverlay = nullptr;
''',
)

# Create the UI and a runtime media-replacement lambda after all of the media
# variables and panel dimensions exist. Replacing AVPlayerItem keeps the OpenXR
# session and swapchains alive while changing files.
replace_once(
    '''            ScreenAnchor anchor{};
            controller = gav_controller_create();
            double lastStatusLog = CACurrentMediaTime();
''',
    '''            ScreenAnchor anchor{};
            controller = gav_controller_create();
            std::string currentMediaPath = resolvedInput.path;
            uiOverlay = gav_ui_create(device, currentMediaPath.c_str());

            auto openMedia = [&](const char *input) -> bool {
                if (!input || !*input) return false;
                try {
                    const GAVResolvedMediaInput nextResolved = gav_resolve_media_input(input);
                    NSString *nextPath = [NSString stringWithUTF8String:nextResolved.path.c_str()];
                    if (![[NSFileManager defaultManager] fileExistsAtPath:nextPath]) {
                        throw std::runtime_error("Selected video file does not exist");
                    }
                    NSURL *nextURL = [NSURL fileURLWithPath:nextPath];
                    AVURLAsset *nextAsset = [AVURLAsset URLAssetWithURL:nextURL
                        options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
                    AVAssetTrack *nextTrack = [[nextAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
                    if (!nextTrack) throw std::runtime_error("Selected file has no video track");
                    const CGSize nextSize = orientedVideoSize(nextTrack);
                    const double nextAspect = static_cast<double>(nextSize.width) /
                                              std::max(1.0, static_cast<double>(nextSize.height));

                    AVPlayerItem *nextItem = [AVPlayerItem playerItemWithAsset:nextAsset];
                    AVPlayerItemVideoOutput *nextOutput =
                        [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
                    [nextItem addOutput:nextOutput];

                    [player pause];
                    if (ambisonic) {
                        gav_ambisonic_pause(ambisonic);
                        gav_ambisonic_destroy(ambisonic);
                        ambisonic = nullptr;
                    }
                    player.muted = NO;
                    player.automaticallyWaitsToMinimizeStalling = YES;
                    [player replaceCurrentItemWithPlayerItem:nextItem];
                    playerItem = nextItem;
                    videoOutput = nextOutput;

                    if (!nextResolved.ambisonicPath.empty()) {
                        ambisonic = gav_ambisonic_create(nextResolved.ambisonicPath.c_str());
                        if (ambisonic) {
                            player.muted = YES;
                            player.automaticallyWaitsToMinimizeStalling = NO;
                            gav_ambisonic_set_volume(ambisonic, player.volume);
                        }
                    }

                    if (currentPixelBuffer) {
                        CVPixelBufferRelease(currentPixelBuffer);
                        currentPixelBuffer = nullptr;
                    }
                    projectionMode = projectionModeFromEnvironment(nextResolved.path,
                                                                   nextResolved.youtubeEAC);
                    panelHeight = 1.20f;
                    panelWidth = panelHeight * static_cast<float>(nextAspect);
                    if (panelWidth > 2.40f) {
                        panelWidth = 2.40f;
                        panelHeight = panelWidth / static_cast<float>(nextAspect);
                    }
                    currentMediaPath = nextResolved.path;
                    gav_ui_set_current_path(uiOverlay, currentMediaPath.c_str());
                    playerStarted = false;
                    decodedFrameCount = 0;
                    loggedFirstDecodedFrame = false;
                    anchor.valid = false;
                    std::printf("[ui] opened: %s (%.0fx%.0f, %s)\\n",
                                currentMediaPath.c_str(),
                                nextSize.width,
                                nextSize.height,
                                projectionModeName(projectionMode));
                    return true;
                } catch (const std::exception &error) {
                    std::fprintf(stderr, "[ui] open failed: %s\\n", error.what());
                    return false;
                }
            };

            double lastStatusLog = CACurrentMediaTime();
''',
)

# Feed current playback state into the panel, let the UI consume its controller
# controls, and map D-pad back to the old seek/volume behaviour while hidden.
replace_once(
    '''                GAVControllerSnapshot controls{};
                gav_controller_poll(controller, &controls);
''',
    '''                GAVControllerSnapshot controls{};
                gav_controller_poll(controller, &controls);

                double uiCurrent = CMTimeGetSeconds(player.currentTime);
                double uiDuration = CMTimeGetSeconds(playerItem.duration);
                gav_ui_update(uiOverlay,
                              std::isfinite(uiCurrent) ? uiCurrent : 0.0,
                              std::isfinite(uiDuration) ? uiDuration : 0.0,
                              player.rate > 0.0f ? 1 : 0);

                GAVUIAction uiAction{};
                gav_ui_process_controller(uiOverlay, &controls, &uiAction);
                if (gav_ui_visible(uiOverlay)) {
                    // Cross and D-pad belong to the panel while it is visible.
                    // Shoulder seek and Triangle recenter deliberately remain live.
                    controls.togglePlay = 0;
                    controls.volumeSteps = 0;
                    controls.rightX = 0.0f;
                    controls.rightY = 0.0f;
                } else {
                    // Preserve the POC controls when the UI is hidden.
                    controls.seekSteps += controls.uiNavX;
                    controls.volumeSteps += -controls.uiNavY;
                }

                if (uiAction.type == GAV_UI_ACTION_PLAY_PAUSE) {
                    controls.togglePlay += 1;
                } else if (uiAction.type == GAV_UI_ACTION_RECENTER) {
                    controls.recenter += 1;
                } else if (uiAction.type == GAV_UI_ACTION_OPEN_PATH && uiAction.path) {
                    openMedia(uiAction.path);
                }
''',
)

# Add the UI arguments at the one eye-render call site.
replace_once(
    '''                        renderEye(queue,
                                  pipeline,
                                  target,
                                  source,
                                  views[eye],''',
    '''                        renderEye(queue,
                                  pipeline,
                                  target,
                                  source,
                                  gav_ui_texture(uiOverlay),
                                  gav_ui_visible(uiOverlay) != 0,
                                  views[eye],''',
)

# Destroy UI in both normal and exception cleanup paths. These blocks are the
# final form produced by postprocess_openxr_player.py.
replace_once(
    '''            if (ambisonic) {
                gav_ambisonic_destroy(ambisonic);
                ambisonic = nullptr;
            }
            if (controller) {
''',
    '''            if (uiOverlay) {
                gav_ui_destroy(uiOverlay);
                uiOverlay = nullptr;
            }
            if (ambisonic) {
                gav_ambisonic_destroy(ambisonic);
                ambisonic = nullptr;
            }
            if (controller) {
''',
)
replace_once(
    '''        if (ambisonic) gav_ambisonic_destroy(ambisonic);
        if (controller) gav_controller_destroy(controller);
''',
    '''        if (uiOverlay) gav_ui_destroy(uiOverlay);
        if (ambisonic) gav_ambisonic_destroy(ambisonic);
        if (controller) gav_controller_destroy(controller);
''',
)

path.write_text(source)
