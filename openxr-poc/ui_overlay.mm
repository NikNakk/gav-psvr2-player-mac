#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>

#include "ui_overlay.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

constexpr size_t kWidth = 1024;
constexpr size_t kHeight = 512;
constexpr int kPickerRows = 6;
constexpr double kBrowserSnapshotInterval = 0.10;

struct PickerEntry {
    std::string path;
    std::string name;
    bool directory{false};
};

void setFill(CGContextRef ctx, CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1.0)
{
    CGContextSetRGBFillColor(ctx, r, g, b, a);
}

void fillRounded(CGContextRef ctx,
                 CGRect rect,
                 CGFloat radius,
                 CGFloat r,
                 CGFloat g,
                 CGFloat b,
                 CGFloat a = 1.0)
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

struct GAVUIOverlay;

@interface GAVYouTubeBridge : NSObject <WKScriptMessageHandler, WKNavigationDelegate>
@property(nonatomic, assign) GAVUIOverlay *owner;
@end

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
    bool browserMode{false};
    int controlSelection{1}; // Files, YouTube, Play/Pause, Recenter
    std::string pickerDir;
    std::vector<PickerEntry> pickerEntries;
    int pickerSelection{0};
    int pickerOffset{0};
    int pickerBottomSelection{-1}; // ▲, ▼, Drives, Cancel. -1 = file list
    std::string actionPath;

    __strong WKWebView *browser{nil};
    __strong NSWindow *browserWindow{nil};
    __strong GAVYouTubeBridge *browserBridge{nil};
    __strong NSImage *browserSnapshot{nil};
    bool browserLoaded{false};
    bool browserSnapshotPending{false};
    bool browserNeedsSnapshot{false};
    double lastBrowserSnapshot{0.0};
    double lastBrowserScroll{0.0};
    double lastBrowserCursorUpdate{0.0};
    double browserCursorU{0.50};
    double browserCursorV{0.50};
    std::string pendingBrowserURL;

    bool dirty{true};
    double lastDraw{0.0};
};

static void redraw(GAVUIOverlay *ui);

static void browserNeedsRefresh(GAVUIOverlay *ui)
{
    if (!ui) return;
    ui->browserNeedsSnapshot = true;
}

static void browserLaunchRequested(GAVUIOverlay *ui, NSString *url)
{
    if (!ui || !url.length) return;
    ui->pendingBrowserURL = url.UTF8String ?: "";
    std::printf("[youtube-ui] VR launch requested: %s\n",
                ui->pendingBrowserURL.c_str());
}

@implementation GAVYouTubeBridge

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    (void)userContentController;
    if (![message.name isEqualToString:@"gavVR"]) return;
    if ([message.body isKindOfClass:[NSString class]]) {
        browserLaunchRequested(self.owner, (NSString *)message.body);
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void)webView;
    (void)navigation;
    browserNeedsRefresh(self.owner);
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation
{
    (void)webView;
    (void)navigation;
    browserNeedsRefresh(self.owner);
}

@end

