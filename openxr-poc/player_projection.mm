#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

std::atomic_bool gStopRequested{false};

void handleSignal(int)
{
    gStopRequested.store(true);
}

void checkXr(XrResult result, const char *operation)
{
    if (XR_FAILED(result)) {
        char buffer[256];
        std::snprintf(buffer, sizeof(buffer), "%s failed with XrResult %d", operation, static_cast<int>(result));
        throw std::runtime_error(buffer);
    }
}

const char *sessionStateName(XrSessionState state)
{
    switch (state) {
        case XR_SESSION_STATE_UNKNOWN: return "UNKNOWN";
        case XR_SESSION_STATE_IDLE: return "IDLE";
        case XR_SESSION_STATE_READY: return "READY";
        case XR_SESSION_STATE_SYNCHRONIZED: return "SYNCHRONIZED";
        case XR_SESSION_STATE_VISIBLE: return "VISIBLE";
        case XR_SESSION_STATE_FOCUSED: return "FOCUSED";
        case XR_SESSION_STATE_STOPPING: return "STOPPING";
        case XR_SESSION_STATE_LOSS_PENDING: return "LOSS_PENDING";
        case XR_SESSION_STATE_EXITING: return "EXITING";
        default: return "?";
    }
}

bool hasMetalExtension()
{
    uint32_t count = 0;
    checkXr(xrEnumerateInstanceExtensionProperties(nullptr, 0, &count, nullptr),
            "xrEnumerateInstanceExtensionProperties(count)");
    std::vector<XrExtensionProperties> extensions(count);
    for (auto &extension : extensions) {
        extension = {XR_TYPE_EXTENSION_PROPERTIES};
    }
    checkXr(xrEnumerateInstanceExtensionProperties(nullptr, count, &count, extensions.data()),
            "xrEnumerateInstanceExtensionProperties(list)");
    for (const auto &extension : extensions) {
        if (std::strcmp(extension.extensionName, XR_KHR_METAL_ENABLE_EXTENSION_NAME) == 0) {
            return true;
        }
    }
    return false;
}

MTLPixelFormat chooseSwapchainFormat(XrSession session)
{
    uint32_t count = 0;
    checkXr(xrEnumerateSwapchainFormats(session, 0, &count, nullptr),
            "xrEnumerateSwapchainFormats(count)");
    std::vector<int64_t> formats(count);
    checkXr(xrEnumerateSwapchainFormats(session, count, &count, formats.data()),
            "xrEnumerateSwapchainFormats(list)");

    const MTLPixelFormat preferred[] = {
        MTLPixelFormatBGRA8Unorm_sRGB,
        MTLPixelFormatRGBA8Unorm_sRGB,
        MTLPixelFormatBGRA8Unorm,
        MTLPixelFormatRGBA8Unorm,
    };
    for (MTLPixelFormat candidate : preferred) {
        if (std::find(formats.begin(), formats.end(), static_cast<int64_t>(candidate)) != formats.end()) {
            return candidate;
        }
    }
    throw std::runtime_error("No usable 8-bit Metal OpenXR swapchain format");
}

XrEnvironmentBlendMode chooseBlendMode(XrInstance instance, XrSystemId systemId)
{
    uint32_t count = 0;
    checkXr(xrEnumerateEnvironmentBlendModes(instance,
                                              systemId,
                                              XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                              0,
                                              &count,
                                              nullptr),
            "xrEnumerateEnvironmentBlendModes(count)");
    std::vector<XrEnvironmentBlendMode> modes(count);
    checkXr(xrEnumerateEnvironmentBlendModes(instance,
                                              systemId,
                                              XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                              count,
                                              &count,
                                              modes.data()),
            "xrEnumerateEnvironmentBlendModes(list)");
    auto opaque = std::find(modes.begin(), modes.end(), XR_ENVIRONMENT_BLEND_MODE_OPAQUE);
    if (opaque != modes.end()) return *opaque;
    if (modes.empty()) throw std::runtime_error("Runtime exposed no blend mode");
    return modes.front();
}

CGSize orientedVideoSize(AVAssetTrack *track)
{
    const CGRect transformed = CGRectApplyAffineTransform(
        CGRectMake(0.0, 0.0, track.naturalSize.width, track.naturalSize.height),
        track.preferredTransform);
    CGSize result = CGSizeMake(std::fabs(transformed.size.width), std::fabs(transformed.size.height));
    if (result.width < 1.0 || result.height < 1.0) {
        result = CGSizeMake(std::fabs(track.naturalSize.width), std::fabs(track.naturalSize.height));
    }
    return result;
}

