/* polyfill_stubs.m - Polyfill stubs for macOS 10.9 Mavericks
 * Provides C function stubs, ObjC class stubs, and API polyfills
 * for symbols not available on 10.9 but needed by modern WebKit 615.1.1
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <CoreText/CoreText.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <dirent.h>
#include <limits.h>
#include <dispatch/dispatch.h>
#include <mach/port.h>

// 10.9 backport: CTRunGetBaseAdvancesAndOrigins is 10.11+, so implement it here. A naive return-0 stub
// would zero every glyph's advance and origin, so any complex-text run that reports
// kCTRunStatusHasOrigins (e.g. ligature-substituted icon fonts like Material Icons) would collapse all
// its glyphs onto x=0 and render blank. Instead take the base advances from the real (10.9)
// CTRunGetAdvances and leave the origins zero (10.9 CoreText has no per-glyph origin offsets for the
// scripts WebKit shapes here).
void CTRunGetBaseAdvancesAndOrigins(CTRunRef run, CFRange range, CGSize* advances, CGPoint* origins)
{
    if (!run)
        return;
    CFIndex glyphCount = CTRunGetGlyphCount(run);
    CFIndex count = range.length ? range.length : glyphCount;
    if (advances)
        CTRunGetAdvances(run, range, advances);
    if (origins) {
        for (CFIndex i = 0; i < count; ++i)
            origins[i] = CGPointZero;
    }
}

#pragma mark - C function stubs

int CCRandomGenerateBytes(void *bytes, size_t count) {
    arc4random_buf(bytes, count);
    return 0;
}

void abort_with_reason(uint32_t a, uint64_t b, const char *c, uint64_t d) { abort(); }
void os_fault_with_payload(uint32_t a, uint64_t b, const void *c, uint32_t d, const char *e, uint64_t f) { }

// dyld stubs
bool dyld_program_sdk_at_least(uint32_t v) { return false; }
bool dyld_program_minos_at_least(uint32_t v) { return false; }
bool dyld_sdk_at_least(const void *h, uint32_t v) { return false; }

// cache/simulator stubs
void cache_simulate_size_response(uint64_t a, uint64_t b, uint64_t c) { }

// os_variant stubs
bool os_variant_allows_internal_security_policies(const char *s) { return false; }
bool os_variant_has_internal_content(const char *s) { return false; }
bool os_variant_has_internal_diagnostics(const char *s) { return false; }

// pthread
bool pthread_self_is_exiting_np(void) { return false; }

// os_unfair_lock_assert_owner / _assert_not_owner (10.12+) are the lock-ownership debug assertions WTF::Lock
// emits under the modern SDK. The lock primitive itself is already polyfilled (os_unfair_lock_lock/unlock in
// libpolyfill's os_unfair_lock.o); only these assert helpers are absent on 10.9. No-op them (the lazy bind of
// the weak reference otherwise aborts fatally on first use, during IPC message handling on page load).
void os_unfair_lock_assert_owner(void *lock) { (void)lock; }
void os_unfair_lock_assert_not_owner(void *lock) { (void)lock; }

// os_log unified logging is 10.12+; _os_log_internal is the macro-emitted backing for every os_log()
// call site and is absent from 10.9's libSystem (it links as the Mach-O symbol __os_log_internal).
// WebKit imports it weakly, but the LAZY bind of a weak FUNCTION still aborts fatally on the first
// os_log() call ("lazy symbol binding failed"). Defining a no-op here (libpolyfill.a links into each
// framework) satisfies it in-image; logging just no-ops. (_os_log_default stays weak/NULL — the no-op
// ignores its log argument, and weak DATA resolves to NULL without a fatal bind.)
// Signature uses plain types (os_log_t/os_log_type_t aren't visible under --no-default-config);
// ABI-equivalent: os_log_t==pointer, os_log_type_t==uint8_t, buf==uint8_t*, size==uint32_t.
void _os_log_internal(void *dso, void *log, uint8_t type, const char *format, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

// os_log_create(subsystem, category) -> os_log_t (10.12+, absent on 10.9). os_log_t is an os_object /
// ObjC type, and WebKit wraps the result in a RetainPtr<os_log_t> — so it sends -retain/-release to it.
// Therefore the returned handle MUST be a real, retainable Objective-C object (a bare pointer crashes in
// objc_msgSend on [obj retain]). Return a fresh +1 NSObject (matching os_log_create's create semantics);
// _os_log_internal ignores the log, so the object's only role is to be a valid refcounted handle.
void *_os_log_create(const char *subsystem, const char *category) {
    (void)subsystem; (void)category;
    return (void *)[[NSObject alloc] init];
}

// os_signpost performance tracing is 10.14+; absent on 10.9. No-op so signpost call sites link and the
// "is signposting enabled" guard always reports disabled (no emit happens).
bool os_signpost_enabled(void *log) { (void)log; return false; }
uint64_t os_signpost_id_make_with_pointer(void *log, const void *ptr) { (void)log; return (uint64_t)(uintptr_t)ptr; }
void _os_signpost_emit_with_name_impl(void *dso, void *log, uint8_t type, uint64_t spid,
        const char *name, const char *format, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)spid; (void)name; (void)format; (void)buf; (void)size;
}

// aligned_alloc (C11) was added to macOS libc only in 10.15; on 10.9 use posix_memalign, which yields
// free()-compatible memory just like aligned_alloc.
void *aligned_alloc(size_t alignment, size_t size) {
    void *p = NULL;
    return posix_memalign(&p, alignment, size) ? NULL : p;
}

// mkostemp/mkostemps (the flags-taking mkstemp variants) are absent on 10.9; their polyfill
// now lives in legacy-support/src/mkostemp.c (compiled into libpolyfill.a) so the vendored
// GStreamer compat shim can share the same definition.

// timingsafe_bcmp (constant-time compare, used by crypto) is absent on 10.9. Provide a constant-time
// implementation (no early-out) so timing characteristics match the real function.
int timingsafe_bcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
    unsigned char r = 0;
    for (size_t i = 0; i < n; i++) r |= x[i] ^ y[i];
    return r != 0;
}

// voucher_mach_msg_set (libdispatch QoS voucher propagation) is 10.10+. Vouchers don't exist on 10.9;
// report "no voucher set" (FALSE). Vouchers are only a QoS-propagation optimization, so this is benign.
int voucher_mach_msg_set(void *msg) { (void)msg; return 0; }

// mach_memory_entry_ownership (footprint-ledger attribution of shared memory) is ~10.13+. 10.9 has no
// phys_footprint ledger, so there is genuinely nothing to attribute; report success (the sole caller,
// SharedMemoryHandle, only RELEASE_LOG_ERRORs on failure and is otherwise a no-op).
int mach_memory_entry_ownership(unsigned int mem_entry, unsigned int owner, int ledger_tag, int ledger_flags) {
    (void)mem_entry; (void)owner; (void)ledger_tag; (void)ledger_flags;
    return 0; // KERN_SUCCESS
}

// (__darwin_check_fd_set_overflow lives in the "newer-than-10.9 C / CoreFoundation symbols" section
// below; it is defined exactly once.)

// dispatch_queue_create_with_target() (10.10 SDK) has no 10.9 runtime symbol — the modern SDK emits the
// ABI-tagged "$V2" variant. Recreate it from dispatch_queue_create + dispatch_set_target_queue (both 10.6).
dispatch_queue_t polyfill_dispatch_queue_create_with_target(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target)
    __asm__("_dispatch_queue_create_with_target$V2");
dispatch_queue_t polyfill_dispatch_queue_create_with_target(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target) {
    dispatch_queue_t queue = dispatch_queue_create(label, attr);
    if (queue && target) dispatch_set_target_queue(queue, target);
    return queue;
}

// CGColorCreateSRGB (10.15+) — build the color through the named sRGB color space (available since 10.5).
CGColorRef CGColorCreateSRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[4] = { r, g, b, a };
    CGColorRef color = CGColorCreate(cs, comps);
    CGColorSpaceRelease(cs);
    return color;
}

// sqlite3_errstr (SQLite 3.7.15) — 10.9 ships an older SQLite. Map the primary result codes to the same
// strings SQLite uses, so WebCore's diagnostic logging stays meaningful. Used only for error messages.
const char *sqlite3_errstr(int rc) {
    switch (rc & 0xff) {
        case 0:  return "not an error";
        case 1:  return "SQL logic error";
        case 2:  return "internal error";
        case 3:  return "access permission denied";
        case 4:  return "query aborted";
        case 5:  return "database is locked";
        case 6:  return "database table is locked";
        case 7:  return "out of memory";
        case 8:  return "attempt to write a readonly database";
        case 9:  return "interrupted";
        case 10: return "disk I/O error";
        case 11: return "database disk image is malformed";
        case 12: return "unknown operation";
        case 13: return "database or disk is full";
        case 14: return "unable to open database file";
        case 15: return "locking protocol";
        case 17: return "database schema has changed";
        case 18: return "string or blob too big";
        case 19: return "constraint failed";
        case 20: return "datatype mismatch";
        case 21: return "library routine called out of sequence";
        case 23: return "authorization denied";
        case 25: return "column index out of range";
        case 26: return "file is not a database";
        case 100: return "another row available";
        case 101: return "no more rows available";
        default: return "unknown error";
    }
}

// kIOMainPortDefault (the 12.0 rename of kIOMasterPortDefault) has no 10.9 symbol; its value is the same
// MACH_PORT_NULL sentinel meaning "use the default IOKit master port".
const mach_port_t kIOMainPortDefault = 0;

// kCTFontOpenTypeFeatureTag / ...Value (10.10 SDK) are the CFDictionary keys for OpenType font features.
// They have no 10.9 symbol; building a feature dictionary with a NULL key would crash CFDictionary, so
// define them with CoreText's documented key strings. (10.9 CoreText may not honor the new-style feature
// dictionary, but the code links and runs without crashing.)
const CFStringRef kCTFontOpenTypeFeatureTag = CFSTR("CTFeatureOpenTypeTag");
const CFStringRef kCTFontOpenTypeFeatureValue = CFSTR("CTFeatureOpenTypeValue");

// CAFrameRateRangeMake (12.0+) — CADisplayLink frame-rate range constructor. Build the
// {minimum,maximum,preferred} struct directly. asm label so the C identifier doesn't collide with the
// SDK's CAFrameRateRange return type (which AppKit→QuartzCore may declare); the struct layout is ABI-
// identical (three floats), so the returned value is passed back exactly as callers expect.
typedef struct { float minimum; float maximum; float preferred; } PolyCAFrameRateRange;
PolyCAFrameRateRange polyfill_CAFrameRateRangeMake(float minimum, float maximum, float preferred) __asm__("_CAFrameRateRangeMake");
PolyCAFrameRateRange polyfill_CAFrameRateRangeMake(float minimum, float maximum, float preferred) {
    PolyCAFrameRateRange r = { minimum, maximum, preferred };
    return r;
}

// xpc_type_get_name (newer XPC introspection) — used only for diagnostic strings; return a generic label.
const char *xpc_type_get_name(void *type) { (void)type; return "xpc-object"; }

// QuartzCore/CoreText string constants with no 10.9 symbol. Define them non-NULL (documented values) so
// the corner-curve / downloaded-font features degrade gracefully and never feed a NULL key to a
// CFDictionary/CTFontDescriptor (which would crash). 10.9 won't honor the values, which is fine.
const CFStringRef kCACornerCurveCircular = CFSTR("circular");
const CFStringRef kCTFontDownloadedAttribute = CFSTR("kCTFontDownloadedAttribute");

#pragma mark - newer-than-10.9 C / CoreFoundation symbols WebKit references
// A few plain C / CoreFoundation symbols WebKit (and the bundled libwebrtc) reference are absent from
// the 10.9 runtime. (The vendored GStreamer dylibs' own post-10.9 libc gap is handled separately by
// MavericksSupport/deps/gstreamer/libsystem_compat.dylib, not here.)

// __darwin_check_fd_set_overflow (the fortified FD_SET bounds check) is newer; on 10.9 reproduce its
// semantics: a descriptor is valid if non-negative and (when not unlimited) within FD_SETSIZE. The
// FD_SET macro the modern SDK emits calls it, and no other libpolyfill member defines it.
int __darwin_check_fd_set_overflow(int n, const void *fdset, int unlimited) {
    (void)fdset;
    return (n >= 0 && (unlimited || n < FD_SETSIZE)) ? 1 : 0;
}

// CoreVideo color-space constants added in 10.11 / 10.13 (referenced by the bundled libwebrtc H.264/
// H.265 decoders, and by GStreamer's video plugins, to tag HDR / wide-gamut frames). Absent on 10.9;
// provide the canonical CFString values so the dependent code links and never feeds a NULL key/value
// into a CoreVideo attachment dictionary.
const CFStringRef kCVImageBufferColorPrimaries_ITU_R_2020         = CFSTR("ITU_R_2020");
const CFStringRef kCVImageBufferColorPrimaries_P3_D65             = CFSTR("P3_D65");
const CFStringRef kCVImageBufferColorPrimaries_DCI_P3             = CFSTR("DCI_P3");
const CFStringRef kCVImageBufferTransferFunction_ITU_R_2020       = CFSTR("ITU_R_2020");
const CFStringRef kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ = CFSTR("SMPTE_ST_2084_PQ");
const CFStringRef kCVImageBufferTransferFunction_sRGB             = CFSTR("IEC_sRGB");
const CFStringRef kCVImageBufferYCbCrMatrix_ITU_R_2020            = CFSTR("ITU_R_2020");

#pragma mark - ObjC class stubs (proper metadata for 10.9 ObjC runtime)
// Defined ONLY in JavaScriptCore.framework (JSC loads first). WebCore and WebKit
// reference these via their JSC dylib dependency — otherwise duplicate class
// registrations overflow libobjc's _read_images limit on 10.9.


// CoreAnimation classes absent on 10.9, referenced by PlatformCAFiltersCocoa for CSS backdrop-filter
// (CABackdropLayer, 10.10+) and scroll-driven presentation modifiers (CAPresentationModifier, ~14.0).
// CABackdropLayer MUST subclass CALayer: PlatformCALayerCocoa::createLayer does
// `NSClassFromString(@"CABackdropLayer") ?: [CALayer class]`, so this stub IS used as a real layer
// (the <video controls> bar uses backdrop-filter). An NSObject base crashed (-[... bounds] unrecognized,
// and CA reads the layer struct directly). A bare CALayer subclass renders without the GPU-requiring
// backdrop blur — a graceful degradation. The CALayer base makes libpolyfill.a need OBJC_CLASS_$_CALayer;
// the JSC build tools that link it (LLIntSettingsExtractor) get -framework QuartzCore via OptionsMac.cmake.
// CAPresentationModifier stays NSObject (its only path is HAVE(CORE_ANIMATION_SEPARATED_LAYERS), off on 10.9).



// UTType polyfill — provides class methods returning UTType instances whose
// .identifier matches the kUTType* CFString constant. This avoids the
// unrecognized-selector crash from `UTTypeFileURL.identifier` etc.


// NSTouchBar and its item classes are deliberately NOT stubbed. Touch Bar is a 10.12.2+ feature and
// HAVE(TOUCH_BAR) is gated off for the 10.9 deployment target, so WebKit references none of these
// classes (every reference lives under #if HAVE(TOUCH_BAR) and compiles out). Defining empty stubs
// here would register the classes in the GLOBAL ObjC runtime, so any 10.9 app that loads our WebKit
// and feature-detects Touch Bar via NSClassFromString(@"NSTouchBar") would believe it exists and then
// crash invoking the absent -[NSResponder setTouchBar:] (observed: Dash.app aborts on launch when its
// nib-load path enables a Touch Bar). Leaving the names undefined keeps the runtime honest about 10.9.








// WebViewVisualIdentificationOverlay: the real Source/WebCore/testing/cocoa/
// WebViewVisualIdentificationOverlay.mm is excluded from the build (it would
// duplicate this stub, since libpolyfill links into every framework). Both
// WKWebView and (legacy) WebView call +installForWebViewIfNeeded:kind:deprecated:
// at creation time, so the stub MUST implement that class method (as a no-op)
// or every web-view creation throws unrecognized-selector. The overlay is a
// debug/visual-identification affordance, so a no-op is functionally complete.

// WKWebInspectorProxyObjCAdapter and WebKeyGenerator are defined in
// Source/WebKit/PolyfillClasses_109.mm so Safari finds them in WebKit.framework
// (where it expects them) without duplicating them in JSC too.

// Stub classes that need real ObjC class metadata: defined here as proper
// @interface/@implementation rather than bare function-symbol stubs, because
// libobjc crashes on a class symbol that lacks metadata.
// NOTE: CATransformLayer (QuartzCore), NSColorPopoverController (AppKit) and
// SFCertificatePanel (SecurityInterface) are REAL classes that DO exist on macOS
// 10.9 — they must NOT be stubbed here, or the empty stub can shadow the genuine
// system class (e.g. CATransformLayer backs 3D CSS transforms). They resolve from
// their system frameworks, which WebCore/WebKit already link.
// WKInspectorViewController is compiled from real source
// (Source/WebKit/UIProcess/Inspector/mac/WKInspectorViewController.mm) into
// WebKit.framework, so it must NOT be stubbed here — doing so duplicated the
// symbol in the WebKit framework link.

#pragma mark - NSPopUpMenu constants
NSString * const NSPopUpMenuPopupButtonBounds = @"NSPopUpMenuPopupButtonBounds";
NSString * const NSPopUpMenuPopupButtonOrigin = @"NSPopUpMenuPopupButtonOrigin";

#pragma mark - NSTouchBar notifications
NSString * const NSTouchBarDidExitCustomization = @"NSTouchBarDidExitCustomization";
NSString * const NSTouchBarWillEnterCustomization = @"NSTouchBarWillEnterCustomization";

#pragma mark - NSWorkspace polyfill (10.15+)

#pragma mark - CGColorSpace polyfills

/* CGColorSpaceGetName (10.12+) */
CFStringRef CGColorSpaceGetName(CGColorSpaceRef cs) {
    return NULL;
}


