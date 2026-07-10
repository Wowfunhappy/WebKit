// MAVERICKS_BACKPORT: minimal but functional IOSurface wrapper. Modern WebKit's
// version is heavily integrated with newer IOKit features (volatility,
// EDR/HDR, lossless compression, sharing primitives) that don't all exist on
// 10.9. We implement just enough for layer backing-store allocation +
// CGBitmapContext wrapping so the compositor pipeline can paint into surfaces.
#include "config.h"
#include "IOSurface.h"

#import "ColorSpaceCG.h"
#import "DestinationColorSpace.h"
// MAVERICKS_BACKPORT: pull in the CG context helpers and IOSurface pool this minimal wrapper uses (upstream's heavier media/SPI includes are dropped on 10.9).
#import "GraphicsContextCG.h"
#import "IOSurfacePool.h"
#import "PlatformScreen.h"
// MAVERICKS_BACKPORT: minimal CoreGraphics + WTF includes for the 10.9 wrapper.
#import <CoreGraphics/CoreGraphics.h>
// MAVERICKS_BACKPORT: CGIOSurfaceContext* SPI declarations (all but CreateImageReference exist in
// 10.9's CoreGraphics; CreateImageReference resolves from libpolyfill as a CreateImage alias).
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <wtf/FastMalloc.h>
#import <wtf/MachSendRight.h>
// MAVERICKS_BACKPORT: minimal WTF includes for the 10.9 wrapper.
#import <wtf/RetainPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
// MAVERICKS_BACKPORT: use the WTF IOSurface SPI header (the classic 10.9 IOSurface symbols), not PAL's newer CoreVideo/CG SPI surface headers.
#import <wtf/spi/cocoa/IOSurfaceSPI.h>

