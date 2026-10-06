/*
 * open_memstream (POSIX.1-2008; macOS 10.13+) over funopen(), which 10.9 has.
 *
 * The stream writes into a buffer it grows and owns until close, keeps a NUL one byte past the
 * highest offset written, and republishes the caller's pointer and size as it goes. Seeking past
 * the end leaves a zero-filled gap; the reported size is the highest offset written, not the
 * seek position.
 */

#include "LegacySupport.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct wk_memstream {
    char **bufp;
    size_t *sizep;
    char *buf;
    size_t len;   /* highest offset written, not counting the NUL */
    size_t cap;   /* bytes allocated, including room for that NUL */
    size_t pos;
};

static void wk_ms_publish(struct wk_memstream *m)
{
    *m->bufp = m->buf;
    *m->sizep = m->len;
}

/* need counts the NUL. */
static int wk_ms_grow(struct wk_memstream *m, size_t need)
{
    size_t cap = m->cap ? m->cap : 128;
    char *p;

    while (cap < need) {
        if (cap > (size_t)-1 / 2) {
            errno = ENOMEM;
            return -1;
        }
        cap *= 2;
    }
    if (cap == m->cap)
        return 0;
    if (!(p = realloc(m->buf, cap))) {
        errno = ENOMEM;
        return -1;
    }
    memset(p + m->cap, 0, cap - m->cap);
    m->buf = p;
    m->cap = cap;
    return 0;
}

static int wk_ms_write(void *cookie, const char *data, int n)
{
    struct wk_memstream *m = cookie;

    if (n < 0) {
        errno = EINVAL;
        return -1;
    }
    if (n == 0)
        return 0;
    if (m->pos > (size_t)-1 - (size_t)n - 1) {
        errno = ENOMEM;
        return -1;
    }
    if (wk_ms_grow(m, m->pos + (size_t)n + 1) < 0)
        return -1;
    memcpy(m->buf + m->pos, data, (size_t)n);
    m->pos += (size_t)n;
    if (m->pos > m->len) {
        m->len = m->pos;
        m->buf[m->len] = '\0';
    }
    wk_ms_publish(m);
    return n;
}

static fpos_t wk_ms_seek(void *cookie, fpos_t off, int whence)
{
    struct wk_memstream *m = cookie;
    fpos_t base;

    switch (whence) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = (fpos_t)m->pos; break;
    case SEEK_END: base = (fpos_t)m->len; break;
    default: errno = EINVAL; return -1;
    }
    if (off > 0 && base > INT64_MAX - off) {
        errno = EOVERFLOW;
        return -1;
    }
    base += off;
    if (base < 0) {
        errno = EINVAL;
        return -1;
    }
    /* The gap a forward seek leaves is zero-filled by the growth in wk_ms_write. */
    m->pos = (size_t)base;
    return base;
}

static int wk_ms_close(void *cookie)
{
    struct wk_memstream *m = cookie;

    m->buf[m->len] = '\0';
    wk_ms_publish(m);
    free(m);
    return 0;
}

FILE *open_memstream(char **bufp, size_t *sizep)
{
    struct wk_memstream *m;
    FILE *f;

    if (!bufp || !sizep) {
        errno = EINVAL;
        return NULL;
    }
    if (!(m = calloc(1, sizeof(*m))))
        return NULL;
    m->bufp = bufp;
    m->sizep = sizep;
    if (wk_ms_grow(m, 1) < 0) {
        free(m);
        return NULL;
    }
    m->buf[0] = '\0';
    wk_ms_publish(m);
    if (!(f = funopen(m, NULL, wk_ms_write, wk_ms_seek, wk_ms_close))) {
        free(m->buf);
        free(m);
        return NULL;
    }
    return f;
}
