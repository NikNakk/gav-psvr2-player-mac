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
    '#import <AVFoundation/AVFoundation.h>\n#import <CoreAudio/CoreAudio.h>\n',
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

# Add CoreAudio device lookup inside the existing anonymous namespace.
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

} // namespace

int main(int argc, const char *argv[])
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
''',
)

path.write_text(source)