static NSString *browserInjectionScript()
{
    return @R"JS(
(() => {
  const BUTTON_ID = 'gav-psvr2-play-button';
  const isPlayableURL = value => {
    try {
      const u = new URL(value, location.href);
      const host = u.hostname.toLowerCase();
      const isYouTube = host === 'youtube.com' || host === 'www.youtube.com' || host.endsWith('.youtube.com');
      if (!isYouTube) return null;
      if (u.pathname === '/watch' && u.searchParams.get('v')) return u.href;
      if (u.pathname.startsWith('/shorts/')) return u.href;
    } catch (_) {}
    return null;
  };

  // Clicking a real video result should enter VR immediately rather than first
  // loading YouTube's watch page. Search/channel/playlist navigation remains
  // normal browser navigation. The injected button below remains as fallback.
  document.addEventListener('click', ev => {
    const target = ev.target instanceof Element ? ev.target : null;
    const anchor = target ? target.closest('a[href]') : null;
    if (!anchor) return;
    const playable = isPlayableURL(anchor.href);
    if (!playable) return;
    ev.preventDefault();
    ev.stopImmediatePropagation();
    window.webkit.messageHandlers.gavVR.postMessage(playable);
  }, true);

  const install = () => {
    document.querySelectorAll('video').forEach(v => { v.muted = true; v.pause(); });
    const onVideo = location.pathname === '/watch' || location.pathname.startsWith('/shorts/');
    let button = document.getElementById(BUTTON_ID);
    if (!onVideo) {
      if (button) button.remove();
      return;
    }
    if (!button) {
      button = document.createElement('button');
      button.id = BUTTON_ID;
      button.textContent = '🥽 Play in PSVR2';
      Object.assign(button.style, {
        position: 'fixed', right: '24px', bottom: '76px', zIndex: '2147483647',
        border: '1px solid rgba(255,255,255,.32)', borderRadius: '14px',
        padding: '13px 18px', color: 'white', background: 'rgba(92,107,242,.96)',
        font: '600 16px -apple-system, BlinkMacSystemFont, sans-serif',
        boxShadow: '0 8px 28px rgba(0,0,0,.38)', cursor: 'pointer'
      });
      button.addEventListener('click', ev => {
        ev.preventDefault();
        ev.stopPropagation();
        window.webkit.messageHandlers.gavVR.postMessage(location.href);
      }, true);
      document.documentElement.appendChild(button);
    }
  };
  install();
  new MutationObserver(install).observe(document.documentElement, {subtree:true, childList:true});
  window.addEventListener('yt-navigate-finish', install, true);
  setInterval(install, 1200);
})();
)JS";
}

static void ensureBrowser(GAVUIOverlay *ui)
{
    if (!ui || ui->browser) return;

    [NSApplication sharedApplication];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
    configuration.allowsAirPlayForMediaPlayback = NO;

    WKUserContentController *content = [[WKUserContentController alloc] init];
    ui->browserBridge = [[GAVYouTubeBridge alloc] init];
    ui->browserBridge.owner = ui;
    [content addScriptMessageHandler:ui->browserBridge name:@"gavVR"];
    [content addUserScript:[[WKUserScript alloc]
        initWithSource:browserInjectionScript()
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:NO]];
    configuration.userContentController = content;

    ui->browser = [[WKWebView alloc]
        initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)
        configuration:configuration];
    ui->browser.navigationDelegate = ui->browserBridge;
    ui->browser.allowsMagnification = NO;

    ui->browserWindow = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(-20000, -20000, kWidth, kHeight)
        styleMask:NSWindowStyleMaskTitled
        backing:NSBackingStoreBuffered
        defer:NO];
    ui->browserWindow.releasedWhenClosed = NO;
    ui->browserWindow.collectionBehavior =
        NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
    ui->browserWindow.contentView = ui->browser;
    [ui->browserWindow orderFront:nil];
}

static void openBrowser(GAVUIOverlay *ui)
{
    if (!ui) return;
    ensureBrowser(ui);
    if (!ui->browser) return;

    ui->pickerMode = false;
    ui->browserMode = true;
    ui->browserCursorU = 0.50;
    ui->browserCursorV = 0.50;
    ui->lastBrowserCursorUpdate = CACurrentMediaTime();
    ui->browserNeedsSnapshot = true;
    ui->dirty = true;

    if (!ui->browserLoaded) {
        ui->browserLoaded = true;
        NSURL *url = [NSURL URLWithString:
            @"https://www.youtube.com/results?search_query=VR180+8K"];
        [ui->browser loadRequest:[NSURLRequest requestWithURL:url]];
        std::printf("[youtube-ui] opened YouTube VR browser\n");
    }
}

static void pumpBrowserRunLoop()
{
    @autoreleasepool {
        for (int i = 0; i < 4; ++i) {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate date]
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (!event) break;
            [NSApp sendEvent:event];
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
    }
}

