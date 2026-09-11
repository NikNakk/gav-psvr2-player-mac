#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
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
        if (std::find(formats.begin(), formats.end(), static_cast<int64_t>(candidate)) != formats.end()) {
            return candidate;
        }
    }
    throw std::runtime_error("OpenXR runtime exposed no usable 8-bit Metal swapchain format");
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
    if (opaque != modes.end()) {
        return *opaque;
    }
    if (modes.empty()) {
        throw std::runtime_error("OpenXR runtime exposed no environment blend modes");
    }
    return modes.front();
}

void clearTexture(id<MTLCommandQueue> commandQueue, id<MTLTexture> texture, MTLClearColor clearColor)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = clearColor;

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    if (!commandBuffer) {
        throw std::runtime_error("Could not allocate Metal command buffer");
    }
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        throw std::runtime_error("Could not create Metal render command encoder");
    }
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status == MTLCommandBufferStatusError) {
        const char *message = commandBuffer.error.localizedDescription.UTF8String ?: "unknown Metal error";
        throw std::runtime_error(std::string("Metal clear failed: ") + message);
    }
}

struct EyeSwapchain {
    XrSwapchain handle{XR_NULL_HANDLE};
    uint32_t width{0};
    uint32_t height{0};
    std::vector<XrSwapchainImageMetalKHR> images;
};

} // namespace