#pragma mark - CGColorSpace name constants (10.11.2+)
CFStringRef const kCGColorSpaceDisplayP3 = CFSTR("kCGColorSpaceDisplayP3");
CFStringRef const kCGColorSpaceExtendedSRGB = CFSTR("kCGColorSpaceExtendedSRGB");
CFStringRef const kCGColorSpaceLinearSRGB = CFSTR("kCGColorSpaceLinearSRGB");
CFStringRef const kCGColorSpaceExtendedLinearSRGB = CFSTR("kCGColorSpaceExtendedLinearSRGB");
CFStringRef const kCGColorSpaceExtendedDisplayP3 = CFSTR("kCGColorSpaceExtendedDisplayP3");
CFStringRef const kCGColorSpaceLinearDisplayP3 = CFSTR("kCGColorSpaceLinearDisplayP3");
CFStringRef const kCGColorSpaceExtendedLinearDisplayP3 = CFSTR("kCGColorSpaceExtendedLinearDisplayP3");
CFStringRef const kCGColorSpaceITUR_2020 = CFSTR("kCGColorSpaceITUR_2020");
CFStringRef const kCGColorSpaceExtendedITUR_2020 = CFSTR("kCGColorSpaceExtendedITUR_2020");
CFStringRef const kCGColorSpaceROMMRGB = CFSTR("kCGColorSpaceROMMRGB");

