/*
 * mmap's MAP_JIT flag and the pthread JIT write-protection calls.
 *
 * Plain C bodies: the vendored non-WebKit binaries (the GStreamer/FFmpeg media stack,
 * the build's own python3) compile this same source, and they carry no polyfill
 * registry. One definition, used by all of them.
 *
 * WK_POLYFILL_REGISTERED is defined only by polyfill/scripts/build-polyfill.sh, i.e.
 * only when this file is built into libpolyfill.a for WebKit. It adds the registry
 * entry for mmap and nothing else; deps/build_deps.sh and
 * toolchain/scripts/build_python3.sh compile the file without it and stay plain C.
 */

#include <sys/mman.h>
#include <sys/types.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

/*
 * mmap -- a DELIBERATE OVERRIDE of a function 10.9 has. MAP_JIT (0x0800, added 10.14)
 * asks for a page that can be flipped between writable and executable; anything
 * compiled against a modern SDK passes it when mapping JIT code (WebKit's own JIT,
 * libffi's closures). 10.9's kernel does not know the flag and fails the whole mapping
 * with EINVAL, so strip it: on this OS a JIT page is simply mapped RWX, which is what
 * MAP_JIT would have got here anyway. Every other flag is passed through untouched.
 *
 * __mmap is libc's internal entry point, called directly so this cannot recurse into
 * itself.
 */

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

extern void *__mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
	flags &= ~MAP_JIT;
	return __mmap(addr, len, prot, flags, fd, offset);
}

#ifdef WK_POLYFILL_REGISTERED
/*
 * Register the override, so WK_POLYFILL_REPORT lists it like any other deliberate
 * replacement. Without this, mmap is the one polyfilled symbol whose being ours rather
 * than libc's does not show up anywhere. The entry is written out by hand rather than
 * via WK_POLYFILL_REPLACES because the body above has to keep compiling with no
 * wk_polyfill.h for the vendored builds. Provider NULL: libSystem, found process-wide.
 */
WK_PF_ENTRY(mmap, NULL, &mmap, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
#endif
