// libSystem: entry points and constants modern WebKit references that 10.9's libSystem does not
// export -- libc, dyld, xpc, dispatch, os_log / os_signpost / os_variant, pthread,
// mach, voucher, sandbox, os_state and CommonCrypto.
#include "wk_polyfill.h"
#include "dispatch-activate-once.h"

#import <Foundation/Foundation.h>
#include <Block.h>
#include <CommonCrypto/CommonCrypto.h>
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
#include <pthread/qos.h>
#include <sys/qos.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <syslog.h>
#include <unistd.h>
#include <uuid/uuid.h>

// The XPC activity criteria keys added after 10.9 (referenced via WTF XPCSPI.h). 10.9's libxpc has
// the other XPC_ACTIVITY_* keys but not these two; 10.9's xpc_activity ignores an unknown criterion,
// so the activity simply runs without that requirement.
typedef const char *PolyCStringConst;
WK_POLYFILL_CONST(NULL, PolyCStringConst, XPC_ACTIVITY_REQUIRE_NETWORK_CONNECTIVITY, "RequireNetworkConnectivity");
WK_POLYFILL_CONST(NULL, PolyCStringConst, XPC_ACTIVITY_RANDOM_INITIAL_DELAY, "RandomInitialDelay");

// _os_log_default is the storage behind OS_LOG_DEFAULT (10.12+). Call sites only ever take its
// ADDRESS and hand that to _os_log_internal / _os_log_impl, which on 10.9 ignore the log handle
// (below), so nothing reads the storage — it exists so that taking its address yields a
// valid, stable pointer rather than dereferencing a NULL weak import.
static struct { int unused; } wkOSLogDefaultStorage;
typedef void *PolyVoidPtrConst;
WK_POLYFILL_CONST(NULL, PolyVoidPtrConst, _os_log_default, &wkOSLogDefaultStorage);

// ---------------------------------------------------------------------------------------------------
// Sandbox -- two extension flags absent on 10.9.
//
// 10.9 has SANDBOX_EXTENSION_CANONICAL (0x2) and SANDBOX_BUILD_ID (both bind from libsandbox.1.dylib),
// but neither flag below. Both request behavior this sandbox has no notion of -- suppressing violation
// reports for an extension, and tagging one as issued on explicit user intent -- so define them as no
// bits: WebKit ORs them into the flags word it passes to sandbox_extension_issue_*, and an unrecognized
// bit would risk the 10.9 issuer rejecting the request, whereas 0 leaves it at this OS's default handling.
WK_POLYFILL_CONST(NULL, uint32_t, SANDBOX_EXTENSION_NO_REPORT, 0);
WK_POLYFILL_CONST(NULL, uint32_t, SANDBOX_EXTENSION_USER_INTENT, 0);

#pragma mark - C function stubs

