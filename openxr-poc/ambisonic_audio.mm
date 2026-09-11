#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMedia/CoreMedia.h>

#include "ambisonic_audio.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

@interface GAVAmbisonicState : NSObject
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioEnvironmentNode *environment;
@property(nonatomic, strong) NSArray<AVAudioPlayerNode *> *players;
@property(nonatomic, strong) NSArray<AVAudioFile *> *files;
@property(nonatomic, copy) NSString *sourcePath;
@end

@implementation GAVAmbisonicState
@end

struct GAVAmbisonicAudio {
    void *retainedState{nullptr};
};

namespace {

static constexpr NSUInteger kSpeakerCount = 6;

enum SpeakerIndex : NSUInteger {
    SpeakerFront = 0,
    SpeakerBack = 1,
    SpeakerLeft = 2,
    SpeakerRight = 3,
    SpeakerUp = 4,
    SpeakerDown = 5,
};

GAVAmbisonicState *stateFor(GAVAmbisonicAudio *audio)
{
    return audio && audio->retainedState
        ? (__bridge GAVAmbisonicState *)audio->retainedState
        : nil;
}

AudioDeviceID findPSVR2AudioDevice()
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
        return kAudioObjectUnknown;
    }

    std::vector<AudioDeviceID> devices(dataSize / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &devicesAddress,
                                   0,
                                   nullptr,
                                   &dataSize,
                                   devices.data()) != noErr) {
        return kAudioObjectUnknown;
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
        const BOOL match =
            [nameString rangeOfString:@"PS VR2" options:NSCaseInsensitiveSearch].location != NSNotFound;
        CFRelease(name);
        if (match) {
            return deviceId;
        }
    }
    return kAudioObjectUnknown;
}

bool routeEngineToPSVR2(AVAudioEngine *engine)
{
    const AudioDeviceID deviceId = findPSVR2AudioDevice();
    if (deviceId == kAudioObjectUnknown) {
        std::fprintf(stderr, "[audio] ambisonic renderer: PS VR2 audio device not found\n");
        return false;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AudioUnit outputUnit = engine.outputNode.audioUnit;
#pragma clang diagnostic pop
    if (!outputUnit) {
        std::fprintf(stderr, "[audio] ambisonic renderer: AVAudioEngine has no output AudioUnit\n");
        return false;
    }

    AudioDeviceID mutableDeviceId = deviceId;
    const OSStatus status = AudioUnitSetProperty(outputUnit,
                                                  kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global,
                                                  0,
                                                  &mutableDeviceId,
                                                  sizeof(mutableDeviceId));
    if (status != noErr) {
        std::fprintf(stderr,
                     "[audio] ambisonic renderer: could not select PS VR2 output (OSStatus %d)\n",
                     static_cast<int>(status));
        return false;
    }
    return true;
}

NSArray<NSString *> *speakerCachePaths(NSString *sidecarPath)
{
    NSString *base = [sidecarPath stringByDeletingPathExtension];
    return @[
        [base stringByAppendingString:@".gav-foa-front.wav"],
        [base stringByAppendingString:@".gav-foa-back.wav"],
        [base stringByAppendingString:@".gav-foa-left.wav"],
        [base stringByAppendingString:@".gav-foa-right.wav"],
        [base stringByAppendingString:@".gav-foa-up.wav"],
        [base stringByAppendingString:@".gav-foa-down.wav"],
    ];
}

bool haveSpeakerCache(NSArray<NSString *> *paths)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in paths) {
        if (![fm fileExistsAtPath:path]) {
            return false;
        }
    }
    return true;
}

