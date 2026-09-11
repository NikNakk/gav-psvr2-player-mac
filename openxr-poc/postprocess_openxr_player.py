#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"postprocess_openxr_player: {message}")


if len(sys.argv) != 2:
    fail("usage: postprocess_openxr_player.py GENERATED_SOURCE")

path = pathlib.Path(sys.argv[1])
source = path.read_text()


def replace_once(needle: str, replacement: str) -> None:
    global source
    count = source.count(needle)
    if count != 1:
        fail(f"expected exactly one source fragment, found {count}: {needle[:100]!r}")
    source = source.replace(needle, replacement, 1)


# Route the AVPlayer itself to the PS VR2 CoreAudio device, matching the
# existing Swift player without changing the system-wide default output.
replace_once(
    '#import <AVFoundation/AVFoundation.h>\n',
    '#import <AVFoundation/AVFoundation.h>\n#import <CoreAudio/CoreAudio.h>\n#import <CoreMedia/CoreMedia.h>\n',
)

replace_once(
    '#include "controller_input.h"\n#include "media_input.h"\n',
    '#include "controller_input.h"\n#include "media_input.h"\n#include "ambisonic_audio.h"\n',
)

# FFmpeg/YouTube EAC has a two-pixel pad around cube-face edges.  The original
# experimental EAC shader got the face order and rotations right but sampled
# each 1/3 x 1/2 cell edge-to-edge, which leaves a visible discontinuity at
# the padded row/face boundaries.  Mirror vf_v360.c xyz_to_eac exactly.
replace_once(
    'static float2 projectEAC(float3 w)\n{',
    'static float2 projectEAC(float3 w, uint textureWidth, uint textureHeight)\n{',
)

replace_once(
    '''    uf = (2.0 / PI) * atan(uf) + 0.5;
    vf = (2.0 / PI) * atan(vf) + 0.5;
    return float2((uf + float(col)) / 3.0,
                  (vf + float(row)) / 2.0);
}''',
    '''    uf = (2.0 / PI) * atan(uf) + 0.5;
    vf = (2.0 / PI) * atan(vf) + 0.5;

    // FFmpeg EAC uses two pixels of padding around face edges (but not
    // between adjacent faces on the same row).  These are the inverse
    // eac_to_xyz formulas used by vf_v360.c::xyz_to_eac.
    const float uPad = 2.0 / float(max(textureWidth, 1u));
    const float vPad = 2.0 / float(max(textureHeight, 1u));
    return float2((uf + float(col)) * (1.0 - 2.0 * uPad) / 3.0 + uPad,
                  vf * (0.5 - 2.0 * vPad) + vPad + 0.5 * float(row));
}''',
)

replace_once(
    'return video.sample(smp, projectEAC(gavDirection));',
    'return video.sample(smp, projectEAC(gavDirection, video.get_width(), video.get_height()));',
)

# Add CoreAudio device lookup and the common-host-time synchronization helper
# inside the existing anonymous namespace.
replace_once(
    '''} // namespace

int main(int argc, const char *argv[])
''',
    '''bool routeAudioToPSVR2(AVPlayer *player)
{
    AudioObjectPropertyAddress devicesAddress{
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 dataSize = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                       &devicesAddress,
                                       0,
                                       nullptr,
                                       &dataSize) != noErr) {
        std::fprintf(stderr, "[audio] could not enumerate CoreAudio devices\\n");
        return false;
    }

    const size_t count = dataSize / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> devices(count);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &devicesAddress,
                                   0,
                                   nullptr,
                                   &dataSize,
                                   devices.data()) != noErr) {
        std::fprintf(stderr, "[audio] could not read CoreAudio device list\\n");
        return false;
    }

    for (AudioDeviceID deviceId : devices) {
        AudioObjectPropertyAddress nameAddress{
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        CFStringRef name = nullptr;
        UInt32 nameSize = sizeof(name);
        if (AudioObjectGetPropertyData(deviceId,
                                       &nameAddress,
                                       0,
                                       nullptr,
                                       &nameSize,
                                       &name) != noErr || !name) {
            continue;
        }

        NSString *nameString = (__bridge NSString *)name;
        const BOOL isPSVR2 =
            [nameString rangeOfString:@"PS VR2" options:NSCaseInsensitiveSearch].location != NSNotFound;
        const std::string printableName = nameString.UTF8String ?: "PS VR2";
        CFRelease(name);
        if (!isPSVR2) {
            continue;
        }

        AudioObjectPropertyAddress uidAddress{
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        CFStringRef uid = nullptr;
        UInt32 uidSize = sizeof(uid);
        if (AudioObjectGetPropertyData(deviceId,
                                       &uidAddress,
                                       0,
                                       nullptr,
                                       &uidSize,
                                       &uid) != noErr || !uid) {
            std::fprintf(stderr, "[audio] found %s but could not read its device UID\\n",
                         printableName.c_str());
            return false;
        }

        [player setAudioOutputDeviceUniqueID:(__bridge NSString *)uid];
        CFRelease(uid);
        std::printf("[audio] Audio routed to headset: %s\\n", printableName.c_str());
        return true;
    }

    std::fprintf(stderr,
                 "[audio] PS VR2 audio device not found; using current macOS default output\\n");
    return false;
}

bool startSynchronizedAmbisonicPlayback(AVPlayer *player,
                                        GAVAmbisonicAudio *ambisonic,
                                        double mediaTimeSeconds)
{
    uint64_t hostTime = 0;
    if (!gav_ambisonic_schedule(ambisonic, mediaTimeSeconds, &hostTime)) {
        return false;
    }
    const CMTime itemTime = CMTimeMakeWithSeconds(std::max(0.0, mediaTimeSeconds), 600);
    const CMTime hostClockTime = CMClockMakeHostTimeFromSystemUnits(hostTime);
    [player setRate:1.0f time:itemTime atHostTime:hostClockTime];
    return true;
}

} // namespace

int main(int argc, const char *argv[])
''',
)