namespace WebCore {

// MAVERICKS_BACKPORT: cache the max surface size in a simple static (upstream queries IOSurfaceGetPropertyMaximum behind atomics; the 8K default below matches 10.9 / Core Animation limits).
std::optional<IntSize> IOSurface::s_maximumSize;

// MAVERICKS_BACKPORT: return the cached max size, defaulting to 8192x8192 on 10.9.
IntSize IOSurface::maximumSize()
{
    if (s_maximumSize)
        return *s_maximumSize;
    return IntSize(8192, 8192);
}

// MAVERICKS_BACKPORT: store the max size in the static cache.
void IOSurface::setMaximumSize(IntSize size)
{
    s_maximumSize = size;
}

// MAVERICKS_BACKPORT: hardcode the 10.9 IOSurface row alignment (16) instead of querying IOSurfaceGetPropertyAlignment.
size_t IOSurface::bytesPerRowAlignment()
{
    return 16;
}

// MAVERICKS_BACKPORT: row alignment is fixed on 10.9; ignore overrides.
void IOSurface::setBytesPerRowAlignment(size_t)
{
}

// MAVERICKS_BACKPORT: bytes-per-pixel per IOSurface format, computed locally (upstream derives this from CoreVideo format descriptors that are unavailable on 10.9).
static unsigned bytesPerPixelForFormat(IOSurface::Format format)
{
    switch (format) {
    // MAVERICKS_BACKPORT: 32-bit RGBA/BGRA variants are 4 bytes per pixel.
    case IOSurface::Format::BGRA:
    case IOSurface::Format::BGRX:
    case IOSurface::Format::RGBA:
    case IOSurface::Format::RGBX:
        // MAVERICKS_BACKPORT: 4 bytes per pixel for the 32-bit RGBA/BGRA variants.
        return 4;
    case IOSurface::Format::YUV422:
        return 2;
#if ENABLE(PIXEL_FORMAT_RGB10)
    // MAVERICKS_BACKPORT: packed 10-bit RGB occupies one 32-bit word per pixel.
    case IOSurface::Format::RGB10:
        return 4;
#endif
#if ENABLE(PIXEL_FORMAT_RGB10A8)
    // MAVERICKS_BACKPORT: 10-bit RGB + 8-bit alpha biplanar approximated as 5 bytes per pixel.
    case IOSurface::Format::RGB10A8:
        return 5;
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    // MAVERICKS_BACKPORT: half-float RGBA is 8 bytes per pixel.
    case IOSurface::Format::RGBA16F:
        return 8;
#endif
    }
    // MAVERICKS_BACKPORT: default to 4 bytes per pixel for unhandled formats.
    return 4;
}

// MAVERICKS_BACKPORT: map WebCore IOSurface formats to the classic 10.9 IOSurface pixel-format four-char codes (upstream's CoreVideo format helpers are unavailable here).
static OSType pixelFormatTypeForFormat(IOSurface::Format format)
{
    switch (format) {
    case IOSurface::Format::BGRA:
    case IOSurface::Format::BGRX:
        return 'BGRA';
    // MAVERICKS_BACKPORT: classic 10.9 IOSurface four-char pixel-format codes.
    case IOSurface::Format::RGBA:
    case IOSurface::Format::RGBX:
        return 'RGBA';
    case IOSurface::Format::YUV422:
        return '2vuy';
    default:
        return 'BGRA';
    }
}

// MAVERICKS_BACKPORT: allocating constructor — build the surface directly from a property dictionary (CoreVideo / lossless-compression allocation paths upstream uses are unavailable on 10.9).
IOSurface::IOSurface(IntSize size, const DestinationColorSpace& colorSpace, Name name, Format format, UseLosslessCompression, bool& success)
    : m_colorSpace(colorSpace)
    , m_size(size)
    , m_name(name)
{
    // MAVERICKS_BACKPORT: pessimistic init; flipped true only after IOSurfaceCreate succeeds.
    success = false;
    if (size.isEmpty())
        return;

    // MAVERICKS_BACKPORT: compute row stride from the per-format bytes-per-pixel and alignment.
    unsigned bpp = bytesPerPixelForFormat(format);
    size_t alignedBytesPerRow = (size.width() * bpp + bytesPerRowAlignment() - 1) & ~(bytesPerRowAlignment() - 1);
    m_totalBytes = alignedBytesPerRow * size.height();

    // MAVERICKS_BACKPORT: populate the IOSurfaceCreate property dictionary directly (10.9 IOKit allocation path).
    auto properties = adoptCF(CFDictionaryCreateMutable(kCFAllocatorDefault, 8, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    auto setNumber = [&](CFStringRef key, int64_t value) {
        auto num = adoptCF(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value));
        CFDictionaryAddValue(properties.get(), key, num.get());
    };
    setNumber(kIOSurfaceWidth, size.width());
    setNumber(kIOSurfaceHeight, size.height());
    setNumber(kIOSurfaceBytesPerElement, bpp);
    setNumber(kIOSurfaceBytesPerRow, alignedBytesPerRow);
    setNumber(kIOSurfaceAllocSize, m_totalBytes);
    setNumber(kIOSurfacePixelFormat, pixelFormatTypeForFormat(format));

    m_surface = adoptCF(IOSurfaceCreate(properties.get()));
    // MAVERICKS_BACKPORT: leave success=false if the 10.9 IOSurfaceCreate failed.
    if (!m_surface)
        return;

    // MAVERICKS_BACKPORT: lossless compression is unavailable on 10.9; always record the uncompressed format.
    m_format = UsedFormat { format, UseLosslessCompression::No };
    success = true;
}

// MAVERICKS_BACKPORT: adopt an existing IOSurfaceRef; derive size/alloc-size via the 10.9 IOKit getters.
IOSurface::IOSurface(IOSurfaceRef surface, std::optional<DestinationColorSpace>&& colorSpace)
    : m_colorSpace(WTF::move(colorSpace))
    , m_size(IntSize(IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface)))
    , m_totalBytes(IOSurfaceGetAllocSize(surface))
    , m_surface(surface)
    // MAVERICKS_BACKPORT: this wrapper does not carry the per-purpose surface name; default it.
    , m_name(Name::Default)
{
}

IOSurface::~IOSurface() = default;

// MAVERICKS_BACKPORT: pool-less create — construct directly from the 10.9 IOSurface allocation path (no IOSurfacePool recycling).
std::unique_ptr<IOSurface> IOSurface::create(IOSurfacePool*, IntSize size, const DestinationColorSpace& colorSpace, Name name, Format format, UseLosslessCompression compression)
{
    bool success = false;
    auto surface = std::unique_ptr<IOSurface>(new IOSurface(size, colorSpace, name, format, compression, success));
    if (!success)
        return nullptr;
    return surface;
}

// MAVERICKS_BACKPORT: look up the surface from a mach send right via the 10.9 IOKit API.
std::unique_ptr<IOSurface> IOSurface::createFromSendRight(const WTF::MachSendRight&& sendRight)
{
    auto surfaceRef = adoptCF(IOSurfaceLookupFromMachPort(sendRight.sendRight()));
    if (!surfaceRef)
        return nullptr;
    return createFromSurface(surfaceRef.get(), std::nullopt);
}

// MAVERICKS_BACKPORT: wrap an existing IOSurfaceRef in this minimal 10.9 wrapper.
std::unique_ptr<IOSurface> IOSurface::createFromSurface(IOSurfaceRef surface, std::optional<DestinationColorSpace>&& colorSpace)
{
    if (!surface)
        return nullptr;
    return std::unique_ptr<IOSurface>(new IOSurface(surface, WTF::move(colorSpace)));
}

// MAVERICKS_BACKPORT: createFromImage was dropped from this tree but is still called by
// WebViewImpl (swipe-navigation snapshots) and RemoteMediaPlayerProxy. Recreate the
// upstream behavior: allocate an sRGB IOSurface the size of the image and paint the
// CGImage into it through the surface's CG context.
std::unique_ptr<IOSurface> IOSurface::createFromImage(IOSurfacePool* pool, CGImageRef image)
{
    // MAVERICKS_BACKPORT: restored createFromImage (see note above) — allocate an sRGB surface and paint the CGImage into it.
    if (!image)
        return nullptr;

    // MAVERICKS_BACKPORT: restored createFromImage — derive the surface size from the source image.
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (!width || !height)
        return nullptr;

    // MAVERICKS_BACKPORT: restored createFromImage — allocate the backing sRGB IOSurface.
    auto surface = IOSurface::create(pool, IntSize(static_cast<int>(width), static_cast<int>(height)), DestinationColorSpace::SRGB());
    if (!surface)
        return nullptr;

    // MAVERICKS_BACKPORT: restored createFromImage — paint through the surface's CG context.
    auto surfaceContext = surface->createPlatformContext();
    if (!surfaceContext)
        return nullptr;

    // MAVERICKS_BACKPORT: restored createFromImage — draw and flush the image into the surface.
    CGContextDrawImage(surfaceContext.get(), CGRectMake(0, 0, width, height), image);
    CGContextFlush(surfaceContext.get());

    return surface;
}

// MAVERICKS_BACKPORT: IOSurfacePool recycling is not used on 10.9; drop the surface (no pooling).
void IOSurface::moveToPool(std::unique_ptr<IOSurface>&&, IOSurfacePool*)
{
}

// MAVERICKS_BACKPORT: wrap the 10.9 IOSurfaceCreateMachPort directly; null-guarded.
WTF::MachSendRight IOSurface::createSendRight() const
{
    if (!m_surface)
        return { };
    mach_port_t p = IOSurfaceCreateMachPort(m_surface.get());
    return WTF::MachSendRight::adopt(p);
}

// MAVERICKS_BACKPORT: upstream body plus a null-context guard. Works because createPlatformContext
// below produces a real CGIOSurfaceContext again.
RetainPtr<CGImageRef> IOSurface::createImage(CGContextRef context)
{
    if (!context)
        return { };
    ASSERT(CGIOSurfaceContextGetSurface(context) == m_surface);
    return adoptCF(CGIOSurfaceContextCreateImage(context));
}

// MAVERICKS_BACKPORT: upstream body plus null guards. CGIOSurfaceContextCreateImageReference does
// not exist in 10.9's CoreGraphics; libpolyfill supplies it as an alias of
// CGIOSurfaceContextCreateImage (copy instead of live-reference semantics — safe for a sunk surface).
RetainPtr<CGImageRef> IOSurface::sinkIntoImage(std::unique_ptr<IOSurface> surface, RetainPtr<CGContextRef> context)
{
    if (!surface)
        return { };
    if (!context)
        context = surface->createPlatformContext();
    if (!context)
        return { };
    ASSERT(CGIOSurfaceContextGetSurface(context.get()) == surface->m_surface);
    return adoptCF(CGIOSurfaceContextCreateImageReference(context.get()));
}

// MAVERICKS_BACKPORT: upstream bitmapConfiguration(), scoped to the 8-bit-per-component formats this
// wrapper allocates (see pixelFormatTypeForFormat above).
static CGBitmapInfo bitmapInfoForFormat(IOSurface::Format format)
{
    switch (format) {
    case IOSurface::Format::BGRX:
    case IOSurface::Format::RGBX:
        return static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipFirst) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Host);
    default:
        return static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Host);
    }
}

