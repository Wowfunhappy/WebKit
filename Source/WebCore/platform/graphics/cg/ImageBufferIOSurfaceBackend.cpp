/*
 * Copyright (C) 2020-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ImageBufferIOSurfaceBackend.h"

#if HAVE(IOSURFACE)

#include "GraphicsClient.h"
#include "GraphicsContextCG.h"
#include "IOSurface.h"
#include "IOSurfacePool.h"
#include "IntRect.h"
#include "NativeImage.h"
#include "PixelBuffer.h"
#include <CoreGraphics/CoreGraphics.h>
#include <pal/cg/CoreGraphicsSoftLink.h>
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ImageBufferIOSurfaceBackend);

IntSize ImageBufferIOSurfaceBackend::calculateSafeBackendSize(const Parameters& parameters)
{
    IntSize backendSize = parameters.backendSize;
    if (backendSize.isEmpty())
        return { };

    IntSize maxSize = IOSurface::maximumSize();
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[IOSurfBE::calcSafe] backendSize=%dx%d maxSize=%dx%d\n", backendSize.width(), backendSize.height(), maxSize.width(), maxSize.height()); fclose(_d);}}
    // 10.9 backport: IOSurface::maximumSize() returns 0x0 due to polyfill stub returning
    // junk via struct-return register. Substitute a sane cap (16K x 16K) so the size
    // check doesn't reject every valid backing-store request.
    if (maxSize.width() <= 0 || maxSize.height() <= 0)
        maxSize = IntSize(16384, 16384);
    if (backendSize.width() > maxSize.width() || backendSize.height() > maxSize.height())
        return { };

    return backendSize;
}

unsigned ImageBufferIOSurfaceBackend::calculateBytesPerRow(const IntSize& backendSize, PixelFormat imageBufferPixelFormat)
{
    unsigned bytesPerRow = ImageBufferCGBackend::calculateBytesPerRow(backendSize, imageBufferPixelFormat);
    size_t alignmentMask = IOSurface::bytesPerRowAlignment() - 1;
    return (bytesPerRow + alignmentMask) & ~alignmentMask;
}

size_t ImageBufferIOSurfaceBackend::calculateMemoryCost(const Parameters& parameters)
{
    return ImageBufferBackend::calculateMemoryCost(parameters.backendSize, calculateBytesPerRow(parameters.backendSize, parameters.bufferFormat.pixelFormat));
}

std::unique_ptr<ImageBufferIOSurfaceBackend> ImageBufferIOSurfaceBackend::create(const Parameters& parameters, const ImageBufferCreationContext& creationContext)
{
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[WCore::IOSurfBE::create] purpose=%d paramsBackendSize=%dx%d scale=%g\n", (int)parameters.purpose, parameters.backendSize.width(), parameters.backendSize.height(), (double)parameters.resolutionScale); fclose(_d);}}
    // 10.9 backport: skip IOSurface backend for canvas — IOSurface drawing/readback is
    // unreliable on this build (canvas pixels read back as zeros even after fillRect,
    // canvas.toDataURL returns empty "data:,"). Falling back to ImageBufferPlatformBitmapBackend
    // gives a working CG bitmap context. Other purposes (compositing, layer scratch buffers)
    // still use IOSurface — those paths have other 10.9 workarounds in place.
    if (parameters.purpose == RenderingPurpose::Canvas)
        return nullptr;

    IntSize backendSize = calculateSafeBackendSize(parameters);
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[WCore::IOSurfBE] backendSize=%dx%d empty=%d\n", backendSize.width(), backendSize.height(), (int)backendSize.isEmpty()); fclose(_d);}}
    if (backendSize.isEmpty())
        return nullptr;

    auto surface = IOSurface::create(RefPtr { creationContext.surfacePool }.get(), backendSize, parameters.colorSpace, IOSurface::Name::ImageBuffer, convertToIOSurfaceFormat(parameters.bufferFormat.pixelFormat), parameters.bufferFormat.useLosslessCompression);
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[WCore::IOSurfBE] IOSurface::create returned=%p\n", surface.get()); fclose(_d);}}
    if (!surface)
        return nullptr;

    RetainPtr<CGContextRef> cgContext = surface->createPlatformContext(creationContext.displayID);
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[WCore::IOSurfBE] createPlatformContext returned=%p\n", cgContext.get()); fclose(_d);}}
    if (!cgContext)
        return nullptr;

    CGContextClearRect(cgContext.get(), FloatRect(FloatPoint::zero(), backendSize));

    return std::unique_ptr<ImageBufferIOSurfaceBackend> { new ImageBufferIOSurfaceBackend { parameters, WTF::move(surface), WTF::move(cgContext), creationContext.displayID, creationContext.surfacePool.get() } };
}

ImageBufferIOSurfaceBackend::ImageBufferIOSurfaceBackend(const Parameters& parameters, std::unique_ptr<IOSurface> surface, RetainPtr<CGContextRef> platformContext, PlatformDisplayID displayID, IOSurfacePool* ioSurfacePool)
    : ImageBufferCGBackend(parameters)
    , m_surface(WTF::move(surface))
    , m_platformContext(WTF::move(platformContext))
    , m_displayID(displayID)
    , m_ioSurfacePool(ioSurfacePool)
{
    ASSERT(m_surface);
    ASSERT(!m_surface->isVolatile());
}

ImageBufferIOSurfaceBackend::~ImageBufferIOSurfaceBackend()
{
    ensureNativeImagesHaveCopiedBackingStore();
    releaseGraphicsContext();
    IOSurface::moveToPool(WTF::move(m_surface), m_ioSurfacePool.get());
}


GraphicsContext& ImageBufferIOSurfaceBackend::context()
{
    if (!m_context) {
        m_context = makeUnique<GraphicsContextCG>(ensurePlatformContext());
        applyBaseTransform(*m_context);
    }
    return *m_context;
}

void ImageBufferIOSurfaceBackend::flushContext()
{
    flushContextDraws();
}

void ImageBufferIOSurfaceBackend::submitDrawingCommands()
{
    if (PAL::canLoad_CoreGraphics_CGIOSurfaceContextFlushQueue())
        PAL::softLink_CoreGraphics_CGIOSurfaceContextFlushQueue(ensurePlatformContext());
    else {
        // Creating a snapshot image forces the rendering to commence
        createImage();
    }
}

bool ImageBufferIOSurfaceBackend::flushContextDraws()
{
    bool contextNeedsFlush = m_context && m_context->consumeHasDrawn();
    if (!contextNeedsFlush && !m_needsFirstFlush)
        return false;
    m_needsFirstFlush = false;
    if (auto* ctx = ensurePlatformContext())
        CGContextFlush(ctx);
    return true;
}

CGContextRef ImageBufferIOSurfaceBackend::ensurePlatformContext()
{
    if (!m_platformContext) {
        // 10.9 backport: m_surface may be null/freed by the time the renderer
        // calls back to flush. CNN crashes here. Skip if no surface.
        if (!m_surface)
            return nullptr;
        m_platformContext = m_surface->createPlatformContext(m_displayID);
        if (!m_platformContext)
            return nullptr;
    }
    return m_platformContext.get();
}

unsigned ImageBufferIOSurfaceBackend::bytesPerRow() const
{
    return m_surface->bytesPerRow();
}

void ImageBufferIOSurfaceBackend::transferToNewContext(const ImageBufferCreationContext& creationContext)
{
    m_ioSurfacePool = creationContext.surfacePool;
    if (creationContext.resourceOwner)
        m_surface->setOwnershipIdentity(creationContext.resourceOwner);
}

bool ImageBufferIOSurfaceBackend::invalidateCachedNativeImage()
{
    // Force QuartzCore to invalidate its cached CGImageRef for this IOSurface.
    // This is necessary in cases where we know (a priori) that the IOSurface has been
    // modified, but QuartzCore may have a cached CGImageRef that does not reflect the
    // current state of the IOSurface.
    // See https://webkit.org/b/157966 and https://webkit.org/b/228682 for more context.
    if (PAL::canLoad_CoreGraphics_CGIOSurfaceContextInvalidateSurface()) {
        PAL::softLink_CoreGraphics_CGIOSurfaceContextInvalidateSurface(ensurePlatformContext());
        return false;
    }

    CGContextFillRect(ensurePlatformContext(), CGRect { });
    return true;
}

RefPtr<NativeImage> ImageBufferIOSurfaceBackend::copyNativeImage()
{
    // 10.9 backport: m_surface->createImage is broken on this build
    // (CFRelease crash on null CGImageRef). createImageReference uses
    // CGIOSurfaceContextCreateImageReference which works. Same fix already
    // applied to sinkIntoNativeImage.
    if (!m_surface)
        return nullptr;
    return NativeImage::create(createImageReference());
}

RefPtr<NativeImage> ImageBufferIOSurfaceBackend::createNativeImageReference()
{
    // The destination backend needs to read the actual pixels. Returning non-refence will
    // copy the pixels and but still cache the image to the context. This means we must
    // return the reference or cleanup later if we return the non-reference.
    return NativeImage::create(createImageReference());
}

RefPtr<NativeImage> ImageBufferIOSurfaceBackend::sinkIntoNativeImage()
{
    // 10.9 backport: IOSurface::sinkIntoImage AND m_surface->createImage are
    // both broken on this build (vimeo canvas.toDataURL crashes CFRelease in
    // both). createImageReference uses a different CG path and works.
    if (!m_surface)
        return nullptr;
    return NativeImage::create(createImageReference());
}

void ImageBufferIOSurfaceBackend::getPixelBuffer(const IntRect& srcRect, PixelBuffer& destination)
{
    // 10.9 backport: twitter.com calls canvas getImageData; m_surface can be
    // null on this build, crashing in m_surface->lock(). Bail silently.
    if (!m_surface)
        return;
    const_cast<ImageBufferIOSurfaceBackend*>(this)->prepareForExternalRead();
    if (auto lock = m_surface->lock<IOSurface::AccessMode::ReadOnly>())
        ImageBufferBackend::getPixelBuffer(srcRect, lock->surfaceSpan(), destination);
}

void ImageBufferIOSurfaceBackend::putPixelBuffer(const PixelBufferSourceView& pixelBuffer, const IntRect& srcRect, const IntPoint& destPoint, AlphaPremultiplication destFormat)
{
    if (!m_surface)
        return;
    prepareForExternalWrite();
    if (auto lock = m_surface->lock<IOSurface::AccessMode::ReadWrite>())
        ImageBufferBackend::putPixelBuffer(pixelBuffer, srcRect, destPoint, destFormat, lock->surfaceSpan());
}

bool ImageBufferIOSurfaceBackend::canMapBackingStore() const
{
    return true;
}

IOSurface* ImageBufferIOSurfaceBackend::surface()
{
    prepareForExternalWrite(); // This is conservative. At the time of writing this is not used.
    return m_surface.get();
}

bool ImageBufferIOSurfaceBackend::isInUse() const
{
    return m_surface->isInUse();
}

void ImageBufferIOSurfaceBackend::releaseGraphicsContext()
{
    m_context = nullptr;
    m_platformContext = nullptr;
}

bool ImageBufferIOSurfaceBackend::setVolatile()
{
    if (m_surface->isInUse())
        return false;

    if (m_volatilityState == VolatilityState::Volatile) {
        ASSERT(m_surface->isVolatile());
        return true;
    }

    setVolatilityState(VolatilityState::Volatile);
    m_surface->setVolatile(true);
    return true;
}

SetNonVolatileResult ImageBufferIOSurfaceBackend::setNonVolatile()
{
    if (m_volatilityState == VolatilityState::Volatile) {
        setVolatilityState(VolatilityState::NonVolatile);

        auto previousState = m_surface->setVolatile(false);
        if (previousState == SetNonVolatileResult::Empty) {
            RetainPtr context = ensurePlatformContext();
            ASSERT(CGAffineTransformIsIdentity(CGContextGetCTM(context.get())));
            CGContextClearRect(context.get(), FloatRect({ }, size()));
        }

        return previousState;
    }

    ASSERT(!m_surface->isVolatile());
    return SetNonVolatileResult::Valid;
}

VolatilityState ImageBufferIOSurfaceBackend::volatilityState() const
{
    return m_volatilityState;
}

void ImageBufferIOSurfaceBackend::setVolatilityState(VolatilityState volatilityState)
{
    m_volatilityState = volatilityState;
}

void ImageBufferIOSurfaceBackend::ensureNativeImagesHaveCopiedBackingStore()
{
    // FIXME: This will be removed. This was needed when putImageData was not properly accounting
    // for outstanding reads.
    if (!m_mayHaveOutstandingBackingStoreReferences)
        return;
    prepareForExternalWrite();
}

void ImageBufferIOSurfaceBackend::prepareForExternalRead()
{
    // Ensure that there are no pending draws to this surface. This is ensured by flushing the context
    // through which the draws may have come.
    flushContextDraws();
}

void ImageBufferIOSurfaceBackend::prepareForExternalWrite()
{
    bool needFlush = false;
    // Ensure that there are no future draws from the surface that would use the surface context image cache.
    if (m_mayHaveOutstandingBackingStoreReferences) {
        needFlush = invalidateCachedNativeImage();
        m_mayHaveOutstandingBackingStoreReferences = false;
    }

    // Ensure that there are no pending draws to this surface. This is ensured by flushing the context
    // through which the draws may have come.
    // Ensure that there are no pending draws from this surface. This is ensured by drawing the invalidation marker before
    // flushing the the context. The invalidation marker forces the draws from this surface to complete before
    // the invalidation marker completes.
    if (flushContextDraws())
        needFlush = false;
    if (needFlush)
        CGContextFlush(ensurePlatformContext());
}

RetainPtr<CGImageRef> ImageBufferIOSurfaceBackend::createImage()
{
    // Consumers may hold on to the image, so mark external writes needing the invalidation marker.
    m_mayHaveOutstandingBackingStoreReferences = true;
    // 10.9 backport: IOSurface::createPlatformContext returns a CGBitmapContext (not a real
    // CGIOSurfaceContext — CGIOSurfaceContextCreate is private/unavailable on 10.9). The upstream
    // IOSurface::createImage path calls CGIOSurfaceContextCreateImage on that context which spams
    // "CGIOSurfaceContextCreateImage: invalid context ... serious error" on every paint and returns
    // null. Use CGBitmapContextCreateImage instead — it copies the pixel data into a standalone
    // CGImage (matching the "may have outstanding references" contract above). The companion
    // createImageReference() already uses a different CG path for synchronized reads.
    if (auto ctx = ensurePlatformContext()) {
        if (auto image = adoptCF(CGBitmapContextCreateImage(ctx)))
            return image;
    }
    return m_surface->createImage(ensurePlatformContext());
}

RetainPtr<CGImageRef> ImageBufferIOSurfaceBackend::createImageReference()
{
    // The reference is used only in synchronized manner, so after the use ends, we can update
    // externally without invalidation marker. Thus we do not set m_mayHaveOutstandingBackingStoreReferences.
    // 10.9 backport: libpolyfill's CGIOSurfaceContextCreateImageReference is just a wrapper that calls
    // CGIOSurfaceContextCreateImage, which fails on our CGBitmapContext-backed "IOSurface" with
    // "invalid context ... serious error" spam on every paint and returns null. CGBitmapContextCreateImage
    // works correctly — it copies the bitmap pixels into a standalone CGImage. (We give up the
    // "synchronized reference" semantics, but they were already broken: the previous code returned null
    // images, so anywhere we relied on them seeing live IOSurface mutations was already getting blanks.)
    RetainPtr<CGImageRef> image;
    if (auto ctx = ensurePlatformContext())
        image = adoptCF(CGBitmapContextCreateImage(ctx));
    else
        image = adoptCF(CGIOSurfaceContextCreateImageReference(ensurePlatformContext()));
    if (image) {
        // CG has internal caches for some operations related to software bitmap draw.
        // One of these caches are per-image color matching cache. Since these will not get any hits
        // from an image that is recreated every time, mark the image transient to skip these caches.
        // This also skips WebKit GraphicsContext subimage cache.
        CGImageSetCachingFlags(image.get(), kCGImageCachingTransient);
    }
    return image;
}

} // namespace WebCore

#endif // HAVE(IOSURFACE)
