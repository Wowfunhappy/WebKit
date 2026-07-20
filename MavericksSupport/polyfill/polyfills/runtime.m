// libSystem entry points modern WebKit references that 10.9's libSystem does not export: libc, dyld,
// xpc, dispatch, os_log / os_signpost / os_variant / os_unfair_lock, pthread, mach and voucher.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/sysctl.h>
#include <syslog.h>
#include <unistd.h>
#include <uuid/uuid.h>

#pragma mark - C function stubs

WK_POLYFILL_ABSENT(NULL, void, abort_with_reason, (uint32_t a, uint64_t b, const char *c, uint64_t d), (a, b, c, d)) { abort(); }
WK_POLYFILL_ABSENT(NULL, void, os_fault_with_payload, (uint32_t a, uint64_t b, const void *c, uint32_t d, const char *e, uint64_t f), (a, b, c, d, e, f)) { }

#pragma mark - dyld version queries (10.10+)

// dyld_priv.h's version types, restated here because 10.9 ships neither the header nor these calls.
// The layout IS the ABI: two uint32_t packed into a single 64-bit integer register. Declaring these
// entry points as taking a plain uint32_t (as this file once did) therefore read only the platform
// half of the argument and threw the version away.
typedef uint32_t dyld_platform_t;
typedef struct {
    dyld_platform_t platform;
    uint32_t version;
} dyld_build_version_t;

#define WK_PLATFORM_MACOS 1         // PLATFORM_MACOS; the only platform this OS runs
#define WK_VERSION_SET 0xffffffffu  // dyld_build_version_t.platform marking a "version set" (below)
#define WK_VERSION_NONE 0xffffffffu // a version nothing can be at least as new as

// LC_BUILD_VERSION is how linkers newer than 10.9's record platform/minos/sdk; 10.9's <mach-o/loader.h>
// knows only LC_VERSION_MIN_MACOSX, which is what a binary deploying to 10.9 (ours included) carries.
// Both are handled so that reading an image's versions does not depend on which linker produced it.
#ifndef LC_BUILD_VERSION
#define LC_BUILD_VERSION 0x32
struct build_version_command {
    uint32_t cmd, cmdsize, platform, minos, sdk, ntools;
};
#endif

// dyld's "version set" form of dyld_build_version_t: platform == 0xffffffff means the version field is
// a DATE (0xYYYYMMDD) naming the OS releases that shipped together on that date, and the comparison is
// against whichever of those releases belongs to the running platform. 10.9 carries no such table, so
// the macOS column of dyld's own is restated here. The season -> macOS pairing is the one WebKit
// itself encodes: Source/WTF/wtf/spi/darwin/dyldSPI.h lists each dyld_<season>_os_versions macro
// alongside the DYLD_MACOSX_VERSION_* constant that season's fallback check uses.
//
// Nothing in this port can currently reach this path: a version set can only be spelled by a macro
// from dyld_priv.h, which exists only in Apple's internal SDK, and dyldSPI.h defines every one of them
// as {0, 0} otherwise -- which linkedBefore() explicitly filters out before calling. It is implemented
// anyway so the entry point is correct rather than correct-by-accident.
static const struct { uint32_t set; uint32_t macos; } wk_version_sets[] = {
    { 0x07DE0901, 0x000A0A00 }, // fall 2014      -> macOS 10.10
    { 0x07DF0901, 0x000A0B00 }, // fall 2015      -> macOS 10.11
    { 0x07E00901, 0x000A0C00 }, // fall 2016      -> macOS 10.12
    { 0x07E10901, 0x000A0D00 }, // fall 2017      -> macOS 10.13
    { 0x07E20301, 0x000A0D04 }, // spring 2018    -> macOS 10.13.4
    { 0x07E20901, 0x000A0E00 }, // fall 2018      -> macOS 10.14
    { 0x07E30301, 0x000A0E04 }, // spring 2019    -> macOS 10.14.4
    { 0x07E30901, 0x000A0F00 }, // fall 2019      -> macOS 10.15
    { 0x07E30C01, 0x000A0F01 }, // late fall 2019 -> macOS 10.15.1
    { 0x07E40301, 0x000A0F04 }, // spring 2020    -> macOS 10.15.4
    { 0x07E40901, 0x000A1000 }, // fall 2020      -> macOS 10.16
    { 0x07E50301, 0x000B0300 }, // spring 2021    -> macOS 11.3
    { 0x07E50901, 0x000C0000 }, // fall 2021      -> macOS 12.0
    { 0x07E60301, 0x000C0300 }, // spring 2022    -> macOS 12.3
    { 0x07E60901, 0x000D0000 }, // fall 2022      -> macOS 13.0
    { 0x07E70301, 0x000D0300 }, // 2022 SU E      -> macOS 13.3
    { 0x07E70901, 0x000E0000 }, // fall 2023      -> macOS 14.0
    { 0x07E70C01, 0x000E0200 }, // 2023 SU C      -> macOS 14.2
    { 0x07E80301, 0x000E0400 }, // 2023 SU E      -> macOS 14.4
    { 0x07E80901, 0x000F0000 }, // fall 2024      -> macOS 15.0
    { 0x07E80C01, 0x000F0200 }, // 2024 SU C      -> macOS 15.2
    { 0x07E90301, 0x000F0400 }, // 2024 SU E      -> macOS 15.4
    { 0x07E90501, 0x000F0500 }, // 2024 SU F      -> macOS 15.5
    { 0x07E90B01, 0x001A0100 }, // 2025 SU B      -> macOS 26.1
};