static void requestBrowserSnapshot(GAVUIOverlay *ui)
{
    if (!ui || !ui->browser || ui->browserSnapshotPending) return;
    const double now = CACurrentMediaTime();
    if (!ui->browserNeedsSnapshot && now - ui->lastBrowserSnapshot < kBrowserSnapshotInterval) {
        return;
    }

    ui->browserNeedsSnapshot = false;
    ui->browserSnapshotPending = true;
    ui->lastBrowserSnapshot = now;
    __weak GAVYouTubeBridge *weakBridge = ui->browserBridge;
    [ui->browser takeSnapshotWithConfiguration:nil
                             completionHandler:^(NSImage *image, NSError *error) {
        GAVYouTubeBridge *bridge = weakBridge;
        GAVUIOverlay *owner = bridge.owner;
        if (!owner) return;
        owner->browserSnapshotPending = false;
        if (image) {
            owner->browserSnapshot = image;
            owner->dirty = true;
        } else if (error) {
            std::fprintf(stderr,
                         "[youtube-ui] snapshot failed: %s\n",
                         error.localizedDescription.UTF8String ?: "unknown error");
        }
    }];
}

static void browserClick(GAVUIOverlay *ui)
{
    if (!ui || !ui->browser) return;
    const double x = ui->browserCursorU * static_cast<double>(kWidth);
    const double y = ui->browserCursorV * static_cast<double>(kHeight);
    NSString *script = [NSString stringWithFormat:
        @"(() => { const e=document.elementFromPoint(%0.1f,%0.1f);"
         "if(!e)return ''; if(e.focus)e.focus(); e.click();"
         "return (e.tagName||'').toLowerCase(); })()", x, y];
    __weak GAVYouTubeBridge *weakBridge = ui->browserBridge;
    [ui->browser evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        (void)error;
        GAVYouTubeBridge *bridge = weakBridge;
        GAVUIOverlay *owner = bridge.owner;
        if (!owner) return;
        owner->browserNeedsSnapshot = true;
        if ([result isKindOfClass:[NSString class]]) {
            NSString *tag = (NSString *)result;
            if ([tag isEqualToString:@"input"] || [tag isEqualToString:@"textarea"]) {
                [owner->browserWindow makeKeyAndOrderFront:nil];
                [owner->browserWindow makeFirstResponder:owner->browser];
                std::printf("[youtube-ui] keyboard focus sent to YouTube search field\n");
            }
        }
    }];
}

