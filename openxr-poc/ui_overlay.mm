#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "ui_overlay.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

constexpr size_t kWidth = 1024;
constexpr size_t kHeight = 512;

struct PickerEntry {
    std::string path;
    std::string name;
    bool directory{false};
};

void setFill(CGContextRef ctx, CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1.0)
{
    CGContextSetRGBFillColor(ctx, r, g, b, a);
}

void fillRounded(CGContextRef ctx, CGRect rect, CGFloat radius,
                 CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1.0)
{
    CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, nullptr);
    setFill(ctx, r, g, b, a);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);
}

struct TextLine {
    CTFontRef font{nullptr};
    CGColorRef color{nullptr};
    CFStringRef string{nullptr};
    CFAttributedStringRef attributed{nullptr};
    CTLineRef line{nullptr};
    CGFloat width{0.0};
};

TextLine makeTextLine(const std::string &text,
                      CGFloat size,
                      CGFloat r = 1.0,
                      CGFloat g = 1.0,
                      CGFloat b = 1.0)
{
    TextLine result{};
    result.string = CFStringCreateWithCString(kCFAllocatorDefault,
                                               text.c_str(),
                                               kCFStringEncodingUTF8);
    if (!result.string) return result;
    result.font = CTFontCreateWithName(CFSTR("SF Pro Display"), size, nullptr);
    result.color = CGColorCreateGenericRGB(r, g, b, 1.0);
    const void *keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void *values[] = {result.font, result.color};
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault,
                                                keys,
                                                values,
                                                2,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    result.attributed = CFAttributedStringCreate(kCFAllocatorDefault,
                                                  result.string,
                                                  attrs);
    CFRelease(attrs);
    result.line = CTLineCreateWithAttributedString(result.attributed);
    result.width = static_cast<CGFloat>(CTLineGetTypographicBounds(result.line,
                                                                   nullptr,
                                                                   nullptr,
                                                                   nullptr));
    return result;
}

void releaseTextLine(TextLine &line)
{
    if (line.line) CFRelease(line.line);
    if (line.attributed) CFRelease(line.attributed);
    if (line.color) CGColorRelease(line.color);
    if (line.font) CFRelease(line.font);
    if (line.string) CFRelease(line.string);
    line = {};
}

void drawText(CGContextRef ctx,
              const std::string &text,
              CGFloat x,
              CGFloat y,
              CGFloat size,
              CGFloat r = 1.0,
              CGFloat g = 1.0,
              CGFloat b = 1.0)
{
    if (text.empty()) return;
    TextLine line = makeTextLine(text, size, r, g, b);
    if (!line.line) {
        releaseTextLine(line);
        return;
    }
    CGContextSetTextPosition(ctx, x, y);
    CTLineDraw(line.line, ctx);
    releaseTextLine(line);
}

void drawCenteredText(CGContextRef ctx,
                      const std::string &text,
                      CGRect rect,
                      CGFloat size,
                      CGFloat r = 1.0,
                      CGFloat g = 1.0,
                      CGFloat b = 1.0)
{
    if (text.empty()) return;
    TextLine line = makeTextLine(text, size, r, g, b);
    if (!line.line) {
        releaseTextLine(line);
        return;
    }
    const CGFloat x = CGRectGetMidX(rect) - line.width * 0.5;
    const CGFloat y = CGRectGetMidY(rect) - size * 0.34;
    CGContextSetTextPosition(ctx, x, y);
    CTLineDraw(line.line, ctx);
    releaseTextLine(line);
}

std::string timeLabel(double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0.0) seconds = 0.0;
    const int total = static_cast<int>(std::llround(seconds));
    const int hours = total / 3600;
    const int minutes = (total / 60) % 60;
    const int secs = total % 60;
    char buf[32];
    if (hours > 0) {
        std::snprintf(buf, sizeof(buf), "%d:%02d:%02d", hours, minutes, secs);
    } else {
        std::snprintf(buf, sizeof(buf), "%d:%02d", minutes, secs);
    }
    return buf;
}

