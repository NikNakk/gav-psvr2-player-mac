#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
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

struct SwapchainSize {
    uint32_t width;
    uint32_t height;
};

SwapchainSize chooseSwapchainSize(CGSize videoSize, const XrSystemGraphicsProperties &limits)
{
    // Keep the first proof-of-concept deliberately modest. The decoded source can
    // still be 4K; Metal downsamples it into this composition-layer texture.
    const double videoWidth = std::max(1.0, static_cast<double>(videoSize.width));
    const double videoHeight = std::max(1.0, static_cast<double>(videoSize.height));

    const double scale = std::min({
        1.0,
        1920.0 / videoWidth,
        1080.0 / videoHeight,
        static_cast<double>(limits.maxSwapchainImageWidth) / videoWidth,
        static_cast<double>(limits.maxSwapchainImageHeight) / videoHeight,
    });

    return {
        std::max(2u, static_cast<uint32_t>(std::lround(videoWidth * scale))),
        std::max(2u, static_cast<uint32_t>(std::lround(videoHeight * scale))),
    };
}

id<MTLRenderPipelineState> makePipeline(id<MTLDevice> device, MTLPixelFormat targetFormat)
{
    static NSString *shaderSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut videoVertex(uint vertexID [[vertex_id]])
{
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 uvs[3] = {
        float2(0.0,  1.0),
        float2(2.0,  1.0),
        float2(0.0, -1.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 videoFragment(VertexOut in [[stage_in]],
                              texture2d<float> video [[texture(0)]])
{
    constexpr sampler videoSampler(coord::normalized,
                                   address::clamp_to_edge,
                                   filter::linear);
    return video.sample(videoSampler, in.uv);
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

void renderVideoFrame(id<MTLCommandQueue> commandQueue,
                      id<MTLRenderPipelineState> pipeline,
                      id<MTLTexture> target,
                      id<MTLTexture> source)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    if (source) {
        [encoder setFragmentTexture:source atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder endEncoding];
    [commandBuffer commit];

    // Intentionally conservative for the first POC: don't release the OpenXR
    // image until Metal has finished writing it. We can remove this blocking wait
    // once the basic playback path is proven.
    [commandBuffer waitUntilCompleted];
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

        XrInstance instance = XR_NULL_HANDLE;
        XrSession session = XR_NULL_HANDLE;
        XrSpace localSpace = XR_NULL_HANDLE;
        XrSwapchain swapchain = XR_NULL_HANDLE;
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
                    (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                };
                AVPlayerItemVideoOutput *videoOutput =
                    [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixelBufferAttributes];
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

                const SwapchainSize swapchainSize =
                    chooseSwapchainSize(videoSize, systemProperties.graphicsProperties);
                const MTLPixelFormat swapchainFormat = chooseSwapchainFormat(session);

                XrSwapchainCreateInfo swapchainInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
                swapchainInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
                swapchainInfo.format = static_cast<int64_t>(swapchainFormat);
                swapchainInfo.sampleCount = 1;
                swapchainInfo.width = swapchainSize.width;
                swapchainInfo.height = swapchainSize.height;
                swapchainInfo.faceCount = 1;
                swapchainInfo.arraySize = 1;
                swapchainInfo.mipCount = 1;
                checkXr(xrCreateSwapchain(session, &swapchainInfo, &swapchain),
                        "xrCreateSwapchain(video quad)");

                uint32_t swapchainImageCount = 0;
                checkXr(xrEnumerateSwapchainImages(swapchain, 0, &swapchainImageCount, nullptr),
                        "xrEnumerateSwapchainImages(count)");
                std::vector<XrSwapchainImageMetalKHR> swapchainImages(swapchainImageCount);
                for (auto &image : swapchainImages) {
                    image = {XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
                }
                checkXr(xrEnumerateSwapchainImages(
                            swapchain,
                            swapchainImageCount,
                            &swapchainImageCount,
                            reinterpret_cast<XrSwapchainImageBaseHeader *>(swapchainImages.data())),
                        "xrEnumerateSwapchainImages(list)");

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

                std::printf("OpenXR system: %s\n", systemProperties.systemName);
                std::printf("Metal device: %s\n", device.name.UTF8String);
                std::printf("Video: %.0fx%.0f (aspect %.3f)\n", videoSize.width, videoSize.height, aspect);
                std::printf("Quad swapchain: %ux%u; virtual screen %.2fm x %.2fm at 2.0m\n",
                            swapchainSize.width,
                            swapchainSize.height,
                            panelWidth,
                            panelHeight);
                std::printf("Audio follows the current macOS default output in this POC. Ctrl-C exits.\n");

                bool sessionRunning = false;
                bool exitRequested = false;
                XrSessionState sessionState = XR_SESSION_STATE_UNKNOWN;

                while (!exitRequested && !gStopRequested.load()) {
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
                                [player play];
                            } else if (sessionState == XR_SESSION_STATE_STOPPING && sessionRunning) {
                                [player pause];
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

                    XrFrameWaitInfo waitInfo{XR_TYPE_FRAME_WAIT_INFO};
                    XrFrameState frameState{XR_TYPE_FRAME_STATE};
                    checkXr(xrWaitFrame(session, &waitInfo, &frameState), "xrWaitFrame");

                    XrFrameBeginInfo frameBeginInfo{XR_TYPE_FRAME_BEGIN_INFO};
                    checkXr(xrBeginFrame(session, &frameBeginInfo), "xrBeginFrame");

                    XrCompositionLayerQuad quad{XR_TYPE_COMPOSITION_LAYER_QUAD};
                    const XrCompositionLayerBaseHeader *layers[1] = {};
                    uint32_t layerCount = 0;

                    if (frameState.shouldRender) {
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
                            }
                        }

                        uint32_t imageIndex = 0;
                        XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
                        checkXr(xrAcquireSwapchainImage(swapchain, &acquireInfo, &imageIndex),
                                "xrAcquireSwapchainImage");

                        XrSwapchainImageWaitInfo imageWaitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                        imageWaitInfo.timeout = XR_INFINITE_DURATION;
                        checkXr(xrWaitSwapchainImage(swapchain, &imageWaitInfo),
                                "xrWaitSwapchainImage");

                        id<MTLTexture> target =
                            (__bridge id<MTLTexture>)swapchainImages[imageIndex].texture;
                        id<MTLTexture> source = nil;
                        CVMetalTextureRef cvTexture = nullptr;

                        if (currentPixelBuffer) {
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
                            }
                        }

                        renderVideoFrame(commandQueue, pipeline, target, source);
                        if (cvTexture) {
                            CFRelease(cvTexture);
                        }

                        XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                        checkXr(xrReleaseSwapchainImage(swapchain, &releaseInfo),
                                "xrReleaseSwapchainImage");

                        quad.layerFlags = 0;
                        quad.space = localSpace;
                        quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
                        quad.subImage.swapchain = swapchain;
                        quad.subImage.imageRect.offset = {0, 0};
                        quad.subImage.imageRect.extent = {
                            static_cast<int32_t>(swapchainSize.width),
                            static_cast<int32_t>(swapchainSize.height),
                        };
                        quad.subImage.imageArrayIndex = 0;
                        quad.pose.orientation = {0.0f, 0.0f, 0.0f, 1.0f};
                        quad.pose.position = {0.0f, 0.0f, -2.0f};
                        quad.size = {panelWidth, panelHeight};

                        layers[0] = reinterpret_cast<const XrCompositionLayerBaseHeader *>(&quad);
                        layerCount = 1;
                    }

                    XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
                    endInfo.displayTime = frameState.predictedDisplayTime;
                    endInfo.environmentBlendMode = blendMode;
                    endInfo.layerCount = layerCount;
                    endInfo.layers = layerCount ? layers : nullptr;
                    checkXr(xrEndFrame(session, &endInfo), "xrEndFrame");
                }

                [player pause];
            } catch (const std::exception &error) {
                std::fprintf(stderr, "gav-monado-poc: %s\n", error.what());
                if (currentPixelBuffer) {
                    CVPixelBufferRelease(currentPixelBuffer);
                    currentPixelBuffer = nullptr;
                }
                if (textureCache) {
                    CFRelease(textureCache);
                    textureCache = nullptr;
                }
                if (swapchain != XR_NULL_HANDLE) xrDestroySwapchain(swapchain);
                if (localSpace != XR_NULL_HANDLE) xrDestroySpace(localSpace);
                if (session != XR_NULL_HANDLE) xrDestroySession(session);
                if (instance != XR_NULL_HANDLE) xrDestroyInstance(instance);
                return 1;
            }
        } @catch (NSException *exception) {
            std::fprintf(stderr,
                         "gav-monado-poc: Objective-C exception: %s\n",
                         exception.reason.UTF8String);
            return 1;
        }

        if (currentPixelBuffer) CVPixelBufferRelease(currentPixelBuffer);
        if (textureCache) CFRelease(textureCache);
        if (swapchain != XR_NULL_HANDLE) xrDestroySwapchain(swapchain);
        if (localSpace != XR_NULL_HANDLE) xrDestroySpace(localSpace);
        if (session != XR_NULL_HANDLE) xrDestroySession(session);
        if (instance != XR_NULL_HANDLE) xrDestroyInstance(instance);
        return 0;
    }
}
