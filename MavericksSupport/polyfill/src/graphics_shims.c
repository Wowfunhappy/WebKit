// CoreGraphics / Accelerate entry points modern WebKit calls that 10.9 names
// differently. Each forwards to the equivalent function 10.9 does ship.
#include <CoreGraphics/CoreGraphics.h>

// CGIOSurfaceContextCreateImageReference (newer name) == CGIOSurfaceContextCreateImage.
extern CGImageRef CGIOSurfaceContextCreateImage(CGContextRef);
CGImageRef CGIOSurfaceContextCreateImageReference(CGContextRef context) {
    return CGIOSurfaceContextCreateImage(context);
}

// vImage's premultiply math touches the three colour bytes and leaves alpha, so it is
// identical for BGRA8888 and RGBA8888; the BGRA-named entry points forward to the RGBA ones.
// We only pass the buffers through, so vImage_Buffer stays opaque -- no Accelerate header.
typedef unsigned long vImage_Flags;
typedef long vImage_Error;
struct vImage_Buffer;
extern vImage_Error vImagePremultiplyData_RGBA8888(const struct vImage_Buffer *, const struct vImage_Buffer *, vImage_Flags);
extern vImage_Error vImageUnpremultiplyData_RGBA8888(const struct vImage_Buffer *, const struct vImage_Buffer *, vImage_Flags);

vImage_Error vImagePremultiplyData_BGRA8888(const struct vImage_Buffer *src, const struct vImage_Buffer *dst, vImage_Flags flags) {
    return vImagePremultiplyData_RGBA8888(src, dst, flags);
}
vImage_Error vImageUnpremultiplyData_BGRA8888(const struct vImage_Buffer *src, const struct vImage_Buffer *dst, vImage_Flags flags) {
    return vImageUnpremultiplyData_RGBA8888(src, dst, flags);
}
