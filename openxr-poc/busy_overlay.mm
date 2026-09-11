#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "busy_overlay.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace {

void setFill(CGContextRef ctx, CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGContextSetRGBFillColor(ctx, r, g, b, a);
}

void fillRounded(CGContextRef ctx,
                 CGRect rect,
                 CGFloat radius,
                 CGFloat r,
                 CGFloat g,
                 CGFloat b,
                 CGFloat a)
{
    CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, nullptr);
    setFill(ctx, r, g, b, a);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);
}

void strokeRounded(CGContextRef ctx,
                   CGRect rect,
                   CGFloat radius,
                   CGFloat r,
                   CGFloat g,
                   CGFloat b,
                   CGFloat a,
                   CGFloat width)
{
    CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, nullptr);
    CGContextSetRGBStrokeColor(ctx, r, g, b, a);
    CGContextSetLineWidth(ctx, width);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGPathRelease(path);
}

void drawCenteredText(CGContextRef ctx,
                      const char *utf8,
                      CGRect rect,
                      CGFloat size,
                      CGFloat r,
                      CGFloat g,
                      CGFloat b)
{
    if (!utf8 || !*utf8) return;
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault,
                                                    utf8,
                                                    kCFStringEncodingUTF8);
    if (!string) return;
    CTFontRef font = CTFontCreateWithName(CFSTR("SF Pro Display"), size, nullptr);
    CGColorRef color = CGColorCreateGenericRGB(r, g, b, 1.0);
    const void *keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void *values[] = {font, color};
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault,
                                                keys,
                                                values,
                                                2,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault,
                                                                 string,
                                                                 attrs);
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    const CGFloat width = static_cast<CGFloat>(
        CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr));
    CGContextSetTextPosition(ctx,
                             CGRectGetMidX(rect) - width * 0.5,
                             CGRectGetMidY(rect) - size * 0.34);
    CTLineDraw(line, ctx);
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(attrs);
    CGColorRelease(color);
    CFRelease(font);
    CFRelease(string);
}

} // namespace

void gav_busy_overlay_draw(id<MTLTexture> texture,
                           const char *title,
                           const char *detail,
                           double timeSeconds)
{
    if (!texture) return;
    const size_t width = texture.width;
    const size_t height = texture.height;
    if (width == 0 || height == 0) return;

    static std::vector<uint8_t> pixels;
    pixels.resize(width * height * 4);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    const CGBitmapInfo bitmapInfo = static_cast<CGBitmapInfo>(
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextRef ctx = CGBitmapContextCreate(pixels.data(),
                                             width,
                                             height,
                                             8,
                                             width * 4,
                                             colorSpace,
                                             bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    if (!ctx) return;

    const CGRect bounds = CGRectMake(0, 0, width, height);
    CGContextClearRect(ctx, bounds);

    const CGRect plate = CGRectInset(bounds, 4.0, 4.0);
    fillRounded(ctx, plate, 28.0, 0.07, 0.08, 0.10, 0.90);
    strokeRounded(ctx, plate, 28.0, 1.0, 1.0, 1.0, 0.12, 1.2);

    drawCenteredText(ctx,
                     title ? title : "Preparing video…",
                     CGRectMake(80, 286, width - 160, 84),
                     35.0,
                     0.95, 0.96, 0.99);
    drawCenteredText(ctx,
                     detail ? detail : "Please wait",
                     CGRectMake(100, 230, width - 200, 54),
                     21.0,
                     0.72, 0.75, 0.82);

    const CGFloat trackW = std::min<CGFloat>(560.0, static_cast<CGFloat>(width) - 180.0);
    const CGRect track = CGRectMake((static_cast<CGFloat>(width) - trackW) * 0.5,
                                    172.0,
                                    trackW,
                                    14.0);
    fillRounded(ctx, track, 7.0, 0.26, 0.28, 0.34, 0.92);

    const CGFloat segmentW = trackW * 0.28;
    double phase = std::fmod(std::max(0.0, timeSeconds), 1.8) / 1.8;
    if (phase > 0.5) phase = 1.0 - phase;
    phase *= 2.0;
    const CGFloat segmentX = track.origin.x + (trackW - segmentW) * phase;
    fillRounded(ctx,
                CGRectMake(segmentX, track.origin.y, segmentW, track.size.height),
                7.0,
                0.36, 0.42, 0.95, 1.0);

    drawCenteredText(ctx,
                     "The headset will stay responsive while this completes",
                     CGRectMake(80, 90, width - 160, 50),
                     17.0,
                     0.58, 0.61, 0.68);

    CGContextRelease(ctx);

    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:pixels.data()
               bytesPerRow:width * 4];
}