// The macOS release a version set names. The table is ordered by date, so the first entry at or after
// the requested date is the release being asked about; a date past the end names a release newer than
// anything this table knows, which no SDK can be shown to be at least as new as.
static uint32_t wk_macos_version_for_version_set(uint32_t versionSet)
{
    for (size_t i = 0; i < sizeof(wk_version_sets) / sizeof(wk_version_sets[0]); i++) {
        if (wk_version_sets[i].set >= versionSet)
            return wk_version_sets[i].macos;
    }
    return WK_VERSION_NONE;
}

// platform / minimum-OS / SDK of a Mach-O image, read from whichever load command records them.
static bool wk_image_build_versions(const struct mach_header *header, uint32_t *platform, uint32_t *minos, uint32_t *sdk)
{
    if (!header)
        return false;

    const uint8_t *cursor;
    uint32_t commandCount;
    if (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64) {
        cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
        commandCount = ((const struct mach_header_64 *)header)->ncmds;
    } else if (header->magic == MH_MAGIC || header->magic == MH_CIGAM) {
        cursor = (const uint8_t *)header + sizeof(struct mach_header);
        commandCount = header->ncmds;
    } else
        return false;

    for (uint32_t i = 0; i < commandCount; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command))
            return false;
        if (command->cmd == LC_VERSION_MIN_MACOSX) {
            const struct version_min_command *version = (const struct version_min_command *)command;
            *platform = WK_PLATFORM_MACOS;
            *minos = version->version;
            *sdk = version->sdk;
            return true;
        }
        if (command->cmd == LC_BUILD_VERSION) {
            const struct build_version_command *build = (const struct build_version_command *)command;
            *platform = build->platform;
            *minos = build->minos;
            *sdk = build->sdk;
            return true;
        }
        cursor += command->cmdsize;
    }
    return false;
}

// Is `have` (a version of `platform`) at least `want`? A query about a platform the image was not
// built for cannot be satisfied, which is also what dyld answers.
static bool wk_version_at_least(uint32_t platform, uint32_t have, dyld_build_version_t want)
{
    if (want.platform == WK_VERSION_SET) {
        if (platform != WK_PLATFORM_MACOS)
            return false;
        uint32_t mapped = wk_macos_version_for_version_set(want.version);
        return mapped != WK_VERSION_NONE && have >= mapped;
    }
    if (want.platform != platform)
        return false;
    return have >= want.version;
}

// 10.9's dyld DOES export dyld_get_program_sdk_version / dyld_get_program_min_os_version (verified by
// dlsym on this host); they read the main executable's LC_VERSION_MIN_MACOSX, which is exactly what
// the modern *_at_least calls answer from. Resolved through the registry rather than linked, so no
// image force-loading this archive acquires an undefined dyld-SPI symbol (see wk_polyfill.h).
WK_SYSTEM_FN(NULL, uint32_t, dyld_get_program_sdk_version, (void));
WK_SYSTEM_FN(NULL, uint32_t, dyld_get_program_min_os_version, (void));

// _dyld_get_image_header(0) is the main executable, so the same load command is readable directly if
// this dyld turns out not to export the accessor.
static uint32_t wk_program_version(uint32_t (*accessor)(void), bool wantSDK)
{
    if (accessor)
        return accessor();
    uint32_t platform = 0, minos = 0, sdk = 0;
    if (!wk_image_build_versions(_dyld_get_image_header(0), &platform, &minos, &sdk))
        return 0;
    return wantSDK ? sdk : minos;
}

WK_POLYFILL_ABSENT(NULL, bool, dyld_program_sdk_at_least, (dyld_build_version_t version), (version))
{
    return wk_version_at_least(WK_PLATFORM_MACOS,
        wk_program_version(WK_SYSTEM(dyld_get_program_sdk_version), true), version);
}

WK_POLYFILL_ABSENT(NULL, bool, dyld_program_minos_at_least, (dyld_build_version_t version), (version))
{
    return wk_version_at_least(WK_PLATFORM_MACOS,
        wk_program_version(WK_SYSTEM(dyld_get_program_min_os_version), false), version);
}

WK_POLYFILL_ABSENT(NULL, bool, dyld_sdk_at_least, (const struct mach_header *header, dyld_build_version_t version), (header, version))
{
    uint32_t platform = 0, minos = 0, sdk = 0;
    if (!wk_image_build_versions(header, &platform, &minos, &sdk))
        return false;
    (void)minos;
    return wk_version_at_least(platform, sdk, version);
}

// cache/simulator stubs
WK_POLYFILL_ABSENT(NULL, void, cache_simulate_size_response, (uint64_t a, uint64_t b, uint64_t c), (a, b, c)) { }

