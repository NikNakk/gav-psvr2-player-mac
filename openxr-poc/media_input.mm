#import <Foundation/Foundation.h>

#include "media_input.h"

#include <cstdio>
#include <cstring>
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

GAVResolvedMediaInput
gav_resolve_media_input(const char *input)
{
    if (!input || !*input) {
        throw std::runtime_error("No media input supplied");
    }

    if (!isHttpURL(input)) {
        return {input, false};
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
            [NSString stringWithUTF8String:input],
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

        NSString *basename = resolvedPath.lastPathComponent;
        NSString *upper = basename.uppercaseString;
        bool eacHint = [upper containsString:@"EAC360"];

        // Carry forward the youtube-vr-support branch convention: YouTube 360
        // DASH downloads use EAC, and dimensions alone are not a reliable clue.
        // Explicitly tag obvious 360 titles so the renderer can auto-select EAC.
        if (!eacHint && [upper containsString:@"360"] && ![upper containsString:@"180"]) {
            NSString *taggedName = [@"EAC360 " stringByAppendingString:basename];
            NSString *taggedPath = [resolvedPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:taggedName];
            NSFileManager *fm = NSFileManager.defaultManager;
            if ([fm fileExistsAtPath:taggedPath]) {
                NSError *removeError = nil;
                if (![fm removeItemAtPath:taggedPath error:&removeError]) {
                    throw std::runtime_error(std::string("Could not replace cached YouTube EAC file: ") +
                                             (removeError.localizedDescription.UTF8String ?: "unknown error"));
                }
            }
            NSError *moveError = nil;
            if (![fm moveItemAtPath:resolvedPath toPath:taggedPath error:&moveError]) {
                throw std::runtime_error(std::string("Could not tag YouTube EAC file: ") +
                                         (moveError.localizedDescription.UTF8String ?: "unknown error"));
            }
            resolvedPath = taggedPath;
            eacHint = true;
        }

        std::printf("[youtube] local file: %s%s\n",
                    resolvedPath.UTF8String,
                    eacHint ? " (EAC360)" : "");
        return {resolvedPath.UTF8String, eacHint};
    }
#endif
}