// MAVERICKS_BACKPORT: upstream body (CGIOSurfaceContextCreate — present and functional in 10.9's
// CoreGraphics; the previous CGBitmapContext-over-locked-base-address fallback here was based on the
// false premise that the SPI is unavailable, and it forced every IOSurface consumer onto bitmap-context
// workarounds and permanent surface locks). Omitted relative to upstream: OpenGL display-mask
// targeting (single-GPU 10.9) and CGContextSetOwnerIdentity resource tagging (no m_resourceOwner in
// this wrapper; the API is 12.0+ anyway).
RetainPtr<CGContextRef> IOSurface::createPlatformContext(PlatformDisplayID, std::optional<CGImageAlphaInfo> overrideAlphaInfo)
{
    if (!m_surface)
        return nullptr;

    CGBitmapInfo bitmapInfo = bitmapInfoForFormat(m_format ? m_format->format : Format::BGRA);
    if (overrideAlphaInfo)
        bitmapInfo = (bitmapInfo & ~kCGBitmapAlphaInfoMask) | *overrideAlphaInfo;

    auto cs = m_colorSpace.value_or(DestinationColorSpace::SRGB());
    // MAVERICKS_BACKPORT: cs.platformColorSpace() can return NULL on Mavericks (CG fails to construct
    // named SRGB); fall back to sRGBColorSpaceSingleton like asCAIOSurfaceLayerContents below.
    RetainPtr<CGColorSpaceRef> csRef = cs.platformColorSpace();
    if (!csRef)
        csRef = sRGBColorSpaceSingleton();

    return adoptCF(CGIOSurfaceContextCreate(m_surface.get(), m_size.width(), m_size.height(), 8, 32, csRef.get(), bitmapInfo));
}