// os_variant stubs
WK_POLYFILL_ABSENT(NULL, bool, os_variant_allows_internal_security_policies, (const char *s), (s)) { return false; }
WK_POLYFILL_ABSENT(NULL, bool, os_variant_has_internal_content, (const char *s), (s)) { return false; }
WK_POLYFILL_ABSENT(NULL, bool, os_variant_has_internal_diagnostics, (const char *s), (s)) { return false; }

// pthread
WK_POLYFILL_ABSENT(NULL, bool, pthread_self_is_exiting_np, (void), ()) { return false; }

// os_unfair_lock_assert_owner / _assert_not_owner (10.12+) are the lock-ownership debug assertions WTF::Lock
// emits under the modern SDK. The lock primitive itself is polyfilled separately; only these assert
// helpers are absent on 10.9. No-op them -- without a definition the first use aborts fatally, during
// IPC message handling on page load.
WK_POLYFILL_ABSENT(NULL, void, os_unfair_lock_assert_owner, (void *lock), (lock)) { (void)lock; }
WK_POLYFILL_ABSENT(NULL, void, os_unfair_lock_assert_not_owner, (void *lock), (lock)) { (void)lock; }

// os_log unified logging is 10.12+; _os_log_internal is the macro-emitted backing for every os_log()
// call site and is absent from 10.9's libSystem (it links as the Mach-O symbol __os_log_internal).
// Without a definition the first os_log() call aborts fatally ("lazy symbol binding failed"); a no-op
// makes logging silently do nothing. (OS_LOG_DEFAULT's backing storage, _os_log_default, is a data
// symbol and lives in constants.m; the no-op ignores whichever log handle it is handed.)
// Signature uses plain types (os_log_t/os_log_type_t aren't visible under --no-default-config);
// ABI-equivalent: os_log_t==pointer, os_log_type_t==uint8_t, buf==uint8_t*, size==uint32_t.
WK_POLYFILL_ABSENT(NULL, void, _os_log_internal,
    (void *dso, void *log, uint8_t type, const char *format, uint8_t *buf, uint32_t size),
    (dso, log, type, format, buf, size)) {
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

// os_log_create(subsystem, category) -> os_log_t (10.12+, absent on 10.9). os_log_t is an os_object /
// ObjC type, and WebKit wraps the result in a RetainPtr<os_log_t> — so it sends -retain/-release to it.
// Therefore the returned handle MUST be a real, retainable Objective-C object (a bare pointer crashes in
// objc_msgSend on [obj retain]). Return a fresh +1 NSObject (matching os_log_create's create semantics);
// _os_log_internal ignores the log, so the object's only role is to be a valid refcounted handle.
WK_POLYFILL_ABSENT(NULL, void *, _os_log_create, (const char *subsystem, const char *category), (subsystem, category)) {
    (void)subsystem; (void)category;
    return (void *)[[NSObject alloc] init];
}

// os_signpost performance tracing is 10.14+; absent on 10.9. No-op so signpost call sites link and the
// "is signposting enabled" guard always reports disabled (no emit happens).
WK_POLYFILL_ABSENT(NULL, bool, os_signpost_enabled, (void *log), (log)) { (void)log; return false; }
WK_POLYFILL_ABSENT(NULL, uint64_t, os_signpost_id_make_with_pointer, (void *log, const void *ptr), (log, ptr)) { (void)log; return (uint64_t)(uintptr_t)ptr; }
WK_POLYFILL_ABSENT(NULL, void, _os_signpost_emit_with_name_impl,
    (void *dso, void *log, uint8_t type, uint64_t spid, const char *name, const char *format, uint8_t *buf, uint32_t size),
    (dso, log, type, spid, name, format, buf, size)) {
    (void)dso; (void)log; (void)type; (void)spid; (void)name; (void)format; (void)buf; (void)size;
}

// os_feature_enabled(domain, feature) — libSystem feature-flag query (10.13+). Every WebKit call site
// gates a feature that postdates 10.9 (VisualIntelligence/Translate/TextComposer post-editing/the
// redesigned text cursor), so the faithful answer on this OS is "not enabled".
WK_POLYFILL_ABSENT(NULL, bool, _os_feature_enabled_impl, (const char *domain, const char *feature), (domain, feature))
{
    (void)domain;
    (void)feature;
    return false;
}


// timingsafe_bcmp (constant-time compare, used by crypto) is absent on 10.9. Provide a constant-time
// implementation (no early-out) so timing characteristics match the real function.
WK_POLYFILL_ABSENT(NULL, int, timingsafe_bcmp, (const void *a, const void *b, size_t n), (a, b, n)) {
    const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
    unsigned char r = 0;
    for (size_t i = 0; i < n; i++) r |= x[i] ^ y[i];
    return r != 0;
}

// voucher_mach_msg_set (libdispatch QoS voucher propagation) is 10.10+. Vouchers don't exist on 10.9;
// report "no voucher set" (FALSE). Vouchers are only a QoS-propagation optimization, so this is benign.
WK_POLYFILL_ABSENT(NULL, int, voucher_mach_msg_set, (void *msg), (msg)) { (void)msg; return 0; }

// mach_memory_entry_ownership (footprint-ledger attribution of shared memory) is ~10.13+. 10.9 has no
// phys_footprint ledger, so there is genuinely nothing to attribute; report success (the sole caller,
// SharedMemoryHandle, only RELEASE_LOG_ERRORs on failure and is otherwise a no-op).
WK_POLYFILL_ABSENT(NULL, int, mach_memory_entry_ownership,
    (unsigned int mem_entry, unsigned int owner, int ledger_tag, int ledger_flags),
    (mem_entry, owner, ledger_tag, ledger_flags)) {
    (void)mem_entry; (void)owner; (void)ledger_tag; (void)ledger_flags;
    return 0; // KERN_SUCCESS
}

// (__darwin_check_fd_set_overflow lives in the "newer-than-10.9 C / CoreFoundation symbols" section
// below; it is defined exactly once.)

// dispatch_queue_create_with_target() (10.10 SDK): the modern SDK emits the ABI-tagged "$V2" variant,
// and 10.9 has no "$V2" symbol. Recreate it from dispatch_queue_create + dispatch_set_target_queue
// (both 10.6). The asm label is what puts the "$V2" suffix on the emitted symbol; the C identifier
// stays the plain name.
// REPLACES, not a gap-fill: 10.9's libdispatch does export the UNSUFFIXED
// dispatch_queue_create_with_target (verified by dlsym on this host — it is the pre-10.10 "legacy"
// V1 entry point), so a gap-fill would forward every $V2 call to V1's semantics. Callers here are
// compiled against $V2, so ours always wins; the registry entry records that 10.9's same-named
// symbol is deliberately not used.
dispatch_queue_t dispatch_queue_create_with_target(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target)
    __asm__("_dispatch_queue_create_with_target$V2");
WK_POLYFILL_REPLACES(NULL, dispatch_queue_t, dispatch_queue_create_with_target,
    (const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target)) {
    dispatch_queue_t queue = dispatch_queue_create(label, attr);
    if (queue && target) dispatch_set_target_queue(queue, target);
    return queue;
}

// xpc_type_get_name (newer XPC introspection) — used only for diagnostic strings; return a generic label.
WK_POLYFILL_ABSENT(NULL, const char *, xpc_type_get_name, (void *type), (type)) { (void)type; return "xpc-object"; }

// xpc_dictionary_get_array (10.10+): the typed array accessor. 10.9 has xpc_dictionary_get_value, which
// returns the same borrowed object when the key holds an array — exactly what callers (e.g. the auth
// client-certificate chain in AuthenticationManagerCocoa) expect.
WK_POLYFILL_ABSENT(NULL, xpc_object_t, xpc_dictionary_get_array, (xpc_object_t xdict, const char *key), (xdict, key)) { return xpc_dictionary_get_value(xdict, key); }

// xpc_connection_copy_invalidation_reason (10.10+): no per-connection reason string on 10.9; return a
// caller-freeable generic reason (used only for diagnostic logging).
WK_POLYFILL_ABSENT(NULL, char *, xpc_connection_copy_invalidation_reason, (xpc_connection_t connection), (connection)) { (void)connection; return strdup("connection invalidated"); }

// xpc_transaction_exit_clean (10.10+): exit once outstanding transactions drain. It is called from the
// XPC service entry point's shutdown path (after the OS transaction is cleared), so a clean exit matches.
WK_POLYFILL_ABSENT(NULL, void, xpc_transaction_exit_clean, (void), ()) { exit(0); }

#pragma mark - newer-than-10.9 C / CoreFoundation symbols WebKit references
// A few plain C / CoreFoundation symbols WebKit (and the bundled libwebrtc) reference are absent from
// the 10.9 runtime. (The vendored GStreamer dylibs' own post-10.9 libc gap is handled separately by
// MavericksSupport/deps/gstreamer/libsystem_compat.dylib, not here.)

// __darwin_check_fd_set_overflow (the fortified FD_SET bounds check) is newer; on 10.9 reproduce its
// semantics: a descriptor is valid if non-negative and (when not unlimited) within FD_SETSIZE. The
// FD_SET macro the modern SDK emits calls it.
WK_POLYFILL_ABSENT(NULL, int, __darwin_check_fd_set_overflow, (int n, const void *fdset, int unlimited), (n, fdset, unlimited)) {
    (void)fdset;
    return (n >= 0 && (unlimited || n < FD_SETSIZE)) ? 1 : 0;
}

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
// backdrop blur — a graceful degradation.
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

#pragma mark - dyld image identity and the shared cache (10.10+)

// The image an address belongs to. dladdr already answers exactly this question -- dli_fbase is the
// mach header of the image containing the address -- and is 10.9 API.
WK_POLYFILL_ABSENT(NULL, const struct mach_header *, dyld_image_header_containing_address, (const void *address), (address))
{
    Dl_info info;
    if (!dladdr(address, &info))
        return NULL;
    return (const struct mach_header *)info.dli_fbase;
}

// The mach header behind a dlopen handle. 10.9's handle is an opaque dyld pointer with no public way
// to walk back to the image, but dlopen answers by identity: reopening an already-loaded image with
// RTLD_NOLOAD hands back the very same handle. So ask each loaded image for its handle and match.
// RTLD_NOLOAD loads nothing, and the matching dlclose gives back the reference the reopen took, so
// the process is left exactly as it was found.
WK_POLYFILL_ABSENT(NULL, const struct mach_header *, _dyld_get_dlopen_image_header, (void *handle), (handle))
{
    if (!handle)
        return NULL;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name)
            continue;
        void *candidate = dlopen(name, RTLD_LAZY | RTLD_NOLOAD);
        if (!candidate)
            continue;
        dlclose(candidate);
        if (candidate == handle)
            return _dyld_get_image_header(i);
    }
    return NULL;
}