std::string basenameForPath(const std::string &path)
{
    if (path.empty()) return "No video";
    NSString *ns = [NSString stringWithUTF8String:path.c_str()];
    return ns.lastPathComponent.UTF8String ?: path;
}

std::string shortenedLabel(const std::string &text, NSUInteger maxCharacters)
{
    NSString *ns = [NSString stringWithUTF8String:text.c_str()];
    if (!ns) return text;
    if (ns.length <= maxCharacters) return text;
    NSString *shortened = [[ns substringToIndex:maxCharacters > 1 ? maxCharacters - 1 : 0]
        stringByAppendingString:@"…"];
    return shortened.UTF8String ?: text;
}

} // namespace

struct GAVUIOverlay {
    __strong id<MTLTexture> texture{nil};
    std::vector<uint8_t> pixels;
    std::string currentPath;
    std::string currentName;
    double currentSeconds{0.0};
    double durationSeconds{0.0};
    bool playing{false};
    bool visible{false};
    bool pickerMode{false};
    int controlSelection{1}; // Files, Play/Pause, Recenter
    std::string pickerDir;
    std::vector<PickerEntry> pickerEntries;
    int pickerSelection{0};
    int pickerOffset{0};
    std::string actionPath;
    bool dirty{true};
    double lastDraw{0.0};
};

static void redraw(GAVUIOverlay *ui);

static void loadPickerDirectory(GAVUIOverlay *ui, const std::string &path)
{
    if (!ui) return;
    NSString *dir = [NSString stringWithUTF8String:path.c_str()];
    if (!dir.length) return;

    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        return;
    }

    NSError *error = nil;
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir
                                                                                       error:&error];
    if (!names) {
        std::fprintf(stderr, "[ui] could not read %s: %s\n",
                     path.c_str(),
                     error.localizedDescription.UTF8String ?: "unknown error");
        return;
    }

    std::vector<PickerEntry> dirs;
    std::vector<PickerEntry> files;
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL childIsDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&childIsDir]) continue;
        PickerEntry entry;
        entry.path = full.UTF8String ?: "";
        entry.name = name.UTF8String ?: "";
        entry.directory = childIsDir;
        if (childIsDir) {
            dirs.push_back(std::move(entry));
        } else {
            NSString *ext = name.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"mp4"] ||
                [ext isEqualToString:@"m4v"] ||
                [ext isEqualToString:@"mov"]) {
                files.push_back(std::move(entry));
            }
        }
    }

    auto byName = [](const PickerEntry &a, const PickerEntry &b) {
        NSString *aa = [NSString stringWithUTF8String:a.name.c_str()];
        NSString *bb = [NSString stringWithUTF8String:b.name.c_str()];
        return [aa localizedCaseInsensitiveCompare:bb] == NSOrderedAscending;
    };
    std::sort(dirs.begin(), dirs.end(), byName);
    std::sort(files.begin(), files.end(), byName);

    ui->pickerEntries.clear();
    NSString *parent = dir.stringByDeletingLastPathComponent;
    if (parent.length && ![parent isEqualToString:dir]) {
        ui->pickerEntries.push_back({parent.UTF8String ?: "/", "..", true});
    }
    ui->pickerEntries.insert(ui->pickerEntries.end(), dirs.begin(), dirs.end());
    ui->pickerEntries.insert(ui->pickerEntries.end(), files.begin(), files.end());
    ui->pickerDir = dir.UTF8String ?: path;
    ui->pickerSelection = 0;
    ui->pickerOffset = 0;
    ui->dirty = true;
}

static void openPicker(GAVUIOverlay *ui)
{
    if (!ui) return;
    NSString *start = nil;
    if (!ui->currentPath.empty()) {
        NSString *current = [NSString stringWithUTF8String:ui->currentPath.c_str()];
        start = current.stringByDeletingLastPathComponent;
    }
    if (!start.length) {
        start = [NSHomeDirectory() stringByAppendingPathComponent:@"Movies"];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:start isDirectory:&isDir] || !isDir) {
            start = NSHomeDirectory();
        }
    }
    ui->pickerMode = true;
    loadPickerDirectory(ui, start.UTF8String ?: NSHomeDirectory().UTF8String);
}

