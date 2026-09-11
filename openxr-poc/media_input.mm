#import <Foundation/Foundation.h>

#include "media_input.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <strings.h>
#include <stdexcept>

#ifndef GAV_ENABLE_YTDLP
#define GAV_ENABLE_YTDLP 0
#endif

static bool
isHttpURL(const char *input)
{
    if (!input) {
        return false;
    }
    return std::strncmp(input, "http://", 7) == 0 || std::strncmp(input, "https://", 8) == 0;
}

static NSString *
youtubeVideoID(NSString *urlString)
{
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    if (!components) {
        return nil;
    }

    NSString *host = components.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"youtu.be"] || [host hasSuffix:@".youtu.be"]) {
        NSArray<NSString *> *parts = components.path.pathComponents;
        for (NSString *part in parts) {
            if (part.length > 0 && ![part isEqualToString:@"/"]) {
                return part;
            }
        }
    }

    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"v"] && item.value.length > 0) {
            return item.value;
        }
    }

    NSArray<NSString *> *parts = components.path.pathComponents;
    for (NSUInteger i = 0; i + 1 < parts.count; ++i) {
        NSString *part = parts[i].lowercaseString;
        if ([part isEqualToString:@"shorts"] ||
            [part isEqualToString:@"embed"] ||
            [part isEqualToString:@"live"]) {
            NSString *candidate = parts[i + 1];
            if (candidate.length > 0) {
                return candidate;
            }
        }
    }

    return nil;
}

static bool
filenameSuggestsEAC(NSString *path)
{
    NSString *upper = path.lastPathComponent.uppercaseString;
    return [upper containsString:@"EAC360"] ||
           ([upper containsString:@"360"] && ![upper containsString:@"180"]);
}

static NSString *
findCachedYouTubeFile(NSString *cacheDir, NSString *videoID)
{
    if (videoID.length == 0) {
        return nil;
    }

    NSError *error = nil;
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:cacheDir error:&error];
    if (!entries) {
        return nil;
    }

    NSString *needle = [NSString stringWithFormat:@"[%@]", videoID];
    NSString *fallback = nil;
    for (NSString *entry in entries) {
        if (![entry.pathExtension.lowercaseString isEqualToString:@"mp4"] ||
            ![entry containsString:needle]) {
            continue;
        }
        NSString *candidate = [cacheDir stringByAppendingPathComponent:entry];
        if (filenameSuggestsEAC(candidate)) {
            return candidate;
        }
        fallback = candidate;
    }
    return fallback;
}

static NSInteger
audioChannelCountForFile(NSString *path)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = @[
        @"ffprobe",
        @"-v", @"error",
        @"-select_streams", @"a:0",
        @"-show_entries", @"stream=channels",
        @"-of", @"default=noprint_wrappers=1:nokey=1",
        path,
    ];

    NSPipe *stdoutPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        return -1;
    }

    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        return -1;
    }

    NSString *stdoutText = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
    NSString *trimmed = [stdoutText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return 0;
    }
    return trimmed.integerValue;
}

static NSString *
findCachedAmbisonicFile(NSString *cacheDir, NSString *videoID)
{
    const char *overrideValue = std::getenv("GAV_AMBISONIC_AUDIO");
    if (overrideValue && *overrideValue) {
        NSString *overridePath = [NSString stringWithUTF8String:overrideValue];
        if ([overridePath caseInsensitiveCompare:@"off"] == NSOrderedSame) {
            return nil;
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:overridePath]) {
            return overridePath;
        }
        std::fprintf(stderr, "[audio] GAV_AMBISONIC_AUDIO does not exist: %s\n", overrideValue);
    }

    if (videoID.length == 0) {
        return nil;
    }

    NSError *error = nil;
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:cacheDir error:&error];
    if (!entries) {
        return nil;
    }

    NSString *needle = [NSString stringWithFormat:@"[%@]", videoID];
    NSSet<NSString *> *extensions = [NSSet setWithArray:@[@"webm", @"mka", @"opus", @"ogg", @"m4a", @"mp4"]];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    for (NSString *entry in entries) {
        if (![entry containsString:needle] ||
            ![extensions containsObject:entry.pathExtension.lowercaseString]) {
            continue;
        }
        [candidates addObject:[cacheDir stringByAppendingPathComponent:entry]];
    }

    NSString *explicitMarker = [[NSString stringWithFormat:@"%@ ambisonic.", needle] lowercaseString];
    for (NSString *candidate in candidates) {
        NSString *lower = candidate.lastPathComponent.lowercaseString;
        if (![lower containsString:explicitMarker]) {
            continue;
        }
        const NSInteger channels = audioChannelCountForFile(candidate);
        if (channels > 2 || channels < 0) {
            return candidate;
        }
    }

    for (NSString *candidate in candidates) {
        if (audioChannelCountForFile(candidate) > 2) {
            return candidate;
        }
    }

    if (std::getenv("GAV_AMBISONIC_TRACE") != nullptr) {
        std::fprintf(stderr,
                     "[audio] no >2-channel cached sidecar found for YouTube ID %s in %s\n",
                     videoID.UTF8String ?: "<unknown>",
                     cacheDir.UTF8String ?: "<unknown>");
    }
    return nil;
}

