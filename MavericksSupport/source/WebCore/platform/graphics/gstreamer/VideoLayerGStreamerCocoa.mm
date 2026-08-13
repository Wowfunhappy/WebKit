/*
 * Copyright (C) 2026 Igalia S.L
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

// MAVERICKS_BACKPORT: accelerated <video> compositing for the Cocoa+GStreamer hybrid — see
// VideoLayerGStreamerCocoa.h for the design rationale.

#include "config.h"
#include "VideoLayerGStreamerCocoa.h"

#if ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA) && !USE(COORDINATED_GRAPHICS)

#include "FloatRect.h"
#include "GStreamerCommon.h"
#include "GStreamerVideoFrameConverter.h"
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>

#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// A small round-robin pool of YUV IOSurfaces attached to the video layer. Decoded 4:2:0 frames are
// copied into the next surface (a plain plane copy — the colorspace conversion happens on the GPU
// when CoreAnimation composites the surface), which is then set as the layer's contents. Three
// surfaces ensure the compositor is never reading the surface currently being written, and that
// the contents pointer changes on every frame (CoreAnimation detects new contents by identity).
@interface WebKitGStreamerVideoSurfacePool : NSObject {
@public
    RetainPtr<IOSurfaceRef> surfaces[3];
    unsigned nextSurface;
    size_t width;
    size_t height;
    GstVideoColorMatrix matrix;
    GstVideoColorRange range;
}
@end

@implementation WebKitGStreamerVideoSurfacePool
@end

namespace WebCore {

RetainPtr<CALayer> createGStreamerVideoLayer()
{
    ASSERT(isMainThread());
    auto layer = adoptNS([[CALayer alloc] init]);
    // Frames are stretched to the layer bounds; RenderLayerBacking sizes the contents layer to the
    // element's video box, which already has the frame's aspect ratio.
    [layer setContentsGravity:kCAGravityResize];
    return layer;
}

static void releaseMappedVideoFrame(void* info, const void*, size_t)
{
    delete static_cast<GstMappedFrame*>(info);
}

static WebKitGStreamerVideoSurfacePool* videoSurfacePoolForLayer(CALayer* layer)
{
    static char poolKey;
    WebKitGStreamerVideoSurfacePool* pool = objc_getAssociatedObject(layer, &poolKey);
    if (!pool) {
        // No autorelease anywhere on this path: it runs on the GStreamer streaming thread, which
        // has no autorelease pool, so any stray +1 would pin the pool (and its surfaces) past
        // layer teardown until thread exit. That makes NONATOMIC load-bearing, not a style choice:
        // the atomic RETAIN policy's getter returns retained+autoreleased (a per-frame leak here),
        // while the nonatomic getter returns the bare pointer. Nonatomic is safe: the association
        // is set once, never replaced, and only touched under the sink's serialized rendering.
        // The association holds the owning reference.
        auto newPool = adoptNS([[WebKitGStreamerVideoSurfacePool alloc] init]);
        objc_setAssociatedObject(layer, &poolKey, newPool.get(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pool = newPool.get();
    }
    return pool;
}

static RetainPtr<IOSurfaceRef> createYUVVideoSurface(size_t width, size_t height, GstVideoColorMatrix matrix, GstVideoColorRange range)
{
    // NV12 biplanar layout; '420f' for full-range streams, '420v' otherwise.
    uint32_t pixelFormat = range == GST_VIDEO_COLOR_RANGE_0_255 ? 0x34323066 : 0x34323076;
    size_t chromaWidth = (width + 1) / 2;
    size_t chromaHeight = (height + 1) / 2;
    NSDictionary* properties = @{
        (__bridge NSString*)kIOSurfaceWidth: @(width),
        (__bridge NSString*)kIOSurfaceHeight: @(height),
        (__bridge NSString*)kIOSurfacePixelFormat: @(pixelFormat),
        (__bridge NSString*)kIOSurfacePlaneInfo: @[
            @{ (__bridge NSString*)kIOSurfacePlaneWidth: @(width),
               (__bridge NSString*)kIOSurfacePlaneHeight: @(height),
               (__bridge NSString*)kIOSurfacePlaneBytesPerElement: @1 },
            @{ (__bridge NSString*)kIOSurfacePlaneWidth: @(chromaWidth),
               (__bridge NSString*)kIOSurfacePlaneHeight: @(chromaHeight),
               (__bridge NSString*)kIOSurfacePlaneBytesPerElement: @2 },
        ],
    };
    auto surface = adoptCF(IOSurfaceCreate((__bridge CFDictionaryRef)properties));
    if (!surface)
        return nullptr;

    // CoreAnimation defaults to BT.601 for 4:2:0 surfaces but honors this property (verified on
    // 10.9); without it HD (BT.709) content composites with slightly shifted colors. Only the two
    // matrices 10.9 knows are named here — BT.2020 streams never reach this function (the caller
    // routes them to the converter fallback, since 10.9 predates the ITU_R_2020 constant).
    IOSurfaceSetValue(surface.get(), CFSTR("IOSurfaceYCbCrMatrix"),
        matrix == GST_VIDEO_COLOR_MATRIX_BT709 ? CFSTR("ITU_R_709_2") : CFSTR("ITU_R_601_4"));
    return surface;
}

// Copy a mapped I420 or NV12 frame into an NV12 IOSurface, honoring both sides' strides.
// (I420's separate U and V planes are interleaved into the surface's CbCr plane.)
static bool copyYUVFrameToSurface(GstMappedFrame& frame, IOSurfaceRef surface)
{
    size_t width = frame.width();
    size_t height = frame.height();
    size_t chromaWidth = (width + 1) / 2;
    size_t chromaHeight = (height + 1) / 2;

    if (IOSurfaceLock(surface, 0, nullptr) != kIOReturnSuccess)
        return false;

    uint8_t* destY = static_cast<uint8_t*>(IOSurfaceGetBaseAddressOfPlane(surface, 0));
    size_t destStrideY = IOSurfaceGetBytesPerRowOfPlane(surface, 0);
    uint8_t* destUV = static_cast<uint8_t*>(IOSurfaceGetBaseAddressOfPlane(surface, 1));
    size_t destStrideUV = IOSurfaceGetBytesPerRowOfPlane(surface, 1);

    auto sourceY = frame.planeData(0);
    size_t sourceStrideY = frame.planeStride(0);
    for (size_t row = 0; row < height; row++)
        memcpy(destY + row * destStrideY, sourceY.data() + row * sourceStrideY, width);

    if (frame.format() == GST_VIDEO_FORMAT_NV12) {
        auto sourceUV = frame.planeData(1);
        size_t sourceStrideUV = frame.planeStride(1);
        for (size_t row = 0; row < chromaHeight; row++)
            memcpy(destUV + row * destStrideUV, sourceUV.data() + row * sourceStrideUV, chromaWidth * 2);
    } else {
        ASSERT(frame.format() == GST_VIDEO_FORMAT_I420);
        auto sourceU = frame.planeData(1);
        auto sourceV = frame.planeData(2);
        size_t sourceStrideU = frame.planeStride(1);
        size_t sourceStrideV = frame.planeStride(2);
        for (size_t row = 0; row < chromaHeight; row++) {
            const uint8_t* u = sourceU.data() + row * sourceStrideU;
            const uint8_t* v = sourceV.data() + row * sourceStrideV;
            uint8_t* destination = destUV + row * destStrideUV;
            for (size_t i = 0; i < chromaWidth; i++) {
                destination[2 * i] = u[i];
                destination[2 * i + 1] = v[i];
            }
        }
    }

    IOSurfaceUnlock(surface, 0, nullptr);
    return true;
}

// GPU-composited path for the decoders' native 4:2:0 formats: copy the planes into a pooled YUV
// IOSurface and hand it to CoreAnimation, which performs the YUV->RGB conversion when compositing.
// Returns false if the frame can't take this path (so the caller can fall back).
static bool setGStreamerVideoLayerContentsYUV(CALayer* layer, GstMappedFrame& frame)
{
    size_t width = frame.width();
    size_t height = frame.height();
    if (!width || !height)
        return false;

    auto* info = frame.info();
    GstVideoColorMatrix matrix = GST_VIDEO_INFO_COLORIMETRY(info).matrix;
    GstVideoColorRange range = GST_VIDEO_INFO_COLORIMETRY(info).range;

    // 10.9 CoreAnimation predates the BT.2020 YCbCr matrix name, so such streams would silently
    // composite with BT.601 math. Take the converter fallback instead (videoconvert applies the
    // right colorimetry when producing BGRA).
    if (matrix == GST_VIDEO_COLOR_MATRIX_BT2020)
        return false;

    WebKitGStreamerVideoSurfacePool* pool = videoSurfacePoolForLayer(layer);
    if (pool->width != width || pool->height != height || pool->matrix != matrix || pool->range != range || !pool->surfaces[0]) {
        for (auto& surface : pool->surfaces) {
            surface = createYUVVideoSurface(width, height, matrix, range);
            if (!surface)
                return false;
        }
        pool->width = width;
        pool->height = height;
        pool->matrix = matrix;
        pool->range = range;
        pool->nextSurface = 0;
    }

    // Prefer a surface the render server isn't currently texturing from — writing into a displayed
    // surface tears. If all three are in use (commits lagging frame delivery), reuse the oldest;
    // that bounds the pool while degrading to at worst a torn frame under overload.
    IOSurfaceRef surface = nullptr;
    for (unsigned i = 0; i < 3; i++) {
        IOSurfaceRef candidate = pool->surfaces[(pool->nextSurface + i) % 3].get();
        if (!IOSurfaceIsInUse(candidate)) {
            surface = candidate;
            pool->nextSurface = (pool->nextSurface + i + 1) % 3;
            break;
        }
    }
    if (!surface) {
        surface = pool->surfaces[pool->nextSurface].get();
        pool->nextSurface = (pool->nextSurface + 1) % 3;
    }

    if (!copyYUVFrameToSurface(frame, surface))
        return false;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer setContents:(__bridge id)surface];
    [CATransaction commit];
    return true;
}

// Draw the decoded frame through its source orientation into a bitmap sized to the oriented
// (display) dimensions, so the resulting image is the frame the compositor should show and the layer
// carries no geometry transform. The transform sequence mirrors
// GraphicsContextCG::drawNativeImageInternal so the composited frame matches the software
// drawVideoFrame() path pixel-for-pixel.
static RetainPtr<CGImageRef> createOrientedImage(CGImageRef source, ImageOrientation orientation, size_t storedWidth, size_t storedHeight, CGColorSpaceRef colorSpace)
{
    // 90/270-degree rotations swap width and height (matches naturalSize()'s transposedSize()).
    size_t displayWidth = orientation.usesWidthAsHeight() ? storedHeight : storedWidth;
    size_t displayHeight = orientation.usesWidthAsHeight() ? storedWidth : storedHeight;

    CGBitmapInfo bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | kCGImageAlphaNoneSkipFirst;
    auto context = adoptCF(CGBitmapContextCreate(nullptr, displayWidth, displayHeight, 8, 0, colorSpace, bitmapInfo));
    if (!context)
        return nullptr;

    // ImageOrientation::transformFromDefault and the draw sequence below are defined against a
    // top-left (y-down) coordinate space, matching the GraphicsContext the software drawVideoFrame()
    // path draws into; a CGBitmapContext is bottom-left (y-up). Flip once up front so the rotation is
    // applied with the same handedness (otherwise 90/270 come out rotated the wrong way).
    CGContextTranslateCTM(context.get(), 0, displayHeight);
    CGContextScaleCTM(context.get(), 1, -1);

    // From here this mirrors GraphicsContextCG::drawNativeImageInternal exactly, so the composited
    // frame matches the software path pixel-for-pixel.
    FloatRect destRect(0, 0, displayWidth, displayHeight);
    CGContextConcatCTM(context.get(), orientation.transformFromDefault(destRect.size()));
    // The destination rect was given the oriented dimensions above; transformFromDefault expects the
    // pre-transpose (stored) rect for a rotation, so reverse the swap here.
    if (orientation.usesWidthAsHeight())
        destRect = destRect.transposedRect();
    // Flip back to y-up for the image draw (CGContextDrawImage renders upright in a y-up frame).
    CGContextTranslateCTM(context.get(), 0, destRect.height());
    CGContextScaleCTM(context.get(), 1, -1);
    CGContextDrawImage(context.get(), destRect, source);
    return adoptCF(CGBitmapContextCreateImage(context.get()));
}

void setGStreamerVideoLayerContents(CALayer* layer, const GRefPtr<GstSample>& sample, ImageOrientation orientation)
{
    if (!layer || !sample)
        return;

    std::unique_ptr<GstMappedFrame> mappedFrame(new GstMappedFrame(sample, GST_MAP_READ));
    if (!mappedFrame->isValid())
        return;

    // The decoders' native 4:2:0 formats composite through a YUV IOSurface (GPU colorspace
    // conversion). A non-identity orientation needs the CG bake-into-pixels path below, and a
    // failed surface allocation needs a fallback, so those convert to BGRA first and continue on
    // the packed-RGB path.
    if (mappedFrame->format() == GST_VIDEO_FORMAT_I420 || mappedFrame->format() == GST_VIDEO_FORMAT_NV12) {
        if (orientation.orientation() == ImageOrientation::Orientation::None && setGStreamerVideoLayerContentsYUV(layer, *mappedFrame))
            return;
        auto* info = mappedFrame->info();
        auto caps = adoptGRef(gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, "BGRA",
            "framerate", GST_TYPE_FRACTION, GST_VIDEO_INFO_FPS_N(info), GST_VIDEO_INFO_FPS_D(info),
            "width", G_TYPE_INT, GST_VIDEO_INFO_WIDTH(info), "height", G_TYPE_INT, GST_VIDEO_INFO_HEIGHT(info), nullptr));
        mappedFrame = nullptr; // Unmap before converting.
        auto convertedSample = GStreamerVideoFrameConverter::singleton().convert(sample, caps);
        if (!convertedSample)
            return;
        mappedFrame.reset(new GstMappedFrame(convertedSample, GST_MAP_READ));
        if (!mappedFrame->isValid())
            return;
    }

    // Map the negotiated packed 32-bit RGB layout to the matching CG byte order + alpha combination,
    // mirroring ImageGStreamerCG.cpp. The WebKit fallback video sink negotiates { BGRx, BGRA } on
    // little-endian; the other packings are accepted for completeness.
    CGBitmapInfo bitmapInfo;
    switch (mappedFrame->format()) {
    case GST_VIDEO_FORMAT_BGRA:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | kCGImageAlphaFirst;
        break;
    case GST_VIDEO_FORMAT_BGRx:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | kCGImageAlphaNoneSkipFirst;
        break;
    case GST_VIDEO_FORMAT_ARGB:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaFirst;
        break;
    case GST_VIDEO_FORMAT_xRGB:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaNoneSkipFirst;
        break;
    case GST_VIDEO_FORMAT_RGBA:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaLast;
        break;
    case GST_VIDEO_FORMAT_RGBx:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaNoneSkipLast;
        break;
    default:
        return;
    }

    size_t width = mappedFrame->width();
    size_t height = mappedFrame->height();
    size_t stride = mappedFrame->planeStride(0);
    auto pixels = mappedFrame->planeData(0);
    if (!width || !height || pixels.size() < stride * height)
        return;

    // No pixel copy: the data provider owns the mapped frame (which holds a reference on the
    // underlying GstBuffer), so the pixels stay valid until CoreAnimation releases the image.
    auto provider = adoptCF(CGDataProviderCreateWithData(mappedFrame.get(), pixels.data(), stride * height, releaseMappedVideoFrame));
    if (!provider)
        return;
    mappedFrame.release(); // Now owned by the provider.

    static NeverDestroyed<RetainPtr<CGColorSpaceRef>> colorSpace = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    auto image = adoptCF(CGImageCreate(width, height, 8, 32, stride, colorSpace.get().get(), bitmapInfo, provider.get(), nullptr, false, kCGRenderingIntentDefault));
    if (!image)
        return;

    // Bake a non-identity source orientation into the pixels; identity streams keep the zero-copy
    // image above. This is what lets every orientation composite through the layer instead of the
    // deadlock-prone software draw-wait path.
    if (orientation.orientation() != ImageOrientation::Orientation::None) {
        if (auto orientedImage = createOrientedImage(image.get(), orientation, width, height, colorSpace.get().get()))
            image = WTF::move(orientedImage);
        else
            return;
    }

    // CALayers may be mutated from any thread inside an explicit transaction. This runs on the
    // GStreamer streaming thread, so frame updates never depend on the main thread being idle.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer setContents:(__bridge id)image.get()];
    [CATransaction commit];
}

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA) && !USE(COORDINATED_GRAPHICS)
