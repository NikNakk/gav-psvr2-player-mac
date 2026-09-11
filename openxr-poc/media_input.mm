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
    for (NSString *entry in entries) {
        NSString *lower = entry.lowercaseString;
        if (![entry containsString:needle] ||
            ![lower containsString:@"ambisonic"] ||
            ![extensions containsObject:entry.pathExtension.lowercaseString]) {
            continue;
        }
        return [cacheDir stringByAppendingPathComponent:entry];
    }
    return nil;
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
