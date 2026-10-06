/*
 * mach_timebase_info -- a DELIBERATE OVERRIDE of a function 10.9 has.
 *
 * 10.9's libsystem_kernel implements it as the bare mach trap, so every call is a kernel round
 * trip: measured on this host at 135.8 ns, against 15.4 ns for mach_absolute_time itself. The
 * timebase is a constant of the machine, and newer libsystem_kernel reads the trap once and
 * answers from a static copy; this is that version, measured here at 2.7 ns. It is worth having
 * because the caller reads it per timestamp rather than once: GLib's g_get_monotonic_time calls it
 * before every mach_absolute_time, and every GStreamer clock read goes through that.
 *
 * Plain C: deps/build_deps.sh compiles this file into the gap archive that force-loads into every
 * media dylib -- libglib carries g_get_monotonic_time, so the override has to reach it there -- and
 * polyfill/build-polyfill.sh compiles it into libpolyfill.a for WebKit, where WK_POLYFILL_REGISTERED
 * adds the registry entry.
 *
 * 10.9's function is reached by naming its image, libsystem_kernel.dylib, and looking the symbol up
 * there with NSLookupSymbolInImage. That form always reaches the trap whatever the load order, and it
 * does not go through dlsym, which the polyfill layer replaces in WebKit's own binaries.
 */

#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

typedef kern_return_t (*wk_mach_timebase_info_fn)(mach_timebase_info_t);

static const char kWKKernelPath[] = "/usr/lib/system/libsystem_kernel.dylib";

/* numer and denom travel together in one 64-bit word, so a thread that finds the cache populated
 * can never read one half of a pair another thread is still writing. Zero means "not yet read":
 * the trap never answers a denom of 0. */
static _Atomic uint64_t wk_cached_timebase;

/* The pre-dlopen dyld API, deprecated since 10.5 but present and working on 10.9, and used here
 * precisely BECAUSE it is not dlsym. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static wk_mach_timebase_info_fn wk_system_mach_timebase_info(void)
{
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name || strcmp(name, kWKKernelPath))
            continue;

        NSSymbol symbol = NSLookupSymbolInImage(_dyld_get_image_header(i), "_mach_timebase_info",
            NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR);
        if (symbol)
            return (wk_mach_timebase_info_fn)NSAddressOfSymbol(symbol);
        break;
    }
    return 0;
}

#pragma clang diagnostic pop

kern_return_t mach_timebase_info(mach_timebase_info_t info)
{
    uint64_t packed = __c11_atomic_load(&wk_cached_timebase, __ATOMIC_RELAXED);

    if (!packed) {
        wk_mach_timebase_info_fn system = wk_system_mach_timebase_info();
        mach_timebase_info_data_t read = { 0, 0 };
        kern_return_t kr = system ? system(&read) : KERN_FAILURE;

        if (kr != KERN_SUCCESS || !read.denom) {
            fprintf(stderr, "[wk_polyfill] FATAL: mach_timebase_info could not be read from "
                            "%s (resolved=%p, kr=%d, denom=%u).\n"
                            "[wk_polyfill] Every caller of this function reads numer/denom without "
                            "testing the return value -- GLib's g_get_monotonic_time divides by denom "
                            "directly -- so there is no degraded mode: returning would hand the whole "
                            "process a zero timebase. Aborting here rather than failing later as an "
                            "unrelated-looking division fault.\n",
                    kWKKernelPath, (void *)system, (int)kr, read.denom);
            fflush(stderr);
            abort();
        }

        packed = ((uint64_t)read.numer << 32) | read.denom;
        __c11_atomic_store(&wk_cached_timebase, packed, __ATOMIC_RELAXED);
    }

    info->numer = (uint32_t)(packed >> 32);
    info->denom = (uint32_t)packed;
    return KERN_SUCCESS;
}

#ifdef WK_POLYFILL_REGISTERED
/* Registered so WK_POLYFILL_REPORT lists the override and the shadow gate reads a stated intent.
 * The entry is written out by hand so the body above compiles with no wk_polyfill.h, which is how
 * the vendored builds take it. Provider NULL: libSystem, found process-wide. */
WK_PF_ENTRY(mach_timebase_info, NULL, &mach_timebase_info, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
#endif
