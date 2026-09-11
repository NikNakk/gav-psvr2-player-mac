#!/usr/bin/env python3
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"fix_ui_stereo: {message}")


if len(sys.argv) != 2:
    fail("usage: fix_ui_stereo.py GENERATED_SOURCE")

path = pathlib.Path(sys.argv[1])
source = path.read_text()


def replace_once(needle: str, replacement: str) -> None:
    global source
    count = source.count(needle)
    if count != 1:
        fail(f"expected exactly one source fragment, found {count}: {needle[:120]!r}")
    source = source.replace(needle, replacement, 1)


# The first UI pass drew the same NDC rectangle independently in each eye.
# That is not stereo-correct with asymmetric OpenXR eye frusta and can be
# impossible to fuse. Give the UI its own world-space plane instead.
replace_once(
    '    simd_float4 ui;     // visible, NDC half-width, NDC half-height, unused\n',
    '    simd_float4 ui;     // visible, halfWidth metres, halfHeight metres, hasVideo\n'
    '    simd_float4 uiCenter;\n'
    '    simd_float4 uiRight;\n'
    '    simd_float4 uiUp;\n'
    '    simd_float4 uiNormal;\n',
)

replace_once(
    '    float4 ui;\n};\n\nvertex VertexOut videoVertex',
    '    float4 ui;\n'
    '    float4 uiCenter;\n'
    '    float4 uiRight;\n'
    '    float4 uiUp;\n'
    '    float4 uiNormal;\n'
    '};\n\nvertex VertexOut videoVertex',
)

# The UI bitmap is CoreGraphics premultiplied-alpha BGRA. Composite it over
# the already-computed video colour in shader space; this restores the original
# GAV panel's glass-like transparency without adding extra video texture taps.
replace_once(
    '''fragment float4 videoFragment(VertexOut in [[stage_in]],
                              constant ScreenUniforms &uni [[buffer(0)]],
                              texture2d<float> video [[texture(0)]],
                              texture2d<float> uiTexture [[texture(1)]])
{''',
    '''static float4 gavCompositeUI(float4 base, float4 uiPixel, bool uiHit)
{
    if (!uiHit) return base;
    const float a = clamp(uiPixel.a, 0.0, 1.0);
    return float4(uiPixel.rgb + base.rgb * (1.0 - a), 1.0);
}

fragment float4 videoFragment(VertexOut in [[stage_in]],
                              constant ScreenUniforms &uni [[buffer(0)]],
                              texture2d<float> video [[texture(0)]],
                              texture2d<float> uiTexture [[texture(1)]])
{''',
)

replace_once(
    '''    // First UI pass: a comfortable head-locked 2:1 panel. Keeping this inside
    // the known-good projection layer avoids Monado's currently broken general
    // quad-layer path. A later polish pass can give it GAV's world anchor.
    if (uni.ui.x > 0.5) {
        const float halfW = uni.ui.y;
        const float halfH = uni.ui.z;
        if (fabs(in.ndc.x) <= halfW && fabs(in.ndc.y) <= halfH) {
            const float2 uiUV = float2(0.5 + in.ndc.x / (2.0 * halfW),
                                       0.5 - in.ndc.y / (2.0 * halfH));
            return float4(uiTexture.sample(smp, uiUV).rgb, 1.0);
        }
    }
''',
    '''    // Stereo-correct UI: both eyes look at the same world-space panel.
    // Capture its premultiplied-alpha pixel now, then composite it over the
    // normal video result below instead of replacing the video outright.
    bool uiHit = false;
    float4 uiPixel = float4(0.0);
    if (uni.ui.x > 0.5) {
        const float3 uiOrigin = uni.viewPosition.xyz;
        const float3 uiCenter = uni.uiCenter.xyz;
        const float3 uiNormal = normalize(uni.uiNormal.xyz);
        const float uiDenom = dot(ray, uiNormal);
        if (fabs(uiDenom) > 1e-6) {
            const float uiDistance = dot(uiCenter - uiOrigin, uiNormal) / uiDenom;
            if (uiDistance > 0.0) {
                const float3 uiDelta = (uiOrigin + ray * uiDistance) - uiCenter;
                const float uiX = dot(uiDelta, normalize(uni.uiRight.xyz));
                const float uiY = dot(uiDelta, normalize(uni.uiUp.xyz));
                const float halfW = uni.ui.y;
                const float halfH = uni.ui.z;
                if (fabs(uiX) <= halfW && fabs(uiY) <= halfH) {
                    const float2 uiUV = float2(0.5 + uiX / (2.0 * halfW),
                                               0.5 - uiY / (2.0 * halfH));
                    uiPixel = uiTexture.sample(smp, uiUV);
                    uiHit = uiPixel.a > 0.001;
                }
            }
        }
    }
    const bool hasVideo = uni.ui.w > 0.5;
''',
)

replace_once(
    '''               id<MTLTexture> uiTexture,
               bool uiVisible,
               const XrView &view,''',
    '''               id<MTLTexture> uiTexture,
               bool uiVisible,
               const ScreenAnchor &uiAnchor,
               const XrView &view,''',
)

replace_once(
    '    if (anchor.valid && (testPattern || source || uiVisible)) {\n',
    '    if ((anchor.valid && (testPattern || source)) || (uiVisible && uiAnchor.valid)) {\n',
)