// An image's LC_UUID -- the linker-generated build identity JSCBytecodeCacheVersion.cpp hashes to
// decide whether a cached bytecode file was produced by this very JavaScriptCore. Every Mach-O the
// linker produces carries one; an image without one gets the zeroed UUID and a false return, which is
// how the caller is told there is no identity to hash (dyld does the same).
WK_POLYFILL_ABSENT(NULL, bool, _dyld_get_image_uuid, (const struct mach_header *header, uuid_t uuid), (header, uuid))
{
    if (!uuid)
        return false;
    if (header) {
        const uint8_t *cursor = NULL;
        uint32_t commandCount = 0;
        if (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64) {
            cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
            commandCount = ((const struct mach_header_64 *)header)->ncmds;
        } else if (header->magic == MH_MAGIC || header->magic == MH_CIGAM) {
            cursor = (const uint8_t *)header + sizeof(struct mach_header);
            commandCount = header->ncmds;
        }
        for (uint32_t i = 0; cursor && i < commandCount; i++) {
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(struct load_command))
                break;
            if (command->cmd == LC_UUID) {
                memcpy(uuid, ((const struct uuid_command *)command)->uuid, sizeof(uuid_t));
                return true;
            }
            cursor += command->cmdsize;
        }
    }
    memset(uuid, 0, sizeof(uuid_t));
    return false;
}

