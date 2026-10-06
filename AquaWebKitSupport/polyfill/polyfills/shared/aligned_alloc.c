/*
 * aligned_alloc (C11, added to macOS in 10.15).
 *
 * posix_memalign (present since 10.6) allocates on the same alignment; the only
 * difference is the error reporting, so map its return code onto errno and check
 * aligned_alloc's two documented constraints (power-of-two alignment, size a
 * multiple of it) up front.
 *
 * Plain C, no wk_polyfill.h: the vendored non-WebKit binaries (the GStreamer/FFmpeg
 * media stack, the build's own python3) compile this same source, and they carry no
 * polyfill registry. One definition, used by all of them.
 */

#include <errno.h>
#include <stddef.h>
#include <stdlib.h>

void * aligned_alloc(size_t alignment, size_t size) {
	if (alignment == 0 || (alignment & (alignment - 1)) != 0) {
		errno = EINVAL;
		return NULL;
	}
	if (size % alignment != 0) {
		errno = EINVAL;
		return NULL;
	}

	void *ptr = NULL;
	int result = posix_memalign(&ptr, alignment, size);
	if (result != 0) {
		errno = result;
		return NULL;
	}

	return ptr;
}
