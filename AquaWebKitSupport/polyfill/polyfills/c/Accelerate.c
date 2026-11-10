// Accelerate: vImage entry points modern WebKit calls that 10.9's Accelerate does not export, and the
// ones that reach 10.9 vImage's lookup-table cache.
#include "wk_polyfill.h"

#include <dispatch/dispatch.h>
#include <stddef.h>
#include <stdint.h>
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
    return WK_SYSTEM(vImagePremultiplyData_RGBA8888)(src, dst, flags);
}
WK_POLYFILL_ABSENT("Accelerate", vImage_Error, vImageUnpremultiplyData_BGRA8888,
    (const struct vImage_Buffer *src, const struct vImage_Buffer *dst, vImage_Flags flags))
{
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
    // One copy when the rows are contiguous in both buffers — a full video frame per call rides
    // this, and a single large memcpy reaches memcpy's non-temporal path where a per-row loop
    // re-enters it a thousand times.
    if (s->rowBytes == d->rowBytes && bytes == s->rowBytes)
        memcpy(d->data, s->data, rows * bytes);
    else
        for (unsigned long row = 0; row < rows; ++row)
            memcpy((unsigned char *)d->data + row * d->rowBytes, (const unsigned char *)s->data + row * s->rowBytes, bytes);
    return kvImageNoError;
}

// 10.9's vImage creates the cache its gamma lookup tables live in on first use, inside a dispatch_once,
// but publishes it only after that once returns: a thread that waited on the once, or arrived just after
// it, finds no cache. vImagePiecewiseGamma_Planar16Q12 returns that as an error; converter construction
// ignores it and returns a converter whose vImageConvert_AnyToAny dereferences a NULL table. The entry
// points that reach the cache create it first, on one thread, with a 1x1 vImagePiecewiseGamma_Planar16Q12.
typedef struct vImageConverter *vImageConverterRef;
struct vImage_CGImageFormat;
WK_SYSTEM_FN("Accelerate", vImage_Error, vImagePiecewiseGamma_Planar16Q12,
    (const struct vImage_Buffer *, const struct vImage_Buffer *, const float[3], float, const float[2], int16_t, vImage_Flags));
WK_SYSTEM_FN("Accelerate", vImageConverterRef, vImageConverter_CreateWithCGImageFormat,
    (const struct vImage_CGImageFormat *, const struct vImage_CGImageFormat *, const double *, vImage_Flags, vImage_Error *));
WK_SYSTEM_FN("Accelerate", vImageConverterRef, vImageConverter_CreateWithColorSyncCodeFragment,
    (const void *, const struct vImage_CGImageFormat *, const struct vImage_CGImageFormat *, const double *, vImage_Flags, vImage_Error *));

static void wk_vImageCreateTableCache(void *context)
{
    (void)context;
    int16_t source = 0, destination = 0;
    struct wk_vImage_Buffer from = { &source, 1, 1, sizeof source }, to = { &destination, 1, 1, sizeof destination };
    const float exponential[3] = { 1, 0, 0 }, linear[2] = { 1, 0 };
    WK_SYSTEM(vImagePiecewiseGamma_Planar16Q12)((const struct vImage_Buffer *)&from, (const struct vImage_Buffer *)&to, exponential, 1, linear, 0, 0);
}

static void wk_vImageEnsureTableCache(void)
{
    static dispatch_once_t once;
    dispatch_once_f(&once, NULL, wk_vImageCreateTableCache);
}

WK_POLYFILL_REPLACES("Accelerate", vImage_Error, vImagePiecewiseGamma_Planar16Q12,
    (const struct vImage_Buffer *src, const struct vImage_Buffer *dest, const float exponentialCoeffs[3], float gamma,
     const float linearCoeffs[2], int16_t boundary, vImage_Flags flags))
{
    wk_vImageEnsureTableCache();
    return WK_SYSTEM(vImagePiecewiseGamma_Planar16Q12)(src, dest, exponentialCoeffs, gamma, linearCoeffs, boundary, flags);
}

WK_POLYFILL_REPLACES("Accelerate", vImageConverterRef, vImageConverter_CreateWithCGImageFormat,
    (const struct vImage_CGImageFormat *srcFormat, const struct vImage_CGImageFormat *destFormat, const double *backgroundColor,
     vImage_Flags flags, vImage_Error *error))
{
    wk_vImageEnsureTableCache();
    return WK_SYSTEM(vImageConverter_CreateWithCGImageFormat)(srcFormat, destFormat, backgroundColor, flags, error);
}

WK_POLYFILL_REPLACES("Accelerate", vImageConverterRef, vImageConverter_CreateWithColorSyncCodeFragment,
    (const void *codeFragment, const struct vImage_CGImageFormat *srcFormat, const struct vImage_CGImageFormat *destFormat,
     const double *backgroundColor, vImage_Flags flags, vImage_Error *error))
{
    wk_vImageEnsureTableCache();
    return WK_SYSTEM(vImageConverter_CreateWithColorSyncCodeFragment)(codeFragment, srcFormat, destFormat, backgroundColor, flags, error);
}