#pragma mark - Additional dyld/cache stubs (10.10+)
const void *_dyld_get_dlopen_image_header(void *handle) { return NULL; }
const void *_dyld_get_image_uuid(const void *header) { return NULL; }
const void *_dyld_get_shared_cache_uuid(void) { return NULL; }
void cache_simulate_memory_warning_event(uint64_t a) { }
const char *dyld_shared_cache_file_path(void) { return NULL; }
const void *dyld_image_header_containing_address(const void *addr) { return NULL; }

#pragma mark - NSText constants (10.12+)
NSString * const NSTextCheckingInsertionPointKey = @"NSTextCheckingInsertionPointKey";
NSString * const NSTextCheckingSuppressInitialCapitalizationKey = @"NSTextCheckingSuppressInitialCapitalizationKey";
NSString * const NSTextInsertionUndoableAttributeName = @"NSTextInsertionUndoableAttributeName";

#pragma mark - Additional NSPopUpMenu constants
NSString * const NSPopUpMenuPopupButtonLabelOffset = @"NSPopUpMenuPopupButtonLabelOffset";
NSString * const NSPopUpMenuPopupButtonSize = @"NSPopUpMenuPopupButtonSize";
NSString * const NSPopUpMenuPopupButtonWidget = @"NSPopUpMenuPopupButtonWidget";

