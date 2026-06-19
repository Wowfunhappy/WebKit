/*
 * @available() support -- custom polyfill (not from macports-legacy-support).
 *
 * Recent Clang lowers @available to compiler-rt's __isPlatformVersionAtLeast(),
 * which (on a modern compiler-rt) calls the libSystem function
 * _availability_version_check() -- added in macOS 10.15 and absent on 10.9.
 * compiler-rt declares it __attribute__((weak_import)) and has a sysctl fallback
 * for when it is NULL, BUT lld refuses to resolve the weak-import reference to
 * NULL and errors out.  So rather than duplicate the __is* entry points (which
 * collides with compiler-rt's), we supply the one genuinely-missing low-level
 * symbol and let compiler-rt's own __is* code call it.
 *
 * compiler-rt encodes the requested OS version into dyld_build_version_t.version
 * as ((major & 0xffff) << 16) | ((minor & 0xff) << 8) | (subminor & 0xff) and
 * asks whether the running OS is at least that.  We answer from the real OS
 * version (platforms other than macOS can't run on a 10.9 Intel box).
 */

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/sysctl.h>

static int cached_major = 0, cached_minor = 0, cached_patch = 0;

static void ensure_os_version(void) {
	if (cached_major) return;
	char str[64];
	size_t len = sizeof(str);
	if (sysctlbyname("kern.osproductversion", str, &len, NULL, 0) == 0) {
		sscanf(str, "%d.%d.%d", &cached_major, &cached_minor, &cached_patch);
	}
	if (!cached_major) {
		/* Fallback: we know we're on 10.9 */
		cached_major = 10; cached_minor = 9; cached_patch = 5;
	}
}

typedef struct { uint32_t platform; uint32_t version; } _mp_dyld_build_version_t;

bool _availability_version_check(uint32_t count, _mp_dyld_build_version_t versions[]) {
	ensure_os_version();
	uint32_t cur = ((uint32_t)cached_major << 16)
	             | ((uint32_t)cached_minor << 8)
	             | (uint32_t)cached_patch;
	for (uint32_t i = 0; i < count; i++) {
		if (versions[i].version > cur) return false;
	}
	return true;
}