static NSString *
discoverMultichannelFormatID(NSString *inputString)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = @[
        @"yt-dlp",
        @"-J",
        @"--no-playlist",
        @"--no-warnings",
        @"--extractor-args", @"youtube:player_client=default,web_embedded",
        inputString,
    ];

    NSPipe *stdoutPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (std::getenv("GAV_AMBISONIC_TRACE") != nullptr) {
            std::fprintf(stderr,
                         "[audio] could not launch yt-dlp format discovery: %s\n",
                         launchError.localizedDescription.UTF8String ?: "unknown error");
        }
        return nil;
    }

    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0 || stdoutData.length == 0) {
        return nil;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:stdoutData options:0 error:&jsonError];
    if (![root isKindOfClass:[NSDictionary class]]) {
        if (std::getenv("GAV_AMBISONIC_TRACE") != nullptr) {
            std::fprintf(stderr,
                         "[audio] could not parse yt-dlp format JSON: %s\n",
                         jsonError.localizedDescription.UTF8String ?: "invalid JSON");
        }
        return nil;
    }

    NSArray *formats = ((NSDictionary *)root)[@"formats"];
    if (![formats isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSString *bestFormatID = nil;
    NSInteger bestChannels = 0;
    double bestBitrate = -1.0;

    for (id value in formats) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *format = (NSDictionary *)value;
        NSString *vcodec = [format[@"vcodec"] isKindOfClass:[NSString class]] ? format[@"vcodec"] : nil;
        NSNumber *channelsNumber = [format[@"audio_channels"] isKindOfClass:[NSNumber class]] ? format[@"audio_channels"] : nil;
        NSString *formatID = [format[@"format_id"] isKindOfClass:[NSString class]] ? format[@"format_id"] : nil;
        if (![vcodec isEqualToString:@"none"] || !channelsNumber || formatID.length == 0) {
            continue;
        }

        const NSInteger channels = channelsNumber.integerValue;
        if (channels <= 2) {
            continue;
        }

        double bitrate = -1.0;
        NSNumber *abr = [format[@"abr"] isKindOfClass:[NSNumber class]] ? format[@"abr"] : nil;
        NSNumber *tbr = [format[@"tbr"] isKindOfClass:[NSNumber class]] ? format[@"tbr"] : nil;
        if (abr) {
            bitrate = abr.doubleValue;
        } else if (tbr) {
            bitrate = tbr.doubleValue;
        }

        if (channels > bestChannels ||
            (channels == bestChannels && bitrate > bestBitrate)) {
            bestChannels = channels;
            bestBitrate = bitrate;
            bestFormatID = formatID;
        }
    }

    if (bestFormatID && std::getenv("GAV_AMBISONIC_TRACE") != nullptr) {
        std::fprintf(stderr,
                     "[audio] selected YouTube spatial format %s (%ld channels, %.1f kb/s)\n",
                     bestFormatID.UTF8String ?: "<unknown>",
                     static_cast<long>(bestChannels),
                     bestBitrate);
    }
    return bestFormatID;
}

static NSString *
downloadAmbisonicYouTubeFile(NSString *cacheDir, NSString *inputString)
{
    const char *overrideValue = std::getenv("GAV_AMBISONIC_AUDIO");
    if (overrideValue && strcasecmp(overrideValue, "off") == 0) {
        return nil;
    }

    if (std::getenv("GAV_AMBISONIC_TRACE") != nullptr) {
        std::fprintf(stderr, "[audio] checking YouTube for multichannel spatial audio...\n");
    }

    NSString *formatID = discoverMultichannelFormatID(inputString);
    if (formatID.length == 0) {
        if (std::getenv("GAV_AMBISONIC_TRACE") != nullptr) {
            std::fprintf(stderr,
                         "[audio] YouTube exposes no >2-channel audio format; using stereo fallback\n");
        }
        return nil;
    }

    NSString *outputTemplate = [cacheDir stringByAppendingPathComponent:
        @"%(title)s [YT] [%(id)s] ambisonic.%(ext)s"];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = @[
        @"yt-dlp",
        @"--no-playlist",
        @"--no-warnings",
        @"--extractor-args", @"youtube:player_client=default,web_embedded",
        @"--format", formatID,
        @"--output", outputTemplate,
        @"--print", @"after_move:filepath",
        inputString,
    ];

    NSPipe *stdoutPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (std::getenv("GAV_AMBISONIC_TRACE") != nullptr) {
            std::fprintf(stderr,
                         "[audio] could not launch yt-dlp spatial download: %s\n",
                         launchError.localizedDescription.UTF8String ?: "unknown error");
        }
        return nil;
    }

    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        if (std::getenv("GAV_AMBISONIC_TRACE") != nullptr) {
            std::fprintf(stderr,
                         "[audio] yt-dlp failed downloading spatial format %s; using stereo fallback\n",
                         formatID.UTF8String ?: "<unknown>");
        }
        return nil;
    }

    NSString *stdoutText = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
    NSString *path = [stdoutText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }

    const NSInteger channels = audioChannelCountForFile(path);
    if (channels <= 2) {
        std::fprintf(stderr,
                     "[audio] downloaded spatial-audio candidate has only %ld channels; using stereo fallback\n",
                     static_cast<long>(channels));
        return nil;
    }

    std::printf("[audio] downloaded %ld-channel sidecar: %s\n",
                static_cast<long>(channels),
                path.UTF8String ?: "<unknown>");
    return path;
}

