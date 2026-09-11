#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"async_media_open: {message}")


if len(sys.argv) != 2:
    fail("usage: async_media_open.py GENERATED_SOURCE")

path = pathlib.Path(sys.argv[1])
source = path.read_text()


def replace_once(needle: str, replacement: str) -> None:
    global source
    count = source.count(needle)
    if count != 1:
        fail(f"expected exactly one source fragment, found {count}: {needle[:120]!r}")
    source = source.replace(needle, replacement, 1)


# The loading card paints directly into the existing headset UI texture while
# media resolution/download runs on a worker thread.
replace_once(
    '#include "ui_overlay.h"\n',
    '#include "ui_overlay.h"\n#include "busy_overlay.h"\n',
)

# The resolver thread must outlive the inner playback scope so exception cleanup
# can always join it before destroying helper objects.
replace_once(
    '        GAVUIOverlay *uiOverlay = nullptr;\n',
    '        GAVUIOverlay *uiOverlay = nullptr;\n        std::thread mediaResolveThread;\n',
)

# Replace the synchronous runtime open lambda. AVFoundation/renderer mutation
# remains on the render thread; only gav_resolve_media_input (and therefore
# yt-dlp/ffprobe/ffmpeg discovery/download work) moves to the worker.
open_start = source.find('            auto openMedia = [&](const char *input) -> bool {\n')
if open_start < 0:
    fail("could not locate synchronous openMedia lambda")
open_end_marker = '\n\n            double lastStatusLog = CACurrentMediaTime();'
open_end = source.find(open_end_marker, open_start)
if open_end < 0:
    fail("could not locate end of synchronous openMedia lambda")

async_block = r'''            std::atomic_bool mediaResolveActive{false};
            std::atomic_bool mediaResolveDone{false};
            GAVResolvedMediaInput mediaResolveResult{};
            std::string mediaResolveError;
            std::string mediaBusyTitle;
            std::string mediaBusyDetail;
            double mediaBusyLastDraw = 0.0;

            auto setUIVisible = [&](bool visible) {
                const bool currentlyVisible = gav_ui_visible(uiOverlay) != 0;
                if (currentlyVisible == visible) return;
                GAVControllerSnapshot toggle{};
                GAVUIAction ignored{};
                toggle.uiToggle = 1;
                gav_ui_process_controller(uiOverlay, &toggle, &ignored);
            };

            auto installResolvedMedia = [&](const GAVResolvedMediaInput &nextResolved) -> bool {
                try {
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
                    std::printf("[ui] opened: %s (%.0fx%.0f, %s)\n",
                                currentMediaPath.c_str(),
                                nextSize.width,
                                nextSize.height,
                                projectionModeName(projectionMode));
                    return true;
                } catch (const std::exception &error) {
                    std::fprintf(stderr, "[ui] open failed: %s\n", error.what());
                    return false;
                }
            };

            auto beginOpenMedia = [&](const char *input) -> bool {
                if (!input || !*input || mediaResolveActive.load(std::memory_order_acquire)) {
                    return false;
                }
                if (mediaResolveThread.joinable()) mediaResolveThread.join();

                const std::string request(input);
                const bool remote = request.rfind("http://", 0) == 0 ||
                                    request.rfind("https://", 0) == 0;
                mediaBusyTitle = remote ? "Preparing YouTube video…" : "Opening video…";
                mediaBusyDetail = remote ? "Resolving or downloading with yt-dlp"
                                         : "Loading selected file";
                mediaResolveResult = {};
                mediaResolveError.clear();
                mediaResolveDone.store(false, std::memory_order_release);
                mediaResolveActive.store(true, std::memory_order_release);

                [player pause];
                if (ambisonic) gav_ambisonic_pause(ambisonic);
                setUIVisible(true);
                mediaBusyLastDraw = CACurrentMediaTime();
                gav_busy_overlay_draw(gav_ui_texture(uiOverlay),
                                      mediaBusyTitle.c_str(),
                                      mediaBusyDetail.c_str(),
                                      mediaBusyLastDraw);

                mediaResolveThread = std::thread([&, request]() {
                    @autoreleasepool {
                        try {
                            mediaResolveResult = gav_resolve_media_input(request.c_str());
                        } catch (const std::exception &error) {
                            mediaResolveError = error.what();
                        } catch (...) {
                            mediaResolveError = "Unknown media resolver error";
                        }
                    }
                    mediaResolveDone.store(true, std::memory_order_release);
                });
                return true;
            };'''