void printPixelFormat(OSType format)
{
    char fourcc[5] = {
        static_cast<char>((format >> 24) & 0xff),
        static_cast<char>((format >> 16) & 0xff),
        static_cast<char>((format >> 8) & 0xff),
        static_cast<char>(format & 0xff),
        '\0',
    };
    for (int i = 0; i < 4; ++i) {
        if (fourcc[i] < 32 || fourcc[i] > 126) fourcc[i] = '?';
    }
    std::printf("0x%08x ('%s')", static_cast<unsigned int>(format), fourcc);
}

simd_float3 rotateVector(const XrQuaternionf &q, simd_float3 v)
{
    const simd_float3 qv = {q.x, q.y, q.z};
    return v + 2.0f * simd_cross(qv, simd_cross(qv, v) + q.w * v);
}

struct EyeSwapchain {
    XrSwapchain handle{XR_NULL_HANDLE};
    uint32_t width{0};
    uint32_t height{0};
    std::vector<XrSwapchainImageMetalKHR> images;
};

struct ScreenAnchor {
    bool valid{false};
    simd_float3 center{};
    simd_float3 right{};
    simd_float3 up{};
    simd_float3 normal{};
};

struct ScreenUniforms {
    simd_float4 viewOrientation;
    simd_float4 viewPosition;
    simd_float4 fovTangents;
    simd_float4 panelCenter;
    simd_float4 panelRight;
    simd_float4 panelUp;
    simd_float4 panelNormal;
    simd_float4 screen; // halfWidth, halfHeight, testPattern, unused
};

id<MTLRenderPipelineState> makePipeline(id<MTLDevice> device, MTLPixelFormat targetFormat)
{
    static NSString *shaderSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 ndc;
};

struct ScreenUniforms {
    float4 viewOrientation;
    float4 viewPosition;
    float4 fovTangents;
    float4 panelCenter;
    float4 panelRight;
    float4 panelUp;
    float4 panelNormal;
    float4 screen;
};

vertex VertexOut videoVertex(uint vertexID [[vertex_id]])
{
    const float2 p[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOut out;
    out.position = float4(p[vertexID], 0.0, 1.0);
    out.ndc = p[vertexID];
    return out;
}

static float3 rotateByQuaternion(float3 v, float4 q)
{
    const float3 qv = q.xyz;
    return v + 2.0 * cross(qv, cross(qv, v) + q.w * v);
}

fragment float4 videoFragment(VertexOut in [[stage_in]],
                              constant ScreenUniforms &uni [[buffer(0)]],
                              texture2d<float> video [[texture(0)]])
{
    const float u = (in.ndc.x + 1.0) * 0.5;
    const float v = (in.ndc.y + 1.0) * 0.5;
    const float rayX = mix(uni.fovTangents.x, uni.fovTangents.y, u);
    const float rayY = mix(uni.fovTangents.z, uni.fovTangents.w, v);

    float3 ray = normalize(float3(rayX, rayY, -1.0));
    ray = normalize(rotateByQuaternion(ray, uni.viewOrientation));

    const float3 origin = uni.viewPosition.xyz;
    const float3 center = uni.panelCenter.xyz;
    const float3 normal = uni.panelNormal.xyz;
    const float denom = dot(ray, normal);
    if (fabs(denom) < 1e-6) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    const float distance = dot(center - origin, normal) / denom;
    if (distance <= 0.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    const float3 hitDelta = (origin + ray * distance) - center;
    const float x = dot(hitDelta, uni.panelRight.xyz);
    const float y = dot(hitDelta, uni.panelUp.xyz);
    const float halfWidth = uni.screen.x;
    const float halfHeight = uni.screen.y;
    if (fabs(x) > halfWidth || fabs(y) > halfHeight) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    if (uni.screen.z > 0.5) {
        return float4(1.0, 0.0, 1.0, 1.0);
    }

    const float2 videoUV = float2(0.5 + x / (2.0 * halfWidth),
                                  0.5 - y / (2.0 * halfHeight));
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    return video.sample(smp, videoUV);
}
)METAL";

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:shaderSource options:nil error:&error];
    if (!library) {
        throw std::runtime_error(std::string("Metal shader compilation failed: ") +
                                 (error.localizedDescription.UTF8String ?: "unknown error"));
    }
    id<MTLFunction> vertex = [library newFunctionWithName:@"videoVertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"videoFragment"];
    if (!vertex || !fragment) throw std::runtime_error("Metal shader functions missing");

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertex;
    desc.fragmentFunction = fragment;
    desc.colorAttachments[0].pixelFormat = targetFormat;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) {
        throw std::runtime_error(std::string("Metal pipeline creation failed: ") +
                                 (error.localizedDescription.UTF8String ?: "unknown error"));
    }
    return pipeline;
}