#pragma mark - NSURLProtocol private method (10.10+) absent on 10.9
// Modern WebCore (WebCoreNSURLExtras) calls +[NSURLProtocol _protocolClassForRequest:skipAppSSO:], a 10.10+
// private API. On 10.9 this throws "doesNotRecognizeSelector". Provide a category that
// implements it by falling back to the public +[NSURLProtocol classForRequest:] equivalent
// (which doesn't exist publicly either, but the underlying lookup table does).
// Inject +_protocolClassForRequest:skipAppSSO: at runtime (class_addMethod on the metaclass) rather
// than via an ObjC category, so this object carries NO static reference to _OBJC_CLASS_$_NSURLProtocol.
// The 26.1 build SDK homes that class symbol in CFNetwork, but on the 10.9 runtime NSURLProtocol lives
// in Foundation; a static category reference mis-binds to CFNetwork and fails to load (dyld: Symbol not
// found _OBJC_CLASS_$_NSURLProtocol Expected in CFNetwork). App SSO does not exist on 10.9, so the
// method returns Nil and the caller (WebCoreNSURLExtras) falls back to the standard URL-loading path.
static Class polyfill_NSURLProtocol_protocolClassForRequest_skipAppSSO(id self, SEL _cmd, id request, BOOL skip) {
    (void)self; (void)_cmd; (void)request; (void)skip;
    return Nil;
}
__attribute__((constructor)) static void installNSURLProtocolSkipAppSSOPolyfill(void) {
    Class cls = objc_getClass("NSURLProtocol");
    if (!cls)
        return;
    SEL sel = sel_registerName("_protocolClassForRequest:skipAppSSO:");
    if (class_getClassMethod(cls, sel))
        return; // already provided by the OS (10.10+)
    Class meta = object_getClass((id)cls); // class methods live on the metaclass
    class_addMethod(meta, sel, (IMP)polyfill_NSURLProtocol_protocolClassForRequest_skipAppSSO, "#@:@c");
}

