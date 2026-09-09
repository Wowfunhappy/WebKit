// ImageIO: the decode-policy entry points modern WebKit calls that 10.9's ImageIO does not export.
// Nothing here decodes: this port hands image bytes to WebCore's own decoders, and what is left is
// the process-wide restriction WebKit installs over whatever else in the process reaches ImageIO.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <ImageIO/ImageIO.h>
#include <objc/runtime.h>
#include <stdbool.h>

// ---------------------------------------------------------------------------------------------------
// ImageIO decode-policy controls (newer, security hardening).
//
// These three are NOT interchangeable, and the difference is whether 10.9 already satisfies the
// postcondition the caller is asking for. Reporting success for a restriction the system never
// applied is a fake value -- the caller then believes a security boundary is in place that is not --
// which is the same defect class as an invented KERN_SUCCESS from a kernel call the OS does not have.
// ---------------------------------------------------------------------------------------------------

// "Do not use hardware decode." 10.9's ImageIO has no hardware decode path, so the postcondition is
// already true and noErr is honest: nothing was asked for that is not the case.
WK_POLYFILL_ABSENT("ImageIO", int, CGImageSourceDisableHardwareDecoding, (void))
{
    return 0; /* noErr */
}

// "Enter restricted decoding mode." 10.9's ImageIO has no restricted mode to enter, so nothing is
// restricted and unimpErr is the truth. Reporting noErr would tell WebProcessCocoa.mm that ImageIO's
// decode path is hardened, which it is not. The call site checks the status with ASSERT_UNUSED,
// compiled out of the Release build this port ships, so the honest status costs no shipping
// behaviour.
WK_POLYFILL_ABSENT("ImageIO", int, CGImageSourceEnableRestrictedDecoding, (void))
{
    return -4; /* unimpErr */
}

// "Restrict ImageIO to this UTI set." 10.9's ImageIO has no such mode, so the restriction is
// implemented here, at the same seam ImageIO enforces it: a source whose container type is outside
// the set never produces pixels. WebKit sets the list once per process
// (UTIUtilities.mm setImageSourceAllowableTypes, from WebPageCocoa.mm). Reporting success without
// applying it would tell WebKit a boundary exists that does not.
//
// Enforcement sits on the two image-PRODUCING entry points, and only those. That is where the real
// API enforces, and it is the only point an INCREMENTAL source can be judged at all -- at
// construction it has no bytes and no type. Refusing to CREATE a source for a disallowed container
// would be a contract the real API does not have: a caller that opens a source purely to read
// CGImageSourceGetType, the frame count or the properties of a container outside the set still gets
// its source from real ImageIO, and still does from this one.
// A NULL/unknown type is never rejected: "not yet determined" is not "not allowed".
//
// The restriction is inert until WebKit installs a non-empty list, so every other process, and
// WebKit itself before that call, behaves exactly as stock 10.9.
// The list lives in PROCESS-global storage, not a plain C static. libpolyfill.a is force-loaded into
// every framework, so a file-scope static is duplicated per image: WebCore's copy would be the only
// one the setter ever reaches, while the enforcement hooks linked into WebKit2 would read a copy
// that is forever empty -- and CGImageSourceSetAllowableTypes would still report noErr, claiming a
// process-wide restriction that covers one framework. The ObjC runtime's associated-object table is
// process-global, and a SEL makes a process-global key because the runtime uniques selector names.
//
// Published once and never freed: readers on the image-decoding thread hold the array while the main
// thread could publish again, so the array is made immortal (an extra CFRetain, no release path)
// rather than protected by a lock. That costs one small array per call to a function callers make
// once, and it removes the use-after-free instead of relying on the caller's std::call_once.
// Both cached: these run per decoded frame, and sel_registerName/objc_getClass are locked hash
// lookups. The SEL is process-canonical and the class object immortal, so the cached values are the
// same answers every later call would get.
static const void *wk_allowableImageTypesKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_allowableImageTypes");
    return key;
}

static id wk_allowableImageTypesAnchor(void)
{
    static id anchor;
    if (!anchor)
        anchor = (id)objc_getClass("NSObject");   // any process-global object; the runtime owns it
    return anchor;
}

static CFArrayRef wk_allowableImageTypes(void)
{
    // Read on every query, never cached per image. A cache would latch the first list installed and
    // keep enforcing it after a caller republishes a different one or retracts the restriction with
    // an empty list (GPUProcess.cpp:264 passes {}), while CGImageSourceSetAllowableTypes had already
    // reported the change applied -- success for a postcondition this code did not establish.
    // The published array is immortal, so the pointer this returns can never dangle.
    id anchor = wk_allowableImageTypesAnchor();
    return anchor ? (CFArrayRef)objc_getAssociatedObject(anchor, wk_allowableImageTypesKey()) : NULL;
}

static bool wk_imageTypeIsAllowed(CFStringRef type)
{
    CFArrayRef allowable = wk_allowableImageTypes();
    if (!allowable || !type)
        return true;   // no restriction installed, or the type is not yet known
    CFIndex count = CFArrayGetCount(allowable);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef candidate = (CFStringRef)CFArrayGetValueAtIndex(allowable, i);
        if (candidate && CFGetTypeID(candidate) == CFStringGetTypeID()
            && CFStringCompare(candidate, type, kCFCompareCaseInsensitive) == kCFCompareEqualTo)
            return true;
    }
    return false;
}

static bool wk_imageSourceIsAllowed(CGImageSourceRef source)
{
    return !source || wk_imageTypeIsAllowed(CGImageSourceGetType(source));
}

WK_POLYFILL_ABSENT("ImageIO", OSStatus, CGImageSourceSetAllowableTypes, (CFArrayRef allowableTypes))
{
    // Matches the modern contract: an empty/absent list means "no restriction".
    id anchor = wk_allowableImageTypesAnchor();
    if (!anchor)
        return -4; /* unimpErr -- without process-global storage the restriction cannot be enforced */
    CFArrayRef installed = NULL;
    if (allowableTypes && CFArrayGetCount(allowableTypes)) {
        installed = CFArrayCreateCopy(kCFAllocatorDefault, allowableTypes);
        if (!installed)
            return -108; /* memFullErr */
        CFRetain(installed);   // immortal: a decode thread may hold it across a later publish
    }
    // ASSIGN, not RETAIN: the array is already immortal, so a retain policy only adds a
    // retain/autorelease to every read on the image-decoding thread, which has no pool of its own.
    objc_setAssociatedObject(anchor, wk_allowableImageTypesKey(), (id)installed, OBJC_ASSOCIATION_ASSIGN);
    return 0; /* noErr -- the restriction is in force for the process */
}

WK_POLYFILL_REPLACES("ImageIO", CGImageRef, CGImageSourceCreateImageAtIndex, (CGImageSourceRef source, size_t index, CFDictionaryRef options))
{
    if (!WK_ORIGINAL(CGImageSourceCreateImageAtIndex) || !wk_imageSourceIsAllowed(source))
        return NULL;
    return WK_ORIGINAL(CGImageSourceCreateImageAtIndex)(source, index, options);
}

WK_POLYFILL_REPLACES("ImageIO", CGImageRef, CGImageSourceCreateThumbnailAtIndex, (CGImageSourceRef source, size_t index, CFDictionaryRef options))
{
    if (!WK_ORIGINAL(CGImageSourceCreateThumbnailAtIndex) || !wk_imageSourceIsAllowed(source))
        return NULL;
    return WK_ORIGINAL(CGImageSourceCreateThumbnailAtIndex)(source, index, options);
}