// _dyld_get_all_image_infos is the 10.9 dyld SPI that hands back the process's dyld_all_image_infos.
// Resolved through the registry rather than linked (see wk_polyfill.h): it is not part of any modern
// SDK's libSystem, so a link-time reference would be an undefined symbol in every image that
// force-loads this archive.
WK_SYSTEM_FN(NULL, const struct dyld_all_image_infos *, _dyld_get_all_image_infos, (void));

// The UUID of the dyld shared cache this process is running against. dyld records it in
// dyld_all_image_infos.sharedCacheUUID, a field present from version 13 (10.9) onward -- so this is
// the running cache's own answer, not an inference. A process detached from the shared region has no
// cache and leaves the field zeroed, which is reported as the honest "there is none" (false).
WK_POLYFILL_ABSENT(NULL, bool, _dyld_get_shared_cache_uuid, (uuid_t uuid), (uuid))
{
    if (!uuid)
        return false;
    const struct dyld_all_image_infos *infos = WK_SYSTEM(_dyld_get_all_image_infos)
        ? WK_SYSTEM(_dyld_get_all_image_infos)() : NULL;
    if (infos && infos->version >= 13 && !infos->processDetachedFromSharedRegion) {
        uuid_t zero = { 0 };
        if (memcmp(infos->sharedCacheUUID, zero, sizeof(uuid_t))) {
            memcpy(uuid, infos->sharedCacheUUID, sizeof(uuid_t));
            return true;
        }
    }
    memset(uuid, 0, sizeof(uuid_t));
    return false;
}

// Where that cache lives. 10.9 keeps no per-process record of the path, but it has exactly one place
// it maps the cache from: /var/db/dyld/dyld_shared_cache_<arch>, one file per architecture. Confirmed
// on this host rather than assumed -- the UUID stored at offset 0x58 of
// /private/var/db/dyld/dyld_shared_cache_x86_64 is byte-for-byte the sharedCacheUUID dyld reports for
// the running process (a998f590-4df9-3cf1-9bda-97d3bb2875cf).
WK_POLYFILL_ABSENT(NULL, const char *, dyld_shared_cache_file_path, (void), ())
{
#if defined(__x86_64__)
    return "/private/var/db/dyld/dyld_shared_cache_x86_64";
#elif defined(__i386__)
    return "/private/var/db/dyld/dyld_shared_cache_i386";
#else
    #error "no 10.9 dyld shared cache path is known for this architecture"
#endif
}

WK_POLYFILL_ABSENT(NULL, void, cache_simulate_memory_warning_event, (uint64_t a), (a)) { }

#pragma mark - os_log emit points (10.12+)

// The other two macro-emitted os_log() backings, and the "would this level be logged?" query the
// os_log macros consult first. Unified logging does not exist on 10.9: report every level disabled
// and drop what is emitted anyway. (_os_log_internal above is the third backing.)
WK_POLYFILL_ABSENT(NULL, int, os_log_type_enabled, (void *log, int type), (log, type))
{
    (void)log; (void)type;
    return 0; // logging disabled
}

