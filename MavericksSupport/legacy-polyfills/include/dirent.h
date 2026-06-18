/*
 * Copyright (c) 2019
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

#ifndef _MACPORTS_DIRENT_H_
#define _MACPORTS_DIRENT_H_

/* MP support header */
#include "LegacySupport.h"

/* Do our SDK-related setup */

/* Include the primary system dirent.h */
#include_next <dirent.h>

/* Additional functionality provided by:
 * POSIX.1-2008
 */
#if __DARWIN_C_LEVEL >= 200809L

/* fdopendir */

__MP__BEGIN_DECLS

#ifndef __DARWIN_ALIAS_I
extern DIR *fdopendir(int fd) __DARWIN_ALIAS(fdopendir);
#else
extern DIR *fdopendir(int fd) __DARWIN_ALIAS_I(fdopendir);
#endif

__MP__END_DECLS

/* New signature for scandir and alphasort (optionally) */

/* These functions are non-POSIX, so avoid broken refs. */
#if !defined(_POSIX_C_SOURCE) \
    || (defined(_DARWIN_C_SOURCE) && __MPLS_SDK_MAJOR >= 1050)

/* Dummy wrapper functions without unnecessary casts */

static __inline__ int
__mpls_alphasort(const struct dirent **d1, const struct dirent **d2)
{
  return alphasort(d1, d2);
}

static __inline__ int
__mpls_scandir(const char *dirnam, struct dirent ***namelist,
               int (*selector)(const struct dirent *),
               int (*compar)(const struct dirent **, const struct dirent **))
{
  return scandir(dirnam, namelist, selector, compar);
}

#endif /* (!_POSIX_C_SOURCE || (_DARWIN_C_SOURCE && >10.4)) */

#endif /* __DARWIN_C_LEVEL >= 200809L */

/* Provide a testable condition for the scandir signature issue. */
/* 10.9 already has the modern scandir/alphasort signatures. */
#define _MACPORTS_LEGACY_OLD_SCANDIR 0

#endif /* _MACPORTS_DIRENT_H_ */
