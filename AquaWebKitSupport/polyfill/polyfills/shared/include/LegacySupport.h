/*
 * Support header for the shared/ libc gap-fills.  This library targets exactly
 * one OS (OS X 10.9 Mavericks), so the SDK and architecture flags the gap-fills
 * test are constants, which is all this header provides.
 *
 * Copyright (c) 2018 Chris Jones <jonesc@macports.org>
 * Copyright (c) 2019 Michael Dickens <michaelld@macports.org>
 * Copyright (c) 2026 Wowfunhappy
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

#ifndef _AQUAWEBKIT_LEGACY_SUPPORT_H_
#define _AQUAWEBKIT_LEGACY_SUPPORT_H_

/* C++ declaration wrappers used by the wrapper headers. */
#if defined(__cplusplus)
#define __MP__BEGIN_DECLS extern "C" {
#define __MP__END_DECLS   }
#else
#define __MP__BEGIN_DECLS
#define __MP__END_DECLS
#endif

/*
 * Fixed SDK: OS X 10.9.  A handful of wrapper conditions combine a version test
 * with a POSIX-level test; this gives them the 10.9 result.
 */
#define __MPLS_SDK_MAJOR 1090

/* 64-bit (x86_64) vs 32-bit (i386) -- the only architecture split on 10.9. */
#if defined(__LP64__) && __LP64__
#define __MPLS_64BIT 1
#else
#define __MPLS_64BIT 0
#endif

#endif /* _AQUAWEBKIT_LEGACY_SUPPORT_H_ */