#pragma mark - NSView beginDeferringViewInWindowChanges (10.11+)

// Safari's BrowserWindowControllerMac _selectTabAtIndex: calls
// -[NSView beginDeferringViewInWindowChanges] / endDeferringViewInWindowChanges
// before/after swapping the active tab's view (10.11+ NSView API).
// On 10.9 the call throws "unrecognized selector" and aborts Safari's tab
// transition — without this polyfill, Cmd+T leaves Safari with no visible tab
// bar and a blank content area. With the polyfill (no-op), Safari's transition
// completes: tab bar becomes visible, new tab shows its top-sites/favorites
// page. NOTE: the previous tab's WKView content is still lost on switch-back —
// that is a separate deeper bug being worked on independently.


// 10.9 backport: kVTVideoEncoderSpecification_RequiredLowLatency is a 10.13+
// VideoToolbox encoder-spec key. libwebrtc's VTB H.264/VP9 encoder (built with
// ENABLE_WEB_RTC) references it; WebCore resolves it via flat-namespace dynamic
// lookup, so without a definition dyld aborts Safari at launch ("Symbol not
// found: _kVTVideoEncoderSpecification_RequiredLowLatency"). Provide the real
// CFString value; on 10.9 the encoder simply ignores this unknown spec key.
#import <CoreFoundation/CoreFoundation.h>
const CFStringRef kVTVideoEncoderSpecification_RequiredLowLatency = CFSTR("RequiredLowLatency");

