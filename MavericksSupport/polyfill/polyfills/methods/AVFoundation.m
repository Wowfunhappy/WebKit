// AVFoundation: Objective-C methods on AVFoundation classes that macOS 10.9 does not have, implemented
// with the APIs 10.9 does have, and the AVCaptureDeviceType and AVVideoRange constants those methods produce
// (constants in a methods file, next to their producer).

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <AVFoundation/AVFoundation.h>
#import "avf-resource-loader-drain.h"
#import "avf-display-color.h"
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// -[AVCaptureDevice deviceType] (10.15+), -portraitEffectActive (12+) and +systemPreferredCamera
// (13+): three accessors added to a class 10.9 HAS, so they are method polyfills rather than a class
// stub. AVCaptureDALDevice, the concrete class 10.9's AVFoundation hands out, raises
// unrecognized-selector for all three.
//
// deviceType names the camera's hardware kind. 10.9 has no AVCaptureDeviceType vocabulary at all --
// neither the constants nor the property -- so the distinction it can still draw is the one
// -transportType draws: a camera wired into the machine ('bltn') versus anything attached to it. That
// is exactly the built-in-wide-angle / external split, which is what the two constants below name.
// Since 10.9 has no other producer OR consumer of an AVCaptureDeviceType, the constants and this
// method are a closed system: what matters is that they are the same objects on both sides, which
// polyfilling the constants (rather than returning a literal) is what guarantees -- WebKit compares
// device types by pointer. Their values are the constants' own spelling, so a log or a debugger
// shows something meaningful.
WK_POLYFILL_CONST("AVFoundation", AVCaptureDeviceType, AVCaptureDeviceTypeBuiltInWideAngleCamera,
                  @"AVCaptureDeviceTypeBuiltInWideAngleCamera");
WK_POLYFILL_CONST("AVFoundation", AVCaptureDeviceType, AVCaptureDeviceTypeExternalUnknown,
                  @"AVCaptureDeviceTypeExternalUnknown");

// kIOAudioDeviceTransportTypeBuiltIn, the transport a camera on the logic board reports.
enum { WKAVCaptureTransportTypeBuiltIn = 'bltn' };

WK_POLYFILL_ADD_METHODS(AVCaptureDevice)

- (AVCaptureDeviceType)deviceType
{
    // Both names are 10.15+ in the SDK and absent on the 10.9 runtime; this file supplies them
    // (WK_POLYFILL_CONST above).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    return [self transportType] == WKAVCaptureTransportTypeBuiltIn
        ? AVCaptureDeviceTypeBuiltInWideAngleCamera : AVCaptureDeviceTypeExternalUnknown;
#pragma clang diagnostic pop
}

// The portrait/background-blur effect is a macOS 12 Continuity Camera feature with no 10.9
// counterpart, so no device here has it active -- which is also what the real property reports on a
// modern machine whose camera does not support it.
- (BOOL)isPortraitEffectActive
{
    return NO;
}

// -minimumFocusDistance (12+) is in millimetres, with -1 as its "unknown" value. 10.9's capture stack
// reports no focus distance for any device.
- (NSInteger)minimumFocusDistance
{
    return -1;
}

// systemPreferredCamera is "the camera the system would choose", which on 10.9 is precisely what
// +defaultDeviceWithMediaType: answers. The modern property additionally reflects a user override
// set through +setUserPreferredCamera:, which 10.9 has no store for; a machine where the user has
// never expressed a preference is the case the two definitions agree on.
+ (AVCaptureDevice *)systemPreferredCamera
{
    return [self defaultDeviceWithMediaType:AVMediaTypeVideo];
}

