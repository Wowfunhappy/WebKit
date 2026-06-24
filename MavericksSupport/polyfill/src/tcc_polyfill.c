// TCC (Transparency, Consent and Control) shim for macOS 10.9.
//
// Per-application camera/microphone privacy gating did not exist before macOS 10.14. The 10.9 TCC
// framework therefore has no kTCCServiceCamera / kTCCServiceMicrophone identifiers, and WebKit's
// TCC soft-link resolves those constants to NULL. Passing a NULL service to the 10.9
// TCCAccessPreflight dereferences it (CFStringGetLength(NULL)) and crashes the UI process at
// WebProcessPool startup, via WebPreferences::platformInitializeStore ->
// UserMediaPermissionRequestManagerProxy::permittedToCapture{Audio,Video} ->
// checkUsageDescriptionStringForType. Even when handed a non-NULL string, the 10.9 TCC fails
// *closed* (returns Denied) for those unknown services, which would silently disable getUserMedia.
//
// This shim is loaded in place of the system TCC framework by WebKit::TCCLibrary() (see
// TCCSoftLink.mm). It answers the (ungated-on-10.9) camera/microphone services as Granted and
// forwards every other service to the real system TCC, and it supplies the service-identifier
// constants WebKit soft-links. TCC identifiers are exactly their name strings on every macOS, so the
// fabricated constants below carry the same CFString values the system framework would.

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

// Matches TCCAccessPreflightResult in <TCC/TCC.h>.
typedef int TCCAccessPreflightResult;
enum {
    kTCCAccessPreflightGranted = 0,
    kTCCAccessPreflightDenied  = 1,
    kTCCAccessPreflightUnknown = 2,
};

CFStringRef kTCCServiceAccessibility = CFSTR("kTCCServiceAccessibility");
CFStringRef kTCCServiceCamera = CFSTR("kTCCServiceCamera");
CFStringRef kTCCServiceMicrophone = CFSTR("kTCCServiceMicrophone");
CFStringRef kTCCServicePhotos = CFSTR("kTCCServicePhotos");
CFStringRef kTCCServiceWebKitIntelligentTrackingPrevention = CFSTR("kTCCServiceWebKitIntelligentTrackingPrevention");

typedef TCCAccessPreflightResult (*PreflightFn)(CFStringRef, CFDictionaryRef);

// Resolve the real system TCCAccessPreflight once, for services 10.9 genuinely knows (Accessibility,
// AddressBook, Calendar, ...). Idempotent; first use is on the main thread during startup.
static PreflightFn systemPreflight(void)
{
    static PreflightFn fn = NULL;
    static int resolved = 0;
    if (!resolved) {
        void* handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW);
        fn = handle ? (PreflightFn)dlsym(handle, "TCCAccessPreflight") : NULL;
        resolved = 1;
    }
    return fn;
}

TCCAccessPreflightResult TCCAccessPreflight(CFStringRef service, CFDictionaryRef options)
{
    if (service && (CFEqual(service, kTCCServiceMicrophone) || CFEqual(service, kTCCServiceCamera)))
        return kTCCAccessPreflightGranted;

    PreflightFn fn = systemPreflight();
    if (fn && service)
        return fn(service, options);
    return kTCCAccessPreflightUnknown;
}