bool buildSpeakerCache(NSString *sidecarPath, NSArray<NSString *> *paths)
{
    if (haveSpeakerCache(paths)) {
        std::printf("[audio] ambisonic decode cache hit\n");
        return true;
    }

    // YouTube's ambisonics_quad is first-order AmbiX: ACN channel order
    // W, Y, Z, X with SN3D normalization. Decode it to six cardinal virtual
    // speakers. AVAudioEnvironmentNode then HRTF-renders those mono feeds.
    // The 0.408/0.707 coefficients form a simple energy-balanced first-order
    // decoder suitable for this proof-of-concept.
    NSString *filter = @"[0:a:0]asplit=6[a0][a1][a2][a3][a4][a5];[a0]pan=mono|c0=0.4082482905*c0+0.7071067812*c3[front];[a1]pan=mono|c0=0.4082482905*c0-0.7071067812*c3[back];[a2]pan=mono|c0=0.4082482905*c0+0.7071067812*c1[left];[a3]pan=mono|c0=0.4082482905*c0-0.7071067812*c1[right];[a4]pan=mono|c0=0.4082482905*c0+0.7071067812*c2[up];[a5]pan=mono|c0=0.4082482905*c0-0.7071067812*c2[down]";

    NSArray<NSString *> *labels = @[@"[front]", @"[back]", @"[left]", @"[right]", @"[up]", @"[down]"];
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[
        @"ffmpeg",
        @"-hide_banner",
        @"-loglevel", @"error",
        @"-nostdin",
        @"-y",
        @"-i", sidecarPath,
        @"-filter_complex", filter,
    ]];
    for (NSUInteger i = 0; i < kSpeakerCount; ++i) {
        [arguments addObjectsFromArray:@[
            @"-map", labels[i],
            @"-c:a", @"pcm_s16le",
            @"-ar", @"48000",
            paths[i],
        ]];
    }

    std::printf("[audio] decoding AmbiX sidecar to six-speaker HRTF cache...\n");
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithStandardError];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        std::fprintf(stderr,
                     "[audio] could not launch ffmpeg for ambisonic decode: %s\n",
                     launchError.localizedDescription.UTF8String ?: "unknown error");
        return false;
    }
    [task waitUntilExit];
    if (task.terminationStatus != 0 || !haveSpeakerCache(paths)) {
        std::fprintf(stderr,
                     "[audio] ffmpeg ambisonic decode failed (status %d); using stereo fallback\n",
                     task.terminationStatus);
        return false;
    }
    return true;
}

void setDefaultSpeakerPositions(GAVAmbisonicState *state)
{
    NSArray<AVAudioPlayerNode *> *players = state.players;
    players[SpeakerFront].position = AVAudioMake3DPoint(0.0f, 0.0f, -1.0f);
    players[SpeakerBack].position = AVAudioMake3DPoint(0.0f, 0.0f, 1.0f);
    players[SpeakerLeft].position = AVAudioMake3DPoint(-1.0f, 0.0f, 0.0f);
    players[SpeakerRight].position = AVAudioMake3DPoint(1.0f, 0.0f, 0.0f);
    players[SpeakerUp].position = AVAudioMake3DPoint(0.0f, 1.0f, 0.0f);
    players[SpeakerDown].position = AVAudioMake3DPoint(0.0f, -1.0f, 0.0f);
}

void rotateVector(const XrQuaternionf &q,
                  float x, float y, float z,
                  float &outX, float &outY, float &outZ)
{
    const float cx1 = q.y * z - q.z * y;
    const float cy1 = q.z * x - q.x * z;
    const float cz1 = q.x * y - q.y * x;
    const float tx = cx1 + q.w * x;
    const float ty = cy1 + q.w * y;
    const float tz = cz1 + q.w * z;
    const float cx2 = q.y * tz - q.z * ty;
    const float cy2 = q.z * tx - q.x * tz;
    const float cz2 = q.x * ty - q.y * tx;
    outX = x + 2.0f * cx2;
    outY = y + 2.0f * cy2;
    outZ = z + 2.0f * cz2;
}

} // namespace

