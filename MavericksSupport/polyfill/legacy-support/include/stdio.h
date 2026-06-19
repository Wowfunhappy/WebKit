/*
 * Copyright (c) 2018 Chris Jones <jonesc@macports.org>
 * Copyright (c) 2018
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

#ifndef _MACPORTS_STDIO_H_
#define _MACPORTS_STDIO_H_

/* MP support header */
#include "LegacySupport.h"

/* Do our SDK-related setup */

/* Work around recent compilers that treat undefineds as errors. */

/* Include the primary system stdio.h */
#include_next <stdio.h>

/* Extend Apple's 10.10+ include of sys/stdio.h to earlier versions. */
#include <sys/stdio.h>

/* Additional functionality provided by:
 * POSIX.1-2008
 */
#if __DARWIN_C_LEVEL >= 200809L

/* dprintf */

/* getline */

/* open_memstream */

__MP__BEGIN_DECLS
FILE *open_memstream(char **ptr, size_t *sizeloc);
__MP__END_DECLS

/* fmemopen */

__MP__BEGIN_DECLS
FILE *fmemopen(void *buf, size_t size, const char *mode);
__MP__END_DECLS

#endif /* __DARWIN_C_LEVEL >= 200809L */

#endif /* _MACPORTS_STDIO_H_ */