#pragma mark - macOS 26.1 SDK symbols absent on the 10.9 runtime
// The 26.1 build SDK declares these as extern / @interface, so WebKit emits
// undefined references that dyld cannot resolve against the 10.9 system
// frameworks. Define them here (force-loaded polyfill archive) so the
// references bind in-image. The features are unused/inert on 10.9, so only the
// SYMBOL needs to exist with the right type; values are low-stakes.

// --- NSTextList marker format constants (10.13+) -------------------------
// Documented "{...}" CSS-list-style marker strings.
NSString * const NSTextListMarkerCircle = @"{circle}";
NSString * const NSTextListMarkerDecimal = @"{decimal}";
NSString * const NSTextListMarkerDisc = @"{disc}";
NSString * const NSTextListMarkerLowercaseAlpha = @"{lower-alpha}";
NSString * const NSTextListMarkerLowercaseHexadecimal = @"{lower-hexadecimal}";
NSString * const NSTextListMarkerLowercaseLatin = @"{lower-latin}";
NSString * const NSTextListMarkerLowercaseRoman = @"{lower-roman}";
NSString * const NSTextListMarkerOctal = @"{octal}";
NSString * const NSTextListMarkerSquare = @"{square}";
NSString * const NSTextListMarkerUppercaseAlpha = @"{upper-alpha}";
NSString * const NSTextListMarkerUppercaseHexadecimal = @"{upper-hexadecimal}";
NSString * const NSTextListMarkerUppercaseLatin = @"{upper-latin}";
NSString * const NSTextListMarkerUppercaseRoman = @"{upper-roman}";

