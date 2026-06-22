/*
 * mkostemp / mkostemps -- custom polyfill (not from macports-legacy-support).
 *
 * The flags-taking mkstemp variants were added after 10.9 (mkostemp in 10.10); 10.9 has
 * only mkstemp/mkstemps. Emulate via mkstemp/mkstemps plus fcntl to apply the documented
 * O_CLOEXEC/O_APPEND/O_NONBLOCK flags to the returned descriptor.
 *
 * Lives in the general polyfill (compiled into libpolyfill.a) so any modern-SDK binary
 * linked against it -- WebKit itself as well as the vendored GStreamer compat shim -- can
 * use it. (Previously inline in polyfill_stubs.m; moved here so the GStreamer shim, which
 * cannot compile the full ObjC stub file, shares the same single definition.)
 */

#include <stdlib.h>
#include <fcntl.h>

/* mkstemps() exists in the 10.9 runtime libc but the 10.9 SDK headers (which the
 * legacy-support sources compile against, -isysroot /) don't declare it. Declare it
 * explicitly so mkostemps() below compiles and links against the real symbol. */
extern int mkstemps(char *template, int suffixlen);

static void applyOpenFlags(int fd, int flags) {
	if (fd < 0) return;
	if (flags & O_CLOEXEC) fcntl(fd, F_SETFD, FD_CLOEXEC);
	int sfl = (flags & (O_APPEND | O_NONBLOCK));
	if (sfl) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | sfl);
}

int mkostemp(char *tmpl, int flags) { int fd = mkstemp(tmpl); applyOpenFlags(fd, flags); return fd; }
int mkostemps(char *tmpl, int suffixlen, int flags) { int fd = mkstemps(tmpl, suffixlen); applyOpenFlags(fd, flags); return fd; }
