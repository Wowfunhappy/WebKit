/*
 * Copyright (c) 2025
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

/* sysconf wrap */

#include <sys/types.h>
#include <sys/sysctl.h>

#include <unistd.h>
#include <stdlib.h>
#include <stddef.h>

#include "util.h"

/*
 * Emulate several commonly used but missing (or broken) selectors from
 * sysconf() on various OS versions.
 */

long sysconf(int name) {
    GET_OS_FUNC(sysconf)

    if ( name == _SC_PHYS_PAGES ) {

        /* the number of pages is the total memory / pagesize */
        uint64_t mem_size;
        size_t len = sizeof(mem_size);
        int ms_mib[] = {CTL_HW, HW_MEMSIZE};
        size_t ms_miblen = sizeof(ms_mib) / sizeof(ms_mib[0]);
        int pagesize = getpagesize();

        if (sysctl(ms_mib, ms_miblen, &mem_size, &len, NULL, 0)) {
          return -1;
        }

        /*
         * Note that the 32-bit version of this function is inherently
         * invalid in any system with >=1TB of RAM.
         * Apple's 32-bit implementation is invalid in any system with
         * >=2GB of RAM, which is why we override any existing Apple
         * implementation in all 32-bit builds.
         */
        return (long)(mem_size/pagesize);

    }

    /* for any other values of "name", call the real sysconf() */
    return (*os_sysconf)(name);
}

/* compatibility function so code does not have to be recompiled */
long macports_legacy_sysconf(int name) { return sysconf(name); }

