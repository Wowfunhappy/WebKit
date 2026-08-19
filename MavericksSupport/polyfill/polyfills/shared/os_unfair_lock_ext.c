/*
 * os_unfair_lock_lock_with_flags / _with_options (10.15+).
 *
 * The flags and options only select scheduling hints (priority inheritance, adaptive
 * spinning) for the wait; the locking itself is unchanged. Take the plain lock, which
 * shared/os_unfair_lock.c builds on OSSpinLock.
 *
 * Plain C, no wk_polyfill.h: the vendored non-WebKit binaries (the GStreamer/FFmpeg
 * media stack, the build's own python3) compile this same source, and they carry no
 * polyfill registry. One definition, used by all of them.
 */

#include <stdint.h>

extern void os_unfair_lock_lock(void *lock);

void os_unfair_lock_lock_with_flags(void *lock, uint32_t flags) {
	(void)flags;
	os_unfair_lock_lock(lock);
}

void os_unfair_lock_lock_with_options(void *lock, uint32_t options) {
	(void)options;
	os_unfair_lock_lock(lock);
}
