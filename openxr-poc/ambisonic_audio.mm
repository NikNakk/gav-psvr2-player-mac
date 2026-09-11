#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMedia/CoreMedia.h>

#include "ambisonic_audio.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

@interface GAVAmbisonicState : NSObject
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioEnvironmentNode *environment;
@property(nonatomic, strong) AVAudioPlayerNode *player;
@property(nonatomic, strong) AVAudioFile *file;
@property(nonatomic, strong) AVAudioFormat *ambisonicFormat;
@property(nonatomic, copy) NSString *sourcePath;
@property(nonatomic, copy) NSString *pcmPath;
@end

@implementation GAVAmbisonicState
@end

struct GAVAmbisonicAudio {
    void *retainedState{nullptr};
    float sceneRight[3]{1.0f, 0.0f, 0.0f};
    float sceneUp[3]{0.0f, 1.0f, 0.0f};
    float sceneForward[3]{0.0f, 0.0f, -1.0f};
    bool sceneBasisValid{false};
    bool traceOrientation{false};
    uint64_t orientationUpdateCount{0};
};

namespace {

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

NSString *nativeCachePath(NSString *sidecarPath)
{
    return [[sidecarPath stringByDeletingPathExtension] stringByAppendingString:@".gav-foa-acn-sn3d.caf"];
}

void removeOldSpeakerCache(NSString *sidecarPath)
{
    NSString *base = [sidecarPath stringByDeletingPathExtension];
    NSArray<NSString *> *suffixes = @[
        @".gav-foa-front.wav",
        @".gav-foa-back.wav",
        @".gav-foa-left.wav",
        @".gav-foa-right.wav",
        @".gav-foa-up.wav",
        @".gav-foa-down.wav",
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *suffix in suffixes) {
        NSString *path = [base stringByAppendingString:suffix];
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:nil];
        }
    }
}

bool buildNativeCache(NSString *sidecarPath, NSString *pcmPath)
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:pcmPath]) {
        std::printf("[audio] native AmbiX decode cache hit\n");
        removeOldSpeakerCache(sidecarPath);
        return true;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = @[
        @"ffmpeg",
        @"-hide_banner",
        @"-loglevel", @"error",
        @"-nostdin",
        @"-y",
        @"-i", sidecarPath,
        @"-map", @"0:a:0",
        @"-c:a", @"pcm_f32le",
        @"-ar", @"48000",
        @"-f", @"caf",
        pcmPath,
    ];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithStandardError];

    std::printf("[audio] decoding AmbiX sidecar to native 4-channel ACN/SN3D cache...\n");
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        std::fprintf(stderr,
                     "[audio] could not launch ffmpeg for AmbiX decode: %s\n",
                     launchError.localizedDescription.UTF8String ?: "unknown error");
        return false;
    }
    [task waitUntilExit];
    if (task.terminationStatus != 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:pcmPath]) {
        std::fprintf(stderr,
                     "[audio] ffmpeg AmbiX decode failed (status %d); using stereo fallback\n",
                     task.terminationStatus);
        return false;
    }

    removeOldSpeakerCache(sidecarPath);
    return true;
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

float dot3(float ax, float ay, float az, const float b[3])
{
    return ax * b[0] + ay * b[1] + az * b[2];
}

