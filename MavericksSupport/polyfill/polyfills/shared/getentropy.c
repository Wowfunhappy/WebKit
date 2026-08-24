
/*
 * Copyright (c) 2021
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

#include "LegacySupport.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/random.h>
#include <errno.h>

static int
_randopen(const char* name)
{
    return open(name, O_RDONLY | O_CLOEXEC);
}

int
getentropy(void* buf, size_t n)
{

    static int fd = -1;
    uint8_t* b    = (uint8_t*)buf;

    /* POSIX/BSD getentropy() rejects requests larger than 256 bytes. */
    if (n > 256) {
        errno = EIO;
        return -1;
    }

    if (fd < 0) {
        fd = _randopen("/dev/urandom");
        if (fd < 0)
            return -1;
    }

    while (n > 0)
    {
        ssize_t m = (read)(fd, b, n);

        if (m < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (m == 0) {
            errno = EIO;
            return -1;
        }
        b += m;
        n -= m;
    }

    return 0;
}

