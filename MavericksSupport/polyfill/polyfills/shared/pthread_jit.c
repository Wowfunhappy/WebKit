/*
 * pthread_jit_write_protect_np / pthread_jit_write_protect_supported_np (macOS 11.0+),
 * absent on 10.9 (verified by dlsym on this host).
 *
 * Per-thread W^X for JIT pages is an Apple Silicon mechanism. x86_64 has nothing equivalent
 * on any macOS, so "do nothing" and "unsupported" are what this OS can truthfully answer, and
 * they are correct for any caller rather than for one caller's convenience.
 *
 * Separate from jit.c: that file's MAP_JIT-stripping mmap override is a DELIBERATE OVERRIDE of
 * a function 10.9 has, so it belongs only where a caller passes MAP_JIT -- WebKit's JIT. These
 * two are pure gaps, and the non-WebKit builds weak-import them from the modern SDK's pthread.h,
 * so they go in the deps gap archive while mmap does not.
 *
 * Plain C so the builds that carry no polyfill registry -- deps/build_deps.sh, which force-loads
 * these into every media dylib -- compile this same source.
 *
 * WK_POLYFILL_REGISTERED is defined only by polyfill/build-polyfill.sh, i.e. only when
 * this file is built into libpolyfill.a for WebKit. It adds the registry entries and nothing else.
 */

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

void pthread_jit_write_protect_np(int enabled) {
	(void)enabled;
}

int pthread_jit_write_protect_supported_np(void) {
	return 0;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(pthread_jit_write_protect_np, NULL,
    &pthread_jit_write_protect_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(pthread_jit_write_protect_supported_np, NULL,
    &pthread_jit_write_protect_supported_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