void normalize3(float v[3])
{
    const float length = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (length > 1e-6f) {
        v[0] /= length;
        v[1] /= length;
        v[2] /= length;
    }
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

        NSString *pcmPath = nativeCachePath(sourcePath);
        if (!buildNativeCache(sourcePath, pcmPath)) {
            return nullptr;
        }

        NSError *fileError = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:pcmPath]
                                                          error:&fileError];
        if (!file || file.processingFormat.channelCount != 4) {
            std::fprintf(stderr,
                         "[audio] native AmbiX cache is not four-channel: %s\n",
                         fileError.localizedDescription.UTF8String ?: "invalid format");
            return nullptr;
        }

        const AudioChannelLayoutTag hoaTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4;
        AVAudioChannelLayout *hoaLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:hoaTag];
        if (!hoaLayout) {
            std::fprintf(stderr, "[audio] could not create ACN/SN3D FOA channel layout\n");
            return nullptr;
        }

        AVAudioFormat *hoaFormat = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
                      sampleRate:48000.0
                     interleaved:NO
                   channelLayout:hoaLayout];
        if (!hoaFormat || hoaFormat.channelCount != 4) {
            std::fprintf(stderr, "[audio] could not create four-channel FOA processing format\n");
            return nullptr;
        }

        GAVAmbisonicState *state = [[GAVAmbisonicState alloc] init];
        state.sourcePath = sourcePath;
        state.pcmPath = pcmPath;
        state.file = file;
        state.ambisonicFormat = hoaFormat;
        state.engine = [[AVAudioEngine alloc] init];
        state.environment = [[AVAudioEnvironmentNode alloc] init];
        state.player = [[AVAudioPlayerNode alloc] init];

        [state.engine attachNode:state.environment];
        [state.engine attachNode:state.player];
        [state.engine connect:state.player to:state.environment format:hoaFormat];
        [state.engine connect:state.environment to:state.engine.mainMixerNode format:nil];

        state.environment.outputType = AVAudioEnvironmentOutputTypeHeadphones;
        state.environment.listenerPosition = AVAudioMake3DPoint(0.0f, 0.0f, 0.0f);
        state.player.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmAuto;
        state.player.sourceMode = AVAudio3DMixingSourceModeAmbienceBed;
        state.player.reverbBlend = 0.0f;
        state.player.position = AVAudioMake3DPoint(0.0f, 0.0f, -1.0f);
        state.engine.mainMixerNode.outputVolume = 1.0f;

        if (!routeEngineToPSVR2(state.engine)) {
            return nullptr;
        }

        [state.engine prepare];
        NSError *engineError = nil;
        if (![state.engine startAndReturnError:&engineError]) {
            std::fprintf(stderr,
                         "[audio] could not start native Ambisonic AVAudioEngine: %s\n",
                         engineError.localizedDescription.UTF8String ?: "unknown error");
            return nullptr;
        }

        auto *audio = new GAVAmbisonicAudio{};
        audio->retainedState = (__bridge_retained void *)state;
        audio->traceOrientation = std::getenv("GAV_AMBISONIC_TRACE") != nullptr;
        if (audio->traceOrientation) {
            std::fprintf(stderr, "[audio] GAV_AMBISONIC_TRACE enabled\n");
        }
        std::printf("[audio] native head-tracked AmbiX enabled (ACN/SN3D -> Apple binaural renderer)\n");
        return audio;
    }
}

