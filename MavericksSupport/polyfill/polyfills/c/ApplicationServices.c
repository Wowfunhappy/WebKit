// ApplicationServices (HIServices accessibility): entry points and constants modern WebKit references
// that 10.9's ApplicationServices does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceDifferentiateWithoutColorKey, CFSTR("kAXInterfaceDifferentiateWithoutColorKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceIncreaseContrastKey, CFSTR("kAXInterfaceIncreaseContrastKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceReduceMotionKey, CFSTR("kAXInterfaceReduceMotionKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXSAccessibilityPreferenceDomain, CFSTR("kAXSAccessibilityPreferenceDomain"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXSEnhanceTextLegibilityChangedNotification, CFSTR("kAXSEnhanceTextLegibilityChangedNotification"));

// ---------------------------------------------------------------------------------------------------
// AX — runtime-gated; never executed on 10.9.
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

// HIServices SPI that tags the calling process with an AX "client type" (e.g. WebKitTesting) so the AX
// runtime can special-case test harnesses. Absent on 10.9 (postdates this OS). The layout-test drivers
// (DumpRenderTree/WebKitTestRunner) call it during accessibility-controller setup; on 10.9 there is no AX
// client-type registry, so a no-op is the correct behavior (the AX tests that depend on it are skipped).
WK_POLYFILL_ABSENT("ApplicationServices", void, _AXSetClientIdentificationOverride, (int clientType))
{
    (void)clientType;
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

// _AXGetClientForCurrentRequestUntrusted reports which assistive client (VoiceOver, a test harness, ...) is
// servicing the current accessibility request. Absent on 10.9 (postdates this OS) and referenced as a direct
// extern (not soft-linked), so a call would dyld-halt WebContent on the text-input path
// (AXObjectCache::shouldSpellCheck / clientIsInTestMode). 10.9 has no AX client-type registry, so the neutral
// answer is kAXClientTypeNoActiveRequestFound (0) — no active request, hence no test/VoiceOver client.
WK_POLYFILL_ABSENT("ApplicationServices", int, _AXGetClientForCurrentRequestUntrusted, (void))
{
    return 0; // kAXClientTypeNoActiveRequestFound
}