WK_POLYFILL_ABSENT(NULL, void, abort_with_reason, (uint32_t a, uint64_t b, const char *c, uint64_t d)) { (void)a; (void)b; (void)c; (void)d; abort(); }
WK_POLYFILL_ABSENT(NULL, void, os_fault_with_payload, (uint32_t a, uint64_t b, const void *c, uint32_t d, const char *e, uint64_t f)) { (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; }

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

WK_POLYFILL_ABSENT(NULL, bool, dyld_program_sdk_at_least, (dyld_build_version_t version))
{
    return wk_version_at_least(WK_PLATFORM_MACOS,
        wk_program_version(WK_SYSTEM(dyld_get_program_sdk_version), true), version);
}

WK_POLYFILL_ABSENT(NULL, bool, dyld_program_minos_at_least, (dyld_build_version_t version))
{
    return wk_version_at_least(WK_PLATFORM_MACOS,
        wk_program_version(WK_SYSTEM(dyld_get_program_min_os_version), false), version);
}

WK_POLYFILL_ABSENT(NULL, bool, dyld_sdk_at_least, (const struct mach_header *header, dyld_build_version_t version))
{
    uint32_t platform = 0, minos = 0, sdk = 0;
    if (!wk_image_build_versions(header, &platform, &minos, &sdk))
        return false;
    (void)minos;
    return wk_version_at_least(platform, sdk, version);
}

// cache/simulator stubs
WK_POLYFILL_ABSENT(NULL, void, cache_simulate_size_response, (uint64_t a, uint64_t b, uint64_t c)) { (void)a; (void)b; (void)c; }

// os_variant stubs
WK_POLYFILL_ABSENT(NULL, bool, os_variant_allows_internal_security_policies, (const char *s)) { (void)s; return false; }
WK_POLYFILL_ABSENT(NULL, bool, os_variant_has_internal_content, (const char *s)) { (void)s; return false; }
WK_POLYFILL_ABSENT(NULL, bool, os_variant_has_internal_diagnostics, (const char *s)) { (void)s; return false; }

// os_log unified logging is 10.12+; _os_log_internal is the macro-emitted backing for every os_log()
// call site and is absent from 10.9's libSystem (it links as the Mach-O symbol __os_log_internal).
// Without a definition the first os_log() call aborts fatally ("lazy symbol binding failed"); a no-op
// makes logging silently do nothing. (OS_LOG_DEFAULT's backing storage, _os_log_default, is a data
// symbol defined above; the no-op ignores whichever log handle it is handed.)
// Signature uses plain types (os_log_t/os_log_type_t aren't visible under --no-default-config);
// ABI-equivalent: os_log_t==pointer, os_log_type_t==uint8_t, buf==uint8_t*, size==uint32_t.
WK_POLYFILL_ABSENT(NULL, void, _os_log_internal,
    (void *dso, void *log, uint8_t type, const char *format, uint8_t *buf, uint32_t size)) {
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

// os_log_create(subsystem, category) -> os_log_t (10.12+, absent on 10.9). os_log_t is an os_object /
// ObjC type, and WebKit wraps the result in a RetainPtr<os_log_t> — so it sends -retain/-release to it.
// Therefore the returned handle MUST be a real, retainable Objective-C object (a bare pointer crashes in
// objc_msgSend on [obj retain]). Return a fresh +1 NSObject (matching os_log_create's create semantics);
// _os_log_internal ignores the log, so the object's only role is to be a valid refcounted handle.
WK_POLYFILL_ABSENT(NULL, void *, _os_log_create, (const char *subsystem, const char *category)) {
    (void)subsystem; (void)category;
    return (void *)[[NSObject alloc] init];
}

// os_signpost performance tracing is 10.14+; absent on 10.9. No-op so signpost call sites link and the
// "is signposting enabled" guard always reports disabled (no emit happens).
WK_POLYFILL_ABSENT(NULL, bool, os_signpost_enabled, (void *log)) { (void)log; return false; }
WK_POLYFILL_ABSENT(NULL, uint64_t, os_signpost_id_make_with_pointer, (void *log, const void *ptr)) { (void)log; return (uint64_t)(uintptr_t)ptr; }
WK_POLYFILL_ABSENT(NULL, void, _os_signpost_emit_with_name_impl,
    (void *dso, void *log, uint8_t type, uint64_t spid, const char *name, const char *format, uint8_t *buf, uint32_t size)) {
    (void)dso; (void)log; (void)type; (void)spid; (void)name; (void)format; (void)buf; (void)size;
}

// os_feature_enabled(domain, feature) — libSystem feature-flag query (10.13+). Every WebKit call site
// gates a feature that postdates 10.9 (VisualIntelligence/Translate/TextComposer post-editing/the
// redesigned text cursor), so the faithful answer on this OS is "not enabled".
WK_POLYFILL_ABSENT(NULL, bool, _os_feature_enabled_impl, (const char *domain, const char *feature))
{
    (void)domain;
    (void)feature;
    return false;
}


// timingsafe_bcmp (constant-time compare, used by crypto) is absent on 10.9. Provide a constant-time
// implementation (no early-out) so timing characteristics match the real function.
WK_POLYFILL_ABSENT(NULL, int, timingsafe_bcmp, (const void *a, const void *b, size_t n)) {
    const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
    unsigned char r = 0;
    for (size_t i = 0; i < n; i++) r |= x[i] ^ y[i];
    return r != 0;
}

// voucher_mach_msg_set (libdispatch QoS voucher propagation) is 10.10+. Vouchers don't exist on 10.9;
// report "no voucher set" (FALSE). Vouchers are only a QoS-propagation optimization, so this is benign.
WK_POLYFILL_ABSENT(NULL, boolean_t, voucher_mach_msg_set, (mach_msg_header_t *msg)) { (void)msg; return FALSE; }

// mach_memory_entry_ownership (footprint-ledger attribution of shared memory) is ~10.13+. 10.9's
// kernel does not implement the routine, and KERN_NOT_SUPPORTED is what a kernel without it answers --
// the same honest answer task_create_identity_token gives below, for the same reason.
//
// The status must not claim success. SharedMemoryHandle::takeOwnershipOfMemory (WebCore
// SharedMemoryCocoa.mm:75) calls this unconditionally -- unlike setOwnershipOfMemory at :88, which is
// gated on ProcessIdentity and so stays quiet on 10.9 -- and RELEASE_LOG_ERROR_IFs the result. That
// log line is the only signal that footprint attribution did not happen, and it is accurate:
// ownership really is not taken. Reporting a success the kernel never performed would be a fake
// value rather than a no-op stub, and would rest on one caller's tolerance instead of on what the
// platform can do.
WK_POLYFILL_ABSENT(NULL, int, mach_memory_entry_ownership,
    (unsigned int mem_entry, unsigned int owner, int ledger_tag, int ledger_flags)) {
    (void)mem_entry; (void)owner; (void)ledger_tag; (void)ledger_flags;
    return KERN_NOT_SUPPORTED;
}

// (__darwin_check_fd_set_overflow lives in the "newer-than-10.9 C / CoreFoundation symbols" section
// below; it is defined exactly once.)

// dispatch_queue_create_with_target() (10.10 SDK): the modern SDK emits the ABI-tagged "$V2" variant,
// and 10.9 has no "$V2" symbol. Recreate it from dispatch_queue_create + dispatch_set_target_queue
// (both 10.6). The asm label is what puts the "$V2" suffix on the emitted symbol; the C identifier
// stays the plain name.
// REPLACES, not a gap-fill: 10.9's libdispatch does export the UNSUFFIXED
// dispatch_queue_create_with_target (verified by dlsym on this host — the pre-10.10 "legacy" V1 entry
// point), so the registry name collides with a symbol 10.9 has. REPLACES records that we deliberately
// supply our own $V2 body — rebuilt from the primitives above — rather than 10.9's same-named V1. The
// body always runs; nothing forwards.
dispatch_queue_t dispatch_queue_create_with_target(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target)
    __asm__("_dispatch_queue_create_with_target$V2");
WK_POLYFILL_REPLACES(NULL, dispatch_queue_t, dispatch_queue_create_with_target,
    (const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target)) {
    dispatch_queue_t queue = dispatch_queue_create(label, attr);
    if (queue && target) dispatch_set_target_queue(queue, target);
    return queue;
}

// dispatch_get_global_queue with a QOS class identifier (10.10+): 10.9's libdispatch knows only the
// legacy DISPATCH_QUEUE_PRIORITY_* identifiers and returns NULL for a QOS class — and a NULL queue
// turns every dispatch onto it into a crash. Map each QOS class onto the legacy band upstream
// libdispatch itself equates it with (its legacy entry point maps HIGH↔USER_INITIATED,
// DEFAULT↔DEFAULT, LOW↔UTILITY, BACKGROUND↔BACKGROUND/MAINTENANCE) and forward; legacy identifiers
// (and QOS_CLASS_UNSPECIFIED, which is 0 like PRIORITY_DEFAULT) pass through untouched. REPLACES:
// the function itself is present and correct for legacy inputs.
WK_POLYFILL_REPLACES(NULL, dispatch_queue_global_t, dispatch_get_global_queue, (intptr_t identifier, uintptr_t flags)) {
    if (identifier == 0x21 /*QOS_CLASS_USER_INTERACTIVE*/ || identifier == 0x19 /*QOS_CLASS_USER_INITIATED*/)
        identifier = DISPATCH_QUEUE_PRIORITY_HIGH;
    else if (identifier == 0x15 /*QOS_CLASS_DEFAULT*/)
        identifier = DISPATCH_QUEUE_PRIORITY_DEFAULT;
    else if (identifier == 0x11 /*QOS_CLASS_UTILITY*/)
        identifier = DISPATCH_QUEUE_PRIORITY_LOW;
    else if (identifier == 0x09 /*QOS_CLASS_BACKGROUND*/ || identifier == 0x05 /*QOS_CLASS_MAINTENANCE*/)
        identifier = DISPATCH_QUEUE_PRIORITY_BACKGROUND;
    return WK_ORIGINAL(dispatch_get_global_queue)(identifier, flags);
}

// task_info(TASK_VM_INFO) grew phys_footprint after 10.9. This kernel answers the flavor with the
// 2013 structure and reports the length it filled: measured on this host, kr=0 and count=36, which is
// exactly the modern header's TASK_VM_INFO_REV0_COUNT and ends at offsetof(phys_footprint) — the two
// layouts agree byte for byte up to that point, so the field is simply never written and a caller
// that reads it gets whatever was in its buffer.
//
// phys_footprint is a task's internal (dirty anonymous) pages plus what the compressor holds for it,
// and 10.9 fills both of those. Measured here, internal+compressed is 282624 where resident_size is
// 503808: resident size is not a stand-in, because it counts clean file-backed pages that are not
// part of the footprint. Fill the short field and report the count that includes it, which is what a
// kernel that implements REV1 replies. Every other flavor — TASK_AUDIT_TOKEN among them — and any
// reply that already reaches phys_footprint pass through untouched.
WK_POLYFILL_REPLACES(NULL, kern_return_t, task_info,
    (task_name_t target, task_flavor_t flavor, task_info_t out, mach_msg_type_number_t *outCnt)) {
    if (flavor != TASK_VM_INFO || !out || !outCnt)
        return WK_ORIGINAL(task_info)(target, flavor, out, outCnt);

    const mach_msg_type_number_t requested = *outCnt;
    kern_return_t kr = WK_ORIGINAL(task_info)(target, flavor, out, outCnt);
    if (kr != KERN_SUCCESS)
        return kr;

    const mach_msg_type_number_t throughCompressed = (mach_msg_type_number_t)
        ((offsetof(task_vm_info_data_t, compressed) + sizeof(((task_vm_info_data_t *)0)->compressed)) / sizeof(natural_t));
    const mach_msg_type_number_t throughPhysFootprint = (mach_msg_type_number_t)
        ((offsetof(task_vm_info_data_t, phys_footprint) + sizeof(((task_vm_info_data_t *)0)->phys_footprint)) / sizeof(natural_t));
    if (requested < throughPhysFootprint || *outCnt >= throughPhysFootprint || *outCnt < throughCompressed)
        return kr;

    task_vm_info_data_t *info = (task_vm_info_data_t *)out;
    info->phys_footprint = info->internal + info->compressed;
    *outCnt = throughPhysFootprint;
    return kr;
}

// DISPATCH_MEMORYPRESSURE_PROC_LIMIT_WARN and _PROC_LIMIT_CRITICAL are 10.10+. 10.9's libdispatch
// validates the mask and answers a mask carrying them with NULL — measured on this host: 0x07 gives a
// source, 0x37 and 0x17 give NULL — and a NULL source means the caller registered no handler at all,
// so nothing hears system memory pressure. Narrow a memorypressure mask to the three levels this
// kernel notifies on, which is every level it can deliver; a process-limit notification has no source
// here to raise it. Every other source type is forwarded with its mask untouched.
WK_POLYFILL_REPLACES(NULL, dispatch_source_t, dispatch_source_create,
    (dispatch_source_type_t type, uintptr_t handle, uintptr_t mask, dispatch_queue_t queue)) {
    if (type == DISPATCH_SOURCE_TYPE_MEMORYPRESSURE)
        mask &= (uintptr_t)(DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL);
    return WK_ORIGINAL(dispatch_source_create)(type, handle, mask, queue);
}

// xpc_type_get_name (newer XPC introspection) — used only for diagnostic strings; return a generic label.
WK_POLYFILL_ABSENT(NULL, const char *, xpc_type_get_name, (xpc_type_t type)) { (void)type; return "xpc-object"; }

// xpc_dictionary_get_array (10.10+): the typed array accessor. 10.9 has xpc_dictionary_get_value, which
// returns the same borrowed object when the key holds an array — exactly what callers (e.g. the auth
// client-certificate chain in AuthenticationManagerCocoa) expect.
WK_POLYFILL_ABSENT(NULL, xpc_object_t, xpc_dictionary_get_array, (xpc_object_t xdict, const char *key)) { return xpc_dictionary_get_value(xdict, key); }

// xpc_connection_copy_invalidation_reason (10.10+): no per-connection reason string on 10.9; return a
// caller-freeable generic reason (used only for diagnostic logging).
WK_POLYFILL_ABSENT(NULL, char *, xpc_connection_copy_invalidation_reason, (xpc_connection_t connection)) { (void)connection; return strdup("connection invalidated"); }

// xpc_connection_activate (10.14+): starts a connection created in the suspended state, which is
// exactly what xpc_connection_resume did before the rename — 10.14 split "resume" into activate
// (first start) and resume (undo a suspend), keeping the old spelling working for both. 10.9 has
// only xpc_connection_resume (checked against libxpc), and every call site here activates a
// freshly-created connection, which is the case the two spellings share.
WK_POLYFILL_ABSENT(NULL, void, xpc_connection_activate, (xpc_connection_t connection))
{
    if (connection)
        xpc_connection_resume(connection);
}

// xpc_transaction_exit_clean (10.10+): exit once outstanding transactions drain. It is called from the
// XPC service entry point's shutdown path (after the OS transaction is cleared), so a clean exit matches.
WK_POLYFILL_ABSENT(NULL, void, xpc_transaction_exit_clean, (void)) { exit(0); }

#pragma mark - newer-than-10.9 C / CoreFoundation symbols WebKit references
// A few plain C / CoreFoundation symbols WebKit (and the bundled libwebrtc) reference are absent from
// the 10.9 runtime. (The GStreamer dylibs' own post-10.9 libc gap is closed at link time by the gap
// archive MavericksSupport/deps/build_deps.sh force-loads into them, not here.)

// __darwin_check_fd_set_overflow (the fortified FD_SET bounds check) is newer; on 10.9 reproduce its
// semantics: a descriptor is valid if non-negative and (when not unlimited) within FD_SETSIZE. The
// FD_SET macro the modern SDK emits calls it.
WK_POLYFILL_ABSENT(NULL, int, __darwin_check_fd_set_overflow, (int n, const void *fdset, int unlimited)) {
    (void)fdset;
    return (n >= 0 && (unlimited || n < FD_SETSIZE)) ? 1 : 0;
}

#pragma mark - dyld image identity and the shared cache (10.10+)

// The image an address belongs to. dladdr already answers exactly this question -- dli_fbase is the
// mach header of the image containing the address -- and is 10.9 API.
WK_POLYFILL_ABSENT(NULL, const struct mach_header *, dyld_image_header_containing_address, (const void *address))
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
WK_POLYFILL_ABSENT(NULL, const struct mach_header *, _dyld_get_dlopen_image_header, (void *handle))
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
WK_POLYFILL_ABSENT(NULL, bool, _dyld_get_image_uuid, (const struct mach_header *header, uuid_t uuid))
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
WK_POLYFILL_ABSENT(NULL, bool, _dyld_get_shared_cache_uuid, (uuid_t uuid))
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
WK_POLYFILL_ABSENT(NULL, const char *, dyld_shared_cache_file_path, (void))
{
#if defined(__x86_64__)
    return "/private/var/db/dyld/dyld_shared_cache_x86_64";
#elif defined(__i386__)
    return "/private/var/db/dyld/dyld_shared_cache_i386";
#else
    #error "no 10.9 dyld shared cache path is known for this architecture"
#endif
}

WK_POLYFILL_ABSENT(NULL, void, cache_simulate_memory_warning_event, (uint64_t a)) { (void)a; }

#pragma mark - os_log emit points (10.12+)

// The other two macro-emitted os_log() backings, and the "would this level be logged?" query the
// os_log macros consult first. Unified logging does not exist on 10.9: report every level disabled
// and drop what is emitted anyway. (_os_log_internal above is the third backing.)
WK_POLYFILL_ABSENT(NULL, int, os_log_type_enabled, (void *log, int type))
{
    (void)log; (void)type;
    return 0; // logging disabled
}

WK_POLYFILL_ABSENT(NULL, void, _os_log_impl,
    (void *dso, void *log, int type, const char *format, void *buf, unsigned int size))
{
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

WK_POLYFILL_ABSENT(NULL, void, _os_log_error_impl,
    (void *dso, void *log, int type, const char *format, void *buf, unsigned int size))
{
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

// The os_log/os_trace SPI WebKit reaches for through wtf/spi/cocoa/OSLogSPI.h. None of the five
// symbols exist in this OS's libSystem or libsystem_trace (checked with nm against both), which is
// the whole of the gap: unified logging arrived in 10.12 and there is no hook for it to call here.
// Plain types are used for the same reason the emit points above use them — os_log_t and
// os_log_type_t are not visible under --no-default-config, and both are ABI-equivalent to a pointer
// and a uint8_t.
WK_POLYFILL_ABSENT(NULL, void, os_log_with_args,
    (void *log, int type, const char *format, va_list args, void *ret_addr))
{
    (void)log; (void)type; (void)format; (void)args; (void)ret_addr;
}

// set_mode/get_mode are a pair: whatever mode is set is the mode reported back. There is no tracing
// subsystem underneath to apply it to, so setting a mode changes nothing observable — but a caller
// that sets a mode and reads it back gets its own value rather than a fabricated one. The starting
// value is an empty mode set, which is the truthful description of an OS with no os_trace at all;
// notably it is NOT OS_TRACE_MODE_OFF (0x0400), because nobody has asked for OFF.
static uint32_t wk_os_trace_mode = 0;

WK_POLYFILL_ABSENT(NULL, void, os_trace_set_mode, (uint32_t mode))
{
    wk_os_trace_mode = mode;
}

WK_POLYFILL_ABSENT(NULL, uint32_t, os_trace_get_mode, (void))
{
    return wk_os_trace_mode;
}

// Returns the PREVIOUSLY installed hook, which on this OS is always none. Answering with the hook
// just handed in would be wrong in a way that bites: WebProcessCocoa.mm stores the result in
// prevHook and its own hook body opens with `if (prevHook) prevHook(type, msg);`, so echoing the
// argument back points the hook at itself and the first message logged would recurse until the
// stack ran out. Nothing invokes it here — no hook can fire without unified logging — so this is
// latent either way, but NULL is both the honest answer and the safe one.
WK_POLYFILL_ABSENT(NULL, void *, os_log_set_hook, (int level, void *hook))
{
    (void)level; (void)hook;
    return NULL;
}

// The message body a hook would have been handed. No hook can fire, so this is unreachable in
// practice; NULL is the documented "no string" answer and its callers all null-check (they wrap it
// in adoptSystemMalloc, which frees what it is given).
WK_POLYFILL_ABSENT(NULL, char *, os_log_copy_message_string, (void *msg))
{
    (void)msg;
    return NULL;
}

#pragma mark - syslog

// syslog$DARWIN_EXTSN is the DARWIN_EXTSN ABI variant of syslog(); 10.9's libc exports only the
// plain spelling, which is the one this forwards to (through vsyslog, the va_list form of the same
// call), so the message reaches syslogd exactly as it would have. The asm label is what puts the
// "$DARWIN_EXTSN" suffix on the emitted symbol. Declared WK_POLYFILL_REPLACES because the registry
// name (plain syslog) is a symbol 10.9 exports; the body always runs and forwards through vsyslog by hand.
void syslog(int priority, const char *message, ...) __asm__("_syslog$DARWIN_EXTSN");
WK_POLYFILL_REPLACES(NULL, void, syslog, (int priority, const char *message, ...))
{
    va_list ap;
    va_start(ap, message);
    vsyslog(priority, message, ap);
    va_end(ap);
}

#pragma mark - dispatch (APIs newer than 10.9)

// ---------------------------------------------------------------------------------------------------
// The QoS-class family (10.10+). 10.9's kernel has no QoS bands at all, and none of these entry points
// exist here — pthread_attr_set_qos_class_np, pthread_set_qos_class_self_np, pthread_get_qos_class_np,
// dispatch_queue_attr_make_with_qos_class, qos_class_self and qos_class_main are all absent (checked
// with nm against libSystem, libdispatch and libsystem_pthread).
//
// Because there are no bands, a QoS request cannot land anywhere: threads run at the scheduling
// priority the OS gives them whether or not anyone asks for a class. So each of these reports the
// truth rather than pretending to have applied something. QOS_CLASS_UNSPECIFIED is Apple's own
// encoding for "this thread has no QoS class assigned", which is the literal state of every thread on
// this kernel — so pthread_get_qos_class_np answering UNSPECIFIED is an accurate reading, not a stub
// value. (WTF's toQOS maps UNSPECIFIED to QOS::Default, the same answer its no-QoS-classes branch
// returns, so currentThreadQOS() is unchanged by having these.)
//
// The pthread half of this family (pthread_{set,get}_qos_class_np, pthread_attr_{set,get}_qos_class_np
// and the override pair) is under "pthread QoS (10.10+)" below, with these same semantics.

// Returns a queue attribute carrying the requested class. With no classes to carry, the attribute is
// returned unmodified, so the queue it configures is exactly the queue the caller would have made.
WK_POLYFILL_ABSENT(NULL, dispatch_queue_attr_t, dispatch_queue_attr_make_with_qos_class,
    (dispatch_queue_attr_t attr, dispatch_qos_class_t qosClass, int relativePriority))
{
    (void)qosClass; (void)relativePriority;
    return attr;
}

// The calling thread's class: none, as above.
WK_POLYFILL_ABSENT(NULL, qos_class_t, qos_class_self, (void))
{
    return QOS_CLASS_UNSPECIFIED;
}

// The main thread's class. Unlike an arbitrary thread, the main thread has a defined band on systems
// that have them, and DEFAULT is what it is given; reporting that keeps main/non-main distinguishable.
WK_POLYFILL_ABSENT(NULL, qos_class_t, qos_class_main, (void))
{
    return QOS_CLASS_DEFAULT;
}

// dispatch_block_create_with_qos_class (10.10+). 10.9's libdispatch has no dispatch_block_create
// family at all — dispatch_block_create, _with_qos_class and dispatch_block_perform are all absent
// (checked with nm against libdispatch and libSystem).
//
// What the modern call does is wrap a block so that it carries a QoS class of its own, which
// DISPATCH_BLOCK_ENFORCE_QOS_CLASS then makes win over the queue's. 10.9 has no per-block QoS to
// carry: a block runs at the priority of the queue it is submitted to, full stop. There is no
// approximation available — the QoS-to-legacy-priority mapping this layer applies in
// dispatch_get_global_queue works because that call SELECTS a queue, whereas here the queue is
// already chosen by the caller and the QoS could only override it.
//
// So the block itself is honoured exactly and the QoS is not: the work runs, at the target queue's
// priority. That is a true statement about this OS rather than a dropped parameter — the alternative
// is WTF's dispatchWithQOS silently doing nothing, which is what the in-tree workaround did before
// this. Returns +1 (Block_copy) to match the Create semantics its callers adopt from.
WK_POLYFILL_ABSENT(NULL, dispatch_block_t, dispatch_block_create_with_qos_class,
    (dispatch_block_flags_t flags, dispatch_qos_class_t qosClass, int relativePriority, dispatch_block_t block))
{
    (void)flags; (void)qosClass; (void)relativePriority;
    return block ? Block_copy(block) : NULL;
}

// The same call without a QoS request; 10.9 lacks it for the same reason.
WK_POLYFILL_ABSENT(NULL, dispatch_block_t, dispatch_block_create, (dispatch_block_flags_t flags, dispatch_block_t block))
{
    (void)flags;
    return block ? Block_copy(block) : NULL;
}

// dispatch_async_and_wait family (10.14). The "async_and_wait" variants differ from dispatch_sync
// only in which thread the block may run on (they may be moved to the queue's own thread rather
// than executed on the caller's); the completion contract — enqueue, then block until done — is the
// same, so dispatch_sync satisfies every caller.
WK_POLYFILL_ABSENT(NULL, void, dispatch_async_and_wait, (dispatch_queue_t queue, dispatch_block_t block))
{
    dispatch_sync(queue, block);
}

WK_POLYFILL_ABSENT(NULL, void, dispatch_async_and_wait_f, (dispatch_queue_t queue, void *ctx, void (*work)(void *)))
{
    dispatch_sync_f(queue, ctx, work);
}

WK_POLYFILL_ABSENT(NULL, void, dispatch_barrier_async_and_wait, (dispatch_queue_t queue, dispatch_block_t block))
{
    dispatch_barrier_sync(queue, block);
}

WK_POLYFILL_ABSENT(NULL, void, dispatch_barrier_async_and_wait_f, (dispatch_queue_t queue, void *ctx, void (*work)(void *)))
{
    dispatch_barrier_sync_f(queue, ctx, work);
}

// dispatch_set_qos_class_floor (10.14) raises the floor of a queue's QoS class. 10.9 has no QoS
// scheduling classes at all (see the pthread QoS group below), so there is no floor to raise.
WK_POLYFILL_ABSENT(NULL, void, dispatch_set_qos_class_floor, (dispatch_object_t object, dispatch_qos_class_t qos_class, int relpri))
{
    (void)object; (void)qos_class; (void)relpri;
}

// dispatch_assert_queue (public in 10.12; the modern SDK emits the ABI-tagged "$V2" spelling, which
// 10.9 has no symbol for). 10.9's libdispatch DOES export the unsuffixed dispatch_assert_queue — the
// pre-10.12 entry point with the same semantics — so the body forwards the $V2 call to it by hand and
// the assertion keeps its real teeth rather than being stubbed out. REPLACES, not a gap-fill, for the
// same reason as dispatch_queue_create_with_target above: the registry name collides with a symbol
// 10.9 exports. The body always runs and calls through explicitly (not the removed auto-forward).
void dispatch_assert_queue(dispatch_queue_t queue) __asm__("_dispatch_assert_queue$V2");
WK_POLYFILL_REPLACES(NULL, void, dispatch_assert_queue, (dispatch_queue_t queue))
{
    if (WK_ORIGINAL(dispatch_assert_queue))
        WK_ORIGINAL(dispatch_assert_queue)(queue);
}

// dispatch_workloop_create / _create_inactive (10.14). A workloop is a priority-ordered queue;
// 10.9's libdispatch has no such object, and a serial queue provides the guarantee every caller
// actually relies on (one block at a time, in submission order).

WK_POLYFILL_ABSENT(NULL, dispatch_workloop_t, dispatch_workloop_create, (const char *label))
{
    return (dispatch_workloop_t)(void *)dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
}

WK_POLYFILL_ABSENT(NULL, dispatch_workloop_t, dispatch_workloop_create_inactive, (const char *label))
{
    return (dispatch_workloop_t)(void *)dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
}

#pragma mark - pthread QoS (10.10+)

// 10.9 has no Quality-of-Service scheduling classes, so there is no class to set, and the honest
// answer to a query is QOS_CLASS_UNSPECIFIED (0) at relative priority 0 — which is exactly what a
// thread on this OS is. Overrides likewise have nothing to override; start returns a non-NULL token
// so the caller's paired _end() call is well-formed.
WK_POLYFILL_ABSENT(NULL, int, pthread_set_qos_class_self_np, (qos_class_t qos_class, int relative_priority))
{
    (void)qos_class; (void)relative_priority;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, int, pthread_get_qos_class_np, (pthread_t thread, qos_class_t *qos_class, int *relative_priority))
{
    (void)thread;
    if (qos_class) *qos_class = QOS_CLASS_UNSPECIFIED;
    if (relative_priority) *relative_priority = 0;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, int, pthread_attr_set_qos_class_np, (pthread_attr_t *attr, qos_class_t qos_class, int relative_priority))
{
    (void)attr; (void)qos_class; (void)relative_priority;
    return 0;
}

WK_POLYFILL_ABSENT(NULL, int, pthread_attr_get_qos_class_np, (pthread_attr_t *attr, qos_class_t *qos_class, int *relative_priority))
{
    (void)attr;
    if (qos_class) *qos_class = QOS_CLASS_UNSPECIFIED;
    if (relative_priority) *relative_priority = 0;
    return 0;
}

// 10.9 has no QoS classes, so no override is installed and there is no pthread_override_t to hand
// back. NULL is the real API's failure return (the SDK's non-null annotation notwithstanding); a
// non-NULL sentinel would be a fabricated handle that a caller may dereference or pass to a routine
// expecting a live override.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
WK_POLYFILL_ABSENT(NULL, pthread_override_t, pthread_override_qos_class_start_np, (pthread_t thread, qos_class_t qos_class, int relative_priority))
{
    (void)thread; (void)qos_class; (void)relative_priority;
    return NULL;
}
#pragma clang diagnostic pop

WK_POLYFILL_ABSENT(NULL, int, pthread_override_qos_class_end_np, (pthread_override_t override))
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

#pragma mark - notify

// notify_is_valid_token (10.10+) asks whether a notify token is still live. 10.9's notify has no
// token registry to consult, so the call cannot be answered: report "not valid" and set ENOSYS,
// which is how a caller distinguishes "no" from "unsupported".
WK_POLYFILL_ABSENT(NULL, bool, notify_is_valid_token, (int token))
{
    (void)token;
    errno = ENOSYS;
    return false;
}

#pragma mark - dyld shared cache

// dyld_shared_cache_iterate_text (10.10+) walks the text ranges of the images in the shared cache.
// Returning non-zero is the "no shared cache to iterate" answer, which leaves callers on the path
// they take on a machine whose cache is unavailable.
WK_POLYFILL_ABSENT(NULL, int, dyld_shared_cache_iterate_text, (const void *uuid, void (*callback)(const void *info)))
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
//
// Calling objc_msgSend through a prototype cast to the concrete signature is the documented way to
// get the right ABI out of its variadic declaration, so the mismatch diagnostic is silenced across
// exactly these four sends and stays armed for every other function-pointer cast in the layer.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type-mismatch"

// @selector literals, not sel_getUid: dyld uniques a selref once at image load, whereas sel_getUid
// is a locked hash-table lookup on every call — and these entry points are the compiler-emitted
// fast paths, so they run on hot code.
WK_POLYFILL_ABSENT(NULL, id, objc_alloc_init, (Class cls))
{
    id object = ((id (*)(Class, SEL))objc_msgSend)(cls, @selector(alloc));
    return ((id (*)(id, SEL))objc_msgSend)(object, @selector(init));
}

WK_POLYFILL_ABSENT(NULL, Class, objc_opt_class, (id object))
{
    if (!object)
        return Nil;
    return ((Class (*)(id, SEL))objc_msgSend)(object, @selector(class));
}

WK_POLYFILL_ABSENT(NULL, BOOL, objc_opt_isKindOfClass, (id object, Class cls))
{
    if (!object)
        return NO;
    return ((BOOL (*)(id, SEL, Class))objc_msgSend)(object, @selector(isKindOfClass:), cls);
}

WK_POLYFILL_ABSENT(NULL, BOOL, objc_opt_respondsToSelector, (id object, SEL selector))
{
    if (!object)
        return NO;
    return ((BOOL (*)(id, SEL, SEL))objc_msgSend)(object, @selector(respondsToSelector:), selector);
}

#pragma clang diagnostic pop

// objc_unsafeClaimAutoreleasedReturnValue (10.11+) claims an autoreleased return value without
// retaining it. 10.9 has only the retaining form; claiming with a retain is the conservative
// direction (the object stays alive at least as long), and ARC balances it at the call site.
extern id objc_retainAutoreleasedReturnValue(id object);
WK_POLYFILL_ABSENT(NULL, id, objc_unsafeClaimAutoreleasedReturnValue, (id object))
{
    return objc_retainAutoreleasedReturnValue(object);
}

#pragma mark - mach thread register scanning

// thread_get_register_pointer_values (10.11+) reports a suspended thread's stack pointer and the
// registers that may hold pointers — what a conservative garbage collector scans for roots. 10.9
// has no such call, but it does have thread_get_state, from which the same values come directly:
// %rsp plus the 15 general-purpose registers and %rip.
WK_POLYFILL_ABSENT(NULL, kern_return_t, thread_get_register_pointer_values,
    (thread_t thread, uintptr_t *sp, size_t *count, uintptr_t *register_values))
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

// ============================================================================
// dlopen: frameworks that are top-level on a modern system but ship here only
// inside an umbrella
// ============================================================================
// Several frameworks a modern system installs at /System/Library/Frameworks/<X>.framework
// exist here ONLY as subframeworks of an umbrella -- PDFKit, CoreImage, QuickLookUI and
// ImageKit all live under Quartz.framework/Frameworks, for example. Soft-linking asks for
// the canonical top-level path (SOFT_LINK_FRAMEWORK_FOR_SOURCE builds exactly
// "/System/Library/Frameworks/<X>.framework/<X>"), and a miss there is not a graceful
// degradation: the generated lookup ends in RELEASE_ASSERT, which took Safari down inside
// -[WKPrintingView drawRect:] the moment Save-as-PDF asked PDFKit for a PDFDocument.
//
// Retry a failed canonical-path open against the umbrella locations, so the modern layout
// resolves to whatever this system actually ships. Only the exact canonical shape is
// rewritten (.../X.framework/X); every other path, and every successful open, is the
// original's answer untouched.
static const char *const wk_umbrellaFrameworks[] = {
    "Quartz", "ApplicationServices", "CoreServices", "Carbon", "Accelerate", "WebKit", NULL
};

WK_POLYFILL_REPLACES(NULL, void *, dlopen, (const char *path, int mode))
{
    if (!WK_ORIGINAL(dlopen))
        return NULL;

    void *handle = WK_ORIGINAL(dlopen)(path, mode);
    if (handle || !path)
        return handle;

    static const char frameworksPrefix[] = "/System/Library/Frameworks/";
    static const char privateFrameworksPrefix[] = "/System/Library/PrivateFrameworks/";
    static const char frameworkInfix[] = ".framework/";
    const size_t infixLength = sizeof(frameworkInfix) - 1;

    // SOFT_LINK_FRAMEWORK_FOR_SOURCE builds the first shape, SOFT_LINK_PRIVATE_FRAMEWORK_FOR_SOURCE
    // the second; both end in the RELEASE_ASSERT the token below exists to satisfy.
    size_t prefixLength;
    int isPublicFramework;
    if (!strncmp(path, frameworksPrefix, sizeof(frameworksPrefix) - 1)) {
        prefixLength = sizeof(frameworksPrefix) - 1;
        isPublicFramework = 1;
    } else if (!strncmp(path, privateFrameworksPrefix, sizeof(privateFrameworksPrefix) - 1)) {
        prefixLength = sizeof(privateFrameworksPrefix) - 1;
        isPublicFramework = 0;
    } else
        return handle;

    const char *name = path + prefixLength;
    const char *infix = strstr(name, frameworkInfix);
    if (!infix)
        return handle;

    // The canonical shape names the framework twice: <X>.framework/<X>, nothing after it.
    size_t nameLength = (size_t)(infix - name);
    const char *leaf = infix + infixLength;
    if (strncmp(leaf, name, nameLength) || leaf[nameLength])
        return handle;

    if (isPublicFramework) {
        for (size_t i = 0; wk_umbrellaFrameworks[i]; ++i) {
            char candidate[PATH_MAX];
            int written = snprintf(candidate, sizeof(candidate), "%s%s.framework/Frameworks/%.*s.framework/%.*s",
                frameworksPrefix, wk_umbrellaFrameworks[i], (int)nameLength, name, (int)nameLength, name);
            if (written <= 0 || (size_t)written >= sizeof(candidate))
                continue;
            handle = WK_ORIGINAL(dlopen)(candidate, mode);
            if (handle)
                return handle;
        }
    }

    // Not anywhere on this system, but the polyfill registry may vend its symbols. Hand back the
    // provider's token, keyed by the path the caller asked for -- the same key providerHandle derives
    // -- so the handle here and the one handleCanSeeProvider compares against are the same object.
    // <Framework>Library() then has a handle instead of a RELEASE_ASSERT, and its canLoad_ probes go
    // on to answer from the registry: true for a name the layer supplies, false for every other,
    // which is how upstream degrades on a system missing that particular SPI.
    void *token = wk_polyfill_absent_provider_token(path);
    if (token) {
        dlerror();   // the failed attempts above left an error pending; this call succeeded
        return token;
    }

    // dlerror() is part of dlopen's contract, and callers report it: soft-linking ends in
    // RELEASE_ASSERT_WITH_MESSAGE(..., dlerror()). After the retries above, the pending error
    // describes an umbrella path the caller never asked for, so re-issue the original request
    // and let a genuine failure name the path that was actually requested.
    return WK_ORIGINAL(dlopen)(path, mode);
}

// A handle dlopen above returned is one dlclose has to take back. A token is this layer's own object
// with nothing mapped behind it, so closing it succeeds and does nothing.
WK_POLYFILL_REPLACES(NULL, int, dlclose, (void *handle))
{
    if (wk_polyfill_is_absent_provider_token(handle))
        return 0;
    if (!WK_ORIGINAL(dlclose))
        return 0;
    return WK_ORIGINAL(dlclose)(handle);
}

// ---------------------------------------------------------------------------------------------------
// Diagnostics + audit-token sandbox checks absent on 10.9.
// ---------------------------------------------------------------------------------------------------

typedef struct { unsigned int val[8]; } mav_audit_token_t;

// The pid-keyed sandbox check: present on 10.9 in libsystem_sandbox.dylib, which every process has
// loaded through libSystem, but SPI that this SDK's <sandbox.h> does not declare and its libSystem
// stub library does not necessarily list. Soft-linked through RTLD_DEFAULT so a link-time reference
// cannot fail in the host tools that force-load this archive. The signature matches
// Source/WTF/wtf/spi/darwin/SandboxSPI.h, with the filter-type enum spelled as the int it promotes to.
WK_SYSTEM_FN(NULL, int, sandbox_check, (pid_t, const char *operation, int type, ...));

// audit_token_to_pid() is soft-linked rather than linked: it lives in libbsm, which this archive's
// consumers do not otherwise pull in, and a link-time reference would make every small host tool
// that force-loads libpolyfill (LLIntSettingsExtractor and friends) need -lbsm. audit_token_t is
// laid out identically to mav_audit_token_t, so it is passed by value unchanged.
WK_SYSTEM_FN("/usr/lib/libbsm.dylib", pid_t, audit_token_to_pid, (mav_audit_token_t));

// State-dump (sysdiagnose) handler registration. None on 10.9; return a null handle.
WK_POLYFILL_ABSENT(NULL, unsigned long, os_state_add_handler, (void *queue, void *handler))
{
    (void)queue; (void)handler;
    return 0;
}

// Audit-token sandbox checks. 10.9 has the real check, just keyed by pid (sandbox_check, in
// libsystem_sandbox.dylib) rather than by audit token, so this asks it the same question about the
// pid the token names. audit_token_to_pid() is the standard accessor and is present here.
//
// The answer is therefore the kernel's, for any caller: sandbox_check() reports 0 when the target
// is permitted the operation (including when it is unsandboxed) and nonzero when the sandbox
// denies it. Callers depend on that being real -- connectedProcessIsSandboxed() in
// Shared/Cocoa/SandboxUtilities.mm, XPCServiceInitializerDelegate::checkEntitlements(), and
// isNetworkAccessBlockedInUIProcess() all decide on it.
//
// The variadic tail is the filter argument. With no operation, or with SANDBOX_FILTER_NONE, the
// query is "is this process sandboxed at all" and there is no filter to pass; every other filter
// type takes exactly one pointer.
WK_POLYFILL_ABSENT(NULL, int, sandbox_check_by_audit_token, (mav_audit_token_t token, const char *operation, int type, ...))
{
    // SANDBOX_FILTER_NONE is 0; the flag bits (SANDBOX_CHECK_NO_REPORT and friends) live in the
    // high bits of the same argument and must be preserved when forwarding.
    enum { MAV_SANDBOX_FILTER_TYPE_MASK = 0xff };

    // Without either half there is no way to answer; report the error rather than invent a verdict.
    if (!WK_SYSTEM(audit_token_to_pid) || !WK_SYSTEM(sandbox_check))
        return -1;
    pid_t pid = WK_SYSTEM(audit_token_to_pid)(token);
    if (pid <= 0)
        return -1;

    if (!operation || !(type & MAV_SANDBOX_FILTER_TYPE_MASK))
        return WK_SYSTEM(sandbox_check)(pid, operation, type);

    va_list arguments;
    va_start(arguments, type);
    const void *filter = va_arg(arguments, const void *);
    va_end(arguments);
    return WK_SYSTEM(sandbox_check)(pid, operation, type, filter);
}

WK_POLYFILL_ABSENT(NULL, bool, sandbox_enable_state_flag, (const char *name, mav_audit_token_t token))
{
    (void)name; (void)token;
    return false;
}

// ---------------------------------------------------------------------------------------------------
// Sandbox extension issuing and profile compilation absent on 10.9.
//
// 10.9 has the process-agnostic issuers (sandbox_extension_issue_file / _mach / _generic, plus
// _consume and _release) and the full compile/apply profile API (sandbox_create_params, _set_param,
// _free_params, sandbox_compile_file / _string, sandbox_apply, _free_profile, SANDBOX_BUILD_ID) in
// /usr/lib/libsandbox.1.dylib, reached via the -lsandbox the WebKit link already passes. Absent are
// only the audit-token variants: the "_to_process" issuers, the IOKit registry-entry-class issuers,
// sandbox_check_by_audit_token, sandbox_enable_state_flag, and the SANDBOX_EXTENSION_NO_REPORT /
// SANDBOX_EXTENSION_USER_INTENT flags. Only those are polyfilled here.
// ---------------------------------------------------------------------------------------------------

extern char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
extern char *sandbox_extension_issue_mach(const char *extension_class, const char *name, uint32_t flags);

// The "_to_process" issuers bind an extension to one target process by audit token; 10.9 only has the
// process-agnostic form, which yields an extension token any process can consume. The token still
// travels over the same trusted IPC channel to the same child, so the grant reaching its intended
// consumer is unchanged -- it simply is not additionally scoped to that process by the kernel.
WK_POLYFILL_ABSENT(NULL, char *, sandbox_extension_issue_file_to_process, (const char *extension_class, const char *path, uint32_t flags, mav_audit_token_t token))
{
    (void)token;
    return sandbox_extension_issue_file(extension_class, path, flags);
}

WK_POLYFILL_ABSENT(NULL, char *, sandbox_extension_issue_mach_to_process, (const char *extension_class, const char *name, uint32_t flags, mav_audit_token_t token))
{
    (void)token;
    return sandbox_extension_issue_mach(extension_class, name, flags);
}

// 10.9's sandbox has no IOKit registry-entry-class extension class, and no other extension class stands
// in for it (a generic or file extension is not consumable as an IOKit one). Report "could not issue"
// -- the honest answer -- which is the same NULL upstream handles when the sandbox declines.
WK_POLYFILL_ABSENT(NULL, char *, sandbox_extension_issue_iokit_registry_entry_class, (const char *extension_class, const char *registry_entry_class, uint32_t flags))
{
    (void)extension_class; (void)registry_entry_class; (void)flags;
    return NULL;
}

WK_POLYFILL_ABSENT(NULL, char *, sandbox_extension_issue_iokit_registry_entry_class_to_process, (const char *extension_class, const char *registry_entry_class, uint32_t flags, mav_audit_token_t token))
{
    (void)extension_class; (void)registry_entry_class; (void)flags; (void)token;
    return NULL;
}

// sandbox_create_params / _set_param / _free_params / sandbox_compile_file / _string / sandbox_apply /
// _free_profile are all present in /usr/lib/libsandbox.1.dylib on 10.9 and bind directly; they are not
// polyfilled.

// ---------------------------------------------------------------------------------------------------
// CommonCrypto — KDF + one-shot AES-GCM SPI absent on 10.9.
//
// The CCKDFParameters/CCDeriveKey key-derivation API and the one-shot CCCryptorGCMOneshotDecrypt are
// 10.10+ and have no symbol in 10.9's libcommonCrypto (verified: absent; CCHmac and the deprecated
// one-shot CCCryptorGCM ARE present). WebCore reaches them through PAL's CommonCryptoSPI.h — WebCrypto
// HKDF (deriveBits/deriveKey) via CCKDFParametersCreateHkdf + CCDeriveKey, and the Push API's aes128gcm
// payload decryption via CCCryptorGCMOneshotDecrypt. Reimplement each over the 10.9-present primitives
// so the upstream call sites revert to pristine. CCStatus/CCDigestAlgorithm/CCKDFParametersRef are SPI
// (not in the public SDK headers); use their underlying ABI types (int32_t / uint32_t /
// struct CCKDFParameters *) here to avoid redeclaring them. The CCDigestAlgorithm values are the
// CommonDigestSPI enum: kCCDigestSHA1=8, DeprecatedCCDigestSHA224=9, kCCDigestSHA256=10, SHA384=11,
// SHA512=12.
// ---------------------------------------------------------------------------------------------------

// CCCryptorGCM (the deprecated but 10.9-present one-shot GCM) is SPI; forward-declare it.
extern CCCryptorStatus CCCryptorGCM(CCOperation op, CCAlgorithm alg, const void *key, size_t keyLength, const void *iv, size_t ivLen, const void *aData, size_t aDataLen, const void *dataIn, size_t dataInLength, void *dataOut, void *tag, size_t *tagLength);

// One-shot AES-GCM decrypt-and-verify. CCCryptorGCM decrypts and computes the authentication tag over
// the data; compare it to the caller's expected tag in constant time and report kCCDecodeError on
// mismatch (the authenticated-decrypt contract: a forged/wrong tag fails rather than returning
// plaintext — the caller treats any non-success as decryption failure).
WK_POLYFILL_ABSENT(NULL, CCCryptorStatus, CCCryptorGCMOneshotDecrypt,
    (CCAlgorithm alg, const void *key, size_t keyLength, const void *iv, size_t ivLen, const void *aData, size_t aDataLen, const void *dataIn, size_t dataInLength, void *dataOut, const void *tagIn, size_t tagLength))
{
    unsigned char computedTag[16];
    if (tagLength > sizeof(computedTag))
        return kCCParamError;
    size_t computedTagLen = tagLength;
    CCCryptorStatus rv = CCCryptorGCM(kCCDecrypt, alg, key, keyLength, iv, ivLen, aData, aDataLen, dataIn, dataInLength, dataOut, computedTag, &computedTagLen);
    if (rv != kCCSuccess)
        return rv;
    const unsigned char *expected = (const unsigned char *)tagIn;
    unsigned char diff = 0;
    for (size_t i = 0; i < tagLength; ++i)
        diff |= (unsigned char)(computedTag[i] ^ expected[i]);
    return diff ? kCCDecodeError : kCCSuccess;
}

// CCKDFParametersRef is `struct CCKDFParameters *` (opaque to callers); complete it here to carry the
// HKDF salt + info(context). CreateHkdf copies them, CCDeriveKey runs extract+expand, Destroy frees.
struct CCKDFParameters {
    void *salt;    size_t saltLen;
    void *context; size_t contextLen;
};

WK_POLYFILL_ABSENT(NULL, int32_t, CCKDFParametersCreateHkdf,
    (struct CCKDFParameters **params, const void *salt, size_t saltLen, const void *context, size_t contextLen))
{
    if (!params)
        return kCCParamError;
    struct CCKDFParameters *p = (struct CCKDFParameters *)calloc(1, sizeof(*p));
    if (!p)
        return kCCMemoryFailure;
    if (saltLen) {
        p->salt = malloc(saltLen);
        if (!p->salt) { free(p); return kCCMemoryFailure; }
        memcpy(p->salt, salt, saltLen);
        p->saltLen = saltLen;
    }
    if (contextLen) {
        p->context = malloc(contextLen);
        if (!p->context) { free(p->salt); free(p); return kCCMemoryFailure; }
        memcpy(p->context, context, contextLen);
        p->contextLen = contextLen;
    }
    *params = p;
    return kCCSuccess;
}

WK_POLYFILL_ABSENT(NULL, void, CCKDFParametersDestroy, (struct CCKDFParameters *params))
{
    if (!params)
        return;
    free(params->salt);
    free(params->context);
    free(params);
}

// Map a CCDigestAlgorithm (8..12) to its HMAC algorithm + output length.
static int mav_hkdfDigestInfo(uint32_t digest, CCHmacAlgorithm *hmacAlg, unsigned *hashLen)
{
    switch (digest) {
    case 8:  *hmacAlg = kCCHmacAlgSHA1;   *hashLen = CC_SHA1_DIGEST_LENGTH;   return 1; // kCCDigestSHA1
    case 9:  *hmacAlg = kCCHmacAlgSHA224; *hashLen = CC_SHA224_DIGEST_LENGTH; return 1; // DeprecatedCCDigestSHA224
    case 10: *hmacAlg = kCCHmacAlgSHA256; *hashLen = CC_SHA256_DIGEST_LENGTH; return 1; // kCCDigestSHA256
    case 11: *hmacAlg = kCCHmacAlgSHA384; *hashLen = CC_SHA384_DIGEST_LENGTH; return 1; // kCCDigestSHA384
    case 12: *hmacAlg = kCCHmacAlgSHA512; *hashLen = CC_SHA512_DIGEST_LENGTH; return 1; // kCCDigestSHA512
    default: return 0;
    }
}

// HKDF (RFC 5869): extract PRK = HMAC(salt, IKM), then expand OKM = T(1..N) where
// T(i) = HMAC(PRK, T(i-1) || info || i), truncated to derivedKeyLen.
WK_POLYFILL_ABSENT(NULL, int32_t, CCDeriveKey,
    (const struct CCKDFParameters *params, uint32_t digest, const void *keyDerivationKey, size_t keyDerivationKeyLen, void *derivedKey, size_t derivedKeyLen))
{
    if (!params || (!derivedKey && derivedKeyLen))
        return kCCParamError;

    CCHmacAlgorithm hmacAlg;
    unsigned hashLen;
    if (!mav_hkdfDigestInfo(digest, &hmacAlg, &hashLen))
        return kCCParamError;

    // HKDF-Extract (RFC 5869 §2.2): empty salt -> HashLen zero bytes.
    unsigned char prk[CC_SHA512_DIGEST_LENGTH];
    if (params->saltLen)
        CCHmac(hmacAlg, params->salt, params->saltLen, keyDerivationKey, keyDerivationKeyLen, prk);
    else {
        unsigned char zeroSalt[CC_SHA512_DIGEST_LENGTH];
        memset(zeroSalt, 0, hashLen);
        CCHmac(hmacAlg, zeroSalt, hashLen, keyDerivationKey, keyDerivationKeyLen, prk);
    }

    // HKDF-Expand (RFC 5869 §2.3).
    size_t N = (derivedKeyLen + hashLen - 1) / hashLen;
    if (N > 255)
        return kCCParamError;

    unsigned char *input = (unsigned char *)malloc(hashLen + params->contextLen + 1);
    if (!input)
        return kCCMemoryFailure;

    unsigned char T[CC_SHA512_DIGEST_LENGTH];
    size_t Tlen = 0, outOffset = 0;
    for (size_t i = 1; i <= N; ++i) {
        size_t pos = 0;
        if (Tlen) { memcpy(input + pos, T, Tlen); pos += Tlen; }
        if (params->contextLen) { memcpy(input + pos, params->context, params->contextLen); pos += params->contextLen; }
        input[pos++] = (unsigned char)i;
        CCHmac(hmacAlg, prk, hashLen, input, pos, T);
        Tlen = hashLen;
        size_t remain = derivedKeyLen - outOffset;
        size_t copyLen = hashLen < remain ? hashLen : remain;
        memcpy((unsigned char *)derivedKey + outOffset, T, copyLen);
        outOffset += copyLen;
    }
    free(input);
    return kCCSuccess;
}

// ---------------------------------------------------------------------------------------------
// Mach: two kernel routines whose MIG subsystems 10.9 predates.

// mach_voucher_deallocate (10.10+). A voucher is a port name in the task's IPC space, and
// deallocating one is releasing that name -- which is what mach_port_deallocate does, and what this
// routine is defined as. 10.9's kernel has no voucher subsystem at all, so no message it delivers
// ever carries one (MACH_MSGH_BITS_HAS_VOUCHER is never set) and IPC::ImportanceAssertion never gets
// as far as calling this; it is implemented properly regardless, so it is right for a caller that
// does hold a name.
WK_POLYFILL_ABSENT(NULL, kern_return_t, mach_voucher_deallocate, (mach_port_name_t voucher))
{
    if (voucher == MACH_PORT_NULL)
        return KERN_SUCCESS;
    return mach_port_deallocate(mach_task_self(), voucher);
}

// task_create_identity_token (12+) mints the token that lets a process attribute memory (IOSurfaces,
// CG backing stores) to another process's ledger. 10.9's kernel has no identity-token subsystem and
// no per-process memory ledger to attribute to, so there is no token to hand back and the honest
// answer is the one a kernel without the routine gives: KERN_NOT_SUPPORTED. That is a case upstream
// already handles -- ProcessIdentity's constructor logs the failure and leaves itself empty, which
// makes `operator bool()` false, which is how every attribution call site is gated. So restoring
// HAVE(TASK_IDENTITY_TOKEN) to upstream costs nothing at runtime: the attribution simply does not
// happen, exactly as when the flag was off.
WK_POLYFILL_ABSENT(NULL, kern_return_t, task_create_identity_token, (task_t task, task_id_token_t *token))
{
    (void)task;
    if (token)
        *token = MACH_PORT_NULL;
    return KERN_NOT_SUPPORTED;
}

// os_retain / os_release (10.10+). WHY THIS EXISTS, since it is easy to conclude it does not need to:
// <os/object.h> defines these as MACROS (`[object retain]`) when OS_OBJECT_USE_OBJC is 1, which it is in
// any ObjC or ObjC++ translation unit — so probing them from a .mm file says "macro, no linker symbol,
// nothing to polyfill". That probe is misleading. In a plain C++ TU, which is most of JavaScriptCore,
// OS_OBJECT_USE_OBJC is 0 and they are ORDINARY FUNCTIONS — absent from 10.9's libSystem, so
// JavaScriptCore fails to load with "Symbol not found: _os_retain". (Measured, after I removed an in-tree
// #ifndef os_retain shim from wtf/OSObjectPtr.h believing it was dead code.)
//
// Every os_object_t 10.9 knows is a libdispatch object, and dispatch_retain/dispatch_release are present
// here (nm-verified) and already do the right thing whichever way libdispatch was built: with
// OS_OBJECT_USE_OBJC they forward to the ObjC retain/release the object actually uses, without it they run
// the plain refcount. So these forward rather than reimplement, which also keeps them correct for any
// os_object_t that is not a dispatch object.
//
// The #undefs are needed because THIS file is ObjC, so the macros are in scope here.
#undef os_retain
#undef os_release

WK_SYSTEM_FN(NULL, void, dispatch_retain, (void *));
WK_SYSTEM_FN(NULL, void, dispatch_release, (void *));

WK_POLYFILL_ABSENT(NULL, void *, os_retain, (void *object))
{
    if (object && WK_SYSTEM(dispatch_retain))
        WK_SYSTEM(dispatch_retain)(object);
    return object;
}

WK_POLYFILL_ABSENT(NULL, void, os_release, (void *object))
{
    if (object && WK_SYSTEM(dispatch_release))
        WK_SYSTEM(dispatch_release)(object);
}

// ---------------------------------------------------------------------------------------------------
// libxpc — the XPC bootstrap-dictionary channel, absent on 10.9 (CoreFoundation.c has the
// _CFBundleSetupXPCBootstrap half).
//
// Modern WebKit hands a child its launch parameters as a "bootstrap dictionary" attached to the
// connection itself: the UI process fills one in and calls xpc_connection_set_bootstrap(), and the
// child reads it back with xpc_copy_bootstrap(). 10.9's libxpc has NO such channel -- verified with
// nm: xpc_copy_bootstrap, xpc_connection_set_bootstrap and _CFBundleSetupXPCBootstrap are all
// absent, while xpc_connection_set_instance IS present.
//
// "Absent, and no equivalent exists" is the honest answer for all three, and it is correct for any
// caller rather than for WebKit's in particular: a NULL bootstrap dictionary is exactly what a
// process that was never given one has, and every caller must already handle that (WebKit's own
// `if (bootstrap)` block simply does not run). The launch parameters still reach the child -- the
// port sends the same dictionary as an ordinary "bootstrap" message instead, which is the
// mechanism upstream itself used before set_bootstrap existed.
// ---------------------------------------------------------------------------------------------------

// A process on 10.9 never has a bootstrap dictionary, so report the absence rather than invent one.
WK_POLYFILL_ABSENT(NULL, xpc_object_t, xpc_copy_bootstrap, (void))
{
    return NULL;
}

WK_POLYFILL_ABSENT(NULL, void, xpc_connection_set_bootstrap, (xpc_connection_t connection, xpc_object_t bootstrap))
{
    (void)connection; (void)bootstrap;
}

// xpc_connection_set_oneshot_instance (10.10+) targets a connection at a service instance that is
// torn down when the connection goes away. 10.9 has its predecessor xpc_connection_set_instance,
// which targets the same per-UUID instance; what it lacks is only the automatic teardown, and the
// instance still dies with the service process. Both take the caller's UUID, so this is a rename
// plus a lifetime nicety, not a missing capability -- and forwarding is correct for any caller,
// since a caller that passes a fresh UUID (which is what "oneshot" is for) gets its own instance
// either way.
extern void xpc_connection_set_instance(xpc_connection_t, uuid_t);

WK_POLYFILL_ABSENT(NULL, void, xpc_connection_set_oneshot_instance, (xpc_connection_t connection, uuid_t instance))
{
    if (!connection)
        return;
    xpc_connection_set_instance(connection, instance);
}

// os_transaction_create (10.10+). The XPC service entry point (Shared/EntryPointUtilities/Cocoa/
// XPCService/XPCServiceEntryPoint) creates one os_transaction to keep the child process alive across
// its initializer; on 10.9 that symbol is absent from libSystem, so every WebContent/Networking/GPU
// child crashed at launch on a lazy bind of _os_transaction_create (EXC_BREAKPOINT in
// dyld::fastBindLazySymbol from NetworkServiceInitializer / WebContentServiceInitializer).
//
// os_transaction is the os_object-era spelling of the launchd transaction 10.9 exports as
// xpc_transaction_begin / xpc_transaction_end (both present in /usr/lib/system/libxpc.dylib, over
// vproc_transaction): while a job holding one is dirty, launchd leaves it alone; a job that holds
// none is clean and launchd may terminate it. A dispatch queue carries the transaction because it
// is an os_object with a finalizer, so the count follows the returned handle's own lifetime through
// the os_retain / os_release forwarders above, however the caller scopes it.
WK_SYSTEM_FN(NULL, void, xpc_transaction_begin, (void));
WK_SYSTEM_FN(NULL, void, xpc_transaction_end, (void));

// 10.9's libdispatch runs an object's finalizer only when its context is non-NULL, so the handle
// carries this address to keep the end of the transaction reachable from its dispose.
static const char wk_transactionContext;

static void wk_endTransaction(void *context)
{
    (void)context;
    if (WK_SYSTEM(xpc_transaction_end))
        WK_SYSTEM(xpc_transaction_end)();
}

WK_POLYFILL_ABSENT(NULL, void *, os_transaction_create, (const char *description))
{
    // The finalizer rides on the handle only when the count was actually taken; ending a
    // transaction nobody began would mark a busy process clean.
    if (!WK_SYSTEM(xpc_transaction_begin))
        return NULL;
    dispatch_queue_t transaction = dispatch_queue_create(description ? description : "com.apple.webkit.os-transaction", DISPATCH_QUEUE_SERIAL);
    if (!transaction)
        return NULL;
    WK_SYSTEM(xpc_transaction_begin)();
    dispatch_set_context(transaction, (void *)&wk_transactionContext);
    dispatch_set_finalizer_f(transaction, wk_endTransaction);
    return transaction;
}

// voucher_replace_default_voucher (10.10+). The same XPC service entry point calls this right after
// InitializeWebKit2() to adopt the mach voucher XPC propagated to the child; on 10.9 the voucher API
// does not exist, so the child crashed at launch on a lazy bind of _voucher_replace_default_voucher
// (same fastBindLazySymbol path as os_transaction_create above). 10.9 has no voucher propagation, so
// leaving the task default voucher untouched is the correct behaviour — a no-op.
WK_POLYFILL_ABSENT(NULL, void, voucher_replace_default_voucher, (void))
{
}

// dispatch_activate (10.11+). A dispatch source/queue created suspended is started with either
// dispatch_activate (one-way, idempotent "make active") or dispatch_resume; on a freshly-created object
// that the caller has not otherwise suspended they are equivalent, and dispatch_resume is present on
// 10.9. Without this, the absent symbol lazy-bind-crashed the process on VideoMediaSampleRenderer.mm's
// timer setup.
//
// The one place the two differ is repetition: activating an already-active object is defined to do
// nothing, while a second dispatch_resume is an over-resume — undefined behaviour, and on a source
// it starts firing events the caller never asked for. Rather than rely on callers activating once,
// this resumes each object exactly once, so it honours the real contract no matter who calls it.
//
// The signature must match <dispatch/dispatch.h>'s declaration (dispatch_object_t, not void*), which is
// present in the SDK even though the symbol is not on 10.9; dispatch_resume IS on 10.9 and lives in
// always-linked libdispatch, so a direct call is safe.
// The "exactly once, keyed to the object" rule lives in dispatch-activate-once.h, one definition
// shared with tests/behaviour/libSystem-dispatch.m so the probe covers this code and not a copy of it.
#include "dispatch-activate-once.h"

WK_POLYFILL_ABSENT(NULL, void, dispatch_activate, (dispatch_object_t object))
{
    wkDispatchActivateOnce(object);
}