static void drawTimeline(GAVUIOverlay *ui, CGContextRef ctx)
{
    const CGRect timelineRect = CGRectMake(24, 348, 976, 88);
    const CGRect track = CGRectMake(52, 377, 920, 12);

    double fraction = 0.0;
    if (std::isfinite(ui->durationSeconds) && ui->durationSeconds > 0.01) {
        fraction = std::clamp(ui->currentSeconds / ui->durationSeconds, 0.0, 1.0);
    }

    fillRounded(ctx, track, 6, 0.30, 0.32, 0.38, 1.0);
    if (fraction > 0.0) {
        fillRounded(ctx,
                    CGRectMake(track.origin.x,
                               track.origin.y,
                               track.size.width * fraction,
                               track.size.height),
                    6,
                    0.36, 0.42, 0.95, 1.0);
    }

    const CGFloat knobX = track.origin.x + track.size.width * fraction;
    setFill(ctx, 1.0, 1.0, 1.0, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(knobX - 14, CGRectGetMidY(track) - 14, 28, 28));

    const std::string current = timeLabel(ui->currentSeconds);
    const std::string duration = timeLabel(ui->durationSeconds);
    drawText(ctx, current, timelineRect.origin.x + 8, 405, 22, 0.90, 0.91, 0.94);

    TextLine durationLine = makeTextLine(duration, 22, 0.90, 0.91, 0.94);
    if (durationLine.line) {
        CGContextSetTextPosition(ctx,
                                 CGRectGetMaxX(timelineRect) - durationLine.width - 8,
                                 405);
        CTLineDraw(durationLine.line, ctx);
    }
    releaseTextLine(durationLine);
}

static void drawControlButton(CGContextRef ctx,
                              CGRect rect,
                              const std::string &label,
                              bool selected)
{
    if (selected) {
        fillRounded(ctx, rect, 14, 0.36, 0.42, 0.95, 1.0);
    } else {
        fillRounded(ctx, rect, 14, 0.20, 0.22, 0.27, 1.0);
    }
    drawCenteredText(ctx, label, rect, 32);
}

static void drawControls(GAVUIOverlay *ui, CGContextRef ctx)
{
    const std::string title = shortenedLabel(ui->currentName, 58);
    drawText(ctx, title, 30, 461, 27, 0.94, 0.95, 0.97);
    drawTimeline(ui, ctx);

    const CGFloat buttonW = 232.0;
    const CGFloat buttonH = 100.0;
    const CGFloat gap = 16.0;
    const CGFloat totalW = buttonW * 3.0 + gap * 2.0;
    const CGFloat x0 = (static_cast<CGFloat>(kWidth) - totalW) * 0.5;
    const CGFloat y = 116.0;

    const struct {
        const char *label;
        int actionIndex;
    } buttons[] = {
        {"Files", 0},
        {ui->playing ? "❚❚ Pause" : "▶ Play", 1},
        {"Recenter", 2},
    };

    for (int i = 0; i < 3; ++i) {
        drawControlButton(ctx,
                          CGRectMake(x0 + i * (buttonW + gap), y, buttonW, buttonH),
                          buttons[i].label,
                          ui->controlSelection == buttons[i].actionIndex);
    }

    drawCenteredText(ctx,
                     "D-pad: choose    Cross: select    L1/R1: seek 15 s    Circle/Menu: close",
                     CGRectMake(20, 28, kWidth - 40, 48),
                     18,
                     0.67, 0.69, 0.75);
}