WK_POLYFILL_ABSENT(NULL, void, _os_log_impl,
    (void *dso, void *log, int type, const char *format, void *buf, unsigned int size),
    (dso, log, type, format, buf, size))
{
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

WK_POLYFILL_ABSENT(NULL, void, _os_log_error_impl,
    (void *dso, void *log, int type, const char *format, void *buf, unsigned int size),
    (dso, log, type, format, buf, size))
{
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

#pragma mark - syslog

// syslog$DARWIN_EXTSN is the DARWIN_EXTSN ABI variant of syslog(); 10.9's libc exports only the
// plain spelling, which is the one this forwards to (through vsyslog, the va_list form of the same
// call), so the message reaches syslogd exactly as it would have. The asm label is what puts the
// "$DARWIN_EXTSN" suffix on the emitted symbol. Variadic, so it is declared with
// WK_POLYFILL_REPLACES — WK_POLYFILL_ABSENT's generated forward-to-10.9 call cannot pass varargs.
void syslog(int priority, const char *message, ...) __asm__("_syslog$DARWIN_EXTSN");
WK_POLYFILL_REPLACES(NULL, void, syslog, (int priority, const char *message, ...))
{
    va_list ap;
    va_start(ap, message);
    vsyslog(priority, message, ap);
    va_end(ap);
}

#pragma mark - dispatch (APIs newer than 10.9)

// dispatch_async_and_wait family (10.14). The "async_and_wait" variants differ from dispatch_sync
// only in which thread the block may run on (they may be moved to the queue's own thread rather
// than executed on the caller's); the completion contract — enqueue, then block until done — is the
// same, so dispatch_sync satisfies every caller.
WK_POLYFILL_ABSENT(NULL, void, dispatch_async_and_wait, (dispatch_queue_t queue, dispatch_block_t block), (queue, block))
{
    dispatch_sync(queue, block);
}

WK_POLYFILL_ABSENT(NULL, void, dispatch_async_and_wait_f, (dispatch_queue_t queue, void *ctx, void (*work)(void *)), (queue, ctx, work))
{
    dispatch_sync_f(queue, ctx, work);
}

WK_POLYFILL_ABSENT(NULL, void, dispatch_barrier_async_and_wait, (dispatch_queue_t queue, dispatch_block_t block), (queue, block))
{
    dispatch_barrier_sync(queue, block);
}

WK_POLYFILL_ABSENT(NULL, void, dispatch_barrier_async_and_wait_f, (dispatch_queue_t queue, void *ctx, void (*work)(void *)), (queue, ctx, work))
{
    dispatch_barrier_sync_f(queue, ctx, work);
}

// dispatch_set_qos_class_floor (10.14) raises the floor of a queue's QoS class. 10.9 has no QoS
// scheduling classes at all (see the pthread QoS group below), so there is no floor to raise.
WK_POLYFILL_ABSENT(NULL, void, dispatch_set_qos_class_floor, (dispatch_object_t object, int qos_class, int relpri), (object, qos_class, relpri))
{
    (void)object; (void)qos_class; (void)relpri;
}

// dispatch_assert_queue (public in 10.12; the modern SDK emits the ABI-tagged "$V2" spelling, which
// 10.9 has no symbol for). 10.9's libdispatch DOES export the unsuffixed dispatch_assert_queue — the
// pre-10.12 entry point with the same semantics — so forward the $V2 call to it and the assertion
// keeps its real teeth rather than being stubbed out. REPLACES, not a gap-fill, for the same reason
// as dispatch_queue_create_with_target above: ours must win for the $V2 spelling while the registry
// records that the same-named 10.9 symbol is what we forward to.
void dispatch_assert_queue(dispatch_queue_t queue) __asm__("_dispatch_assert_queue$V2");
WK_POLYFILL_REPLACES(NULL, void, dispatch_assert_queue, (dispatch_queue_t queue))
{
    if (WK_ORIGINAL(dispatch_assert_queue))
        WK_ORIGINAL(dispatch_assert_queue)(queue);
}

// dispatch_workloop_create / _create_inactive (10.14). A workloop is a priority-ordered queue;
// 10.9's libdispatch has no such object, and a serial queue provides the guarantee every caller
// actually relies on (one block at a time, in submission order). dispatch_workloop_t is not
// declared by the 10.9 headers; it is an os_object like every other dispatch object.
typedef struct dispatch_object_s *dispatch_workloop_t;

WK_POLYFILL_ABSENT(NULL, dispatch_workloop_t, dispatch_workloop_create, (const char *label), (label))
{
    return (dispatch_workloop_t)(void *)dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
}

WK_POLYFILL_ABSENT(NULL, dispatch_workloop_t, dispatch_workloop_create_inactive, (const char *label), (label))
{
    return (dispatch_workloop_t)(void *)dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
}

#pragma mark - pthread QoS (10.10+)

// 10.9 has no Quality-of-Service scheduling classes, so there is no class to set, and the honest
// answer to a query is QOS_CLASS_UNSPECIFIED (0) at relative priority 0 — which is exactly what a
// thread on this OS is. Overrides likewise have nothing to override; start returns a non-NULL token
// so the caller's paired _end() call is well-formed.
WK_POLYFILL_ABSENT(NULL, int, pthread_set_qos_class_self_np, (int qos_class, int relative_priority), (qos_class, relative_priority))
{
    (void)qos_class; (void)relative_priority;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, int, pthread_get_qos_class_np, (pthread_t thread, int *qos_class, int *relative_priority), (thread, qos_class, relative_priority))
{
    (void)thread;
    if (qos_class) *qos_class = 0; // QOS_CLASS_UNSPECIFIED
    if (relative_priority) *relative_priority = 0;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, int, pthread_attr_set_qos_class_np, (pthread_attr_t *attr, int qos_class, int relative_priority), (attr, qos_class, relative_priority))
{
    (void)attr; (void)qos_class; (void)relative_priority;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, int, pthread_attr_get_qos_class_np, (pthread_attr_t *attr, int *qos_class, int *relative_priority), (attr, qos_class, relative_priority))
{
    (void)attr;
    if (qos_class) *qos_class = 0;
    if (relative_priority) *relative_priority = 0;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, void *, pthread_override_qos_class_start_np, (pthread_t thread, int qos_class, int relative_priority), (thread, qos_class, relative_priority))
{
    (void)thread; (void)qos_class; (void)relative_priority;
    return (void *)1;
}

WK_POLYFILL_ABSENT(NULL, int, pthread_override_qos_class_end_np, (void *override), (override))
{
    (void)override;
    return 0;
}

#pragma mark - pthread stack size

// pthread_get_stacksize_np — a DELIBERATE REPLACEMENT of a present-but-wrong 10.9 function. On the
// MAIN thread 10.9 reports the default 512 KB rather than the stack the process actually got, which
// makes any caller sizing a recursion guard from it (JavaScriptCore's stack bounds, LLVM, OpenJDK —
// all of which carry the same workaround) believe it has far less room than it does. The real main
// stack is RLIMIT_STACK, clamped to 1 GB because that is the largest stack the kernel will map.
// Non-main threads are unaffected by the bug, so they get 10.9's own answer.
#define WK_MAX_THREAD_STACK_SIZE 0x40000000 /* 1 GB */
pthread_t pthread_main_thread_np(void);
WK_POLYFILL_REPLACES(NULL, size_t, pthread_get_stacksize_np, (pthread_t thread))
{
    if (pthread_equal(thread, pthread_main_thread_np())) {
        // A libc replacement reports, it does not terminate: if RLIMIT_STACK is unreadable, fall
        // through to 10.9's own answer rather than killing the process.
        struct rlimit limit;
        if (!getrlimit(RLIMIT_STACK, &limit)) {
            if (limit.rlim_cur < WK_MAX_THREAD_STACK_SIZE)
                return (size_t)limit.rlim_cur;
            return WK_MAX_THREAD_STACK_SIZE;
        }
    }
    return WK_ORIGINAL(pthread_get_stacksize_np) ? WK_ORIGINAL(pthread_get_stacksize_np)(thread) : 0;
}

#pragma mark - sysconf

// sysconf — a DELIBERATE REPLACEMENT of a present-but-incomplete 10.9 function. 10.9's sysconf has
// no _SC_PHYS_PAGES selector (it returns -1), so callers sizing caches from physical memory get
// nothing to work with. Answer it from hw.memsize / the page size, which is the same quantity newer
// OSes report. Every other selector is 10.9's own answer, unchanged.
// 10.9's <unistd.h> does not name the selector it cannot answer; 200 is its value on every macOS
// that does, and is what the modern SDK WebKit compiles against uses.
#ifndef _SC_PHYS_PAGES
#define _SC_PHYS_PAGES 200
#endif
WK_POLYFILL_REPLACES(NULL, long, sysconf, (int name))
{
    if (name == _SC_PHYS_PAGES) {
        uint64_t memorySize;
        size_t length = sizeof(memorySize);
        int mib[] = { CTL_HW, HW_MEMSIZE };
        int pageSize = getpagesize();
        if (sysctl(mib, sizeof(mib) / sizeof(mib[0]), &memorySize, &length, NULL, 0))
            return -1;
        return (long)(memorySize / pageSize);
    }
    return WK_ORIGINAL(sysconf) ? WK_ORIGINAL(sysconf)(name) : -1;
}

// The name macports-legacy-support gives the same call, kept so a binary built against that library
// resolves here rather than pulling in a second sysconf.
long macports_legacy_sysconf(int name);
long macports_legacy_sysconf(int name) { return sysconf(name); }

#pragma mark - notify

// notify_is_valid_token (10.10+) asks whether a notify token is still live. 10.9's notify has no
// token registry to consult, so the call cannot be answered: report "not valid" and set ENOSYS,
// which is how a caller distinguishes "no" from "unsupported".
WK_POLYFILL_ABSENT(NULL, bool, notify_is_valid_token, (int token), (token))
{
    (void)token;
    errno = ENOSYS;
    return false;
}

#pragma mark - dyld shared cache

// dyld_shared_cache_iterate_text (10.10+) walks the text ranges of the images in the shared cache.
// Returning non-zero is the "no shared cache to iterate" answer, which leaves callers on the path
// they take on a machine whose cache is unavailable.
WK_POLYFILL_ABSENT(NULL, int, dyld_shared_cache_iterate_text, (const void *uuid, void (*callback)(const void *info)), (uuid, callback))
{
    (void)uuid; (void)callback;
    return -1;
}

#pragma mark - ObjC runtime fast paths (10.14+ / 11.0+)

// Each of these is an optimized entry point newer libobjc offers for a message send the compiler
// would otherwise emit inline. 10.9's libobjc has none of them, so implement each as the message
// send it stands for — same result, without the fast path.
//
// objc_alloc is deliberately NOT polyfilled: 10.9's libobjc already exports it.

WK_POLYFILL_ABSENT(NULL, id, objc_alloc_init, (Class cls), (cls))
{
    id object = ((id (*)(Class, SEL))objc_msgSend)(cls, sel_getUid("alloc"));
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_getUid("init"));
}

WK_POLYFILL_ABSENT(NULL, Class, objc_opt_class, (id object), (object))
{
    if (!object)
        return Nil;
    return ((Class (*)(id, SEL))objc_msgSend)(object, sel_getUid("class"));
}

WK_POLYFILL_ABSENT(NULL, BOOL, objc_opt_isKindOfClass, (id object, Class cls), (object, cls))
{
    if (!object)
        return NO;
    return ((BOOL (*)(id, SEL, Class))objc_msgSend)(object, sel_getUid("isKindOfClass:"), cls);
}

WK_POLYFILL_ABSENT(NULL, BOOL, objc_opt_respondsToSelector, (id object, SEL selector), (object, selector))
{
    if (!object)
        return NO;
    return ((BOOL (*)(id, SEL, SEL))objc_msgSend)(object, sel_getUid("respondsToSelector:"), selector);
}

// objc_unsafeClaimAutoreleasedReturnValue (10.11+) claims an autoreleased return value without
// retaining it. 10.9 has only the retaining form; claiming with a retain is the conservative
// direction (the object stays alive at least as long), and ARC balances it at the call site.
extern id objc_retainAutoreleasedReturnValue(id object);
WK_POLYFILL_ABSENT(NULL, id, objc_unsafeClaimAutoreleasedReturnValue, (id object), (object))
{
    return objc_retainAutoreleasedReturnValue(object);
}

#pragma mark - mach thread register scanning

// thread_get_register_pointer_values (10.11+) reports a suspended thread's stack pointer and the
// registers that may hold pointers — what a conservative garbage collector scans for roots. 10.9
// has no such call, but it does have thread_get_state, from which the same values come directly:
// %rsp plus the 15 general-purpose registers and %rip.
WK_POLYFILL_ABSENT(NULL, kern_return_t, thread_get_register_pointer_values,
    (thread_t thread, uintptr_t *sp, size_t *count, uintptr_t *register_values),
    (thread, sp, count, register_values))
{
    x86_thread_state64_t state;
    mach_msg_type_number_t stateCount = x86_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &stateCount);
    if (kr != KERN_SUCCESS)
        return kr;

    if (sp)
        *sp = state.__rsp;

    if (register_values && count) {
        size_t i = 0;
        register_values[i++] = state.__rax;
        register_values[i++] = state.__rbx;
        register_values[i++] = state.__rcx;
        register_values[i++] = state.__rdx;
        register_values[i++] = state.__rdi;
        register_values[i++] = state.__rsi;
        register_values[i++] = state.__rbp;
        register_values[i++] = state.__r8;
        register_values[i++] = state.__r9;
        register_values[i++] = state.__r10;
        register_values[i++] = state.__r11;
        register_values[i++] = state.__r12;
        register_values[i++] = state.__r13;
        register_values[i++] = state.__r14;
        register_values[i++] = state.__r15;
        register_values[i++] = state.__rip;
        *count = i;
    }
    return KERN_SUCCESS;
}

