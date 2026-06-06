/* Compatibility shim for macOS 10.9 - provides missing POSIX functions */
#ifndef _COMPAT_H
#define _COMPAT_H

/* Skip for assembly files */
#ifndef __ASSEMBLER__

#include <sys/cdefs.h>
#include <sys/types.h>

/* mach_vm_offset_t / MACH_VM_MAX_ADDRESS live in <mach/vm_types.h> on 10.9 but
 * aren't pulled in transitively by <mach/vm_param.h> where WTF expands
 * OS_CONSTANT(EFFECTIVE_ADDRESS_WIDTH) (Packed.h, CompactPointerTuple.h,
 * Signals.cpp, WTFConfig.cpp). Force-include so the typedef is always visible. */
#include <mach/vm_types.h>

/* ===== clock_gettime (macOS 10.12+) ===== */
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
#endif

/* ===== *at() functions (macOS 10.10+) ===== */
#ifndef AT_FDCWD
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#define AT_FDCWD -2
#define AT_SYMLINK_NOFOLLOW 0x0020
#define AT_REMOVEDIR 0x0080
#define AT_SYMLINK_FOLLOW 0x0040
#define AT_EACCESS 0x0010
__BEGIN_DECLS
extern int openat(int, const char *, int, ...);
extern int unlinkat(int, const char *, int);
extern int renameat(int, const char *, int, const char *);
extern int fchmodat(int, const char *, mode_t, int);
extern int fchownat(int, const char *, uid_t, gid_t, int);
extern int linkat(int, const char *, int, const char *, int);
extern int symlinkat(const char *, int, const char *);
extern int mkdirat(int, const char *, mode_t);
extern ssize_t readlinkat(int, const char *, char *, size_t);
extern int faccessat(int, const char *, int, int);
extern DIR *fdopendir(int);
extern int utimensat(int, const char *, const struct timespec[2], int);
__END_DECLS
#endif

/* ===== utimensat constants ===== */
#ifndef UTIME_NOW
#define UTIME_NOW  -1
#define UTIME_OMIT -2
#endif

/* ===== aligned_alloc (C11; macOS 10.15+) =====
 * Absent on 10.9. bmalloc/WTF call ::aligned_alloc; provide a static-inline
 * shim over posix_memalign (present since 10.6) so the upstream call sites
 * compile unchanged. static inline => no library symbol / ODR concerns. */
#include <stdlib.h>
static __inline__ void *aligned_alloc(size_t __alignment, size_t __size) {
    void *__p = 0;
    if (posix_memalign(&__p, __alignment, __size) != 0)
        return 0;
    return __p;
}

/* ===== VM_FLAGS_PERMANENT (mach; macOS 10.15+) =====
 * WTFConfig's makePagesFreezable() ORs this into mach_vm_map flags to make the
 * config page kernel-immutable. The 10.9 kernel has no such flag; define it as
 * 0 so the call degrades to an ordinary fixed/overwrite mapping rather than the
 * kernel rejecting an unknown flag. (Loses only a defense-in-depth hardening.) */
#ifndef VM_FLAGS_PERMANENT
#define VM_FLAGS_PERMANENT 0
#endif

#endif /* !__ASSEMBLER__ */
#endif /* _COMPAT_H */