GAVAmbisonicAudio *gav_ambisonic_create(const char *sidecarPath)
{
    if (!sidecarPath || !*sidecarPath) {
        return nullptr;
    }

    @autoreleasepool {
        NSString *sourcePath = [NSString stringWithUTF8String:sidecarPath];
        if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
            std::fprintf(stderr, "[audio] ambisonic sidecar not found: %s\n", sidecarPath);
            return nullptr;
        }

        NSArray<NSString *> *cachePaths = speakerCachePaths(sourcePath);
        if (!buildSpeakerCache(sourcePath, cachePaths)) {
            return nullptr;
        }

        GAVAmbisonicState *state = [[GAVAmbisonicState alloc] init];
        state.sourcePath = sourcePath;
        state.engine = [[AVAudioEngine alloc] init];
        state.environment = [[AVAudioEnvironmentNode alloc] init];
        [state.engine attachNode:state.environment];
        [state.engine connect:state.environment to:state.engine.mainMixerNode format:nil];
        state.environment.outputType = AVAudioEnvironmentOutputTypeHeadphones;
        state.environment.listenerPosition = AVAudioMake3DPoint(0.0f, 0.0f, 0.0f);

        if (!routeEngineToPSVR2(state.engine)) {
            return nullptr;
        }

        NSMutableArray<AVAudioPlayerNode *> *players = [NSMutableArray arrayWithCapacity:kSpeakerCount];
        NSMutableArray<AVAudioFile *> *files = [NSMutableArray arrayWithCapacity:kSpeakerCount];
        for (NSUInteger i = 0; i < kSpeakerCount; ++i) {
            NSError *fileError = nil;
            AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:cachePaths[i]]
                                                              error:&fileError];
            if (!file || file.processingFormat.channelCount != 1) {
                std::fprintf(stderr,
                             "[audio] could not open mono ambisonic cache %s: %s\n",
                             cachePaths[i].UTF8String,
                             fileError.localizedDescription.UTF8String ?: "invalid mono format");
                return nullptr;
            }

            AVAudioPlayerNode *player = [[AVAudioPlayerNode alloc] init];
            player.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTF;
            player.sourceMode = AVAudio3DMixingSourceModeSpatializeIfMono;
            player.reverbBlend = 0.0f;
            [state.engine attachNode:player];
            [state.engine connect:player to:state.environment format:file.processingFormat];
            [players addObject:player];
            [files addObject:file];
        }
        state.players = players;
        state.files = files;
        setDefaultSpeakerPositions(state);
        state.engine.mainMixerNode.outputVolume = 1.0f;

        [state.engine prepare];
        NSError *engineError = nil;
        if (![state.engine startAndReturnError:&engineError]) {
            std::fprintf(stderr,
                         "[audio] could not start ambisonic AVAudioEngine: %s\n",
                         engineError.localizedDescription.UTF8String ?: "unknown error");
            return nullptr;
        }

        auto *audio = new GAVAmbisonicAudio{};
        audio->retainedState = (__bridge_retained void *)state;
        std::printf("[audio] head-tracked AmbiX enabled (6 virtual speakers, macOS HRTF)\n");
        return audio;
    }
}

void gav_ambisonic_destroy(GAVAmbisonicAudio *audio)
{
    if (!audio) {
        return;
    }
    @autoreleasepool {
        GAVAmbisonicState *state = stateFor(audio);
        for (AVAudioPlayerNode *player in state.players) {
            [player stop];
        }
        [state.engine stop];
        if (audio->retainedState) {
            id releasedState = CFBridgingRelease(audio->retainedState);
            (void)releasedState;
            audio->retainedState = nullptr;
        }
        delete audio;
    }
}