// --- NSPasteboard name / type constants (10.13+) -------------------------
NSString * const NSPasteboardNameGeneral = @"Apple CFPasteboard general";
NSString * const NSPasteboardNameFind = @"Apple CFPasteboard find";
NSString * const NSPasteboardNameFont = @"Apple CFPasteboard font";
NSString * const NSPasteboardNameDrag = @"Apple CFPasteboard drag";
NSString * const NSPasteboardTypeURL = @"public.url";
NSString * const NSPasteboardTypeFileURL = @"public.file-url";

// --- CoreAnimation CAFilter HSL (non-separable) blend-mode names (10.10+) -----------------
// 10.9's QuartzCore has the separable blend modes (multiply/overlay/screen/...) but not the four HSL
// ones (CSS mix-blend-mode: hue/saturation/color/luminosity). PlatformCAFiltersCocoa references all of
// them; define the missing four so it links. 10.9's CoreAnimation does not implement these filters, so
// CAFilter rejects the unknown name and the blend degrades to normal compositing — the separable modes
// (which 10.9 does support) are unaffected.
NSString * const kCAFilterHueBlendMode = @"hueBlendMode";
NSString * const kCAFilterSaturationBlendMode = @"saturationBlendMode";
NSString * const kCAFilterColorBlendMode = @"colorBlendMode";
NSString * const kCAFilterLuminosityBlendMode = @"luminosityBlendMode";

// --- XPC functions / activity keys added after 10.9 (referenced via WTF XPCSPI.h) ----------
// 10.9's libxpc has the other XPC_ACTIVITY_* criteria keys but not these two; 10.9's xpc_activity
// ignores an unknown criterion, so the activity simply runs without that requirement.
const char * const XPC_ACTIVITY_REQUIRE_NETWORK_CONNECTIVITY = "RequireNetworkConnectivity";
const char * const XPC_ACTIVITY_RANDOM_INITIAL_DELAY = "RandomInitialDelay";

// xpc_dictionary_get_array (10.10+): the typed array accessor. 10.9 has xpc_dictionary_get_value, which
// returns the same borrowed object when the key holds an array — exactly what callers (e.g. the auth
// client-certificate chain in AuthenticationManagerCocoa) expect.
xpc_object_t xpc_dictionary_get_array(xpc_object_t xdict, const char *key) { return xpc_dictionary_get_value(xdict, key); }

