/*
 * 10.9 backport: force-included (via this directory's CMakeLists.txt, for
 * C/C++/ObjC/ObjC++ — NOT ASM) into every libwebrtc translation unit.
 *
 * libwebrtc (and its bundled libvpx/libyuv/abseil/boringssl) uses POSIX APIs
 * that macOS only gained after 10.9:
 *   - the POSIX monotonic clock (clockid_t / CLOCK_* / clock_gettime), 10.12+
 *   - the *at() file syscalls (openat/fstatat/AT_FDCWD), 10.10+
 * The toolchain's macports-legacy-support library provides the runtime
 * implementations; this header just declares them so the sources compile.
 *
 * This is force-included for libwebrtc specifically because the WebKit-wide
 * 10.9 compat header (MavericksSupport/compat.h) is NOT applied to the
 * Source/ThirdParty/libwebrtc subtree (it carries WebKit-specific C++/ObjC
 * shims that would conflict with third-party C/C++ code).
 */

#ifndef WEBKIT_MAC109_COMPAT_H
#define WEBKIT_MAC109_COMPAT_H

#include <Availability.h>

/* ===== POSIX monotonic clock (macOS 10.12+) ===== */
#ifndef CLOCK_REALTIME
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
#endif /* CLOCK_REALTIME */

/* ===== *at() functions (macOS 10.10+) ===== */
#ifndef AT_FDCWD
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
#endif /* AT_FDCWD */

#endif /* WEBKIT_MAC109_COMPAT_H */