replace_once(
    '''        CVMetalTextureCacheRef textureCache = nullptr;
        CVPixelBufferRef currentPixelBuffer = nullptr;
        GAVControllerInput *controller = nullptr;
''',
    '''        CVMetalTextureCacheRef textureCache = nullptr;
        CVPixelBufferRef currentPixelBuffer = nullptr;
        GAVControllerInput *controller = nullptr;
        GAVAmbisonicAudio *ambisonic = nullptr;
''',
)

replace_once(
    '''            AVPlayer *player = [AVPlayer playerWithPlayerItem:playerItem];
            player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
            player.automaticallyWaitsToMinimizeStalling = YES;
''',
    '''            AVPlayer *player = [AVPlayer playerWithPlayerItem:playerItem];
            player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
            player.automaticallyWaitsToMinimizeStalling = YES;
            routeAudioToPSVR2(player);

            if (!resolvedInput.ambisonicPath.empty()) {
                ambisonic = gav_ambisonic_create(resolvedInput.ambisonicPath.c_str());
                if (ambisonic) {
                    // The four-channel sidecar becomes the sole audio source.
                    // Disable AVPlayer's stereo track and allow precise external
                    // host-clock synchronization.
                    player.muted = YES;
                    player.automaticallyWaitsToMinimizeStalling = NO;
                    gav_ambisonic_set_volume(ambisonic, player.volume);
                }
            }
''',
)

replace_once(
    '            std::printf("Audio follows the current macOS default output. Ctrl-C exits.\\n");\n',
    '            std::printf("Audio routes to PS VR2; cached AmbiX sidecars use head-tracked macOS HRTF. Ctrl-C exits.\\n");\n',
)

replace_once(
    '''                if ((controls.togglePlay & 1) != 0 && playerItem.status == AVPlayerItemStatusReadyToPlay) {
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
''',
    '''                if ((controls.togglePlay & 1) != 0 && playerItem.status == AVPlayerItemStatusReadyToPlay) {
                    if (player.rate > 0.0f) {
                        [player pause];
                        if (ambisonic) gav_ambisonic_pause(ambisonic);
                        std::printf("[controller] pause\\n");
                    } else {
                        const double resumeSeconds = std::max(0.0, CMTimeGetSeconds(player.currentTime));
                        if (ambisonic) {
                            if (!startSynchronizedAmbisonicPlayback(player, ambisonic, resumeSeconds)) {
                                std::fprintf(stderr, "[audio] ambisonic resume failed; reverting to stereo\\n");
                                gav_ambisonic_destroy(ambisonic);
                                ambisonic = nullptr;
                                player.muted = NO;
                                player.automaticallyWaitsToMinimizeStalling = YES;
                                [player play];
                            }
                        } else {
                            [player play];
                        }
                        playerStarted = true;
                        std::printf("[controller] play\\n");
                    }
                }
                if (controls.seekSteps != 0 && playerItem.status == AVPlayerItemStatusReadyToPlay) {
                    const double nowSeconds = CMTimeGetSeconds(player.currentTime);
                    const double targetSeconds = std::max(0.0, nowSeconds + 15.0 * controls.seekSteps);
                    const CMTime targetTime = CMTimeMakeWithSeconds(targetSeconds, 600);
                    if (ambisonic && player.rate > 0.0f) {
                        if (!startSynchronizedAmbisonicPlayback(player, ambisonic, targetSeconds)) {
                            std::fprintf(stderr, "[audio] ambisonic seek failed; reverting to stereo\\n");
                            gav_ambisonic_destroy(ambisonic);
                            ambisonic = nullptr;
                            player.muted = NO;
                            player.automaticallyWaitsToMinimizeStalling = YES;
                            [player seekToTime:targetTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                            [player play];
                        }
                    } else {
                        [player seekToTime:targetTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                    }
                    std::printf("[controller] seek %+.0fs\\n", 15.0 * controls.seekSteps);
                }
                if (controls.volumeSteps != 0) {
                    player.volume = std::clamp(player.volume + 0.05f * controls.volumeSteps, 0.0f, 1.0f);
                    if (ambisonic) gav_ambisonic_set_volume(ambisonic, player.volume);
                    std::printf("[controller] volume %.0f%%\\n", player.volume * 100.0f);
                }
''',
)

