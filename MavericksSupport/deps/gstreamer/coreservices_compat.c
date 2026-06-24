// CoreServices compatibility shim for the vendored GStreamer (Cerbero 1.26.6,
// deploy target 10.13; see PROVENANCE.txt). The vendored libgio-2.0.0.dylib's macOS GAppInfo /
// content-type backend imports two LaunchServices functions that postdate 10.9:
//
//   LSCopyApplicationURLsForBundleIdentifier   (10.10+)
//   LSCopyDefaultApplicationURLForContentType  (10.10+)
//
// gst_init_check() exercises GIO content-type detection, so on 10.9 the lazy bind to these symbols
// fails and the WebContent process aborts the instant any media element initializes GStreamer.
//
// This shim REEXPORTS the real CoreServices framework (so every CoreServices symbol libgio actually
// uses on 10.9 still resolves) and DEFINES exactly those two gap functions, returning NULL — GAppInfo
// then reports "no default application", which GStreamer tolerates (it never needs a default handler
// to decode media). install-safari7.sh repoints each vendored GStreamer dylib's CoreServices
// dependency to @rpath/libcoreservices_compat.dylib, so the existing two-level bind ordinals resolve
// on 10.9 with no flat-namespace games — mirroring libsystem_compat.dylib for libSystem.

#include <CoreFoundation/CoreFoundation.h>

typedef UInt32 LSRolesMask;

CFArrayRef LSCopyApplicationURLsForBundleIdentifier(CFStringRef inBundleIdentifier, CFErrorRef *outError)
{
    (void)inBundleIdentifier;
    if (outError)
        *outError = NULL;
    return NULL;
}

CFURLRef LSCopyDefaultApplicationURLForContentType(CFStringRef inContentType, LSRolesMask inRoleMask, CFErrorRef *outError)
{
    (void)inContentType;
    (void)inRoleMask;
    if (outError)
        *outError = NULL;
    return NULL;
}
