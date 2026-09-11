#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"allow_empty_startup: {message}")


if len(sys.argv) != 2:
    fail("usage: allow_empty_startup.py GENERATED_SOURCE")

path = pathlib.Path(sys.argv[1])
source = path.read_text()


def replace_once(needle: str, replacement: str) -> None:
    global source
    count = source.count(needle)
    if count != 1:
        fail(f"expected exactly one source fragment, found {count}: {needle[:120]!r}")
    source = source.replace(needle, replacement, 1)


# With an in-headset picker there is no reason to require an initial media
# argument. Keep one optional path/URL for the existing direct-launch workflow.
replace_once(
    '''        if (argc != 2) {
            std::fprintf(stderr, "usage: %s /path/to/video-or-url\\n", argv[0]);
            return 2;
        }
''',
    '''        if (argc > 2) {
            std::fprintf(stderr, "usage: %s [video-or-url]\\n", argv[0]);
            return 2;
        }
''',
)

# Make the initial media resolution optional. Runtime file selection already
# replaces AVPlayerItem/AVPlayerItemVideoOutput without touching OpenXR.
replace_once(
    '''            const GAVResolvedMediaInput resolvedInput = gav_resolve_media_input(argv[1]);
            projectionMode = projectionModeFromEnvironment(resolvedInput.path, resolvedInput.youtubeEAC);
            NSString *path = [NSString stringWithUTF8String:resolvedInput.path.c_str()];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                throw std::runtime_error("Video file does not exist");
            }
            NSURL *url = [NSURL fileURLWithPath:path];
''',
    '''            const bool hasInitialMedia = argc == 2;
            GAVResolvedMediaInput resolvedInput{};
            NSString *path = nil;
            NSURL *url = nil;
            if (hasInitialMedia) {
                resolvedInput = gav_resolve_media_input(argv[1]);
                projectionMode = projectionModeFromEnvironment(resolvedInput.path, resolvedInput.youtubeEAC);
                path = [NSString stringWithUTF8String:resolvedInput.path.c_str()];
                if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    throw std::runtime_error("Video file does not exist");
                }
                url = [NSURL fileURLWithPath:path];
            }
''',
)

replace_once(
    '''            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (!videoTrack) throw std::runtime_error("Input has no video track");
            const CGSize videoSize = orientedVideoSize(videoTrack);
            const double aspect = static_cast<double>(videoSize.width) /
                                  std::max(1.0, static_cast<double>(videoSize.height));

            AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
''',
    '''            AVURLAsset *asset = nil;
            AVAssetTrack *videoTrack = nil;
            CGSize videoSize = CGSizeMake(16.0, 9.0);
            double aspect = 16.0 / 9.0;
            if (url) {
                asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
                videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
                if (!videoTrack) throw std::runtime_error("Input has no video track");
                videoSize = orientedVideoSize(videoTrack);
                aspect = static_cast<double>(videoSize.width) /
                         std::max(1.0, static_cast<double>(videoSize.height));
            }

            AVPlayerItem *playerItem = asset ? [AVPlayerItem playerItemWithAsset:asset] : nil;
''',
)

replace_once(
    '''            [playerItem addOutput:videoOutput];
''',
    '''            if (playerItem) [playerItem addOutput:videoOutput];
''',
)

# Avoid asking a nil AVPlayerItem for a structure-valued duration.
replace_once(
    '''                double uiDuration = CMTimeGetSeconds(playerItem.duration);
''',
    '''                double uiDuration = playerItem ? CMTimeGetSeconds(playerItem.duration) : 0.0;
''',
)

# The UI helper already contains all picker navigation. Drive its public
# controller interface once at startup to open Files automatically when no
# media argument was supplied: Menu -> select Files -> Cross.
replace_once(
    '''            uiOverlay = gav_ui_create(device, currentMediaPath.c_str());

            auto openMedia = [&](const char *input) -> bool {
''',
    '''            uiOverlay = gav_ui_create(device, currentMediaPath.c_str());
            if (!hasInitialMedia && uiOverlay) {
                GAVUIAction startupAction{};
                GAVControllerSnapshot startupControls{};
                startupControls.uiToggle = 1;
                gav_ui_process_controller(uiOverlay, &startupControls, &startupAction);
                startupControls = {};
                startupControls.uiNavX = -1;
                gav_ui_process_controller(uiOverlay, &startupControls, &startupAction);
                startupControls = {};
                startupControls.uiSelect = 1;
                gav_ui_process_controller(uiOverlay, &startupControls, &startupAction);
                std::printf("[ui] no startup media; file picker opened\\n");
            }

            auto openMedia = [&](const char *input) -> bool {
''',
)

path.write_text(source)