static void browserScroll(GAVUIOverlay *ui, float rightY)
{
    if (!ui || !ui->browser || std::fabs(rightY) < 0.18f) return;
    const double now = CACurrentMediaTime();
    if (now - ui->lastBrowserScroll < 0.035) return;
    ui->lastBrowserScroll = now;
    const double amount = -static_cast<double>(rightY) * 110.0;
    NSString *script = [NSString stringWithFormat:@"window.scrollBy(0,%0.1f);", amount];
    [ui->browser evaluateJavaScript:script completionHandler:nil];
    ui->browserNeedsSnapshot = true;
}

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
        std::fprintf(stderr,
                     "[ui] could not read %s: %s\n",
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
    ui->pickerBottomSelection = -1;
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
    ui->browserMode = false;
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

    fillRounded(ctx, track, 6, 0.30, 0.32, 0.38, 0.92);
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

static void drawButton(CGContextRef ctx,
                       CGRect rect,
                       const std::string &label,
                       bool selected,
                       CGFloat fontSize)
{
    if (selected) {
        fillRounded(ctx, rect, 14, 0.36, 0.42, 0.95, 0.95);
    } else {
        fillRounded(ctx, rect, 14, 0.20, 0.22, 0.27, 0.90);
    }
    strokeRounded(ctx, rect, 14, 1.0, 1.0, 1.0, selected ? 0.16 : 0.08, 1.0);
    drawCenteredText(ctx, label, rect, fontSize);
}

static void drawControls(GAVUIOverlay *ui, CGContextRef ctx)
{
    const std::string title = shortenedLabel(ui->currentName, 58);
    drawText(ctx, title, 30, 461, 27, 0.94, 0.95, 0.97);
    drawTimeline(ui, ctx);

    const CGFloat buttonW = 232.0;
    const CGFloat buttonH = 100.0;
    const CGFloat gap = 16.0;
    const CGFloat x0 = 24.0;
    const CGFloat y = 116.0;

    const struct {
        const char *label;
        int actionIndex;
    } buttons[] = {
        {"Files", 0},
        {"YouTube", 1},
        {ui->playing ? "❚❚ Pause" : "▶ Play", 2},
        {"Recenter", 3},
    };

    for (int i = 0; i < 4; ++i) {
        drawButton(ctx,
                   CGRectMake(x0 + i * (buttonW + gap), y, buttonW, buttonH),
                   buttons[i].label,
                   ui->controlSelection == buttons[i].actionIndex,
                   i == 1 ? 29 : 31);
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

    constexpr CGFloat rowH = 54.0;
    constexpr CGFloat gap = 8.0;
    constexpr CGFloat x0 = 24.0;
    constexpr CGFloat width = 976.0;

    if (ui->pickerSelection < ui->pickerOffset) ui->pickerOffset = ui->pickerSelection;
    if (ui->pickerSelection >= ui->pickerOffset + kPickerRows) {
        ui->pickerOffset = ui->pickerSelection - kPickerRows + 1;
    }

    for (int row = 0; row < kPickerRows; ++row) {
        const int index = ui->pickerOffset + row;
        if (index >= static_cast<int>(ui->pickerEntries.size())) break;
        const PickerEntry &entry = ui->pickerEntries[index];
        const CGFloat yTop = 76.0 + row * (rowH + gap);
        const CGFloat y = static_cast<CGFloat>(kHeight) - yTop - rowH;
        const CGRect rect = CGRectMake(x0, y, width, rowH);
        const bool selected = ui->pickerBottomSelection < 0 && index == ui->pickerSelection;

        if (selected) {
            fillRounded(ctx, rect, 14, 0.36, 0.42, 0.95, 0.95);
        } else {
            fillRounded(ctx, rect, 14, 0.20, 0.22, 0.27, 0.88);
        }
        strokeRounded(ctx, rect, 14, 1.0, 1.0, 1.0, selected ? 0.15 : 0.06, 1.0);

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

    const CGFloat bottomY = 10.0;
    const CGFloat bottomH = 56.0;
    const CGFloat bottomGap = 8.0;
    const CGFloat bottomW = (width - bottomGap * 3.0) / 4.0;
    const char *bottomLabels[] = {"▲", "▼", "💾 Drives", "Cancel"};
    for (int i = 0; i < 4; ++i) {
        drawButton(ctx,
                   CGRectMake(x0 + i * (bottomW + bottomGap), bottomY, bottomW, bottomH),
                   bottomLabels[i],
                   ui->pickerBottomSelection == i,
                   i == 2 ? 24 : 26);
    }
}

static void drawBrowser(GAVUIOverlay *ui, CGContextRef ctx)
{
    if (ui->browserSnapshot) {
        NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:graphics];
        [ui->browserSnapshot drawInRect:NSMakeRect(0, 0, kWidth, kHeight)
                               fromRect:NSZeroRect
                              operation:NSCompositingOperationCopy
                               fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];
    } else {
        fillRounded(ctx, CGRectMake(4, 4, kWidth - 8, kHeight - 8), 28,
                    0.07, 0.08, 0.10, 0.94);
        drawCenteredText(ctx, "Loading YouTube VR…",
                         CGRectMake(150, 206, 724, 100), 32);
    }

    const CGRect hint = CGRectMake(18, 462, kWidth - 36, 38);
    fillRounded(ctx, hint, 12, 0.07, 0.08, 0.10, 0.82);
    drawCenteredText(ctx,
                     "Left stick/D-pad: cursor   Cross: launch/click   Right stick: scroll   Circle: back",
                     hint, 15, 0.92, 0.93, 0.96);

    const CGFloat cursorX = static_cast<CGFloat>(ui->browserCursorU * kWidth);
    const CGFloat cursorY = static_cast<CGFloat>((1.0 - ui->browserCursorV) * kHeight);
    setFill(ctx, 1.0, 1.0, 1.0, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(cursorX - 8, cursorY - 8, 16, 16));
    CGContextSetRGBStrokeColor(ctx, 0.36, 0.42, 0.95, 1.0);
    CGContextSetLineWidth(ctx, 4.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cursorX - 12, cursorY - 12, 24, 24));
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

    if (ui->browserMode) {
        drawBrowser(ui, ctx);
    } else {
        const CGRect plate = CGRectMake(4, 4, kWidth - 8, kHeight - 8);
        fillRounded(ctx, plate, 28, 0.07, 0.08, 0.10, 0.84);
        strokeRounded(ctx, plate, 28, 1.0, 1.0, 1.0, 0.11, 1.2);
        if (ui->pickerMode) drawPicker(ui, ctx);
        else drawControls(ui, ctx);
    }

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
    std::printf("[ui] Menu/Options opens player controls, files and YouTube VR browser\n");
    return ui;
}

void gav_ui_destroy(GAVUIOverlay *ui)
{
    if (!ui) return;
    if (ui->browserBridge) {
        ui->browserBridge.owner = nullptr;
    }
    if (ui->browser) {
        [ui->browser.configuration.userContentController removeScriptMessageHandlerForName:@"gavVR"];
        ui->browser.navigationDelegate = nil;
    }
    if (ui->browserWindow) {
        [ui->browserWindow orderOut:nil];
        ui->browserWindow.contentView = nil;
    }
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
    ui->browserMode = false;
    ui->pickerBottomSelection = -1;
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

    if (ui->browserMode) {
        pumpBrowserRunLoop();
        requestBrowserSnapshot(ui);
    } else if (ui->visible && CACurrentMediaTime() - ui->lastDraw >= 0.10) {
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

    if (!ui->pendingBrowserURL.empty() && action) {
        ui->actionPath = ui->pendingBrowserURL;
        ui->pendingBrowserURL.clear();
        action->type = GAV_UI_ACTION_OPEN_PATH;
        action->path = ui->actionPath.c_str();
        ui->browserMode = false;
        ui->visible = false;
        if (ui->browserWindow) [ui->browserWindow orderOut:nil];
        ui->dirty = true;
        return 1;
    }

    if ((snapshot->uiToggle & 1) != 0) {
        ui->visible = !ui->visible;
        if (ui->visible) {
            ui->pickerMode = false;
            ui->browserMode = false;
        } else if (ui->browserWindow) {
            [ui->browserWindow orderOut:nil];
        }
        ui->pickerBottomSelection = -1;
        ui->dirty = true;
        redraw(ui);
        return ui->visible ? 1 : 0;
    }

    if (!ui->visible) return 0;

    if (ui->browserMode) {
        browserScroll(ui, snapshot->rightY);

        // True analog cursor movement. A radial dead zone suppresses stick
        // noise; the nonlinear response gives fine control near centre and
        // reaches roughly 0.8 panel-widths/second at full deflection.
        const double now = CACurrentMediaTime();
        const double dt = std::clamp(now - ui->lastBrowserCursorUpdate, 0.0, 0.05);
        ui->lastBrowserCursorUpdate = now;
        const float lx = snapshot->leftX;
        const float ly = snapshot->leftY;
        const float magnitude = std::sqrt(lx * lx + ly * ly);
        constexpr float deadzone = 0.16f;
        if (magnitude > deadzone && dt > 0.0) {
            const float clampedMagnitude = std::min(magnitude, 1.0f);
            const float response = (clampedMagnitude - deadzone) / (1.0f - deadzone);
            const float curved = std::pow(response, 1.45f);
            const double speed = 0.80 * curved;
            const double nx = static_cast<double>(lx / magnitude);
            const double ny = static_cast<double>(ly / magnitude);
            ui->browserCursorU = std::clamp(ui->browserCursorU + nx * speed * dt,
                                            0.025, 0.975);
            // GameController +Y is up; browser V grows downwards.
            ui->browserCursorV = std::clamp(ui->browserCursorV - ny * speed * dt,
                                            0.04, 0.96);
            ui->dirty = true;
        }

        // D-pad remains a useful coarse positioning option.
        if (snapshot->uiNavX != 0 || snapshot->uiNavY != 0) {
            ui->browserCursorU = std::clamp(
                ui->browserCursorU + 0.075 * snapshot->uiNavX, 0.025, 0.975);
            ui->browserCursorV = std::clamp(
                ui->browserCursorV + 0.10 * snapshot->uiNavY, 0.04, 0.96);
            ui->dirty = true;
        }
        if (snapshot->uiSelect != 0) {
            browserClick(ui);
        }
        if (snapshot->uiBack != 0) {
            if (ui->browser && ui->browser.canGoBack) {
                [ui->browser goBack];
                ui->browserNeedsSnapshot = true;
            } else {
                ui->browserMode = false;
                if (ui->browserWindow) [ui->browserWindow orderOut:nil];
                ui->dirty = true;
            }
        }
        if (ui->dirty) redraw(ui);
        return 1;
    }

    if (snapshot->uiBack != 0) {
        if (ui->pickerMode) {
            ui->pickerMode = false;
            ui->pickerBottomSelection = -1;
        } else {
            ui->visible = false;
        }
        ui->dirty = true;
        redraw(ui);
        return 1;
    }

    if (ui->pickerMode) {
        const int lastIndex = static_cast<int>(ui->pickerEntries.size()) - 1;

        if (snapshot->uiNavX != 0) {
            if (ui->pickerBottomSelection < 0) {
                ui->pickerBottomSelection = 2;
            } else {
                ui->pickerBottomSelection = std::clamp(
                    ui->pickerBottomSelection + snapshot->uiNavX, 0, 3);
            }
            ui->dirty = true;
        }

        if (snapshot->uiNavY != 0) {
            if (ui->pickerBottomSelection >= 0) {
                if (snapshot->uiNavY < 0) {
                    ui->pickerBottomSelection = -1;
                }
            } else if (lastIndex >= 0) {
                const int next = ui->pickerSelection + snapshot->uiNavY;
                if (next > lastIndex) {
                    ui->pickerBottomSelection = 2;
                } else {
                    ui->pickerSelection = std::clamp(next, 0, lastIndex);
                }
            } else if (snapshot->uiNavY > 0) {
                ui->pickerBottomSelection = 2;
            }
            ui->dirty = true;
        }

        if (snapshot->uiSelect != 0) {
            if (ui->pickerBottomSelection >= 0) {
                switch (ui->pickerBottomSelection) {
                    case 0:
                        if (lastIndex >= 0) {
                            ui->pickerSelection = std::max(0, ui->pickerSelection - kPickerRows);
                            ui->pickerBottomSelection = -1;
                        }
                        break;
                    case 1:
                        if (lastIndex >= 0) {
                            ui->pickerSelection = std::min(lastIndex,
                                                           ui->pickerSelection + kPickerRows);
                            ui->pickerBottomSelection = -1;
                        }
                        break;
                    case 2:
                        loadPickerDirectory(ui, "/Volumes");
                        break;
                    case 3:
                        ui->pickerMode = false;
                        ui->pickerBottomSelection = -1;
                        break;
                }
            } else if (lastIndex >= 0) {
                const PickerEntry entry = ui->pickerEntries[ui->pickerSelection];
                if (entry.directory) {
                    loadPickerDirectory(ui, entry.path);
                } else if (action) {
                    ui->actionPath = entry.path;
                    action->type = GAV_UI_ACTION_OPEN_PATH;
                    action->path = ui->actionPath.c_str();
                    ui->pickerMode = false;
                    ui->visible = false;
                    ui->pickerBottomSelection = -1;
                    ui->dirty = true;
                }
            }
        }

        if (ui->dirty) redraw(ui);
        return 1;
    }

    if (snapshot->uiNavX != 0) {
        ui->controlSelection = std::clamp(ui->controlSelection + snapshot->uiNavX, 0, 3);
        ui->dirty = true;
    }
    if (snapshot->uiNavY != 0) {
        ui->controlSelection = std::clamp(ui->controlSelection + snapshot->uiNavY, 0, 3);
        ui->dirty = true;
    }
    if (snapshot->uiSelect != 0 && action) {
        switch (ui->controlSelection) {
            case 0:
                openPicker(ui);
                break;
            case 1:
                openBrowser(ui);
                break;
            case 2:
                action->type = GAV_UI_ACTION_PLAY_PAUSE;
                break;
            case 3:
                action->type = GAV_UI_ACTION_RECENTER;
                break;
        }
    }
    if (ui->dirty) redraw(ui);
    return 1;
}