// MAVERICKS_BACKPORT: this wrapper stores the color space directly; default to sRGB when unset.
DestinationColorSpace IOSurface::colorSpace()
{
    return m_colorSpace.value_or(DestinationColorSpace::SRGB());
}

// MAVERICKS_BACKPORT: minimal IOSurface accessor over the 10.9 IOKit API, null-guarded.
IOSurfaceID IOSurface::surfaceID() const
{
    return m_surface ? IOSurfaceGetID(m_surface.get()) : 0;
}

// MAVERICKS_BACKPORT: minimal IOSurface accessor over the 10.9 IOKit API, null-guarded.
size_t IOSurface::bytesPerRow() const
{
    return m_surface ? IOSurfaceGetBytesPerRow(m_surface.get()) : 0;
}

// MAVERICKS_BACKPORT: minimal IOSurface accessor over the 10.9 IOKit API, null-guarded.
IOSurfaceSeed IOSurface::seed() const
{
    return m_surface ? IOSurfaceGetSeed(m_surface.get()) : 0;
}

// MAVERICKS_BACKPORT: minimal IOSurface accessor over the 10.9 IOKit API, null-guarded.
bool IOSurface::isInUse() const
{
    return m_surface ? IOSurfaceIsInUse(m_surface.get()) : false;
}