// xpc_connection_copy_invalidation_reason (10.10+): no per-connection reason string on 10.9; return a
// caller-freeable generic reason (used only for diagnostic logging).
char *xpc_connection_copy_invalidation_reason(xpc_connection_t connection) { (void)connection; return strdup("connection invalidated"); }

// xpc_transaction_exit_clean (10.10+): exit once outstanding transactions drain. It is called from the
// XPC service entry point's shutdown path (after the OS transaction is cleared), so a clean exit matches.
void xpc_transaction_exit_clean(void) { exit(0); }

// --- Other AppKit / Foundation string constants --------------------------
NSString * const NSAppearanceNameDarkAqua = @"NSAppearanceNameDarkAqua";
NSString * const NSPresentationIntentAttributeName = @"NSPresentationIntent";
NSString * const NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification = @"NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification";
// NSLanguageIdentifierAttributeName (Foundation, macos(12.0); absent on 10.9) is Foundation's public
// name for the long-standing NSAttributedString/CoreText language attribute. Its runtime value is
// PROVABLY @"NSLanguage": on 10.9, kCTLanguageAttributeName (present, the single CoreText language
// key) reads as "NSLanguage" (verified on-host), and Foundation's constant must resolve to the same
// key to influence CoreText layout. WebKit already uses kCTLanguageAttributeName directly elsewhere.
NSString * const NSLanguageIdentifierAttributeName = @"NSLanguage";

// --- NSHTTPCookie SameSite policy constants (10.15+) ----------------------
NSString * const NSHTTPCookieSameSiteLax = @"lax";
NSString * const NSHTTPCookieSameSiteStrict = @"strict";

// --- NSURLSessionTask priority constants (float, macos(10.10)) -----------
// Absent on 10.9's Foundation/CFNetwork. The 26.1 SDK declares them
// FOUNDATION_EXPORT API_AVAILABLE(macos(10.10)), i.e. a weak import, so
// WebKit's references (NetworkSessionCocoa/NetworkDataTaskCocoa, used as
// plain KVC float values) bind here on 10.9. Values are the documented
// modern defaults (correct for any caller).
const float NSURLSessionTaskPriorityDefault = 0.5f;
const float NSURLSessionTaskPriorityLow = 0.0f;
const float NSURLSessionTaskPriorityHigh = 1.0f;

// --- NSViewNoIntrinsicMetric (correct spelling, macos(10.11)) ------------
// AppKit ships two symbols: NSViewNoInstrinsicMetric (the historical typo,
// macos(10.7) — PRESENT on 10.9, so we must NOT shadow it) and the
// correctly-spelled NSViewNoIntrinsicMetric (macos(10.11) — ABSENT on 10.9,
// value -1). WebKit references the correct-spelling symbol directly in
// several places (WKView, WebViewImpl, _WKWarningView's intrinsicContentSize).
// Against the 26.1 SDK that is a weak DATA import: on 10.9 the symbol's
// ADDRESS resolves to NULL, so reading the const dereferences NULL and
// crashes (EXC_BAD_ACCESS) — not merely a wrong value. Defining it here
// (pulled into every framework alongside the other stubs) satisfies the
// reference with the correct -1.
const CGFloat NSViewNoIntrinsicMetric = -1;

// --- NSEdgeInsetsEqual (10.10+) ------------------------------------------
// WebKit has an undefined ref, so the SDK exposes it as an extern function
// (not static inline) — define the real symbol with the SDK signature.
BOOL NSEdgeInsetsEqual(NSEdgeInsets a, NSEdgeInsets b)
{
    return a.top == b.top && a.left == b.left
        && a.bottom == b.bottom && a.right == b.right;
}

// --- Class stubs (only the class symbol matters; inert on 10.9) ----------
// The 26.1 SDK's @interface declarations for these are NOT in scope in this
// --no-default-config compile (clang reports "cannot find interface
// declaration"), so a bare @implementation would create a base-class-less root
// class. Per the established fallback, declare a minimal @interface with the
// correct superclass so the class gets real ObjC metadata.


