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
#include <cstdint>
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
        const int64_t value = static_cast<int64_t>(candidate);
        if (std::find(formats.begin(), formats.end(), value) != formats.end()) {
            return candidate;
        }
    }

    throw std::runtime_error("OpenXR runtime did not expose a renderable 8-bit Metal swapchain format");
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

    const auto opaque = std::find(modes.begin(), modes.end(), XR_ENVIRONMENT_BLEND_MODE_OPAQUE);
    if (opaque != modes.end()) {
        return *opaque;
    }
    if (modes.empty()) {
        throw std::runtime_error("OpenXR runtime exposed no environment blend modes");
    }
    return modes.front();
}

CGSize orientedVideoSize(AVAssetTrack *track)
{
    const CGSize natural = track.naturalSize;
    const CGRect transformed = CGRectApplyAffineTransform(
        CGRectMake(0.0, 0.0, natural.width, natural.height), track.preferredTransform);

    CGSize result = CGSizeMake(std::fabs(transformed.size.width), std::fabs(transformed.size.height));
    if (result.width < 1.0 || result.height < 1.0) {
        result = CGSizeMake(std::fabs(natural.width), std::fabs(natural.height));
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

struct EyeSwapchain {
    XrSwapchain handle{XR_NULL_HANDLE};
    uint32_t width{0};
    uint32_t height{0};
    std::vector<XrSwapchainImageMetalKHR> images;
};

struct ScreenUniforms {
    simd_float4 viewOrientation;
    simd_float4 viewPosition;
    simd_float4 fovTangents;
    simd_float4 screen; // half width, half height, local-space Z, test-pattern flag
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
    float4 screen;
};

vertex VertexOut videoVertex(uint vertexID [[vertex_id]])
{
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.ndc = positions[vertexID];
    return out;
}

static float3 rotateByQuaternion(float3 v, float4 q)
{
    // OpenXR quaternion layout is x,y,z,w.
    const float3 qv = q.xyz;
    return v + 2.0 * cross(qv, cross(qv, v) + q.w * v);
}

fragment float4 videoFragment(VertexOut in [[stage_in]],
                              constant ScreenUniforms &uni [[buffer(0)]],
                              texture2d<float> video [[texture(0)]])
{
    // Reconstruct the view-space ray from OpenXR's asymmetric FoV. Metal's
    // viewport places NDC +Y at the top, matching angleUp here.
    const float u = (in.ndc.x + 1.0) * 0.5;
    const float v = (in.ndc.y + 1.0) * 0.5;
    const float rayX = mix(uni.fovTangents.x, uni.fovTangents.y, u);
    const float rayY = mix(uni.fovTangents.z, uni.fovTangents.w, v);

    float3 ray = normalize(float3(rayX, rayY, -1.0));
    ray = rotateByQuaternion(ray, uni.viewOrientation);

    const float3 origin = uni.viewPosition.xyz;
    const float panelZ = uni.screen.z;
    if (fabs(ray.z) < 1e-6) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    const float distance = (panelZ - origin.z) / ray.z;
    if (distance <= 0.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    const float3 hit = origin + ray * distance;
    const float halfWidth = uni.screen.x;
    const float halfHeight = uni.screen.y;
    if (fabs(hit.x) > halfWidth || fabs(hit.y) > halfHeight) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    const float2 videoUV = float2(0.5 + hit.x / (2.0 * halfWidth),
                                  0.5 - hit.y / (2.0 * halfHeight));

    if (uni.screen.w > 0.5) {
        // Visible geometry diagnostic: magenta screen on black projection background.
        return float4(1.0, 0.0, 1.0, 1.0);
    }

    constexpr sampler videoSampler(coord::normalized,
                                   address::clamp_to_edge,
                                   filter::linear);
    return video.sample(videoSampler, videoUV);
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
    if (!vertex || !fragment) {
        throw std::runtime_error("Metal video shader functions were not created");
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = targetFormat;

    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) {
        throw std::runtime_error(std::string("Metal pipeline creation failed: ") +
                                 (error.localizedDescription.UTF8String ?: "unknown error"));
    }
    return pipeline;
}

void renderProjectionEye(id<MTLCommandQueue> commandQueue,
                         id<MTLRenderPipelineState> pipeline,
                         id<MTLTexture> target,
                         id<MTLTexture> source,
                         const XrView &view,
                         float panelWidth,
                         float panelHeight,
                         float panelZ,
                         bool testPattern)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    if (!commandBuffer) {
        throw std::runtime_error("Could not create Metal command buffer");
    }

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        throw std::runtime_error("Could not create Metal render command encoder");
    }

    if (testPattern || source) {
        ScreenUniforms uniforms{};
        uniforms.viewOrientation = {
            view.pose.orientation.x,
            view.pose.orientation.y,
            view.pose.orientation.z,
            view.pose.orientation.w,
        };
        uniforms.viewPosition = {
            view.pose.position.x,
            view.pose.position.y,
            view.pose.position.z,
            0.0f,
        };
        uniforms.fovTangents = {
            std::tan(view.fov.angleLeft),
            std::tan(view.fov.angleRight),
            std::tan(view.fov.angleDown),
            std::tan(view.fov.angleUp),
        };
        uniforms.screen = {
            panelWidth * 0.5f,
            panelHeight * 0.5f,
            panelZ,
            testPattern ? 1.0f : 0.0f,
        };

        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        if (source) {
            [encoder setFragmentTexture:source atIndex:0];
        }
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }

    [encoder endEncoding];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status == MTLCommandBufferStatusError) {
            std::fprintf(stderr,
                         "Metal projection command buffer failed asynchronously: %s\n",
                         completed.error.localizedDescription.UTF8String ?: "unknown error");
        }
    }];
    [commandBuffer commit];

    // Do not block the application CPU here. This is the same queue supplied
    // in XrGraphicsBindingMetalKHR, so Monado's release-side shared-event signal
    // is ordered after this render command buffer. The service waits for that
    // timeline value before making the frame available to the compositor.
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

        @try {
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
                checkXr(xrGetSystemProperties(instance, systemId, &systemProperties),
                        "xrGetSystemProperties");

                PFN_xrGetMetalGraphicsRequirementsKHR getMetalRequirements = nullptr;
                checkXr(xrGetInstanceProcAddr(
                            instance,
                            "xrGetMetalGraphicsRequirementsKHR",
                            reinterpret_cast<PFN_xrVoidFunction *>(&getMetalRequirements)),
                        "xrGetInstanceProcAddr(xrGetMetalGraphicsRequirementsKHR)");
                if (!getMetalRequirements) {
                    throw std::runtime_error("xrGetMetalGraphicsRequirementsKHR was not returned by the runtime");
                }

                XrGraphicsRequirementsMetalKHR metalRequirements{XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
                checkXr(getMetalRequirements(instance, systemId, &metalRequirements),
                        "xrGetMetalGraphicsRequirementsKHR");

                id<MTLDevice> device = (__bridge id<MTLDevice>)metalRequirements.metalDevice;
                if (!device) {
                    throw std::runtime_error("OpenXR runtime returned no Metal device");
                }
                id<MTLCommandQueue> commandQueue = [device newCommandQueue];
                if (!commandQueue) {
                    throw std::runtime_error("Could not create a Metal command queue");
                }

                XrGraphicsBindingMetalKHR graphicsBinding{XR_TYPE_GRAPHICS_BINDING_METAL_KHR};
                graphicsBinding.commandQueue = (__bridge void *)commandQueue;

                XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO};
                sessionInfo.next = &graphicsBinding;
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
                if (viewCount != 2) {
                    throw std::runtime_error("Video POC currently expects exactly two PRIMARY_STEREO views");
                }

                std::vector<XrViewConfigurationView> viewConfigs(viewCount);
                for (auto &view : viewConfigs) {
                    view = {XR_TYPE_VIEW_CONFIGURATION_VIEW};
                }
                checkXr(xrEnumerateViewConfigurationViews(instance,
                                                           systemId,
                                                           XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                                           viewCount,
                                                           &viewCount,
                                                           viewConfigs.data()),
                        "xrEnumerateViewConfigurationViews(list)");

                NSString *path = [NSString stringWithUTF8String:argv[1]];
                NSURL *videoURL = [NSURL fileURLWithPath:path];
                if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    throw std::runtime_error("Video file does not exist");
                }

                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL
                                                        options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
                AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
                if (!videoTrack) {
                    throw std::runtime_error("The input file contains no video track");
                }

                const CGSize videoSize = orientedVideoSize(videoTrack);
                const double aspect = static_cast<double>(videoSize.width) /
                                      std::max(1.0, static_cast<double>(videoSize.height));

                AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
                NSDictionary *pixelBufferAttributes = @{
                    (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelBufferType_32BGRA),
                    (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                };
                [playerItem addOutput:videoOutput];

                AVPlayer *player = [AVPlayer playerWithPlayerItem:playerItem];
                player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
                player.automaticallyWaitsToMinimizeStalling = YES;

                const CVReturn cacheResult = CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                                                        nullptr,
                                                                        device,
                                                                        nullptr,
                                                                        &textureCache);
                if (cacheResult != kCVReturnSuccess || !textureCache) {
                    throw std::runtime_error("CVMetalTextureCacheCreate failed");
                }

                const MTLPixelFormat swapchainFormat = chooseSwapchainFormat(session);
                eyeSwapchains.resize(viewCount);
                for (uint32_t eye = 0; eye < viewCount; ++eye) {
                    EyeSwapchain &sc = eyeSwapchains[eye];
                    sc.width = viewConfigs[eye].recommendedImageRectWidth;
                    sc.height = viewConfigs[eye].recommendedImageRectHeight;

                    XrSwapchainCreateInfo createInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
                    createInfo.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT |
                                            XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
                    createInfo.format = static_cast<int64_t>(swapchainFormat);
                    createInfo.sampleCount = 1;
                    createInfo.width = sc.width;
                    createInfo.height = sc.height;
                    createInfo.faceCount = 1;
                    createInfo.arraySize = 1;
                    createInfo.mipCount = 1;
                    checkXr(xrCreateSwapchain(session, &createInfo, &sc.handle),
                            "xrCreateSwapchain(video projection eye)");

                    uint32_t imageCount = 0;
                    checkXr(xrEnumerateSwapchainImages(sc.handle, 0, &imageCount, nullptr),
                            "xrEnumerateSwapchainImages(count)");
                    sc.images.resize(imageCount);
                    for (auto &image : sc.images) {
                        image = {XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
                    }
                    checkXr(xrEnumerateSwapchainImages(
                                sc.handle,
                                imageCount,
                                &imageCount,
                                reinterpret_cast<XrSwapchainImageBaseHeader *>(sc.images.data())),
                            "xrEnumerateSwapchainImages(list)");
                    if (sc.images.empty()) {
                        throw std::runtime_error("OpenXR eye swapchain contains no images");
                    }

                    id<MTLTexture> firstTexture = (__bridge id<MTLTexture>)sc.images[0].texture;
                    if (!firstTexture) {
                        throw std::runtime_error("OpenXR returned a null Metal eye swapchain texture");
                    }

                    std::printf("Eye %u swapchain: %ux%u, %u images, texture format=%lu usage=0x%lx storageMode=%lu\n",
                                eye,
                                sc.width,
                                sc.height,
                                imageCount,
                                static_cast<unsigned long>(firstTexture.pixelFormat),
                                static_cast<unsigned long>(firstTexture.usage),
                                static_cast<unsigned long>(firstTexture.storageMode));
                }

                id<MTLRenderPipelineState> pipeline = makePipeline(device, swapchainFormat);
                const XrEnvironmentBlendMode blendMode = chooseBlendMode(instance, systemId);

                float panelHeight = 1.20f;
                float panelWidth = panelHeight * static_cast<float>(aspect);
                if (panelWidth > 2.40f) {
                    panelWidth = 2.40f;
                    panelHeight = panelWidth / static_cast<float>(aspect);
                }
                if (panelHeight > 1.60f) {
                    panelHeight = 1.60f;
                    panelWidth = panelHeight * static_cast<float>(aspect);
                }
                constexpr float panelZ = -2.0f;

                std::printf("OpenXR system: %s\n", systemProperties.systemName);
                std::printf("Metal device: %s\n", device.name.UTF8String);
                std::printf("Video: %.0fx%.0f (aspect %.3f)\n", videoSize.width, videoSize.height, aspect);
                std::printf("Projection mode: virtual screen %.2fm x %.2fm at %.1fm in LOCAL space\n",
                            panelWidth,
                            panelHeight,
                            -panelZ);
                if (testPattern) {
                    std::printf("DIAGNOSTIC: GAV_MONADO_TEST_PATTERN enabled; virtual screen will be BRIGHT MAGENTA.\n");
                }
                std::printf("Audio follows the current macOS default output in this POC. Ctrl-C exits.\n");

                bool sessionRunning = false;
                bool exitRequested = false;
                bool playerStarted = false;
                XrSessionState sessionState = XR_SESSION_STATE_UNKNOWN;
                uint64_t decodedFrameCount = 0;
                bool loggedFirstDecodedFrame = false;
                bool loggedFirstProjectionFrame = false;
                double lastStatusLog = CACurrentMediaTime();

                while (!exitRequested && !gStopRequested.load()) {
                    // AVFoundation is normally hosted by an AppKit run loop. This CLI POC
                    // services the Foundation run loop explicitly so item readiness and
                    // media-output bookkeeping are not starved by xrWaitFrame.
                    @autoreleasepool {
                        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.0]];
                    }

                    XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
                    while (xrPollEvent(instance, &event) == XR_SUCCESS) {
                        if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                            const auto *changed = reinterpret_cast<const XrEventDataSessionStateChanged *>(&event);
                            sessionState = changed->state;
                            std::printf("OpenXR session state: %s\n", sessionStateName(sessionState));

                            if (sessionState == XR_SESSION_STATE_READY && !sessionRunning) {
                                XrSessionBeginInfo beginInfo{XR_TYPE_SESSION_BEGIN_INFO};
                                beginInfo.primaryViewConfigurationType =
                                    XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                                checkXr(xrBeginSession(session, &beginInfo), "xrBeginSession");
                                sessionRunning = true;
                            } else if (sessionState == XR_SESSION_STATE_STOPPING && sessionRunning) {
                                [player pause];
                                playerStarted = false;
                                checkXr(xrEndSession(session), "xrEndSession");
                                sessionRunning = false;
                            } else if (sessionState == XR_SESSION_STATE_EXITING ||
                                       sessionState == XR_SESSION_STATE_LOSS_PENDING) {
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

                    XrFrameWaitInfo waitInfo{XR_TYPE_FRAME_WAIT_INFO};
                    XrFrameState frameState{XR_TYPE_FRAME_STATE};
                    checkXr(xrWaitFrame(session, &waitInfo, &frameState), "xrWaitFrame");

                    XrFrameBeginInfo frameBeginInfo{XR_TYPE_FRAME_BEGIN_INFO};
                    checkXr(xrBeginFrame(session, &frameBeginInfo), "xrBeginFrame");

                    std::vector<XrView> views(viewCount);
                    for (auto &view : views) {
                        view = {XR_TYPE_VIEW};
                    }
                    XrViewState viewState{XR_TYPE_VIEW_STATE};
                    uint32_t locatedViewCount = 0;
                    XrViewLocateInfo locateInfo{XR_TYPE_VIEW_LOCATE_INFO};
                    locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                    locateInfo.displayTime = frameState.predictedDisplayTime;
                    locateInfo.space = localSpace;
                    checkXr(xrLocateViews(session,
                                          &locateInfo,
                                          &viewState,
                                          viewCount,
                                          &locatedViewCount,
                                          views.data()),
                            "xrLocateViews");

                    XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
                    std::vector<XrCompositionLayerProjectionView> projectionViews(viewCount);
                    const XrCompositionLayerBaseHeader *layers[1] = {};
                    uint32_t layerCount = 0;

                    CVMetalTextureRef cvTexture = nullptr;
                    id<MTLTexture> source = nil;

                    if (frameState.shouldRender && locatedViewCount == viewCount) {
                        if (!testPattern && playerStarted) {
                            const CMTime itemTime = [videoOutput itemTimeForHostTime:CACurrentMediaTime()];
                            if ([videoOutput hasNewPixelBufferForItemTime:itemTime]) {
                                CMTime displayTime = kCMTimeInvalid;
                                CVPixelBufferRef newBuffer =
                                    [videoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:&displayTime];
                                if (newBuffer) {
                                    if (currentPixelBuffer) {
                                        CVPixelBufferRelease(currentPixelBuffer);
                                    }
                                    currentPixelBuffer = newBuffer;
                                    ++decodedFrameCount;

                                    if (!loggedFirstDecodedFrame) {
                                        loggedFirstDecodedFrame = true;
                                        const size_t w = CVPixelBufferGetWidth(currentPixelBuffer);
                                        const size_t h = CVPixelBufferGetHeight(currentPixelBuffer);
                                        std::printf("DIAGNOSTIC: first decoded AVPlayer frame: %zux%zu pixelFormat=", w, h);
                                        printPixelFormat(CVPixelBufferGetPixelFormatType(currentPixelBuffer));
                                        std::printf("\n");
                                    }
                                }
                            }
                        }

                        if (!testPattern && currentPixelBuffer) {
                            const size_t sourceWidth = CVPixelBufferGetWidth(currentPixelBuffer);
                            const size_t sourceHeight = CVPixelBufferGetHeight(currentPixelBuffer);
                            const CVReturn textureResult = CVMetalTextureCacheCreateTextureFromImage(
                                kCFAllocatorDefault,
                                textureCache,
                                currentPixelBuffer,
                                nullptr,
                                MTLPixelFormatBGRA8Unorm,
                                sourceWidth,
                                sourceHeight,
                                0,
                                &cvTexture);
                            if (textureResult == kCVReturnSuccess && cvTexture) {
                                source = CVMetalTextureGetTexture(cvTexture);
                            } else if (textureResult != kCVReturnSuccess) {
                                std::fprintf(stderr,
                                             "DIAGNOSTIC: CVMetalTextureCacheCreateTextureFromImage failed: %d\n",
                                             static_cast<int>(textureResult));
                            }
                        }

                        for (uint32_t eye = 0; eye < viewCount; ++eye) {
                            EyeSwapchain &sc = eyeSwapchains[eye];
                            uint32_t imageIndex = 0;
                            XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
                            checkXr(xrAcquireSwapchainImage(sc.handle, &acquireInfo, &imageIndex),
                                    "xrAcquireSwapchainImage");

                            XrSwapchainImageWaitInfo imageWaitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                            imageWaitInfo.timeout = XR_INFINITE_DURATION;
                            checkXr(xrWaitSwapchainImage(sc.handle, &imageWaitInfo),
                                    "xrWaitSwapchainImage");

                            id<MTLTexture> target = (__bridge id<MTLTexture>)sc.images[imageIndex].texture;
                            if (!target) {
                                throw std::runtime_error("Acquired OpenXR eye image has null Metal texture");
                            }

                            renderProjectionEye(commandQueue,
                                                pipeline,
                                                target,
                                                source,
                                                views[eye],
                                                panelWidth,
                                                panelHeight,
                                                panelZ,
                                                testPattern);

                            XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                            checkXr(xrReleaseSwapchainImage(sc.handle, &releaseInfo),
                                    "xrReleaseSwapchainImage");

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

                        if (cvTexture) {
                            CFRelease(cvTexture);
                            cvTexture = nullptr;
                            source = nil;
                        }

                        projection.layerFlags = 0;
                        projection.space = localSpace;
                        projection.viewCount = viewCount;
                        projection.views = projectionViews.data();
                        layers[0] = reinterpret_cast<const XrCompositionLayerBaseHeader *>(&projection);
                        layerCount = 1;

                        if (!loggedFirstProjectionFrame) {
                            std::printf("DIAGNOSTIC: submitted first video projection frame; viewStateFlags=0x%llx\n",
                                        static_cast<unsigned long long>(viewState.viewStateFlags));
                            loggedFirstProjectionFrame = true;
                        }
                    }

                    XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
                    endInfo.displayTime = frameState.predictedDisplayTime;
                    endInfo.environmentBlendMode = blendMode;
                    endInfo.layerCount = layerCount;
                    endInfo.layers = layerCount ? layers : nullptr;
                    checkXr(xrEndFrame(session, &endInfo), "xrEndFrame");

                    const double now = CACurrentMediaTime();
                    if (now - lastStatusLog >= 2.0) {
                        const double mediaSeconds = CMTimeGetSeconds(player.currentTime);
                        const char *itemStatus = "unknown";
                        switch (playerItem.status) {
                            case AVPlayerItemStatusUnknown: itemStatus = "unknown"; break;
                            case AVPlayerItemStatusReadyToPlay: itemStatus = "ready"; break;
                            case AVPlayerItemStatusFailed: itemStatus = "failed"; break;
                        }
                        std::printf("DIAGNOSTIC: player status=%s started=%s rate=%.2f time=%.3fs decodedFrames=%llu currentPixelBuffer=%s shouldRender=%s\n",
                                    itemStatus,
                                    playerStarted ? "yes" : "no",
                                    player.rate,
                                    mediaSeconds,
                                    static_cast<unsigned long long>(decodedFrameCount),
                                    currentPixelBuffer ? "yes" : "no",
                                    frameState.shouldRender ? "yes" : "no");
                        if (playerItem.status == AVPlayerItemStatusFailed && playerItem.error) {
                            std::fprintf(stderr,
                                         "DIAGNOSTIC: AVPlayerItem failed: %s\n",
                                         playerItem.error.localizedDescription.UTF8String ?: "unknown error");
                        }
                        lastStatusLog = now;
                    }
                }

                if (sessionRunning) {
                    [player pause];
                    playerStarted = false;
                    checkXr(xrRequestExitSession(session), "xrRequestExitSession");
                }
            } catch (const std::exception &e) {
                std::fprintf(stderr, "fatal: %s\n", e.what());
                gStopRequested.store(true);
            }

            if (currentPixelBuffer) {
                CVPixelBufferRelease(currentPixelBuffer);
                currentPixelBuffer = nullptr;
            }
            if (textureCache) {
                CFRelease(textureCache);
                textureCache = nullptr;
            }
            for (EyeSwapchain &sc : eyeSwapchains) {
                if (sc.handle != XR_NULL_HANDLE) {
                    xrDestroySwapchain(sc.handle);
                    sc.handle = XR_NULL_HANDLE;
                }
            }
            if (localSpace != XR_NULL_HANDLE) {
                xrDestroySpace(localSpace);
                localSpace = XR_NULL_HANDLE;
            }
            if (session != XR_NULL_HANDLE) {
                xrDestroySession(session);
                session = XR_NULL_HANDLE;
            }
            if (instance != XR_NULL_HANDLE) {
                xrDestroyInstance(instance);
                instance = XR_NULL_HANDLE;
            }
        } @catch (NSException *exception) {
            std::fprintf(stderr, "Objective-C exception: %s\n", exception.reason.UTF8String ?: "unknown exception");
            return 1;
        }
    }
    return 0;
}
