# GAV + Monado/OpenXR video proof of concept

This is a deliberately small proof of concept that keeps the existing GAV player untouched while proving the replacement headset path:

- **AVFoundation / AVPlayer** decodes the local video and plays its audio.
- **OpenXR** owns the headset session, lifecycle and composition timing.
- **Monado** owns PSVR2 tracking, presentation and distortion.
- **Metal** copies the latest decoded video frame into an OpenXR swapchain supplied by the runtime.
- The movie is submitted as a **world-locked `XrCompositionLayerQuad`**, 2 m in front of the LOCAL-space origin. Moving your head should therefore move relative to the screen and immediately prove that tracking is coming from Monado.

Nothing in this target opens the PSVR2 display directly or talks to the headset HID interfaces. The existing `player/` target is unchanged.

## Scope of this first version

Intentionally included:

- local video file playback;
- video and audio clocked by `AVPlayer`;
- OpenXR Metal session using `XR_KHR_metal_enable`;
- runtime-provided Metal device;
- world-locked flat virtual screen;
- conservative blocking GPU completion before releasing each OpenXR swapchain image.

Intentionally deferred until this path is proven:

- GAV SwiftUI/OSD controls;
- explicit PSVR2 audio-device routing (audio currently follows the macOS default output);
- SBS / OU stereo interpretation;
- 180°, 360°, fisheye and equirectangular projection modes;
- controller input;
- performance work such as removing the per-frame Metal wait.

The next architectural step for immersive video is an `XrCompositionLayerProjection` using `xrLocateViews`, with the existing GAV projection shaders adapted to render the decoded texture into the two OpenXR eye swapchains.

## Build on the current PSVR2 Mac setup

The working `hello_xr` build already lives under `/private/tmp/OpenXR-SDK-build`, so reuse its generated headers and loader directly:

```sh
cmake -S openxr-poc -B openxr-poc/build \
  -DOPENXR_BUILD_DIR=/private/tmp/OpenXR-SDK-build
cmake --build openxr-poc/build -j
```

This avoids requiring a second OpenXR SDK source checkout. The POC expects generated headers under `OPENXR_BUILD_DIR/include` and the loader under `OPENXR_BUILD_DIR/src/loader`.

An installed OpenXR CMake package is also supported automatically. A full `OpenXR-SDK` or `OpenXR-SDK-Source` checkout can still be supplied with `OPENXR_SDK_SOURCE`, but only if that path contains the repository's top-level `CMakeLists.txt`.

## Run

Use the same Monado runtime and loader environment as the working `hello_xr` setup:

```sh
DYLD_LIBRARY_PATH=/private/tmp/OpenXR-SDK-build/src/loader \
XR_RUNTIME_JSON=/Users/nickkennedy/Code/monado/build-macos-psvr2-display/openxr_monado-dev.json \
  ./openxr-poc/build/gav-monado-poc /path/to/movie.mp4
```

The program prints the OpenXR system, runtime-selected Metal device, source dimensions and quad swapchain size. Playback starts when the OpenXR session reaches `READY`. Press **Ctrl-C** to exit.

For the first test, use an ordinary SDR H.264/HEVC MP4 rather than HDR or an exotic pixel format. The POC asks AVFoundation for BGRA frames and limits the quad swapchain to at most 1920×1080; this keeps decoding/rendering variables out of the initial Monado test.

## What success proves

If this displays a stable flat movie with audio and the screen remains fixed in LOCAL space as you move your head, we have separated the problem cleanly:

1. GAV/AVFoundation is supplying timed decoded frames.
2. The application can render those frames with the Metal device required by the OpenXR runtime.
3. Monado is supplying the tracked headset pose and presenting the composition layer to PSVR2.

At that point the useful work is integration rather than plumbing: share the existing GAV `VideoSource`/controls and replace its direct-display renderer with OpenXR projection rendering for the immersive modes.
