// CoreServices (LaunchServices): entry points modern WebKit calls that 10.9's CoreServices does not
// export. LSCopyApplicationURLsForBundleIdentifier and LSCopyDefaultApplicationURLForContentType live in
// polyfills/shared/launchservices.c, which the deps builds compile too.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>

// LaunchServices UTType predicates added after 10.9 (10.9's LaunchServices has the rest of the UTType
// API — UTTypeConformsTo/UTTypeCopyPreferredTagWithClass/UTTypeCopyDeclaration/etc. — but not these
// two). Both questions ARE answerable on 10.9, so ask LaunchServices rather than guessing:
//
//   declared — UTTypeCopyDeclaration returns the declaring bundle's UTI declaration, and nil for a UTI
//     no installed bundle declares. That is what "declared" means, and it is not a heuristic: on this
//     host public.png/public.jpeg/com.adobe.pdf are declared while public.webp, public.heic and
//     public.avif are NOT, which no name-shaped rule predicts.
//   dynamic — a dynamic UTI is by construction one LaunchServices synthesised under the "dyn." prefix
//     (UTTypeCreatePreferredIdentifierForTag mints them), so the prefix IS the test.
//
// -[UTType isDeclared]/-[UTType isDynamic] in classes/UniformTypeIdentifiers.m answer the same two questions and must stay
// the same two answers; they are implemented the same way there.
WK_SYSTEM_FN("CoreServices", CFDictionaryRef, UTTypeCopyDeclaration, (CFStringRef));

WK_POLYFILL_ABSENT("CoreServices", Boolean, UTTypeIsDynamic, (CFStringRef inUTI))
{
    return inUTI && CFStringHasPrefix(inUTI, CFSTR("dyn."));
}

WK_POLYFILL_ABSENT("CoreServices", Boolean, UTTypeIsDeclared, (CFStringRef inUTI))
{
    if (!inUTI || !WK_SYSTEM(UTTypeCopyDeclaration))
        return false;
    CFDictionaryRef declaration = WK_SYSTEM(UTTypeCopyDeclaration)(inUTI);
    if (!declaration)
        return false;
    CFRelease(declaration);
    return true;
}

// ---------------------------------------------------------------------------------------------------
// CoreServices / LaunchServices — called before LS check-in in auxiliary processes; no-op on 10.9.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("CoreServices", void, _CSCheckFixDisable, (void))
{
}

// ---------------------------------------------------------------------------------------------------
// LaunchServices
// ---------------------------------------------------------------------------------------------------

// LSCopyDefaultApplicationURLForURL (10.10+): which application handles this URL. Rebuild it from the
// 10.9-era LaunchServices calls — take the URL's scheme, ask for that scheme's default handler bundle
// id, and resolve the bundle id to the handler's URL — so the answer is the real default handler, not
// a stub. Returns +1 on success, matching the Copy naming.
//
// On failure *outError MUST be set to a non-NULL CFError: callers that see a NULL result immediately
// wrap *outError to report it, and a NULL there aborts them ("Attempted to create a NULL object" in
// Rust's core-foundation, which is what made Codex's "Sign in with ChatGPT" appear to hang). With a
// real error they log it and fall back cleanly.
//
// LSRolesMask is ignored: 10.9's scheme-handler registry records one default handler per scheme with
// no role distinction, so there is nothing to filter on.
//
// Its two siblings, LSCopyApplicationURLsForBundleIdentifier and
// LSCopyDefaultApplicationURLForContentType, live in polyfills/shared/launchservices.c instead:
// GLib's gosxappinfo calls them, so the media build compiles them too.
typedef UInt32 MavLSRolesMask;
enum { MavLSUnknownCreator = 0, MavLSApplicationNotFoundErr = -10814 };
WK_SYSTEM_FN("CoreServices", CFStringRef, LSCopyDefaultHandlerForURLScheme, (CFStringRef));
WK_SYSTEM_FN("CoreServices", OSStatus, LSFindApplicationForInfo, (OSType, CFStringRef, CFStringRef, void *, CFURLRef *));

WK_POLYFILL_ABSENT("CoreServices", CFURLRef, LSCopyDefaultApplicationURLForURL,
    (CFURLRef inURL, MavLSRolesMask inRoleMask, CFErrorRef *outError))
{
    (void)inRoleMask;
    OSStatus status = MavLSApplicationNotFoundErr;
    CFURLRef applicationURL = NULL;

    CFStringRef scheme = inURL ? CFURLCopyScheme(inURL) : NULL;
    if (scheme) {
        CFStringRef bundleID = WK_SYSTEM(LSCopyDefaultHandlerForURLScheme)
            ? WK_SYSTEM(LSCopyDefaultHandlerForURLScheme)(scheme) : NULL;
        if (bundleID) {
            if (WK_SYSTEM(LSFindApplicationForInfo))
                status = WK_SYSTEM(LSFindApplicationForInfo)(MavLSUnknownCreator, bundleID, NULL, NULL, &applicationURL);
            CFRelease(bundleID);
        }
        CFRelease(scheme);
    }

    if (status != noErr || !applicationURL) {
        if (applicationURL) {
            CFRelease(applicationURL);
            applicationURL = NULL;
        }
        if (outError)
            *outError = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, status, NULL);
        return NULL;
    }
    return applicationURL;
}
