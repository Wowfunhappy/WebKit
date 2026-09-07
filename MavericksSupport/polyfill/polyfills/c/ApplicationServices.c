// ApplicationServices (HIServices accessibility): entry points and constants modern WebKit references
// that 10.9's ApplicationServices does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <stdbool.h>

WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceDifferentiateWithoutColorKey, CFSTR("kAXInterfaceDifferentiateWithoutColorKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceIncreaseContrastKey, CFSTR("kAXInterfaceIncreaseContrastKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceReduceMotionKey, CFSTR("kAXInterfaceReduceMotionKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXSAccessibilityPreferenceDomain, CFSTR("kAXSAccessibilityPreferenceDomain"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXSEnhanceTextLegibilityChangedNotification, CFSTR("kAXSEnhanceTextLegibilityChangedNotification"));

// ---------------------------------------------------------------------------------------------------
// AX (HIServices, AccessibilitySupport)
// ---------------------------------------------------------------------------------------------------

// Notifies AX of a process suspend/resume. No AX process-suspend tracking on 10.9; return success.
WK_POLYFILL_ABSENT("ApplicationServices", int, _AXUIElementNotifyProcessSuspendStatus, (int status))
{
    (void)status;
    return 0; // kAXErrorSuccess
}

// AccessibilitySupport: "Increase Contrast > Enhance text legibility" accessibility setting (absent on
// 10.9 — the framework that vends it postdates this OS). FontCache::platformInvalidate reads it during
// WebProcess init (a flat-namespace bind, so it must resolve). The setting is off by default.
WK_POLYFILL_ABSENT("ApplicationServices", unsigned char, _AXSEnhanceTextLegibilityEnabled, (void))
{
    return 0;
}

// The AX client-identification override. HIServices keeps one per process: _AXSetClientIdentificationOverride
// records a client type (the layout-test drivers' accessibility controllers set kAXClientTypeWebKitTesting,
// 999999, and reset with kAXClientTypeNoActiveRequestFound, 0) and _AXGetClientForCurrentRequestUntrusted
// answers it for every request, which is how AXObjectCache::clientIsInTestMode sees the test client and
// the WebAccessibilityObjectWrapper serves the test-only attributes (AXARIARole, AXControllerFor,
// _AXPageRelativePosition, AXIsIndeterminate, ...). 10.9's HIServices identifies no client, so the
// override is the sole source and 0 (no override) is what it answers otherwise.
//
// The value lives in PROCESS-global storage: libpolyfill.a is force-loaded into every image, so the
// injected test bundle that calls the setter and the WebCore that calls the getter each carry their own
// copy of these two functions. As in ImageIO.c, the ObjC runtime's associated-object table is the
// process-global store and a SEL is a process-global key. Both cached: the getter runs per attribute
// read, and sel_registerName/objc_getClass are locked hash lookups.
static const void *wk_axClientOverrideKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_axClientIdentificationOverride");
    return key;
}

static id wk_axClientOverrideAnchor(void)
{
    static id anchor;
    if (!anchor)
        anchor = (id)objc_getClass("NSObject");   // any process-global object; the runtime owns it
    return anchor;
}

WK_POLYFILL_ABSENT("ApplicationServices", void, _AXSetClientIdentificationOverride, (int clientType))
{
    id anchor = wk_axClientOverrideAnchor();
    if (!anchor)
        return;
    CFNumberRef record = clientType ? CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &clientType) : NULL;
    objc_setAssociatedObject(anchor, wk_axClientOverrideKey(), (id)record, OBJC_ASSOCIATION_RETAIN);
    if (record)
        CFRelease(record);
}

// The secondary-accessibility-thread SPI, absent from 10.9's HIServices and named as a direct extern by
// the isolated tree (ENABLE(ACCESSIBILITY_ISOLATED_TREE) is on, matching PlatformEnableCocoa.h's Mac
// value). 10.9 has no secondary accessibility thread: AXObjectCache::initializeAXThreadIfNeeded only
// asks for one when libAccessibility's _AXSIsolatedTreeMode reports SecondaryThread, and that soft link
// resolves through a dylib this OS does not ship, so accessibility requests all arrive on the main
// thread. Both answers state exactly that.
WK_POLYFILL_ABSENT("ApplicationServices", bool, _AXUIElementRequestServicedBySecondaryAXThread, (void))
{
    return false;
}

WK_POLYFILL_ABSENT("ApplicationServices", int, _AXUIElementUseSecondaryAXThread, (bool enabled))
{
    (void)enabled;
    return -25200; // kAXErrorFailure
}

// libAccessibility's isolated-tree mode setter, named as a direct extern by WebKitTestRunner's
// accessibility controller under the same ENABLE(ACCESSIBILITY_ISOLATED_TREE). 10.9 ships no
// libAccessibility, so there is no mode to record: the reader beside it, _AXSIsolatedTreeMode, is
// soft-linked through that absent dylib and reports unavailable, which is what keeps every isolated
// tree from being built here.
WK_POLYFILL_ABSENT("/usr/lib/libAccessibility.dylib", void, _AXSSetIsolatedTreeMode, (int32_t mode))
{
    (void)mode;
}

// Referenced as a direct extern (not soft-linked) by AXObjectCache::shouldSpellCheck / clientIsInTestMode.
WK_POLYFILL_ABSENT("ApplicationServices", int, _AXGetClientForCurrentRequestUntrusted, (void))
{
    id anchor = wk_axClientOverrideAnchor();
    CFNumberRef record = anchor ? (CFNumberRef)objc_getAssociatedObject(anchor, wk_axClientOverrideKey()) : NULL;
    int clientType = 0; // kAXClientTypeNoActiveRequestFound
    if (record && CFGetTypeID(record) == CFNumberGetTypeID())
        CFNumberGetValue(record, kCFNumberIntType, &clientType);
    return clientType;
}
