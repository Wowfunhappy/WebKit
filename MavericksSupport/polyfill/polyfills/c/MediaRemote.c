// MediaRemote: local command descriptors and publication failure on an OS without mediaremoted.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>

#define MEDIA_REMOTE_PROVIDER "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

typedef uint32_t MRMediaRemoteCommand;
typedef uint32_t MRMediaRemoteError;
typedef uint32_t MRPlaybackState;
typedef uint8_t MRMediaRemoteMergePolicy;
typedef struct _MROrigin *MROriginRef;
typedef struct _MRMediaRemoteCommandInfo *MRMediaRemoteCommandInfoRef;
typedef void (^MRMediaRemoteAsyncCommandHandlerBlock)(MRMediaRemoteCommand, CFDictionaryRef, void (^)(CFArrayRef));

// kMRMediaRemoteFrameworkErrorDomain code 35 denotes a missing now-playing client.
enum { wk_MRMediaRemoteErrorNoNowPlayingClient = 35 };

// A C trampoline rather than a block literal: two translation units emitting a block that captures a
// block produce the same copy/destroy helper symbols, and libpolyfill.a is force-loaded, which makes a
// duplicate a link failure.
static void wk_mediaRemoteReportNoNowPlayingClient(void *context)
{
    void (^completion)(MRMediaRemoteError) = (void (^)(MRMediaRemoteError))context;
    completion(wk_MRMediaRemoteErrorNoNowPlayingClient);
    Block_release(completion);
}

WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoTitle, CFSTR("kMRMediaRemoteNowPlayingInfoTitle"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoArtist, CFSTR("kMRMediaRemoteNowPlayingInfoArtist"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoAlbum, CFSTR("kMRMediaRemoteNowPlayingInfoAlbum"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoArtworkData, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkData"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoArtworkDataHeight, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkDataHeight"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoArtworkDataWidth, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkDataWidth"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoArtworkMIMEType, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkMIMEType"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoArtworkIdentifier, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkIdentifier"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoDuration, CFSTR("kMRMediaRemoteNowPlayingInfoDuration"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoElapsedTime, CFSTR("kMRMediaRemoteNowPlayingInfoElapsedTime"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoPlaybackRate, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteNowPlayingInfoUniqueIdentifier, CFSTR("kMRMediaRemoteNowPlayingInfoUniqueIdentifier"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteOptionPlaybackPosition, CFSTR("kMRMediaRemoteOptionPlaybackPosition"));
WK_POLYFILL_CONST(MEDIA_REMOTE_PROVIDER, CFStringRef, kMRMediaRemoteOptionSkipInterval, CFSTR("kMRMediaRemoteOptionSkipInterval"));

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, MROriginRef, MRMediaRemoteGetLocalOrigin, (void))
{
    return NULL;
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void *, MRMediaRemoteAddAsyncCommandHandlerBlock, (MRMediaRemoteAsyncCommandHandlerBlock block))
{
    (void)block;
    return NULL;
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void, MRMediaRemoteRemoveCommandHandlerBlock, (void *observer))
{
    (void)observer;
}

// The opaque descriptor owns its command, enabled flag, and options through CF collection callbacks.
WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, MRMediaRemoteCommandInfoRef, MRMediaRemoteCommandInfoCreate, (CFAllocatorRef allocator))
{
    return (MRMediaRemoteCommandInfoRef)CFDictionaryCreateMutable(allocator, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void, MRMediaRemoteCommandInfoSetCommand, (MRMediaRemoteCommandInfoRef commandInfo, MRMediaRemoteCommand command))
{
    int64_t value = command;
    CFNumberRef number = CFNumberCreate(CFGetAllocator(commandInfo), kCFNumberSInt64Type, &value);
    CFDictionarySetValue((CFMutableDictionaryRef)commandInfo, CFSTR("command"), number);
    CFRelease(number);
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void, MRMediaRemoteCommandInfoSetEnabled, (MRMediaRemoteCommandInfoRef commandInfo, Boolean enabled))
{
    CFDictionarySetValue((CFMutableDictionaryRef)commandInfo, CFSTR("enabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void, MRMediaRemoteCommandInfoSetOptions, (MRMediaRemoteCommandInfoRef commandInfo, CFDictionaryRef options))
{
    if (!options) {
        CFDictionaryRemoveValue((CFMutableDictionaryRef)commandInfo, CFSTR("options"));
        return;
    }
    CFDictionaryRef copy = CFDictionaryCreateCopy(CFGetAllocator(commandInfo), options);
    CFDictionarySetValue((CFMutableDictionaryRef)commandInfo, CFSTR("options"), copy);
    CFRelease(copy);
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void, MRMediaRemoteSetSupportedCommands, (CFArrayRef commands, MROriginRef origin, dispatch_queue_t replyQueue, void (^completion)(MRMediaRemoteError)))
{
    (void)commands;
    (void)origin;
    if (completion)
        dispatch_async_f(replyQueue, Block_copy(completion), wk_mediaRemoteReportNoNowPlayingClient);
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, Boolean, MRMediaRemoteSetCanBeNowPlayingApplication, (Boolean flag))
{
    (void)flag;
    return false;
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void, MRMediaRemoteSetNowPlayingInfo, (CFDictionaryRef info))
{
    (void)info;
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void, MRMediaRemoteSetNowPlayingInfoWithMergePolicy, (CFDictionaryRef info, MRMediaRemoteMergePolicy mergePolicy))
{
    (void)info;
    (void)mergePolicy;
}

WK_POLYFILL_ABSENT(MEDIA_REMOTE_PROVIDER, void, MRMediaRemoteSetNowPlayingApplicationPlaybackStateForOrigin, (MROriginRef origin, MRPlaybackState playbackState, dispatch_queue_t replyQueue, void (^completion)(MRMediaRemoteError)))
{
    (void)origin;
    (void)playbackState;
    if (completion)
        dispatch_async_f(replyQueue, Block_copy(completion), wk_mediaRemoteReportNoNowPlayingClient);
}
