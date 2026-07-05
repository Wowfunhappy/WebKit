// extra libSystem gap-fills for the vendored GStreamer (Cerbero 1.26.6, deploy
// target 10.13). These three symbols postdate 10.9 and are imported by the vendored libcrypto.3.dylib
// (and other libs built against a newer SDK). They are "expected in" the repointed libSystem
// dependency (@rpath/libsystem_compat.dylib), so defining them here lets those libraries load on 10.9.
// Kept separate from the macports-legacy-support sources because they are Apple-internal libSystem
// runtime helpers, not POSIX gap-fills.

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>   // arc4random_buf

// CommonCrypto RNG (10.10+). libcrypto's RAND backend uses it. arc4random_buf is the 10.9
// cryptographically-secure RNG (Yarrow/Fortuna-seeded), so forward to it. Returns kCCSuccess (0).
int CCRandomGenerateBytes(void *bytes, size_t count)
{
    if (count)
        arc4random_buf(bytes, count);
    return 0;
}

// __darwin_check_fd_set_overflow (10.10+): the FD_SET/FD_CLR/FD_ISSET macros on the modern SDK expand
// to a call into this libSystem helper, which validates that the fd index fits the fd_set and returns
// 1 when the operation may proceed. On 10.9 the macros were inline with no such call; emulate the
// permissive "fits" answer (libcrypto/libnice only select() on small descriptor sets).
int __darwin_check_fd_set_overflow(int n, const void *fd_set_ptr, int unlimited_select)
{
    (void)n;
    (void)fd_set_ptr;
    (void)unlimited_select;
    return 1;
}

// __availability_version_check (10.15+): the runtime backing for `if (@available(...))` checks emitted
// by code compiled against a newer SDK. On 10.9 there is no OS newer than this one, so every newer
// availability requirement is unmet — report "not available" (false). (Libraries deployed to 10.13
// only ever query for >= 10.10 features here, whose 10.9 fallback path is the correct one.)
bool __availability_version_check(uint32_t count, void *versions)
{
    (void)count;
    (void)versions;
    return false;
}

// OSAtomicIncrement32Barrier / OSAtomicDecrement32Barrier (libkern/OSAtomic.h): on 10.9 these are inline
// functions in the SDK header (they expand to the real OSAtomicAdd32Barrier export), so libSystem does
// NOT export them as symbols and there is nothing for libsystem_compat's libSystem reexport to forward.
// The vendored GStreamer dylibs (Cerbero 1.26.6, deploy target 10.13) were built against a newer SDK
// where these became real exported symbols, so libtag/libgstsctp/libzbar import them by name and fail to
// load on 10.9 ("Symbol not found: _OSAtomicDecrement32Barrier, Expected in: libsystem_compat.dylib").
// Define them as the standard full-barrier atomics (returning the post-update value), which is exactly
// the OSAtomic contract. (OSAtomicAdd32Barrier and OSAtomicCompareAndSwapIntBarrier ARE real 10.9 libSystem
// exports and resolve through the reexport, so they need no shim here.)
int32_t OSAtomicIncrement32Barrier(volatile int32_t *value)
{
    return __sync_add_and_fetch(value, 1);
}

int32_t OSAtomicDecrement32Barrier(volatile int32_t *value)
{
    return __sync_sub_and_fetch(value, 1);
}