replace_once(
    '''                    tiltAnchor(anchor, yaw, pitch);
                }

                XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
''',
    '''                    tiltAnchor(anchor, yaw, pitch);
                    if (ambisonic) {
                        const simd_float3 forward = -anchor.normal;
                        gav_ambisonic_set_scene_basis(ambisonic,
                                                      anchor.right.x, anchor.right.y, anchor.right.z,
                                                      anchor.up.x, anchor.up.y, anchor.up.z,
                                                      forward.x, forward.y, forward.z);
                    }
                }

                XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
''',
)

replace_once(
    '''                        } else if (changed->state == XR_SESSION_STATE_STOPPING && sessionRunning) {
                            [player pause];
                            checkXr(xrEndSession(session), "xrEndSession");
''',
    '''                        } else if (changed->state == XR_SESSION_STATE_STOPPING && sessionRunning) {
                            [player pause];
                            if (ambisonic) gav_ambisonic_pause(ambisonic);
                            checkXr(xrEndSession(session), "xrEndSession");
''',
)

replace_once(
    '''                if (!playerStarted && playerItem.status == AVPlayerItemStatusReadyToPlay) {
                    [player play];
                    playerStarted = true;
                    std::printf("DIAGNOSTIC: AVPlayerItem ready; playback started.\\n");
                }
''',
    '''                if (!playerStarted && playerItem.status == AVPlayerItemStatusReadyToPlay) {
                    if (ambisonic) {
                        const double startSeconds = std::max(0.0, CMTimeGetSeconds(player.currentTime));
                        if (!startSynchronizedAmbisonicPlayback(player, ambisonic, startSeconds)) {
                            std::fprintf(stderr, "[audio] ambisonic start failed; reverting to stereo\\n");
                            gav_ambisonic_destroy(ambisonic);
                            ambisonic = nullptr;
                            player.muted = NO;
                            player.automaticallyWaitsToMinimizeStalling = YES;
                            [player play];
                        }
                    } else {
                        [player play];
                    }
                    playerStarted = true;
                    std::printf("DIAGNOSTIC: AVPlayerItem ready; playback started.\\n");
                }
''',
)

replace_once(
    '''                const bool poseValid =
                    (viewState.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0 &&
                    (viewState.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0;
''',
    '''                const bool orientationValid =
                    (viewState.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0;
                const bool poseValid =
                    orientationValid &&
                    (viewState.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0;
                if (ambisonic && orientationValid && locatedViewCount == viewCount) {
                    gav_ambisonic_set_head_orientation(ambisonic, &views[0].pose.orientation);
                }
''',
)

replace_once(
    '''                    anchor.normal = -forward;
                    anchor.valid = true;
                    std::printf("DIAGNOSTIC: projection anchored; centre=(%.3f, %.3f, %.3f), forward=(%.3f, %.3f, %.3f)\\n",
''',
    '''                    anchor.normal = -forward;
                    anchor.valid = true;
                    if (ambisonic) {
                        gav_ambisonic_set_scene_basis(ambisonic,
                                                      right.x, right.y, right.z,
                                                      up.x, up.y, up.z,
                                                      forward.x, forward.y, forward.z);
                    }
                    std::printf("DIAGNOSTIC: projection anchored; centre=(%.3f, %.3f, %.3f), forward=(%.3f, %.3f, %.3f)\\n",
''',
)

replace_once(
    '''            [player pause];
        } catch (const std::exception &error) {
''',
    '''            [player pause];
            if (ambisonic) gav_ambisonic_pause(ambisonic);
        } catch (const std::exception &error) {
''',
)

replace_once(
    '''            if (controller) {
                gav_controller_destroy(controller);
                controller = nullptr;
            }
            if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
''',
    '''            if (ambisonic) {
                gav_ambisonic_destroy(ambisonic);
                ambisonic = nullptr;
            }
            if (controller) {
                gav_controller_destroy(controller);
                controller = nullptr;
            }
            if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
''',
)

replace_once(
    '''        if (controller) gav_controller_destroy(controller);
        if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
''',
    '''        if (ambisonic) gav_ambisonic_destroy(ambisonic);
        if (controller) gav_controller_destroy(controller);
        if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
''',
)

path.write_text(source)