static void drawPicker(GAVUIOverlay *ui, CGContextRef ctx)
{
    std::string folder = basenameForPath(ui->pickerDir);
    if (folder.empty()) folder = ui->pickerDir;
    folder = shortenedLabel(folder, 48);
    drawText(ctx, "Files — " + folder, 28, 458, 28, 0.94, 0.95, 0.97);

    constexpr int rows = 6;
    constexpr CGFloat rowH = 54.0;
    constexpr CGFloat gap = 8.0;
    constexpr CGFloat x0 = 24.0;
    constexpr CGFloat width = 976.0;

    if (ui->pickerSelection < ui->pickerOffset) ui->pickerOffset = ui->pickerSelection;
    if (ui->pickerSelection >= ui->pickerOffset + rows) {
        ui->pickerOffset = ui->pickerSelection - rows + 1;
    }

    for (int row = 0; row < rows; ++row) {
        const int index = ui->pickerOffset + row;
        if (index >= static_cast<int>(ui->pickerEntries.size())) break;
        const PickerEntry &entry = ui->pickerEntries[index];
        const CGFloat yTop = 76.0 + row * (rowH + gap);
        const CGFloat y = static_cast<CGFloat>(kHeight) - yTop - rowH;
        const CGRect rect = CGRectMake(x0, y, width, rowH);
        const bool selected = index == ui->pickerSelection;

        if (selected) {
            fillRounded(ctx, rect, 14, 0.36, 0.42, 0.95, 1.0);
        } else {
            fillRounded(ctx, rect, 14, 0.20, 0.22, 0.27, 1.0);
        }

        std::string icon;
        if (entry.directory) {
            icon = entry.name == ".." ? "‹  " : "▸  ";
        } else if (entry.path == ui->currentPath) {
            icon = "▶  ";
        } else {
            icon = "●  ";
        }
        const std::string label = icon + shortenedLabel(entry.name, 62);
        drawText(ctx, label, rect.origin.x + 20, rect.origin.y + 15, 26);
    }

    if (ui->pickerEntries.empty()) {
        drawCenteredText(ctx,
                         "No supported videos in this folder",
                         CGRectMake(100, 190, 824, 100),
                         24,
                         0.76, 0.78, 0.83);
    }

    drawCenteredText(ctx,
                     "D-pad ↑/↓: choose    Cross: open    Circle: player",
                     CGRectMake(20, 10, kWidth - 40, 48),
                     18,
                     0.67, 0.69, 0.75);
}