#pragma mark - stack probe

// ___chkstk_darwin is the stack probe clang emits ahead of a frame large enough to skip past the
// guard page; 10.9's libSystem predates it. %rax holds the frame size on entry and must be
// preserved, so touch one byte on every page from the caller's stack pointer down to the end of the
// frame — faulting in each page in order, which is what makes the guard page do its job. Written in
// assembly because the calling convention (arguments and clobbers in registers, not on the stack)
// has no C spelling.
__asm__(
    ".globl ____chkstk_darwin\n"
    // -fvisibility=hidden does not reach a .globl inside inline asm, so say it here: this is a
    // libSystem-namespace name and must not become a public export of the WebKit frameworks.
    ".private_extern ____chkstk_darwin\n"
    "____chkstk_darwin:\n"
    "  pushq  %rcx\n"
    "  pushq  %rax\n"
    "  cmpq   $0x1000, %rax\n"
    "  leaq   24(%rsp), %rcx\n"   /* rcx = original rsp */
    "  jb     .Ldone\n"
    ".Lloop:\n"
    "  subq   $0x1000, %rcx\n"
    "  testq  %rcx, (%rcx)\n"     /* probe the page */
    "  subq   $0x1000, %rax\n"
    "  cmpq   $0x1000, %rax\n"
    "  ja     .Lloop\n"
    ".Ldone:\n"
    "  subq   %rax, %rcx\n"
    "  testq  %rcx, (%rcx)\n"     /* probe last partial page */
    "  popq   %rax\n"
    "  popq   %rcx\n"
    "  retq\n"
);