int main()
{
    @autoreleasepool {
        std::signal(SIGINT, handleSignal);
        std::signal(SIGTERM, handleSignal);

        XrInstance instance = XR_NULL_HANDLE;
        XrSession session = XR_NULL_HANDLE;
        XrSpace localSpace = XR_NULL_HANDLE;
        std::vector<EyeSwapchain> eyeSwapchains;

        try {
            if (!hasMetalExtension()) {
                throw std::runtime_error("OpenXR runtime does not advertise XR_KHR_metal_enable");
            }

            const char *extensions[] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME};
            XrInstanceCreateInfo instanceInfo{XR_TYPE_INSTANCE_CREATE_INFO};
            std::strncpy(instanceInfo.applicationInfo.applicationName,
                         "GAV Monado Projection Test",
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
            if (!getMetalRequirements) {
                throw std::runtime_error("Runtime did not return xrGetMetalGraphicsRequirementsKHR");
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
                throw std::runtime_error("Could not create Metal command queue");
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
                throw std::runtime_error("Projection test expected exactly two PRIMARY_STEREO views");
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

            const MTLPixelFormat swapchainFormat = chooseSwapchainFormat(session);
            eyeSwapchains.resize(viewCount);
            for (uint32_t eye = 0; eye < viewCount; ++eye) {
                EyeSwapchain &sc = eyeSwapchains[eye];
                sc.width = viewConfigs[eye].recommendedImageRectWidth;
                sc.height = viewConfigs[eye].recommendedImageRectHeight;

                XrSwapchainCreateInfo createInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
                createInfo.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
                createInfo.format = static_cast<int64_t>(swapchainFormat);
                createInfo.sampleCount = 1;
                createInfo.width = sc.width;
                createInfo.height = sc.height;
                createInfo.faceCount = 1;
                createInfo.arraySize = 1;
                createInfo.mipCount = 1;
                checkXr(xrCreateSwapchain(session, &createInfo, &sc.handle), "xrCreateSwapchain(projection eye)");

                uint32_t imageCount = 0;
                checkXr(xrEnumerateSwapchainImages(sc.handle, 0, &imageCount, nullptr),
                        "xrEnumerateSwapchainImages(count)");
                sc.images.resize(imageCount);
                for (auto &image : sc.images) {
                    image = {XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
                }
                checkXr(xrEnumerateSwapchainImages(sc.handle,
                                                   imageCount,
                                                   &imageCount,
                                                   reinterpret_cast<XrSwapchainImageBaseHeader *>(sc.images.data())),
                        "xrEnumerateSwapchainImages(list)");

                id<MTLTexture> firstTexture = (__bridge id<MTLTexture>)sc.images[0].texture;
                std::printf("Eye %u swapchain: %ux%u, %u images, Metal texture %lux%lu format=%lu usage=0x%lx storageMode=%lu\n",
                            eye,
                            sc.width,
                            sc.height,
                            imageCount,
                            static_cast<unsigned long>(firstTexture.width),
                            static_cast<unsigned long>(firstTexture.height),
                            static_cast<unsigned long>(firstTexture.pixelFormat),
                            static_cast<unsigned long>(firstTexture.usage),
                            static_cast<unsigned long>(firstTexture.storageMode));
            }

            const XrEnvironmentBlendMode blendMode = chooseBlendMode(instance, systemId);
            std::printf("OpenXR system: %s\n", systemProperties.systemName);
            std::printf("Metal device: %s\n", device.name.UTF8String);
            std::printf("PROJECTION TEST: left eye = bright magenta; right eye = bright cyan.\n");
            std::printf("This submits exactly one PRIMARY_STEREO projection layer, forcing Monado's known-working projection fast path.\n");
            std::printf("Ctrl-C exits.\n");

            bool sessionRunning = false;
            bool exitRequested = false;
            XrSessionState sessionState = XR_SESSION_STATE_UNKNOWN;
            bool loggedFirstFrame = false;

            while (!exitRequested && !gStopRequested.load()) {
                XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
                while (xrPollEvent(instance, &event) == XR_SUCCESS) {
                    if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                        const auto *changed = reinterpret_cast<const XrEventDataSessionStateChanged *>(&event);
                        sessionState = changed->state;
                        std::printf("OpenXR session state: %s\n", sessionStateName(sessionState));

                        if (sessionState == XR_SESSION_STATE_READY && !sessionRunning) {
                            XrSessionBeginInfo beginInfo{XR_TYPE_SESSION_BEGIN_INFO};
                            beginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                            checkXr(xrBeginSession(session, &beginInfo), "xrBeginSession");
                            sessionRunning = true;
                        } else if (sessionState == XR_SESSION_STATE_STOPPING && sessionRunning) {
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

                XrFrameBeginInfo beginFrameInfo{XR_TYPE_FRAME_BEGIN_INFO};
                checkXr(xrBeginFrame(session, &beginFrameInfo), "xrBeginFrame");

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

                if (frameState.shouldRender && locatedViewCount == viewCount) {
                    for (uint32_t eye = 0; eye < viewCount; ++eye) {
                        EyeSwapchain &sc = eyeSwapchains[eye];
                        uint32_t imageIndex = 0;
                        XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
                        checkXr(xrAcquireSwapchainImage(sc.handle, &acquireInfo, &imageIndex),
                                "xrAcquireSwapchainImage");

                        XrSwapchainImageWaitInfo imageWaitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                        imageWaitInfo.timeout = XR_INFINITE_DURATION;
                        checkXr(xrWaitSwapchainImage(sc.handle, &imageWaitInfo), "xrWaitSwapchainImage");

                        id<MTLTexture> target = (__bridge id<MTLTexture>)sc.images[imageIndex].texture;
                        const MTLClearColor color = eye == 0
                            ? MTLClearColorMake(1.0, 0.0, 1.0, 1.0)
                            : MTLClearColorMake(0.0, 1.0, 1.0, 1.0);
                        clearTexture(commandQueue, target, color);

                        XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                        checkXr(xrReleaseSwapchainImage(sc.handle, &releaseInfo), "xrReleaseSwapchainImage");

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

                    projection.layerFlags = 0;
                    projection.space = localSpace;
                    projection.viewCount = viewCount;
                    projection.views = projectionViews.data();
                    layers[0] = reinterpret_cast<const XrCompositionLayerBaseHeader *>(&projection);
                    layerCount = 1;

                    if (!loggedFirstFrame) {
                        std::printf("Submitted first projection frame: viewStateFlags=0x%llx predictedDisplayTime=%lld\n",
                                    static_cast<unsigned long long>(viewState.viewStateFlags),
                                    static_cast<long long>(frameState.predictedDisplayTime));
                        loggedFirstFrame = true;
                    }
                }

                XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
                endInfo.displayTime = frameState.predictedDisplayTime;
                endInfo.environmentBlendMode = blendMode;
                endInfo.layerCount = layerCount;
                endInfo.layers = layerCount ? layers : nullptr;
                checkXr(xrEndFrame(session, &endInfo), "xrEndFrame");
            }
        } catch (const std::exception &error) {
            std::fprintf(stderr, "gav-monado-projection-test: %s\n", error.what());
            for (auto &sc : eyeSwapchains) {
                if (sc.handle != XR_NULL_HANDLE) xrDestroySwapchain(sc.handle);
            }
            if (localSpace != XR_NULL_HANDLE) xrDestroySpace(localSpace);
            if (session != XR_NULL_HANDLE) xrDestroySession(session);
            if (instance != XR_NULL_HANDLE) xrDestroyInstance(instance);
            return 1;
        }

        for (auto &sc : eyeSwapchains) {
            if (sc.handle != XR_NULL_HANDLE) xrDestroySwapchain(sc.handle);
        }
        if (localSpace != XR_NULL_HANDLE) xrDestroySpace(localSpace);
        if (session != XR_NULL_HANDLE) xrDestroySession(session);
        if (instance != XR_NULL_HANDLE) xrDestroyInstance(instance);
        return 0;
    }
}
