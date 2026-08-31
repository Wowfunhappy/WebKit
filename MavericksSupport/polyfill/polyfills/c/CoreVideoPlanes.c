// CoreVideo plane accessors. Modern CoreVideo answers the plane-0 accessors on a NON-planar pixel
// buffer with the buffer's own base address, bytes-per-row, width and height; 10.9 answers NULL/0
// for any plane index on a non-planar buffer. WebCore reads BGRA (non-planar) buffers through the
// plane-0 accessors (CVPixelBufferGetSpanOfPlane in CoreVideoSoftLink.h, SharedVideoFrameInfo's
// writePixelBuffer/copyToCVPixelBufferPlane), so under the 10.9 answers every such read sees an
// empty plane: GPU-to-web video-frame transfers serialize as blank frames and the receiving pool
// buffers keep their recycled contents. These replacements serve the modern answers.
#include "wk_polyfill.h"

#include <CoreVideo/CoreVideo.h>

WK_POLYFILL_REPLACES("CoreVideo", void *, CVPixelBufferGetBaseAddressOfPlane, (CVPixelBufferRef pixelBuffer, size_t planeIndex))
{
    if (pixelBuffer && !planeIndex && !CVPixelBufferIsPlanar(pixelBuffer))
        return CVPixelBufferGetBaseAddress(pixelBuffer);
    return WK_ORIGINAL(CVPixelBufferGetBaseAddressOfPlane)(pixelBuffer, planeIndex);
}

WK_POLYFILL_REPLACES("CoreVideo", size_t, CVPixelBufferGetBytesPerRowOfPlane, (CVPixelBufferRef pixelBuffer, size_t planeIndex))
{
    if (pixelBuffer && !planeIndex && !CVPixelBufferIsPlanar(pixelBuffer))
        return CVPixelBufferGetBytesPerRow(pixelBuffer);
    return WK_ORIGINAL(CVPixelBufferGetBytesPerRowOfPlane)(pixelBuffer, planeIndex);
}

WK_POLYFILL_REPLACES("CoreVideo", size_t, CVPixelBufferGetWidthOfPlane, (CVPixelBufferRef pixelBuffer, size_t planeIndex))
{
    if (pixelBuffer && !planeIndex && !CVPixelBufferIsPlanar(pixelBuffer))
        return CVPixelBufferGetWidth(pixelBuffer);
    return WK_ORIGINAL(CVPixelBufferGetWidthOfPlane)(pixelBuffer, planeIndex);
}

WK_POLYFILL_REPLACES("CoreVideo", size_t, CVPixelBufferGetHeightOfPlane, (CVPixelBufferRef pixelBuffer, size_t planeIndex))
{
    if (pixelBuffer && !planeIndex && !CVPixelBufferIsPlanar(pixelBuffer))
        return CVPixelBufferGetHeight(pixelBuffer);
    return WK_ORIGINAL(CVPixelBufferGetHeightOfPlane)(pixelBuffer, planeIndex);
}
