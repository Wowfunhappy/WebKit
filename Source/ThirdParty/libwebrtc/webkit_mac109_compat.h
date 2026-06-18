/*
 * 10.9 backport: force-included (via this directory's CMakeLists.txt, for
 * C/C++/ObjC/ObjC++ — NOT ASM) into every libwebrtc translation unit.
 *
 * MAVERICKS_BACKPORT: libwebrtc (and its bundled libvpx/libyuv/abseil/boringssl)
 * uses POSIX APIs that macOS only gained after 10.9:
 *   - the POSIX monotonic clock (clockid_t / CLOCK_* / clock_gettime), 10.12+
 *   - the *at() file syscalls (openat/fstatat/AT_FDCWD), 10.10+
 * The vendored MavericksSupport polyfill archive provides the runtime
 * implementations; this header only DECLARES them, and only when building against
 * an SDK that lacks the declarations. The blocks below are gated on the SDK version
 * (__MAC_OS_X_VERSION_MAX_ALLOWED), not the deployment target: a modern SDK declares
 * these itself, and re-declaring them would collide with the SDK's own types/enums.
 *
 * Force-included for libwebrtc specifically (its own CMakeLists.txt) because the
 * WebKit-wide compat machinery is not applied to the third-party subtree.
 */

#ifndef WEBKIT_MAC109_COMPAT_H
#define WEBKIT_MAC109_COMPAT_H

#include <Availability.h>

/* ===== POSIX monotonic clock (macOS 10.12+) ===== */
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101200
#include <time.h>
typedef int clockid_t;
enum {
    _CLOCK_REALTIME = 0,
    _CLOCK_MONOTONIC = 6,
    _CLOCK_MONOTONIC_RAW = 4,
    _CLOCK_MONOTONIC_RAW_APPROX = 5,
    _CLOCK_UPTIME_RAW = 8,
    _CLOCK_UPTIME_RAW_APPROX = 9,
    _CLOCK_PROCESS_CPUTIME_ID = 12,
    _CLOCK_THREAD_CPUTIME_ID = 16
};
#define CLOCK_REALTIME _CLOCK_REALTIME
#define CLOCK_MONOTONIC _CLOCK_MONOTONIC
#define CLOCK_MONOTONIC_RAW _CLOCK_MONOTONIC_RAW
#define CLOCK_MONOTONIC_RAW_APPROX _CLOCK_MONOTONIC_RAW_APPROX
#define CLOCK_UPTIME_RAW _CLOCK_UPTIME_RAW
#define CLOCK_UPTIME_RAW_APPROX _CLOCK_UPTIME_RAW_APPROX
#define CLOCK_PROCESS_CPUTIME_ID _CLOCK_PROCESS_CPUTIME_ID
#define CLOCK_THREAD_CPUTIME_ID _CLOCK_THREAD_CPUTIME_ID
__BEGIN_DECLS
extern int clock_gettime(clockid_t, struct timespec *);
extern int clock_getres(clockid_t, struct timespec *);
__END_DECLS
#endif /* __MAC_OS_X_VERSION_MAX_ALLOWED < 101200 */

/* ===== *at() functions (macOS 10.10+) ===== */
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101000
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#define AT_FDCWD -2
#define AT_SYMLINK_NOFOLLOW 0x0020
#define AT_REMOVEDIR 0x0080
__BEGIN_DECLS
extern int openat(int, const char *, int, ...);
extern int fstatat(int, const char *, struct stat *, int);
extern int unlinkat(int, const char *, int);
__END_DECLS
#endif /* __MAC_OS_X_VERSION_MAX_ALLOWED < 101000 */

/* ===== getentropy (macOS 10.12+) ===== */
/* boringssl's crypto/rand/getentropy.cc skips <sys/random.h> when the deployment target is
   < 10.12 and expects this force-included header to declare getentropy. Gate on the SAME
   condition (MIN_REQUIRED, the deployment target) so there is no clash with <sys/random.h>
   when it IS included. The runtime implementation, absent on 10.9, comes from the vendored
   MavericksSupport polyfill archive. */
#if __MAC_OS_X_VERSION_MIN_REQUIRED < 101200
#include <sys/cdefs.h>
#include <stddef.h>
__BEGIN_DECLS
extern int getentropy(void *buffer, size_t size);
__END_DECLS
#endif /* __MAC_OS_X_VERSION_MIN_REQUIRED < 101200 */

#endif /* WEBKIT_MAC109_COMPAT_H */