// MAVERICKS_BACKPORT: IOSurface volatility/purgeability state is not tracked in this wrapper on 10.9; report non-volatile.
bool IOSurface::isVolatile() const
{
    return false;
}

// MAVERICKS_BACKPORT: IOSurface volatility/purgeability is not managed on 10.9; no-op returning a valid result.
SetNonVolatileResult IOSurface::setVolatile(bool)
{
    return static_cast<SetNonVolatileResult>(0);
}

// MAVERICKS_BACKPORT: IOSurface volatility/purgeability is not tracked on 10.9; report a valid result.
SetNonVolatileResult IOSurface::state() const
{
    return static_cast<SetNonVolatileResult>(0);
}

// MAVERICKS_BACKPORT: task-identity-token ownership tagging is unavailable on 10.9; no-op.
void IOSurface::setOwnershipIdentity(const ProcessIdentity&)
{
}

// MAVERICKS_BACKPORT: task-identity-token ownership tagging is unavailable on 10.9; no-op.
void IOSurface::setOwnershipIdentity(IOSurfaceRef, const ProcessIdentity&)
{
}

// MAVERICKS_BACKPORT: the per-rendering-purpose IOSurface naming is not used on 10.9; return the default name.
IOSurface::Name IOSurface::nameForRenderingPurpose(RenderingPurpose)
{
    return Name::Default;
}

// MAVERICKS_BACKPORT: CALayer.contents = IOSurface is unreliable on 10.9; this snapshots the surface pixels into a CGImage instead (see body).
RetainPtr<id> IOSurface::asCAIOSurfaceLayerContents() const
{
#ifdef __OBJC__
    if (!m_surface)
        return nullptr;
    // MAVERICKS_BACKPORT: CALayer.contents = IOSurface is unreliable on Mavericks. Snapshot
    // the IOSurface's pixel data into a CGImage and return that instead.
    if (IOSurfaceLock(m_surface.get(), kIOSurfaceLockReadOnly, nullptr) != kIOReturnSuccess)
        return nullptr;
    void* base = IOSurfaceGetBaseAddress(m_surface.get());
    size_t bpr = IOSurfaceGetBytesPerRow(m_surface.get());
    size_t w = IOSurfaceGetWidth(m_surface.get());
    size_t h = IOSurfaceGetHeight(m_surface.get());
    size_t dataSize = bpr * h;
    void* copy = WTF::fastMalloc(dataSize);
    memcpy(copy, base, dataSize);
    IOSurfaceUnlock(m_surface.get(), kIOSurfaceLockReadOnly, nullptr);
    auto provider = adoptCF(CGDataProviderCreateWithData(copy, copy, dataSize, [](void* info, const void*, size_t) {
        WTF::fastFree(info);
    }));
    auto cs = m_colorSpace.value_or(DestinationColorSpace::SRGB());
    // MAVERICKS_BACKPORT: cs.platformColorSpace() can return NULL on Mavericks (CG fails to
    // construct named SRGB). Fall back to sRGBColorSpaceSingleton so CGImageCreate
    // doesn't return NULL → blank tile → invisible content.
    RetainPtr<CGColorSpaceRef> csRef = cs.platformColorSpace();
    if (!csRef)
        csRef = sRGBColorSpaceSingleton();
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
    auto image = adoptCF(CGImageCreate(w, h, 8, 32, bpr, csRef.get(), bitmapInfo, provider.get(), nullptr, false, kCGRenderingIntentDefault));
    if (!image)
        return nullptr;
    return (__bridge id)image.get();
#else
    return nullptr;
#endif
}

} // namespace WebCore