source = source[:open_start] + async_block + source[open_end:]

# Poll resolver completion before the normal UI update. This keeps xrWaitFrame /
# rendering running while yt-dlp works and installs AVFoundation state only back
# on the render thread.
ui_update_old = '''                double uiCurrent = CMTimeGetSeconds(player.currentTime);
                double uiDuration = playerItem ? CMTimeGetSeconds(playerItem.duration) : 0.0;
                gav_ui_update(uiOverlay,
                              std::isfinite(uiCurrent) ? uiCurrent : 0.0,
                              std::isfinite(uiDuration) ? uiDuration : 0.0,
                              player.rate > 0.0f ? 1 : 0);
'''
ui_update_new = '''                if (mediaResolveActive.load(std::memory_order_acquire) &&
                    mediaResolveDone.load(std::memory_order_acquire)) {
                    if (mediaResolveThread.joinable()) mediaResolveThread.join();
                    mediaResolveActive.store(false, std::memory_order_release);
                    mediaResolveDone.store(false, std::memory_order_release);

                    bool installed = false;
                    if (mediaResolveError.empty()) {
                        installed = installResolvedMedia(mediaResolveResult);
                    } else {
                        std::fprintf(stderr,
                                     "[ui] media resolve failed: %s\\n",
                                     mediaResolveError.c_str());
                    }

                    if (installed) {
                        setUIVisible(false);
                        uiAnchor.valid = false;
                    }
                }

                if (mediaResolveActive.load(std::memory_order_acquire)) {
                    const double busyNow = CACurrentMediaTime();
                    if (busyNow - mediaBusyLastDraw >= 0.08) {
                        mediaBusyLastDraw = busyNow;
                        gav_busy_overlay_draw(gav_ui_texture(uiOverlay),
                                              mediaBusyTitle.c_str(),
                                              mediaBusyDetail.c_str(),
                                              busyNow);
                    }
                } else {
                    double uiCurrent = CMTimeGetSeconds(player.currentTime);
                    double uiDuration = playerItem ? CMTimeGetSeconds(playerItem.duration) : 0.0;
                    gav_ui_update(uiOverlay,
                                  std::isfinite(uiCurrent) ? uiCurrent : 0.0,
                                  std::isfinite(uiDuration) ? uiDuration : 0.0,
                                  player.rate > 0.0f ? 1 : 0);
                }
'''
replace_once(ui_update_old, ui_update_new)

# While busy, leave the panel visible but do not let UIOverlay redraw its normal
# controls over the animated loading card. Recenter/shoulder controls remain in
# the main player path as before.
replace_once(
    '''                const bool uiWasVisible = gav_ui_visible(uiOverlay) != 0;
                gav_ui_process_controller(uiOverlay, &controls, &uiAction);
                const bool uiIsVisible = gav_ui_visible(uiOverlay) != 0;
''',
    '''                const bool uiWasVisible = gav_ui_visible(uiOverlay) != 0;
                if (!mediaResolveActive.load(std::memory_order_acquire)) {
                    gav_ui_process_controller(uiOverlay, &controls, &uiAction);
                }
                const bool uiIsVisible = gav_ui_visible(uiOverlay) != 0;
''',
)

replace_once(
    '''                } else if (uiAction.type == GAV_UI_ACTION_OPEN_PATH && uiAction.path) {
                    openMedia(uiAction.path);
                }
''',
    '''                } else if (uiAction.type == GAV_UI_ACTION_OPEN_PATH && uiAction.path) {
                    beginOpenMedia(uiAction.path);
                }
''',
)

# Always join the resolver before object teardown. The thread normally finishes
# in-loop, but these paths also cover XR exit or exceptions during a download.
replace_once(
    '''            if (uiOverlay) {
                gav_ui_destroy(uiOverlay);
''',
    '''            if (mediaResolveThread.joinable()) mediaResolveThread.join();
            if (uiOverlay) {
                gav_ui_destroy(uiOverlay);
''',
)
replace_once(
    '''        if (uiOverlay) gav_ui_destroy(uiOverlay);
''',
    '''        if (mediaResolveThread.joinable()) mediaResolveThread.join();
        if (uiOverlay) gav_ui_destroy(uiOverlay);
''',
)

path.write_text(source)
