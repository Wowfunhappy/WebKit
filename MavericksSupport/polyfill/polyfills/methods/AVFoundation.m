// AVFoundation: Objective-C methods on AVFoundation classes that macOS 10.9 does not have, implemented
// with the APIs 10.9 does have, and the two AVCaptureDeviceType constants those methods produce (constants
// in a methods file, next to their only producer).

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <AVFoundation/AVFoundation.h>
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

// ---------------------------------------------------------------------------------------------------
// -[AVSampleBufferDisplayLayer status] / -videoPerformanceMetrics (10.10+). 10.9's layer (the class
// shipped in 10.8) cannot report a rendering status or frame metrics at all, so the truthful answers
// are StatusUnknown (0) and no-metrics (nil) — LocalSampleBufferDisplayLayer then never sees a
// spurious Failed and skips its metrics logging, which is what the absent-metrics case calls for. Named
// by class: this layer does not link AVFoundation.
WK_POLYFILL_ADD_METHODS_ON(NSObject, "AVSampleBufferDisplayLayer")
- (NSInteger)status
{
    return 0; // AVQueuedSampleBufferRenderingStatusUnknown
}
- (id)videoPerformanceMetrics
{
    return nil;
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

#pragma clang diagnostic pop
