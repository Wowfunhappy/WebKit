/*
 * mkostemp / mkostemps (10.10+).
 *
 * The flags-taking mkstemp variants were added after 10.9; 10.9 has only
 * mkstemp/mkstemps. Create the file with those, then apply the documented
 * O_CLOEXEC/O_APPEND/O_NONBLOCK flags to the descriptor with fcntl -- the same end
 * state, reached in two steps instead of one.
 *
 * Plain C, no wk_polyfill.h: the vendored non-WebKit binaries (the GStreamer/FFmpeg
 * media stack, the build's own python3) compile this same source, and they carry no
 * polyfill registry. One definition, used by all of them.
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
