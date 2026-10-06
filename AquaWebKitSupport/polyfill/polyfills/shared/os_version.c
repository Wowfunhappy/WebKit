/*
 * @available() support.
 *
 * Plain C, no wk_polyfill.h: the vendored non-WebKit binaries (the GStreamer/FFmpeg
 * media stack, the build's own python3) compile this same source, and they carry no
 * polyfill registry. One definition, used by all of them.
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
 * asks whether the running OS is at least that.  We answer from the running OS
 * version, read at first use (platforms other than macOS can't run on a 10.9
 * Intel box).
 */

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/sysctl.h>

static int cached_major = 0, cached_minor = 0, cached_patch = 0;

static bool record_version(const char *text)
{
	int major = 0, minor = 0, patch = 0;
	if (sscanf(text, "%d.%d.%d", &major, &minor, &patch) < 1 || major <= 0)
		return false;
	cached_major = major; cached_minor = minor; cached_patch = patch;
	return true;
}

/* Present from 10.13 on. Absent here, but this file shouldn't assume its own host. */
static bool from_sysctl(void)
{
	char str[64];
	size_t len = sizeof(str);
	if (sysctlbyname("kern.osproductversion", str, &len, NULL, 0) != 0)
		return false;
	str[sizeof(str) - 1] = '\0';
	return record_version(str);
}

/* Where 10.9 keeps it. Read with open/read rather than stdio or CoreFoundation:
 * @available checks can run anywhere, including before higher-level runtimes are
 * up, and this is the polyfill they land in. */
static bool from_plist(void)
{
	char buf[8192];
	int fd = open("/System/Library/CoreServices/SystemVersion.plist", O_RDONLY);
	if (fd < 0)
		return false;
	ssize_t got = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (got <= 0)
		return false;
	buf[got] = '\0';
	/* ...<key>ProductVersion</key>\n\t<string>10.9.5</string>... */
	const char *key = strstr(buf, "<key>ProductVersion</key>");
	if (!key)
		return false;
	const char *value = strstr(key, "<string>");
	if (!value)
		return false;
	return record_version(value + sizeof("<string>") - 1);
}

/* Last resort if the plist is missing or unparseable: Darwin major maps to the
 * 10.x minor (Darwin 13 == 10.9). Gets the point release wrong, so it ranks below
 * the plist, but it is still the running kernel's answer rather than a guess. */
static bool from_kernel(void)
{
	char str[64];
	size_t len = sizeof(str);
	int darwin = 0;
	if (sysctlbyname("kern.osrelease", str, &len, NULL, 0) != 0)
		return false;
	str[sizeof(str) - 1] = '\0';
	if (sscanf(str, "%d", &darwin) != 1 || darwin < 5)
		return false;
	cached_major = 10; cached_minor = darwin - 4; cached_patch = 0;
	return true;
}

static void read_os_version(void)
{
	if (from_sysctl()) return;
	if (from_plist()) return;
	if (from_kernel()) return;
	/* Nothing readable. Answer 10.0.0 rather than invent a version: every
	 * @available for anything later then says "no", which sends callers down
	 * their fallback path -- the safe direction to be wrong in. */
	cached_major = 10; cached_minor = 0; cached_patch = 0;
}

/* pthread_once rather than an "already cached?" test on cached_major: @available is
 * evaluated from arbitrary threads, and a plain guard publishes the major before
 * the minor, so a second thread could read 10.9.5 as 10.0.0 and take the wrong
 * branch. pthread_once is in libSystem on 10.9 and is safe this early. */
static pthread_once_t version_once = PTHREAD_ONCE_INIT;

static void ensure_os_version(void)
{
	pthread_once(&version_once, read_os_version);
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