replace_once(
    '''        uni.ui = {
            uiVisible ? 1.0f : 0.0f,
            0.78f,
            0.39f,
            0.0f,
        };
''',
    '''        uni.ui = {
            (uiVisible && uiAnchor.valid) ? 1.0f : 0.0f,
            0.60f,
            0.30f,
            source ? 1.0f : 0.0f,
        };
        uni.uiCenter = {uiAnchor.center.x, uiAnchor.center.y, uiAnchor.center.z, 0.0f};
        uni.uiRight = {uiAnchor.right.x, uiAnchor.right.y, uiAnchor.right.z, 0.0f};
        uni.uiUp = {uiAnchor.up.x, uiAnchor.up.y, uiAnchor.up.z, 0.0f};
        uni.uiNormal = {uiAnchor.normal.x, uiAnchor.normal.y, uiAnchor.normal.z, 0.0f};
''',
)

replace_once(
    '''            ScreenAnchor anchor{};
            controller = gav_controller_create();
''',
    '''            ScreenAnchor anchor{};
            ScreenAnchor uiAnchor{};
            controller = gav_controller_create();
''',
)

replace_once(
    '''                GAVUIAction uiAction{};
                gav_ui_process_controller(uiOverlay, &controls, &uiAction);
                if (gav_ui_visible(uiOverlay)) {
''',
    '''                GAVUIAction uiAction{};
                const bool uiWasVisible = gav_ui_visible(uiOverlay) != 0;
                gav_ui_process_controller(uiOverlay, &controls, &uiAction);
                const bool uiIsVisible = gav_ui_visible(uiOverlay) != 0;
                if (!uiWasVisible && uiIsVisible) {
                    // Capture a fresh gaze-relative world anchor the next time
                    // xrLocateViews gives us a valid stereo pose.
                    uiAnchor.valid = false;
                }
                if (uiWasVisible && !uiIsVisible) {
                    uiAnchor.valid = false;
                }
                if (uiIsVisible) {
''',
)

replace_once(
    '''                if (!testPattern && playerStarted) {
''',
    '''                if (gav_ui_visible(uiOverlay) && !uiAnchor.valid &&
                    poseValid && locatedViewCount == viewCount) {
                    const XrQuaternionf uiQ = views[0].pose.orientation;
                    const simd_float3 uiForward = simd_normalize(
                        rotateVector(uiQ, simd_make_float3(0.0f, 0.0f, -1.0f)));
                    const simd_float3 uiRight = simd_normalize(
                        rotateVector(uiQ, simd_make_float3(1.0f, 0.0f, 0.0f)));
                    const simd_float3 uiUp = simd_normalize(
                        rotateVector(uiQ, simd_make_float3(0.0f, 1.0f, 0.0f)));
                    const simd_float3 uiEyeCenter = {
                        0.5f * (views[0].pose.position.x + views[1].pose.position.x),
                        0.5f * (views[0].pose.position.y + views[1].pose.position.y),
                        0.5f * (views[0].pose.position.z + views[1].pose.position.z),
                    };
                    uiAnchor.center = uiEyeCenter + uiForward * 1.5f;
                    uiAnchor.right = uiRight;
                    uiAnchor.up = uiUp;
                    uiAnchor.normal = -uiForward;
                    uiAnchor.valid = true;
                    std::printf("[ui] stereo panel anchored 1.5 m ahead of gaze\\n");
                }

                if (!testPattern && playerStarted) {
''',
)

replace_once(
    '''                                  gav_ui_texture(uiOverlay),
                                  gav_ui_visible(uiOverlay) != 0,
                                  views[eye],''',
    '''                                  gav_ui_texture(uiOverlay),
                                  gav_ui_visible(uiOverlay) != 0,
                                  uiAnchor,
                                  views[eye],''',
)

# Rewrite only the Metal shader's final colour returns so the sampled UI can
# be composited over every projection mode (including EAC) and over black when
# no media is loaded. Keep the rest of the Objective-C++ source untouched.
shader_start = source.find('static NSString *shaderSource = @R"METAL(')
shader_end = source.find(')METAL";', shader_start)
if shader_start < 0 or shader_end < 0:
    fail("could not locate Metal shader for alpha compositing")
shader = source[shader_start:shader_end]

shader = shader.replace(
    'return float4(0.0, 0.0, 0.0, 1.0);',
    'return gavCompositeUI(float4(0.0, 0.0, 0.0, 1.0), uiPixel, uiHit);',
)
shader = shader.replace(
    'return float4(1.0, 0.0, 1.0, 1.0);',
    'return gavCompositeUI(float4(1.0, 0.0, 1.0, 1.0), uiPixel, uiHit);',
)
shader = shader.replace(
    'return video.sample(smp, projectEAC(gavDirection, video.get_width(), video.get_height()));',
    '''if (hasVideo) {
                return gavCompositeUI(video.sample(smp,
                                                   projectEAC(gavDirection,
                                                              video.get_width(),
                                                              video.get_height())),
                                      uiPixel,
                                      uiHit);
            }
            return gavCompositeUI(float4(0.0, 0.0, 0.0, 1.0), uiPixel, uiHit);''',
)
shader = shader.replace(
    'return video.sample(smp, videoUV);',
    '''if (hasVideo) {
            return gavCompositeUI(video.sample(smp, videoUV), uiPixel, uiHit);
        }
        return gavCompositeUI(float4(0.0, 0.0, 0.0, 1.0), uiPixel, uiHit);''',
)

if 'return video.sample(' in shader:
    fail("unhandled direct video return remains after UI compositing rewrite")

source = source[:shader_start] + shader + source[shader_end:]
path.write_text(source)
