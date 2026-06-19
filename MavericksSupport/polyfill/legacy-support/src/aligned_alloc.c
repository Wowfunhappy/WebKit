/*
 * aligned_alloc (C11, added to macOS in 10.15) --
 * custom polyfill (not from macports-legacy-support).
 *
 * Implemented via posix_memalign.
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