void renderEye(id<MTLCommandQueue> queue,
               id<MTLRenderPipelineState> pipeline,
               id<MTLTexture> target,
               id<MTLTexture> source,
               const XrView &view,
               const ScreenAnchor &anchor,
               float panelWidth,
               float panelHeight,
               bool testPattern)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!cb) throw std::runtime_error("Could not create Metal command buffer");
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass];
    if (!encoder) throw std::runtime_error("Could not create Metal render encoder");

    if (anchor.valid && (testPattern || source)) {
        ScreenUniforms uni{};
        uni.viewOrientation = {
            view.pose.orientation.x,
            view.pose.orientation.y,
            view.pose.orientation.z,
            view.pose.orientation.w,
        };
        uni.viewPosition = {
            view.pose.position.x,
            view.pose.position.y,
            view.pose.position.z,
            0.0f,
        };
        uni.fovTangents = {
            std::tan(view.fov.angleLeft),
            std::tan(view.fov.angleRight),
            std::tan(view.fov.angleDown),
            std::tan(view.fov.angleUp),
        };
        uni.panelCenter = {anchor.center.x, anchor.center.y, anchor.center.z, 0.0f};
        uni.panelRight = {anchor.right.x, anchor.right.y, anchor.right.z, 0.0f};
        uni.panelUp = {anchor.up.x, anchor.up.y, anchor.up.z, 0.0f};
        uni.panelNormal = {anchor.normal.x, anchor.normal.y, anchor.normal.z, 0.0f};
        uni.screen = {panelWidth * 0.5f, panelHeight * 0.5f, testPattern ? 1.0f : 0.0f, 0.0f};

        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        if (source) [encoder setFragmentTexture:source atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }

    [encoder endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) {
        throw std::runtime_error(std::string("Metal render failed: ") +
                                 (cb.error.localizedDescription.UTF8String ?: "unknown error"));
    }
}

} // namespace

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            std::fprintf(stderr, "usage: %s /path/to/video\n", argv[0]);
            return 2;
        }

        std::signal(SIGINT, handleSignal);
        std::signal(SIGTERM, handleSignal);
        const bool testPattern = std::getenv("GAV_MONADO_TEST_PATTERN") != nullptr;

        XrInstance instance = XR_NULL_HANDLE;
        XrSession session = XR_NULL_HANDLE;
        XrSpace localSpace = XR_NULL_HANDLE;
        std::vector<EyeSwapchain> eyeSwapchains;
        CVMetalTextureCacheRef textureCache = nullptr;
        CVPixelBufferRef currentPixelBuffer = nullptr;

        try {
            if (!hasMetalExtension()) {
                throw std::runtime_error("OpenXR runtime does not advertise XR_KHR_metal_enable");
            }

            const char *extensions[] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME};
            XrInstanceCreateInfo instanceInfo{XR_TYPE_INSTANCE_CREATE_INFO};
            std::strncpy(instanceInfo.applicationInfo.applicationName,
                         "GAV Monado Video POC",
                         XR_MAX_APPLICATION_NAME_SIZE - 1);
            instanceInfo.applicationInfo.applicationVersion = 1;
            std::strncpy(instanceInfo.applicationInfo.engineName,
                         "GAV/Monado",
                         XR_MAX_ENGINE_NAME_SIZE - 1);
            instanceInfo.applicationInfo.engineVersion = 1;
            instanceInfo.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;
            instanceInfo.enabledExtensionCount = 1;
            instanceInfo.enabledExtensionNames = extensions;
            checkXr(xrCreateInstance(&instanceInfo, &instance), "xrCreateInstance");

            XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
            systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
            XrSystemId systemId = XR_NULL_SYSTEM_ID;
            checkXr(xrGetSystem(instance, &systemInfo, &systemId), "xrGetSystem");

            XrSystemProperties systemProperties{XR_TYPE_SYSTEM_PROPERTIES};
            checkXr(xrGetSystemProperties(instance, systemId, &systemProperties), "xrGetSystemProperties");

            PFN_xrGetMetalGraphicsRequirementsKHR getMetalRequirements = nullptr;
            checkXr(xrGetInstanceProcAddr(instance,
                                          "xrGetMetalGraphicsRequirementsKHR",
                                          reinterpret_cast<PFN_xrVoidFunction *>(&getMetalRequirements)),
                    "xrGetInstanceProcAddr(xrGetMetalGraphicsRequirementsKHR)");
            XrGraphicsRequirementsMetalKHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
            checkXr(getMetalRequirements(instance, systemId, &requirements),
                    "xrGetMetalGraphicsRequirementsKHR");

            id<MTLDevice> device = (__bridge id<MTLDevice>)requirements.metalDevice;
            if (!device) throw std::runtime_error("Runtime returned no Metal device");
            id<MTLCommandQueue> queue = [device newCommandQueue];
            if (!queue) throw std::runtime_error("Could not create Metal command queue");

            XrGraphicsBindingMetalKHR binding{XR_TYPE_GRAPHICS_BINDING_METAL_KHR};
            binding.commandQueue = (__bridge void *)queue;
            XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO};
            sessionInfo.next = &binding;
            sessionInfo.systemId = systemId;
            checkXr(xrCreateSession(instance, &sessionInfo, &session), "xrCreateSession");

            XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
            spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
            spaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
            checkXr(xrCreateReferenceSpace(session, &spaceInfo, &localSpace),
                    "xrCreateReferenceSpace(LOCAL)");

            uint32_t viewCount = 0;
            checkXr(xrEnumerateViewConfigurationViews(instance,
                                                       systemId,
                                                       XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                                       0,
                                                       &viewCount,
                                                       nullptr),
                    "xrEnumerateViewConfigurationViews(count)");
            if (viewCount != 2) throw std::runtime_error("Expected two PRIMARY_STEREO views");
            std::vector<XrViewConfigurationView> viewConfigs(viewCount);
            for (auto &v : viewConfigs) v = {XR_TYPE_VIEW_CONFIGURATION_VIEW};
            checkXr(xrEnumerateViewConfigurationViews(instance,
                                                       systemId,
                                                       XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                                       viewCount,
                                                       &viewCount,
                                                       viewConfigs.data()),
                    "xrEnumerateViewConfigurationViews(list)");

            NSString *path = [NSString stringWithUTF8String:argv[1]];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                throw std::runtime_error("Video file does not exist");
            }
            NSURL *url = [NSURL fileURLWithPath:path];
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (!videoTrack) throw std::runtime_error("Input has no video track");
            const CGSize videoSize = orientedVideoSize(videoTrack);
            const double aspect = static_cast<double>(videoSize.width) /
                                  std::max(1.0, static_cast<double>(videoSize.height));

            AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
            NSDictionary *attrs = @{
                (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
            };
            AVPlayerItemVideoOutput *videoOutput =
                [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
            [playerItem addOutput:videoOutput];
            AVPlayer *player = [AVPlayer playerWithPlayerItem:playerItem];
            player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
            player.automaticallyWaitsToMinimizeStalling = YES;

            if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &textureCache) != kCVReturnSuccess ||
                !textureCache) {
                throw std::runtime_error("CVMetalTextureCacheCreate failed");
            }

            const MTLPixelFormat swapchainFormat = chooseSwapchainFormat(session);
            eyeSwapchains.resize(viewCount);
            for (uint32_t eye = 0; eye < viewCount; ++eye) {
                EyeSwapchain &sc = eyeSwapchains[eye];
                sc.width = viewConfigs[eye].recommendedImageRectWidth;
                sc.height = viewConfigs[eye].recommendedImageRectHeight;
                XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};
                ci.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
                ci.format = static_cast<int64_t>(swapchainFormat);
                ci.sampleCount = 1;
                ci.width = sc.width;
                ci.height = sc.height;
                ci.faceCount = 1;
                ci.arraySize = 1;
                ci.mipCount = 1;
                checkXr(xrCreateSwapchain(session, &ci, &sc.handle), "xrCreateSwapchain(video eye)");

                uint32_t imageCount = 0;
                checkXr(xrEnumerateSwapchainImages(sc.handle, 0, &imageCount, nullptr),
                        "xrEnumerateSwapchainImages(count)");
                sc.images.resize(imageCount);
                for (auto &image : sc.images) image = {XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
                checkXr(xrEnumerateSwapchainImages(sc.handle,
                                                   imageCount,
                                                   &imageCount,
                                                   reinterpret_cast<XrSwapchainImageBaseHeader *>(sc.images.data())),
                        "xrEnumerateSwapchainImages(list)");
                std::printf("Eye %u swapchain: %ux%u images=%u\n", eye, sc.width, sc.height, imageCount);
            }

            id<MTLRenderPipelineState> pipeline = makePipeline(device, swapchainFormat);
            const XrEnvironmentBlendMode blendMode = chooseBlendMode(instance, systemId);

            float panelHeight = 1.20f;
            float panelWidth = panelHeight * static_cast<float>(aspect);
            if (panelWidth > 2.40f) {
                panelWidth = 2.40f;
                panelHeight = panelWidth / static_cast<float>(aspect);
            }

            std::printf("OpenXR system: %s\n", systemProperties.systemName);
            std::printf("Metal device: %s\n", device.name.UTF8String);
            std::printf("Video: %.0fx%.0f (aspect %.3f)\n", videoSize.width, videoSize.height, aspect);
            std::printf("Projection mode: pose-anchored virtual screen %.2fm x %.2fm, 2.0m ahead of initial gaze\n",
                        panelWidth, panelHeight);
            if (testPattern) {
                std::printf("DIAGNOSTIC: GAV_MONADO_TEST_PATTERN enabled; screen will be BRIGHT MAGENTA.\n");
            }
            std::printf("Audio follows the current macOS default output. Ctrl-C exits.\n");

            bool sessionRunning = false;
            bool exitRequested = false;
            bool playerStarted = false;
            uint64_t decodedFrameCount = 0;
            bool loggedFirstDecodedFrame = false;
            bool loggedFirstProjectionFrame = false;
            ScreenAnchor anchor{};
            double lastStatusLog = CACurrentMediaTime();

            while (!exitRequested && !gStopRequested.load()) {
                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.0]];
                }

                XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
                while (xrPollEvent(instance, &event) == XR_SUCCESS) {
                    if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                        const auto *changed = reinterpret_cast<const XrEventDataSessionStateChanged *>(&event);
                        std::printf("OpenXR session state: %s\n", sessionStateName(changed->state));
                        if (changed->state == XR_SESSION_STATE_READY && !sessionRunning) {
                            XrSessionBeginInfo bi{XR_TYPE_SESSION_BEGIN_INFO};
                            bi.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                            checkXr(xrBeginSession(session, &bi), "xrBeginSession");
                            sessionRunning = true;
                        } else if (changed->state == XR_SESSION_STATE_STOPPING && sessionRunning) {
                            [player pause];
                            checkXr(xrEndSession(session), "xrEndSession");
                            sessionRunning = false;
                        } else if (changed->state == XR_SESSION_STATE_EXITING ||
                                   changed->state == XR_SESSION_STATE_LOSS_PENDING) {
                            exitRequested = true;
                        }
                    } else if (event.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) {
                        exitRequested = true;
                    }
                    event = {XR_TYPE_EVENT_DATA_BUFFER};
                }

                if (!sessionRunning) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    continue;
                }

                if (!playerStarted && playerItem.status == AVPlayerItemStatusReadyToPlay) {
                    [player play];
                    playerStarted = true;
                    std::printf("DIAGNOSTIC: AVPlayerItem ready; playback started.\n");
                }

                XrFrameWaitInfo wi{XR_TYPE_FRAME_WAIT_INFO};
                XrFrameState frameState{XR_TYPE_FRAME_STATE};
                checkXr(xrWaitFrame(session, &wi, &frameState), "xrWaitFrame");
                XrFrameBeginInfo fbi{XR_TYPE_FRAME_BEGIN_INFO};
                checkXr(xrBeginFrame(session, &fbi), "xrBeginFrame");

                std::vector<XrView> views(viewCount);
                for (auto &view : views) view = {XR_TYPE_VIEW};
                XrViewState viewState{XR_TYPE_VIEW_STATE};
                uint32_t locatedViewCount = 0;
                XrViewLocateInfo li{XR_TYPE_VIEW_LOCATE_INFO};
                li.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                li.displayTime = frameState.predictedDisplayTime;
                li.space = localSpace;
                checkXr(xrLocateViews(session, &li, &viewState, viewCount, &locatedViewCount, views.data()),
                        "xrLocateViews");

                const bool poseValid =
                    (viewState.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0 &&
                    (viewState.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0;
                if (!anchor.valid && poseValid && locatedViewCount == viewCount) {
                    const XrQuaternionf q = views[0].pose.orientation;
                    const simd_float3 forward = simd_normalize(rotateVector(q, {0.0f, 0.0f, -1.0f}));
                    const simd_float3 right = simd_normalize(rotateVector(q, {1.0f, 0.0f, 0.0f}));
                    const simd_float3 up = simd_normalize(rotateVector(q, {0.0f, 1.0f, 0.0f}));
                    const simd_float3 eyeCenter = {
                        0.5f * (views[0].pose.position.x + views[1].pose.position.x),
                        0.5f * (views[0].pose.position.y + views[1].pose.position.y),
                        0.5f * (views[0].pose.position.z + views[1].pose.position.z),
                    };
                    anchor.center = eyeCenter + forward * 2.0f;
                    anchor.right = right;
                    anchor.up = up;
                    anchor.normal = -forward;
                    anchor.valid = true;
                    std::printf("DIAGNOSTIC: screen anchored at (%.3f, %.3f, %.3f), forward=(%.3f, %.3f, %.3f)\n",
                                anchor.center.x, anchor.center.y, anchor.center.z,
                                forward.x, forward.y, forward.z);
                }

                if (!testPattern && playerStarted) {
                    const CMTime itemTime = [videoOutput itemTimeForHostTime:CACurrentMediaTime()];
                    // Intentionally do NOT gate on hasNewPixelBufferForItemTime. The original
                    // GAV player found that some files return usable frames while that flag is false.
                    CVPixelBufferRef pb =
                        [videoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:nil];
                    if (pb) {
                        if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
                        currentPixelBuffer = pb;
                        ++decodedFrameCount;
                        if (!loggedFirstDecodedFrame) {
                            loggedFirstDecodedFrame = true;
                            std::printf("DIAGNOSTIC: first decoded frame: %zux%zu pixelFormat=",
                                        CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
                            printPixelFormat(CVPixelBufferGetPixelFormatType(pb));
                            std::printf("\n");
                        }
                    }
                }

                CVMetalTextureRef cvTexture = nullptr;
                id<MTLTexture> source = nil;
                if (!testPattern && currentPixelBuffer) {
                    const size_t w = CVPixelBufferGetWidth(currentPixelBuffer);
                    const size_t h = CVPixelBufferGetHeight(currentPixelBuffer);
                    const CVReturn cvret = CVMetalTextureCacheCreateTextureFromImage(
                        kCFAllocatorDefault,
                        textureCache,
                        currentPixelBuffer,
                        nullptr,
                        MTLPixelFormatBGRA8Unorm,
                        w,
                        h,
                        0,
                        &cvTexture);
                    if (cvret == kCVReturnSuccess && cvTexture) {
                        source = CVMetalTextureGetTexture(cvTexture);
                    } else if (cvret != kCVReturnSuccess) {
                        std::fprintf(stderr, "DIAGNOSTIC: CVMetalTexture creation failed: %d\n", static_cast<int>(cvret));
                    }
                }

                XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
                std::vector<XrCompositionLayerProjectionView> projectionViews(viewCount);
                const XrCompositionLayerBaseHeader *layers[1] = {};
                uint32_t layerCount = 0;

                if (frameState.shouldRender && locatedViewCount == viewCount) {
                    for (uint32_t eye = 0; eye < viewCount; ++eye) {
                        EyeSwapchain &sc = eyeSwapchains[eye];
                        uint32_t imageIndex = 0;
                        XrSwapchainImageAcquireInfo ai{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
                        checkXr(xrAcquireSwapchainImage(sc.handle, &ai, &imageIndex), "xrAcquireSwapchainImage");
                        XrSwapchainImageWaitInfo swi{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                        swi.timeout = XR_INFINITE_DURATION;
                        checkXr(xrWaitSwapchainImage(sc.handle, &swi), "xrWaitSwapchainImage");

                        id<MTLTexture> target = (__bridge id<MTLTexture>)sc.images[imageIndex].texture;
                        renderEye(queue,
                                  pipeline,
                                  target,
                                  source,
                                  views[eye],
                                  anchor,
                                  panelWidth,
                                  panelHeight,
                                  testPattern);

                        XrSwapchainImageReleaseInfo ri{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                        checkXr(xrReleaseSwapchainImage(sc.handle, &ri), "xrReleaseSwapchainImage");

                        projectionViews[eye] = {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW};
                        projectionViews[eye].pose = views[eye].pose;
                        projectionViews[eye].fov = views[eye].fov;
                        projectionViews[eye].subImage.swapchain = sc.handle;
                        projectionViews[eye].subImage.imageRect.offset = {0, 0};
                        projectionViews[eye].subImage.imageRect.extent = {
                            static_cast<int32_t>(sc.width),
                            static_cast<int32_t>(sc.height),
                        };
                        projectionViews[eye].subImage.imageArrayIndex = 0;
                    }

                    projection.space = localSpace;
                    projection.viewCount = viewCount;
                    projection.views = projectionViews.data();
                    layers[0] = reinterpret_cast<const XrCompositionLayerBaseHeader *>(&projection);
                    layerCount = 1;
                    if (!loggedFirstProjectionFrame) {
                        std::printf("DIAGNOSTIC: submitted first projection frame; viewStateFlags=0x%llx\n",
                                    static_cast<unsigned long long>(viewState.viewStateFlags));
                        loggedFirstProjectionFrame = true;
                    }
                }

                if (cvTexture) CFRelease(cvTexture);

                XrFrameEndInfo ei{XR_TYPE_FRAME_END_INFO};
                ei.displayTime = frameState.predictedDisplayTime;
                ei.environmentBlendMode = blendMode;
                ei.layerCount = layerCount;
                ei.layers = layerCount ? layers : nullptr;
                checkXr(xrEndFrame(session, &ei), "xrEndFrame");

                const double now = CACurrentMediaTime();
                if (now - lastStatusLog >= 2.0) {
                    const char *status = "unknown";
                    if (playerItem.status == AVPlayerItemStatusReadyToPlay) status = "ready";
                    else if (playerItem.status == AVPlayerItemStatusFailed) status = "failed";
                    std::printf("DIAGNOSTIC: player status=%s started=%s rate=%.2f time=%.3fs decodedFrames=%llu buffer=%s anchor=%s shouldRender=%s\n",
                                status,
                                playerStarted ? "yes" : "no",
                                player.rate,
                                CMTimeGetSeconds(player.currentTime),
                                static_cast<unsigned long long>(decodedFrameCount),
                                currentPixelBuffer ? "yes" : "no",
                                anchor.valid ? "yes" : "no",
                                frameState.shouldRender ? "yes" : "no");
                    if (playerItem.status == AVPlayerItemStatusFailed && playerItem.error) {
                        std::fprintf(stderr, "AVPlayerItem error: %s\n", playerItem.error.localizedDescription.UTF8String);
                    }
                    lastStatusLog = now;
                }
            }

            [player pause];
        } catch (const std::exception &error) {
            std::fprintf(stderr, "gav-monado-poc: %s\n", error.what());
            if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
            if (textureCache) CFRelease(textureCache);
            for (auto &sc : eyeSwapchains) {
                if (sc.handle != XR_NULL_HANDLE) xrDestroySwapchain(sc.handle);
            }
            if (localSpace != XR_NULL_HANDLE) xrDestroySpace(localSpace);
            if (session != XR_NULL_HANDLE) xrDestroySession(session);
            if (instance != XR_NULL_HANDLE) xrDestroyInstance(instance);
            return 1;
        }

        if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
        if (textureCache) CFRelease(textureCache);
        for (auto &sc : eyeSwapchains) {
            if (sc.handle != XR_NULL_HANDLE) xrDestroySwapchain(sc.handle);
        }
        if (localSpace != XR_NULL_HANDLE) xrDestroySpace(localSpace);
        if (session != XR_NULL_HANDLE) xrDestroySession(session);
        if (instance != XR_NULL_HANDLE) xrDestroyInstance(instance);
        return 0;
    }
}