static void redraw(GAVUIOverlay *ui)
{
    if (!ui || !ui->texture) return;
    if (ui->pixels.size() != kWidth * kHeight * 4) {
        ui->pixels.resize(kWidth * kHeight * 4);
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(ui->pixels.data(),
                                             kWidth,
                                             kHeight,
                                             8,
                                             kWidth * 4,
                                             colorSpace,
                                             kCGImageAlphaPremultipliedFirst |
                                             kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!ctx) return;

    CGContextClearRect(ctx, CGRectMake(0, 0, kWidth, kHeight));

    // Match the original GAV overlay: one restrained charcoal plate rather
    // than the nested-card treatment used by the first OpenXR placeholder.
    fillRounded(ctx,
                CGRectMake(4, 4, kWidth - 8, kHeight - 8),
                28,
                0.07, 0.08, 0.10, 1.0);

    if (ui->pickerMode) drawPicker(ui, ctx);
    else drawControls(ui, ctx);

    CGContextRelease(ctx);

    [ui->texture replaceRegion:MTLRegionMake2D(0, 0, kWidth, kHeight)
                   mipmapLevel:0
                     withBytes:ui->pixels.data()
                   bytesPerRow:kWidth * 4];
    ui->dirty = false;
    ui->lastDraw = CACurrentMediaTime();
}

GAVUIOverlay *gav_ui_create(id<MTLDevice> device, const char *currentPath)
{
    if (!device) return nullptr;
    auto *ui = new GAVUIOverlay{};
    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:kWidth
                                    height:kHeight
                                 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    ui->texture = [device newTextureWithDescriptor:desc];
    if (!ui->texture) {
        delete ui;
        return nullptr;
    }
    ui->pixels.resize(kWidth * kHeight * 4);
    gav_ui_set_current_path(ui, currentPath);
    redraw(ui);
    std::printf("[ui] Menu/Options opens player controls and file browser\n");
    return ui;
}

void gav_ui_destroy(GAVUIOverlay *ui)
{
    delete ui;
}

id<MTLTexture> gav_ui_texture(GAVUIOverlay *ui)
{
    return ui ? ui->texture : nil;
}

void gav_ui_set_current_path(GAVUIOverlay *ui, const char *path)
{
    if (!ui) return;
    ui->currentPath = path ? path : "";
    ui->currentName = basenameForPath(ui->currentPath);
    ui->pickerMode = false;
    ui->dirty = true;
}

void gav_ui_update(GAVUIOverlay *ui,
                   double currentSeconds,
                   double durationSeconds,
                   int playing)
{
    if (!ui) return;
    ui->currentSeconds = std::isfinite(currentSeconds) ? currentSeconds : 0.0;
    ui->durationSeconds = std::isfinite(durationSeconds) ? durationSeconds : 0.0;
    ui->playing = playing != 0;
    if (ui->visible && CACurrentMediaTime() - ui->lastDraw >= 0.10) {
        ui->dirty = true;
    }
    if (ui->dirty) redraw(ui);
}

int gav_ui_visible(GAVUIOverlay *ui)
{
    return ui && ui->visible ? 1 : 0;
}

int gav_ui_process_controller(GAVUIOverlay *ui,
                              const GAVControllerSnapshot *snapshot,
                              GAVUIAction *action)
{
    if (action) *action = {GAV_UI_ACTION_NONE, nullptr};
    if (!ui || !snapshot) return 0;

    if ((snapshot->uiToggle & 1) != 0) {
        ui->visible = !ui->visible;
        if (ui->visible) ui->pickerMode = false;
        ui->dirty = true;
        redraw(ui);
        return ui->visible ? 1 : 0;
    }

    if (!ui->visible) return 0;

    if (snapshot->uiBack != 0) {
        if (ui->pickerMode) {
            ui->pickerMode = false;
        } else {
            ui->visible = false;
        }
        ui->dirty = true;
        redraw(ui);
        return 1;
    }

    if (ui->pickerMode) {
        if (snapshot->uiNavY != 0 && !ui->pickerEntries.empty()) {
            ui->pickerSelection = std::clamp(ui->pickerSelection + snapshot->uiNavY,
                                             0,
                                             static_cast<int>(ui->pickerEntries.size()) - 1);
            ui->dirty = true;
        }
        if (snapshot->uiSelect != 0 && !ui->pickerEntries.empty()) {
            const PickerEntry entry = ui->pickerEntries[ui->pickerSelection];
            if (entry.directory) {
                loadPickerDirectory(ui, entry.path);
            } else if (action) {
                ui->actionPath = entry.path;
                action->type = GAV_UI_ACTION_OPEN_PATH;
                action->path = ui->actionPath.c_str();
                ui->pickerMode = false;
                ui->visible = false;
                ui->dirty = true;
            }
        }
        if (ui->dirty) redraw(ui);
        return 1;
    }

    if (snapshot->uiNavX != 0) {
        ui->controlSelection = std::clamp(ui->controlSelection + snapshot->uiNavX, 0, 2);
        ui->dirty = true;
    }
    if (snapshot->uiNavY != 0) {
        ui->controlSelection = std::clamp(ui->controlSelection + snapshot->uiNavY, 0, 2);
        ui->dirty = true;
    }
    if (snapshot->uiSelect != 0 && action) {
        switch (ui->controlSelection) {
            case 0:
                openPicker(ui);
                break;
            case 1:
                action->type = GAV_UI_ACTION_PLAY_PAUSE;
                break;
            case 2:
                action->type = GAV_UI_ACTION_RECENTER;
                break;
        }
    }
    if (ui->dirty) redraw(ui);
    return 1;
}
