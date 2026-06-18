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

/* This (conditionally) contains miscellaneous global utility features. */

/* MP support header */
#include "LegacySupport.h"

#include <dlfcn.h>
#include <stdlib.h>

#include "compiler.h"

/*
 * Obtain the address of an OS function, with an optional suffix
 *
 * This provides both the variable and the code to obtain a pointer to
 * a given OS function via dlsym(), with an optional variant-related
 * suffix (e.g. '$UNIX2003') to use in the lookup.
 *
 * Args are:
 *   name: the standard function name
 *   suffix: the optional suffix
 */
#define GET_OS_ALT_FUNC(name, suffix) \
  static __typeof__(name) *os_##name = NULL; \
  \
  if (MPLS_SLOWPATH(!os_##name)) { \
    if (!(os_##name = dlsym(RTLD_NEXT, #name #suffix))) abort(); \
  }

/* Obtain the address of an OS function, without an optional suffix */
#define GET_OS_FUNC(name) GET_OS_ALT_FUNC(name,)