void gav_ambisonic_destroy(GAVAmbisonicAudio *audio)
{
    if (!audio) return;
    @autoreleasepool {
        GAVAmbisonicState *state = stateFor(audio);
        [state.player stop];
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
    if (!state || !state.file || !state.player) return false;

    mediaTimeSeconds = std::max(0.0, mediaTimeSeconds);
    const double sampleRate = state.file.processingFormat.sampleRate;
    const AVAudioFramePosition startFrame =
        static_cast<AVAudioFramePosition>(std::llround(mediaTimeSeconds * sampleRate));

    [state.player stop];
    if (startFrame >= state.file.length) return false;

    const AVAudioFramePosition remaining = state.file.length - startFrame;
    const AVAudioFrameCount frameCount = static_cast<AVAudioFrameCount>(
        std::min<AVAudioFramePosition>(remaining,
                                       static_cast<AVAudioFramePosition>(UINT32_MAX)));
    [state.player scheduleSegment:state.file
                   startingFrame:startFrame
                      frameCount:frameCount
                          atTime:nil
               completionHandler:nil];

    if (!state.engine.isRunning) {
        NSError *error = nil;
        if (![state.engine startAndReturnError:&error]) {
            std::fprintf(stderr,
                         "[audio] failed to restart native Ambisonic engine: %s\n",
                         error.localizedDescription.UTF8String ?: "unknown error");
            return false;
        }
    }

    const CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    const CMTime start = CMTimeAdd(now, CMTimeMakeWithSeconds(0.100, 1000000000));
    const uint64_t hostTime = CMClockConvertHostTimeToSystemUnits(start);
    AVAudioTime *audioStart = [AVAudioTime timeWithHostTime:hostTime];
    [state.player playAtTime:audioStart];

    if (hostTimeOut) *hostTimeOut = hostTime;
    return true;
}

void gav_ambisonic_pause(GAVAmbisonicAudio *audio)
{
    GAVAmbisonicState *state = stateFor(audio);
    if (state) [state.player pause];
}

void gav_ambisonic_set_volume(GAVAmbisonicAudio *audio, float volume)
{
    GAVAmbisonicState *state = stateFor(audio);
    if (state) state.engine.mainMixerNode.outputVolume = std::clamp(volume, 0.0f, 1.0f);
}

void gav_ambisonic_set_scene_basis(GAVAmbisonicAudio *audio,
                                   float rightX, float rightY, float rightZ,
                                   float upX, float upY, float upZ,
                                   float forwardX, float forwardY, float forwardZ)
{
    if (!audio) return;

    audio->sceneRight[0] = rightX;
    audio->sceneRight[1] = rightY;
    audio->sceneRight[2] = rightZ;
    audio->sceneUp[0] = upX;
    audio->sceneUp[1] = upY;
    audio->sceneUp[2] = upZ;
    audio->sceneForward[0] = forwardX;
    audio->sceneForward[1] = forwardY;
    audio->sceneForward[2] = forwardZ;
    normalize3(audio->sceneRight);
    normalize3(audio->sceneUp);
    normalize3(audio->sceneForward);
    audio->sceneBasisValid = true;
}

void gav_ambisonic_set_head_orientation(GAVAmbisonicAudio *audio,
                                        const XrQuaternionf *orientation)
{
    GAVAmbisonicState *state = stateFor(audio);
    if (!state || !orientation) return;

    if (audio->traceOrientation && audio->orientationUpdateCount == 0) {
        std::fprintf(stderr, "[audio] first OpenXR orientation callback received\n");
    }

    float fx, fy, fz;
    float ux, uy, uz;
    rotateVector(*orientation, 0.0f, 0.0f, -1.0f, fx, fy, fz);
    rotateVector(*orientation, 0.0f, 1.0f, 0.0f, ux, uy, uz);

    AVAudio3DVectorOrientation requestedOrientation{};
    if (audio->sceneBasisValid) {
        const float localForwardX = dot3(fx, fy, fz, audio->sceneRight);
        const float localForwardY = dot3(fx, fy, fz, audio->sceneUp);
        const float localForwardZ = -dot3(fx, fy, fz, audio->sceneForward);
        const float localUpX = dot3(ux, uy, uz, audio->sceneRight);
        const float localUpY = dot3(ux, uy, uz, audio->sceneUp);
        const float localUpZ = -dot3(ux, uy, uz, audio->sceneForward);

        requestedOrientation = AVAudioMake3DVectorOrientation(
            AVAudioMake3DVector(localForwardX, localForwardY, localForwardZ),
            AVAudioMake3DVector(localUpX, localUpY, localUpZ));
    } else {
        requestedOrientation = AVAudioMake3DVectorOrientation(
            AVAudioMake3DVector(fx, fy, fz),
            AVAudioMake3DVector(ux, uy, uz));
    }

    state.environment.listenerVectorOrientation = requestedOrientation;
    const AVAudio3DAngularOrientation angular = state.environment.listenerAngularOrientation;
    state.environment.listenerAngularOrientation = angular;

    ++audio->orientationUpdateCount;
    if (audio->traceOrientation && (audio->orientationUpdateCount % 180u) == 1u) {
        std::fprintf(stderr,
                     "[audio] listener pose yaw=%+.1f pitch=%+.1f roll=%+.1f deg\n",
                     angular.yaw,
                     angular.pitch,
                     angular.roll);
    }
}
