// Accelerate: vImage entry points modern WebKit calls that 10.9's Accelerate does not export.
#include "wk_polyfill.h"

#include <stddef.h>
#include <string.h>

// vImage's premultiply math touches the three colour bytes and leaves alpha, so it is
// identical for BGRA8888 and RGBA8888; the BGRA-named entry points forward to the RGBA ones.
// We only pass the buffers through, so vImage_Buffer stays opaque -- no Accelerate header.
typedef unsigned long vImage_Flags;
typedef long vImage_Error;
struct vImage_Buffer;
enum { kvImageInternalError = -21058 };
WK_SYSTEM_FN("Accelerate", vImage_Error, vImagePremultiplyData_RGBA8888,
    (const struct vImage_Buffer *, const struct vImage_Buffer *, vImage_Flags));
WK_SYSTEM_FN("Accelerate", vImage_Error, vImageUnpremultiplyData_RGBA8888,
    (const struct vImage_Buffer *, const struct vImage_Buffer *, vImage_Flags));

WK_POLYFILL_ABSENT("Accelerate", vImage_Error, vImagePremultiplyData_BGRA8888,
    (const struct vImage_Buffer *src, const struct vImage_Buffer *dst, vImage_Flags flags))
{
    if (!WK_SYSTEM(vImagePremultiplyData_RGBA8888))
        return kvImageInternalError;
    return WK_SYSTEM(vImagePremultiplyData_RGBA8888)(src, dst, flags);
}
WK_POLYFILL_ABSENT("Accelerate", vImage_Error, vImageUnpremultiplyData_BGRA8888,
    (const struct vImage_Buffer *src, const struct vImage_Buffer *dst, vImage_Flags flags))
{
    if (!WK_SYSTEM(vImageUnpremultiplyData_RGBA8888))
        return kvImageInternalError;
    return WK_SYSTEM(vImageUnpremultiplyData_RGBA8888)(src, dst, flags);
}

// vImageCopyBuffer (10.10+) copies the overlapping region of two buffers row by row, honouring each
// buffer's own rowBytes. That needs the field layout, which the ABI has fixed since 10.3.
struct wk_vImage_Buffer { void *data; unsigned long height; unsigned long width; size_t rowBytes; };
enum { kvImageNoError = 0 };
WK_POLYFILL_ABSENT("Accelerate", vImage_Error, vImageCopyBuffer,
    (const struct vImage_Buffer *src, const struct vImage_Buffer *dst, size_t pixelSize, vImage_Flags flags))
{
    const struct wk_vImage_Buffer *s = (const struct wk_vImage_Buffer *)src;
    const struct wk_vImage_Buffer *d = (const struct wk_vImage_Buffer *)dst;
    (void)flags;
    if (!s || !d || !s->data || !d->data)
        return kvImageInternalError;
    unsigned long rows = s->height < d->height ? s->height : d->height;
    unsigned long cols = s->width < d->width ? s->width : d->width;
    size_t bytes = (size_t)cols * pixelSize;
    for (unsigned long row = 0; row < rows; ++row)
        memcpy((unsigned char *)d->data + row * d->rowBytes, (const unsigned char *)s->data + row * s->rowBytes, bytes);
    return kvImageNoError;
}