GAVResolvedMediaInput
gav_resolve_media_input(const char *input)
{
    if (!input || !*input) {
        throw std::runtime_error("No media input supplied");
    }

    if (!isHttpURL(input)) {
        const char *overrideValue = std::getenv("GAV_AMBISONIC_AUDIO");
        std::string ambisonic;
        if (overrideValue && *overrideValue && strcasecmp(overrideValue, "off") != 0) {
            ambisonic = overrideValue;
        }
        return {input, false, ambisonic};
    }

#if !GAV_ENABLE_YTDLP
    throw std::runtime_error(
        "URL input was supplied, but this build has yt-dlp support disabled. "
        "Reconfigure with -DGAV_ENABLE_YTDLP=ON and rebuild.");
#else
    @autoreleasepool {
        NSString *cacheDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/GAVPSVR2/YouTube"];
        NSError *directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&directoryError]) {
            throw std::runtime_error(std::string("Could not create YouTube cache directory: ") +
                                     (directoryError.localizedDescription.UTF8String ?: "unknown error"));
        }

        NSString *inputString = [NSString stringWithUTF8String:input];
        NSString *videoID = youtubeVideoID(inputString);
        NSString *ambisonicPath = findCachedAmbisonicFile(cacheDir, videoID);
        if (!ambisonicPath) {
            ambisonicPath = downloadAmbisonicYouTubeFile(cacheDir, inputString);
        }
        if (ambisonicPath) {
            std::printf("[audio] cached ambisonic sidecar: %s\n", ambisonicPath.UTF8String);
        }

        NSString *cachedPath = findCachedYouTubeFile(cacheDir, videoID);
        if (cachedPath) {
            const bool eacHint = filenameSuggestsEAC(cachedPath);
            std::printf("[youtube] cache hit: %s%s\n",
                        cachedPath.UTF8String,
                        eacHint ? " (EAC360)" : "");
            return {cachedPath.UTF8String,
                    eacHint,
                    ambisonicPath ? (ambisonicPath.UTF8String ?: "") : ""};
        }

        NSString *outputTemplate = [cacheDir stringByAppendingPathComponent:
            @"%(title)s [YT] [%(id)s] [%(width)sx%(height)s].%(ext)s"];

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
        task.arguments = @[
            @"yt-dlp",
            @"--no-playlist",
            @"--no-warnings",
            @"--format", @"bv*[ext=mp4][vcodec^=av01]+ba[ext=m4a]/bv*[ext=mp4][vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4]",
            @"--merge-output-format", @"mp4",
            @"--write-info-json",
            @"--output", outputTemplate,
            @"--print", @"after_move:filepath",
            inputString,
        ];

        NSPipe *stdoutPipe = [NSPipe pipe];
        task.standardOutput = stdoutPipe;
        task.standardError = [NSFileHandle fileHandleWithStandardError];

        std::printf("[youtube] resolving with yt-dlp...\n");
        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            throw std::runtime_error(std::string("Could not launch yt-dlp: ") +
                                     (launchError.localizedDescription.UTF8String ?: "unknown error"));
        }

        NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            char buffer[128];
            std::snprintf(buffer, sizeof(buffer), "yt-dlp exited with status %d", task.terminationStatus);
            throw std::runtime_error(buffer);
        }

        NSString *stdoutText = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
        NSString *resolvedPath = [stdoutText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (resolvedPath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:resolvedPath]) {
            throw std::runtime_error("yt-dlp did not produce a playable local file");
        }

        const bool eacHint = filenameSuggestsEAC(resolvedPath);
        std::printf("[youtube] local file: %s%s\n",
                    resolvedPath.UTF8String,
                    eacHint ? " (EAC360)" : "");
        return {resolvedPath.UTF8String,
                eacHint,
                ambisonicPath ? (ambisonicPath.UTF8String ?: "") : ""};
    }
#endif
}