// +authorizationStatusForMediaType: and +requestAccessForMediaType:completionHandler: are macOS 10.14,
// added with the TCC camera/microphone gating they report on. 10.9 predates that gating entirely: there
// is no per-app camera or microphone authorization on this OS, so there is no state for these to read
// and nothing for them to ask the user. Authorized is the answer for the same reason TCCAccessPreflight
// answers Granted for kTCCServiceCamera in c/TCC.c -- not "permission was given", but "the question
// does not exist here". Denied would be wrong in a way that matters: UserMediaPermissionRequestManagerProxy
// ::requestSystemValidation treats it as a hard refusal and never reaches WebKit's own consent sheet, so
// getUserMedia would fail before ever asking the user.
//
// Absent BOTH selectors, the plain upstream call is worse than a wrong answer: AVCaptureDevice exists on
// 10.9 but does not respond, so +authorizationStatusForMediaType: raises unrecognized-selector. AppKit's
// run loop swallows that exception, requestSystemValidation's completion handler never runs, and the
// getUserMedia promise neither resolves nor rejects -- the request hangs with no prompt and no error.
+ (AVAuthorizationStatus)authorizationStatusForMediaType:(AVMediaType)mediaType
{
    (void)mediaType;
    // AVAuthorizationStatus* are enumerators -- compile-time integers with no runtime symbol.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    return AVAuthorizationStatusAuthorized;
#pragma clang diagnostic pop
}

// Unreachable while the status above reports Authorized (requestSystemValidation only requests access for
// a NotDetermined status), but it is the same absent 10.14 pair and callers may reach it by another route,
// so it answers consistently instead of leaving a second unrecognized selector behind. Answering
// synchronously is safe: upstream's requestAVCaptureAccessForType hops to the main run loop itself.
+ (void)requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))handler
{
    (void)mediaType;
    if (handler)
        handler(YES);
}

@end

// +[AVPlayer preferredVideoRangeForDisplays:] and -setVideoRangeOverride: (11+) and the AVVideoRange
// constants (12+). 10.9's AVPlayer renders every item in standard dynamic range and has no range
// override, so SDR is the preferred range of every display and an override has nothing to act on.
// WebKit reads the constants through PAL's soft links and compares a range to them by value.
WK_POLYFILL_CONST("AVFoundation", AVVideoRange, AVVideoRangeSDR, @"AVVideoRangeSDR");
WK_POLYFILL_CONST("AVFoundation", AVVideoRange, AVVideoRangeHLG, @"AVVideoRangeHLG");
WK_POLYFILL_CONST("AVFoundation", AVVideoRange, AVVideoRangeHDR10, @"AVVideoRangeHDR10");
WK_POLYFILL_CONST("AVFoundation", AVVideoRange, AVVideoRangeDolbyVisionPQ, @"AVVideoRangeDolbyVisionPQ");

WK_POLYFILL_ADD_METHODS(AVPlayer)

+ (AVVideoRange)preferredVideoRangeForDisplays:(NSArray<NSNumber *> *)displays
{
    (void)displays;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    return AVVideoRangeSDR;
#pragma clang diagnostic pop
}

- (void)setVideoRangeOverride:(AVVideoRange)videoRangeOverride
{
    (void)videoRangeOverride;
}

// -setResourceConservationLevelWhilePaused: (12+ SPI). 10.9's AVPlayer has no policy for the resources
// a paused item holds.
- (void)setResourceConservationLevelWhilePaused:(NSInteger)level
{
    (void)level;
}

@end

// CALayer's native KVC machinery reads the scoped rendering-state getters for KVO.
WK_POLYFILL_ADD_LAYER_PROPERTIES_ON(NSObject, "AVSampleBufferDisplayLayer")
- (NSInteger)status
{
    @synchronized (self) {
        return [(WKAVFDisplayColor *)objc_getAssociatedObject(self, wkAVFDisplayColorKey) status];
    }
}
- (NSError *)error
{
    @synchronized (self) {
        return [[[(WKAVFDisplayColor *)objc_getAssociatedObject(self, wkAVFDisplayColorKey) error] retain] autorelease];
    }
}
@end

WK_POLYFILL_ADD_METHODS_ON(NSObject, "AVSampleBufferDisplayLayer")
- (id)videoPerformanceMetrics
{
    return nil;
}
@end

