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

@interface AVCaptureDevice (WKPolyfillScopeCaptureDevice)
- (AVCaptureDeviceType)wk_deviceType;
- (BOOL)wk_isPortraitEffectActive;
+ (AVCaptureDevice *)wk_systemPreferredCamera;
+ (AVAuthorizationStatus)wk_authorizationStatusForMediaType:(AVMediaType)mediaType;
+ (void)wk_requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))handler;
@end

@implementation AVCaptureDevice (WKPolyfillScopeCaptureDevice)

- (AVCaptureDeviceType)wk_deviceType
{
    return [self transportType] == WKAVCaptureTransportTypeBuiltIn
        ? AVCaptureDeviceTypeBuiltInWideAngleCamera : AVCaptureDeviceTypeExternalUnknown;
}

// The portrait/background-blur effect is a macOS 12 Continuity Camera feature with no 10.9
// counterpart, so no device here has it active -- which is also what the real property reports on a
// modern machine whose camera does not support it.
- (BOOL)wk_isPortraitEffectActive
{
    return NO;
}

// systemPreferredCamera is "the camera the system would choose", which on 10.9 is precisely what
// +defaultDeviceWithMediaType: answers. The modern property additionally reflects a user override
// set through +setUserPreferredCamera:, which 10.9 has no store for; a machine where the user has
// never expressed a preference is the case the two definitions agree on.
+ (AVCaptureDevice *)wk_systemPreferredCamera
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
+ (AVAuthorizationStatus)wk_authorizationStatusForMediaType:(AVMediaType)mediaType
{
    (void)mediaType;
    return AVAuthorizationStatusAuthorized;
}

// Unreachable while the status above reports Authorized (requestSystemValidation only requests access for
// a NotDetermined status), but it is the same absent 10.14 pair and callers may reach it by another route,
// so it answers consistently instead of leaving a second unrecognized selector behind. Answering
// synchronously is safe: upstream's requestAVCaptureAccessForType hops to the main run loop itself.
+ (void)wk_requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))handler
{
    (void)mediaType;
    if (handler)
        handler(YES);
}

@end
WK_POLYFILL_SEL("deviceType", "wk_deviceType");
WK_POLYFILL_SEL("isPortraitEffectActive", "wk_isPortraitEffectActive");
WK_POLYFILL_SEL("systemPreferredCamera", "wk_systemPreferredCamera");
WK_POLYFILL_SEL("authorizationStatusForMediaType:", "wk_authorizationStatusForMediaType:");
WK_POLYFILL_SEL("requestAccessForMediaType:completionHandler:", "wk_requestAccessForMediaType:completionHandler:");

// ---------------------------------------------------------------------------------------------------
// -[AVSampleBufferDisplayLayer status] / -videoPerformanceMetrics (10.10+). 10.9's layer (the class
// shipped in 10.8) cannot report a rendering status or frame metrics at all, so the truthful answers
// are StatusUnknown (0) and no-metrics (nil) — LocalSampleBufferDisplayLayer then never sees a
// spurious Failed and skips its metrics logging, which is what the absent-metrics case calls for. Installed
// by NAME: this layer does not link AVFoundation.
static long wk_avSampleBufferDisplayLayer_status(id self, SEL _cmd)
{
    (void)self;
    (void)_cmd;
    return 0; // AVQueuedSampleBufferRenderingStatusUnknown
}
static id wk_avSampleBufferDisplayLayer_videoPerformanceMetrics(id self, SEL _cmd)
{
    (void)self;
    (void)_cmd;
    return nil;
}
WK_POLYFILL_ADD("AVSampleBufferDisplayLayer", "wk_status", wk_avSampleBufferDisplayLayer_status, "q@:");
WK_POLYFILL_SEL("status", "wk_status");
WK_POLYFILL_ADD("AVSampleBufferDisplayLayer", "wk_videoPerformanceMetrics", wk_avSampleBufferDisplayLayer_videoPerformanceMetrics, "@@:");
WK_POLYFILL_SEL("videoPerformanceMetrics", "wk_videoPerformanceMetrics");

// -[AVAssetResourceLoadingDataRequest requestsAllDataToEndOfResource] is 10.11+. 10.9's AVFoundation
// always states a finite -requestedLength on a data request, so it never asks for everything through the
// end of the resource, and WebCoreAVFResourceLoader emits a bounded Range header.
static BOOL wk_avDataRequest_requestsAllDataToEndOfResource(id self, SEL _cmd)
{
    (void)self; (void)_cmd;
    return NO;
}
WK_POLYFILL_ADD("AVAssetResourceLoadingDataRequest", "wk_requestsAllDataToEndOfResource", wk_avDataRequest_requestsAllDataToEndOfResource, "c@:");
WK_POLYFILL_SEL("requestsAllDataToEndOfResource", "wk_requestsAllDataToEndOfResource");

#pragma clang diagnostic pop
