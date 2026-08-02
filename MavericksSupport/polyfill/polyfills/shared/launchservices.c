/*
 * LaunchServices lookups added in 10.10, absent on 10.9.
 *
 * Both are rebuilt on the 10.9-era LaunchServices calls that answer the same question, so the
 * result is the real handler rather than a caller-specific "nothing found":
 *
 *   LSCopyApplicationURLsForBundleIdentifier -> LSFindApplicationForInfo(bundle id), as a
 *                                               1-element CFArray
 *   LSCopyDefaultApplicationURLForContentType -> LSCopyDefaultRoleHandlerForContentType, then
 *                                               LSFindApplicationForInfo on the bundle id it
 *                                               returns
 *
 * Both return +1 on success, matching the Copy naming, and set *outError to a real CFError on
 * failure: a caller that sees NULL may wrap *outError to report it, and a NULL there aborts
 * some of them. The sibling LSCopyDefaultApplicationURLForURL in polyfills/system-spi.m is
 * built the same way on the same primitives.
 *
 * LSRolesMask is honoured where 10.9 can: LSCopyDefaultRoleHandlerForContentType takes the same
 * mask. Resolved with dlsym rather than declared extern because these live in 10.9's
 * LaunchServices but are not in the modern SDK's stub library, so a link-time reference fails to
 * build even though the call works at runtime.
 *
 * Plain C so the non-WebKit builds that carry no polyfill registry -- deps/build_deps.sh, which
 * force-loads these into every media dylib -- compile this same source.
 *
 * WK_POLYFILL_REGISTERED is defined only by polyfill/scripts/build-polyfill.sh, i.e. only when
 * this file is built into libpolyfill.a for WebKit. It adds the registry entries and nothing else.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

typedef UInt32 LSRolesMask;
enum { MavLSUnknownCreator = 0, MavLSApplicationNotFoundErr = -10814 };

typedef OSStatus (*MavLSFindApplicationForInfo)(OSType, CFStringRef, CFStringRef, void *, CFURLRef *);
typedef CFStringRef (*MavLSCopyDefaultRoleHandlerForContentType)(CFStringRef, LSRolesMask);

static void *mav_ls_sym(const char *name)
{
    static void *handle;
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        if (!handle)
            return NULL;
    }
    return dlsym(handle, name);
}

static void mav_ls_set_error(CFErrorRef *outError, OSStatus status)
{
    if (!outError)
        return;
    *outError = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus,
        status ? status : MavLSApplicationNotFoundErr, NULL);
}

// Resolve a bundle identifier to the application's URL. Returns +1, or NULL with *outError set.
static CFURLRef mav_url_for_bundle_id(CFStringRef bundleID, CFErrorRef *outError)
{
    MavLSFindApplicationForInfo find =
        (MavLSFindApplicationForInfo)mav_ls_sym("LSFindApplicationForInfo");
    if (!find || !bundleID) {
        mav_ls_set_error(outError, MavLSApplicationNotFoundErr);
        return NULL;
    }

    CFURLRef url = NULL;
    OSStatus status = find(MavLSUnknownCreator, bundleID, NULL, NULL, &url);
    if (status != noErr || !url) {
        if (url)
            CFRelease(url);
        mav_ls_set_error(outError, status);
        return NULL;
    }
    return url;
}

CFArrayRef LSCopyApplicationURLsForBundleIdentifier(CFStringRef inBundleIdentifier, CFErrorRef *outError)
{
    if (outError)
        *outError = NULL;

    CFURLRef url = mav_url_for_bundle_id(inBundleIdentifier, outError);
    if (!url)
        return NULL;

    // 10.9 resolves one application per bundle identifier, so the array has a single element.
    CFArrayRef urls = CFArrayCreate(kCFAllocatorDefault, (const void **)&url, 1,
        &kCFTypeArrayCallBacks);
    CFRelease(url);
    if (!urls)
        mav_ls_set_error(outError, MavLSApplicationNotFoundErr);
    return urls;
}

CFURLRef LSCopyDefaultApplicationURLForContentType(CFStringRef inContentType, LSRolesMask inRoleMask, CFErrorRef *outError)
{
    if (outError)
        *outError = NULL;

    MavLSCopyDefaultRoleHandlerForContentType roleHandler =
        (MavLSCopyDefaultRoleHandlerForContentType)mav_ls_sym("LSCopyDefaultRoleHandlerForContentType");
    if (!roleHandler || !inContentType) {
        mav_ls_set_error(outError, MavLSApplicationNotFoundErr);
        return NULL;
    }

    CFStringRef bundleID = roleHandler(inContentType, inRoleMask);
    if (!bundleID) {
        mav_ls_set_error(outError, MavLSApplicationNotFoundErr);
        return NULL;
    }

    CFURLRef url = mav_url_for_bundle_id(bundleID, outError);
    CFRelease(bundleID);
    return url;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(LSCopyApplicationURLsForBundleIdentifier, "CoreServices",
    &LSCopyApplicationURLsForBundleIdentifier, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(LSCopyDefaultApplicationURLForContentType, "CoreServices",
    &LSCopyDefaultApplicationURLForContentType, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