// Mavericks presents packed RGB samples in the layer's destination space. vImage supplies the
// attachment-derived color match at the display API boundary, preserving the caller's image buffer.
WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "AVSampleBufferDisplayLayer")
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sample
{
    @autoreleasepool {
        @synchronized (self) {
            WKAVFDisplayColor *color = objc_getAssociatedObject(self, wkAVFDisplayColorKey);
            if (!color) {
                color = [[WKAVFDisplayColor alloc] init];
                objc_setAssociatedObject(self, wkAVFDisplayColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [color release];
            }
            if (!sample || !CMSampleBufferGetFormatDescription(sample)) {
                WK_ORIGINAL_METHOD(void, (CMSampleBufferRef), sample);
                return;
            }
            if ([color error])
                return;
            CMSampleBufferRef matched = [color copySample:sample forLayer:(CALayer *)self];
            if (matched) {
                WK_ORIGINAL_METHOD(void, (CMSampleBufferRef), matched);
                CFRelease(matched);
                [color setStatus:1 error:nil forLayer:(CALayer *)self];
            }
        }
    }
}
@end

WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "AVSampleBufferDisplayLayer")
- (void)flush
{
    @synchronized (self) {
        WK_ORIGINAL_METHOD(void, ());
        [(WKAVFDisplayColor *)objc_getAssociatedObject(self, wkAVFDisplayColorKey) flushForLayer:(CALayer *)self];
    }
}
- (void)flushAndRemoveImage
{
    @synchronized (self) {
        WK_ORIGINAL_METHOD(void, ());
        [(WKAVFDisplayColor *)objc_getAssociatedObject(self, wkAVFDisplayColorKey) flushForLayer:(CALayer *)self];
    }
}
@end

// -[AVAssetResourceLoadingDataRequest requestsAllDataToEndOfResource] is 10.11+. 10.9's AVFoundation
// always states a finite -requestedLength on a data request, so it never asks for everything through the
// end of the resource, and WebCoreAVFResourceLoader emits a bounded Range header.
WK_POLYFILL_ADD_METHODS_ON(NSObject, "AVAssetResourceLoadingDataRequest")
- (BOOL)requestsAllDataToEndOfResource
{
    return NO;
}
@end

// -[AVAssetResourceLoadingContentInformationRequest setContentType:] takes a uniform type identifier.
// Modern AVFoundation also accepts a MIME type there; 10.9's finds no tracks in a resource described
// that way. A value that is already an identifier passes through, so a caller handing over a UTI is
// unaffected.
WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "AVAssetResourceLoadingContentInformationRequest")
- (void)setContentType:(NSString *)contentType
{
    WK_ORIGINAL_METHOD(void, (NSString *), wkAVFContentTypeAsUTI(contentType));
}
@end

// The options an asset was made with, for the local asset the reader polyfill below builds from it.
// Only an asset at a non-local URL can reach that path, so only those carry the association.
WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "AVURLAsset")
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary *)options
{
    id asset = WK_ORIGINAL_METHOD(id, (NSURL *, NSDictionary *), URL, options);
    if (asset && options && !URL.isFileURL)
        objc_setAssociatedObject(asset, wkAVFAssetOptionsKey, options, OBJC_ASSOCIATION_COPY);
    return asset;
}
@end

// -[AVAssetReader initWithAsset:error:] reads an asset served by a resource loader delegate. 10.9's
// raises NSInvalidArgumentException for an asset at any non-local URL, so the delegate is asked for the
// bytes and the reader is given an asset over a local file holding them, carrying the options the
// original was made with. The file lives as long as that asset.
WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "AVAssetReader")
- (instancetype)initWithAsset:(AVAsset *)asset error:(NSError **)error
{
    AVURLAsset *local = wkAVFLocalAssetFor(asset);
    return WK_ORIGINAL_METHOD(id, (AVAsset *, NSError **), local ?: asset, error);
}
@end

// A reader reads its own asset's tracks. The caller took this track from the asset it asked to read, so
// where that asset was served by a resource loader delegate, the track to read is the one with the same
// trackID on the local asset the reader was given.
WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "AVAssetReaderTrackOutput")
- (instancetype)initWithTrack:(AVAssetTrack *)track outputSettings:(NSDictionary *)outputSettings
{
    AVAssetTrack *local = wkAVFLocalTrackFor(track);
    return WK_ORIGINAL_METHOD(id, (AVAssetTrack *, NSDictionary *), local ?: track, outputSettings);
}
@end

#pragma clang diagnostic pop
