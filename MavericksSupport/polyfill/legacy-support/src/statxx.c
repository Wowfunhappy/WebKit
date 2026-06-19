/*
 * Copyright (c) 2025 Frederick H. G. Wright II <fw@fwright.net>
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

/* MP support header */
#include "LegacySupport.h"

/* Common setup for all versions of *stat*() calls provided here */

/*
 * Cause our own refs to always use the 32-bit-inode variants.  This
 * wouldn't work on arm64, but is known to work on all platforms where
 * our implementations are needed.  It means that the referenced function
 * names are always the "unadorned" versions, except when we explicitly
 * add a suffix.
 */

#define _DARWIN_NO_64_BIT_INODE 1

#include <stddef.h>
#include <stdlib.h>

#include <sys/stat.h>

#include "util.h"

/* Make sure we have "struct stat64" */
#if !__MPLS_HAVE_STAT64
struct stat64 __DARWIN_STRUCT_STAT64;
#endif /* !__MPLS_HAVE_STAT64 */

/*
 * Provide "at" versions of the *stat*() calls, on OS versions that don't
 * provide them natively.
 */

int stat$INODE64(const char *__restrict path, struct stat64 *buf);
int lstat$INODE64(const char *__restrict path, struct stat64 *buf);

#include "atcalls.h"

int fstatat(int fd, const char *__restrict path, struct stat *buf, int flag)
{
    ERR_ON(EINVAL, flag & ~AT_SYMLINK_NOFOLLOW);
    if (flag & AT_SYMLINK_NOFOLLOW) {
        return ATCALL(fd, path, lstat(path, buf));
    } else {
        return ATCALL(fd, path, stat(path, buf));
    }
}

int fstatat$INODE64(int fd, const char *__restrict path, struct stat64 *buf,
                    int flag)
{
    ERR_ON(EINVAL, flag & ~AT_SYMLINK_NOFOLLOW);
    if (flag & AT_SYMLINK_NOFOLLOW) {
        return ATCALL(fd, path, lstat$INODE64(path, buf));
    } else {
        return ATCALL(fd, path, stat$INODE64(path, buf));
    }
}

#if __MPLS_HAVE_STAT64

/*
 * The fstatat64 function is not expected to be accessed directly (though many
 * system libraries provide it as a convenience synonym for fstatat$INODE64),
 * so no SDK provides a prototype for it.  We do so here.
 */

extern int fstatat64(int fd, const char *__restrict path,
                     struct stat64 *buf, int flag);

int fstatat64(int fd, const char *path, struct stat64 *buf, int flag)
{
    ERR_ON(EINVAL, flag & ~AT_SYMLINK_NOFOLLOW);
    if (flag & AT_SYMLINK_NOFOLLOW) {
        return ATCALL(fd, path, lstat64(path, buf));
    } else {
        return ATCALL(fd, path, stat64(path, buf));
    }
}

#endif /* __MPLS_HAVE_STAT64 */