bool gav_ambisonic_schedule(GAVAmbisonicAudio *audio,
                            double mediaTimeSeconds,
                            uint64_t *hostTimeOut)
{
    GAVAmbisonicState *state = stateFor(audio);
    if (!state || state.files.count != kSpeakerCount || state.players.count != kSpeakerCount) {
        return false;
    }

    mediaTimeSeconds = std::max(0.0, mediaTimeSeconds);
    const double sampleRate = state.files[0].processingFormat.sampleRate;
    const AVAudioFramePosition startFrame =
        static_cast<AVAudioFramePosition>(std::llround(mediaTimeSeconds * sampleRate));

    for (NSUInteger i = 0; i < kSpeakerCount; ++i) {
        AVAudioPlayerNode *player = state.players[i];
        AVAudioFile *file = state.files[i];
        [player stop];
        if (startFrame >= file.length) {
            return false;
        }
        const AVAudioFramePosition remaining = file.length - startFrame;
        const AVAudioFrameCount frameCount = static_cast<AVAudioFrameCount>(
            std::min<AVAudioFramePosition>(remaining,
                                           static_cast<AVAudioFramePosition>(UINT32_MAX)));
        [player scheduleSegment:file
                  startingFrame:startFrame
                     frameCount:frameCount
                         atTime:nil
              completionHandler:nil];
    }

    if (!state.engine.isRunning) {
        NSError *error = nil;
        if (![state.engine startAndReturnError:&error]) {
            std::fprintf(stderr,
                         "[audio] failed to restart ambisonic engine: %s\n",
                         error.localizedDescription.UTF8String ?: "unknown error");
            return false;
        }
    }

    const CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    const CMTime start = CMTimeAdd(now, CMTimeMakeWithSeconds(0.100, 1000000000));
    const uint64_t hostTime = CMClockConvertHostTimeToSystemUnits(start);
    AVAudioTime *audioStart = [AVAudioTime timeWithHostTime:hostTime];
    for (AVAudioPlayerNode *player in state.players) {
        [player playAtTime:audioStart];
    }
    if (hostTimeOut) {
        *hostTimeOut = hostTime;
    }
    return true;
}

void gav_ambisonic_pause(GAVAmbisonicAudio *audio)
{
    GAVAmbisonicState *state = stateFor(audio);
    if (!state) {
        return;
    }
    for (AVAudioPlayerNode *player in state.players) {
        [player pause];
    }
}

void gav_ambisonic_set_volume(GAVAmbisonicAudio *audio, float volume)
{
    GAVAmbisonicState *state = stateFor(audio);
    if (!state) {
        return;
    }
    state.engine.mainMixerNode.outputVolume = std::clamp(volume, 0.0f, 1.0f);
}

void gav_ambisonic_set_scene_basis(GAVAmbisonicAudio *audio,
                                   float rightX, float rightY, float rightZ,
                                   float upX, float upY, float upZ,
                                   float forwardX, float forwardY, float forwardZ)
{
    GAVAmbisonicState *state = stateFor(audio);
    if (!state || state.players.count != kSpeakerCount) {
        return;
    }

    state.players[SpeakerFront].position = AVAudioMake3DPoint(forwardX, forwardY, forwardZ);
    state.players[SpeakerBack].position = AVAudioMake3DPoint(-forwardX, -forwardY, -forwardZ);
    state.players[SpeakerLeft].position = AVAudioMake3DPoint(-rightX, -rightY, -rightZ);
    state.players[SpeakerRight].position = AVAudioMake3DPoint(rightX, rightY, rightZ);
    state.players[SpeakerUp].position = AVAudioMake3DPoint(upX, upY, upZ);
    state.players[SpeakerDown].position = AVAudioMake3DPoint(-upX, -upY, -upZ);
}

void gav_ambisonic_set_head_orientation(GAVAmbisonicAudio *audio,
                                        const XrQuaternionf *orientation)
{
    GAVAmbisonicState *state = stateFor(audio);
    if (!state || !orientation) {
        return;
    }

    float fx, fy, fz;
    float ux, uy, uz;
    rotateVector(*orientation, 0.0f, 0.0f, -1.0f, fx, fy, fz);
    rotateVector(*orientation, 0.0f, 1.0f, 0.0f, ux, uy, uz);
    state.environment.listenerVectorOrientation = AVAudioMake3DVectorOrientation(
        AVAudioMake3DVector(fx, fy, fz),
        AVAudioMake3DVector(ux, uy, uz));
}
