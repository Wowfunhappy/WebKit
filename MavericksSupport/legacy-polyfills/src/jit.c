/*
 * JIT support shims -- custom polyfill (not from macports-legacy-support).
 */

#include <sys/mman.h>
#include <sys/types.h>

/*
 * mmap wrapper -- strip MAP_JIT flag (0x0800, added 10.14).
 * Some runtimes (.NET, etc.) use MAP_JIT for JIT code pages.
 * On 10.9 this flag doesn't exist and causes mmap to fail.
 */

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

extern void *__mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
	flags &= ~MAP_JIT;
	return __mmap(addr, len, prot, flags, fd, offset);
}

/*
 * pthread_jit_write_protect_np (added macOS 11.0)
 * On x86_64, this is a no-op.
 */
void pthread_jit_write_protect_np(int enabled) {
	(void)enabled;
}
