/*
 * Copyright (c) 2018 Chris Jones <jonesc@macports.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#ifndef _MACPORTS_SYS_STAT_H_
#define _MACPORTS_SYS_STAT_H_

/* MP support header */
#include "LegacySupport.h"

/* Do our SDK-related setup */

/* Include the primary system sys/stat.h */
#include_next <sys/stat.h>

/* Set up condition for having "struct stat64" defined by the SDK. */
#if ((!defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)) \
     && (!defined(__DARWIN_ONLY_64_BIT_INO_T) || !__DARWIN_ONLY_64_BIT_INO_T))
#define __MPLS_HAVE_STAT64 1
#else
#define __MPLS_HAVE_STAT64 0
#endif

#if __DARWIN_C_LEVEL >= 200809L

#define UTIME_NOW -1
#define UTIME_OMIT -2

__MP__BEGIN_DECLS

extern int futimens(int fd, const struct timespec _times_in[2]);
extern int utimensat(int fd, const char *path,
                     const struct timespec _times_in[2], int flags);

__MP__END_DECLS

__MP__BEGIN_DECLS

extern int fchmodat(int fd, const char *path, mode_t mode, int flag);
extern int fstatat(int fd, const char *path,
                   struct stat *buf, int flag) __DARWIN_INODE64(fstatat);

/*
 * Some versions of this header have included a prototype for fstatat64().
 * This is inappropriate, since no SDK has ever directly provided that
 * function.  The intent is that any use of 64-bit-inodes should be
 * via symbol versioning, though many versions of the system library
 * have made fstatat64 available as a convenience alias for fstatat$INODE64.
 *
 * For consistency, we don't provide fstatat64() here.  All our own
 * internal references provide their own prototypes.
 */

extern int mkdirat(int fd, const char *path, mode_t mode);

__MP__END_DECLS

#endif /* __DARWIN_C_LEVEL >= 200809L */

#if !defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)

#endif /* (!_POSIX_C_SOURCE || _DARWIN_C_SOURCE) */

#endif /* _MACPORTS_SYS_STAT_H_ */
