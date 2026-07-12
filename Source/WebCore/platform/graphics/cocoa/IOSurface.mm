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
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #import "ImageBufferBackend.h"
// #import "Logging.h"
// (end MAVERICKS_BACKPORT restored block)
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
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     if (pool)
//         pool->addSurface(WTF::move(surface));
// (end MAVERICKS_BACKPORT restored block)
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
    case IOSurface::Format::RGB10:
    // MAVERICKS_BACKPORT: packed 10-bit RGB occupies one 32-bit word per pixel.
        return 4;
#endif
#if ENABLE(PIXEL_FORMAT_RGB10A8)
    case IOSurface::Format::RGB10A8:
    // MAVERICKS_BACKPORT: 10-bit RGB + 8-bit alpha biplanar approximated as 5 bytes per pixel.
        return 5;
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    case IOSurface::Format::RGBA16F:
    // MAVERICKS_BACKPORT: half-float RGBA is 8 bytes per pixel.
        return 8;
#endif
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
            (id)kIOSurfaceName: surfaceNameToNSString(name).get()
        },
        @"IOSurfacePurgeable" : @YES, // FIXME: Use kCVPixelBufferIOSurfacePurgeableKey: rdar://156450702.
    };

    CVPixelBufferRef rawPixelBuffer = nullptr;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, size.width(), size.height(), coreVideoFormat, (CFDictionaryRef)additionalProperties.get(), &rawPixelBuffer);
    if (status != kCVReturnSuccess) {
        RELEASE_LOG_ERROR(Layers, "IOSurface creation via CVPixelBufferCreate failed for size: (%d %d) and format: (%d) - error %d", size.width(), size.height(), std::to_underlying(format), status);
        return nullptr;
MAVERICKS_BACKPORT */
    }
    // MAVERICKS_BACKPORT: default to 4 bytes per pixel for unhandled formats.
    return 4;
}

// MAVERICKS_BACKPORT: map WebCore IOSurface formats to the classic 10.9 IOSurface pixel-format four-char codes (upstream's CoreVideo format helpers are unavailable here).
static OSType pixelFormatTypeForFormat(IOSurface::Format format)
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    return optionsForSurface(size, 32, pixelFormat, name);
}

#if ENABLE(PIXEL_FORMAT_RGBA16F)
static NSDictionary *optionsFor64BitSurface(IntSize size, unsigned pixelFormat, IOSurface::Name name)
{
    return optionsForSurface(size, 64, pixelFormat, name);
}
#endif

static RetainPtr<IOSurfaceRef> createSurface(IntSize size, IOSurface::Name name, IOSurface::Format format)
{
    RetainPtr<NSDictionary> options;

MAVERICKS_BACKPORT */
    switch (format) {
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     case IOSurface::Format::BGRX:
// (end MAVERICKS_BACKPORT restored block)
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
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//
//     return adoptCF(IOSurfaceCreate((CFDictionaryRef)options.get()));
// (end MAVERICKS_BACKPORT restored block)
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

IOSurface::IOSurface(IOSurfaceRef surface, std::optional<DestinationColorSpace>&& colorSpace)
// MAVERICKS_BACKPORT: adopt an existing IOSurfaceRef; derive size/alloc-size via the 10.9 IOKit getters.
    : m_colorSpace(WTF::move(colorSpace))
    , m_size(IntSize(IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface)))
    , m_totalBytes(IOSurfaceGetAllocSize(surface))
    , m_surface(surface)
    // MAVERICKS_BACKPORT: this wrapper does not carry the per-purpose surface name; default it.
    , m_name(Name::Default)
{
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     m_size = IntSize(IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));
//     m_totalBytes = IOSurfaceGetAllocSize(surface);
//
//     if (m_colorSpace)
//         setColorSpaceProperty();
// (end MAVERICKS_BACKPORT restored block)
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
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     return MachSendRight::adopt(IOSurfaceCreateMachPort(m_surface.get()));
// (end MAVERICKS_BACKPORT restored block)
}

// MAVERICKS_BACKPORT: wrap the 10.9 IOSurfaceCreateMachPort directly; null-guarded.
WTF::MachSendRight IOSurface::createSendRight() const
{
    if (!m_surface)
        return { };
    mach_port_t p = IOSurfaceCreateMachPort(m_surface.get());
    return WTF::MachSendRight::adopt(p);
}

RetainPtr<CGImageRef> IOSurface::createImage(CGContextRef context)
{
// MAVERICKS_BACKPORT: upstream body plus a null-context guard. Works because createPlatformContext
// below produces a real CGIOSurfaceContext again.
    // MAVERICKS_BACKPORT: null-guard the incoming CG context before querying it.
    if (!context)
        return { };
    ASSERT(CGIOSurfaceContextGetSurface(context) == m_surface);
    return adoptCF(CGIOSurfaceContextCreateImage(context));
}

RetainPtr<CGImageRef> IOSurface::sinkIntoImage(std::unique_ptr<IOSurface> surface, RetainPtr<CGContextRef> context)
{
// MAVERICKS_BACKPORT: upstream body plus null guards. CGIOSurfaceContextCreateImageReference does
// not exist in 10.9's CoreGraphics; libpolyfill supplies it as an alias of
// CGIOSurfaceContextCreateImage (copy instead of live-reference semantics — safe for a sunk surface).
    // MAVERICKS_BACKPORT: null-guard the surface being sunk.
    if (!surface)
        return { };
    if (!context)
        context = surface->createPlatformContext();
    // MAVERICKS_BACKPORT: bail if the surface still yields no CG context.
    if (!context)
        return { };
    ASSERT(CGIOSurfaceContextGetSurface(context.get()) == surface->m_surface);
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     UNUSED_PARAM(surface);
// (end MAVERICKS_BACKPORT restored block)
    return adoptCF(CGIOSurfaceContextCreateImageReference(context.get()));
}

// MAVERICKS_BACKPORT: upstream bitmapConfiguration(), scoped to the 8-bit-per-component formats this
// wrapper allocates (see pixelFormatTypeForFormat above).
static CGBitmapInfo bitmapInfoForFormat(IOSurface::Format format)
{
    // MAVERICKS_BACKPORT: BGRX/RGBX map to skip-alpha, all other 8-bit formats to premultiplied-first.
    switch (format) {
    case IOSurface::Format::BGRX:
    case IOSurface::Format::RGBX:
        return static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipFirst) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Host);
    default:
        return static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Host);
    }
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//
//     return { bitmapInfo, bitsPerComponent };
// (end MAVERICKS_BACKPORT restored block)
}

// MAVERICKS_BACKPORT: upstream body (CGIOSurfaceContextCreate — present and functional in 10.9's
// CoreGraphics; the previous CGBitmapContext-over-locked-base-address fallback here was based on the
// false premise that the SPI is unavailable, and it forced every IOSurface consumer onto bitmap-context
// workarounds and permanent surface locks). Omitted relative to upstream: OpenGL display-mask
// targeting (single-GPU 10.9) and CGContextSetOwnerIdentity resource tagging (no m_resourceOwner in
// this wrapper; the API is 12.0+ anyway).
RetainPtr<CGContextRef> IOSurface::createPlatformContext(PlatformDisplayID, std::optional<CGImageAlphaInfo> overrideAlphaInfo)
{
    // MAVERICKS_BACKPORT: guard against a null surface (10.9 IOSurfaceCreate can fail).
    if (!m_surface)
        return nullptr;

    // MAVERICKS_BACKPORT: derive the CGBitmapInfo from the surface format via the local helper.
    CGBitmapInfo bitmapInfo = bitmapInfoForFormat(m_format ? m_format->format : Format::BGRA);
    if (overrideAlphaInfo)
        // MAVERICKS_BACKPORT: fold the optional alpha-info override into the local bitmapInfo.
        bitmapInfo = (bitmapInfo & ~kCGBitmapAlphaInfoMask) | *overrideAlphaInfo;

    auto cs = m_colorSpace.value_or(DestinationColorSpace::SRGB());
    // MAVERICKS_BACKPORT: cs.platformColorSpace() can return NULL on Mavericks (CG fails to construct
    // named SRGB); fall back to sRGBColorSpaceSingleton like asCAIOSurfaceLayerContents below.
    RetainPtr<CGColorSpaceRef> csRef = cs.platformColorSpace();
    if (!csRef)
        csRef = sRGBColorSpaceSingleton();

    // MAVERICKS_BACKPORT: build the CG context directly over the IOSurface with 10.9's CGIOSurfaceContextCreate.
    return adoptCF(CGIOSurfaceContextCreate(m_surface.get(), m_size.width(), m_size.height(), 8, 32, csRef.get(), bitmapInfo));
}

DestinationColorSpace IOSurface::colorSpace()
{
// MAVERICKS_BACKPORT: this wrapper stores the color space directly; default to sRGB when unset.
    return m_colorSpace.value_or(DestinationColorSpace::SRGB());
}

IOSurfaceID IOSurface::surfaceID() const
{
// MAVERICKS_BACKPORT: minimal IOSurface accessor over the 10.9 IOKit API, null-guarded.
    return m_surface ? IOSurfaceGetID(m_surface.get()) : 0;
}

size_t IOSurface::bytesPerRow() const
{
// MAVERICKS_BACKPORT: minimal IOSurface accessor over the 10.9 IOKit API, null-guarded.
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
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     m_contentEDRHeadroom = 1;
//     if (auto valueNumber = dynamic_cf_cast<CFNumberRef>(adoptCF(IOSurfaceCopyValue(m_surface.get(), kIOSurfaceContentHeadroom))))
//         CFNumberGetValue(valueNumber.get(), kCFNumberFloat32Type, &m_contentEDRHeadroom.value());
// (end MAVERICKS_BACKPORT restored block)
}
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #endif
// (end MAVERICKS_BACKPORT restored block)

// MAVERICKS_BACKPORT: task-identity-token ownership tagging is unavailable on 10.9; no-op.
void IOSurface::setOwnershipIdentity(IOSurfaceRef, const ProcessIdentity&)
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    auto propertyList = adoptCF(IOSurfaceCopyValue(m_surface.get(), kIOSurfaceColorSpace));
    if (!propertyList)
        return { };
    
    auto colorSpaceCF = adoptCF(CGColorSpaceCreateWithPropertyList(propertyList.get()));
    if (!colorSpaceCF)
        return { };
    
    return DestinationColorSpace { colorSpaceCF };
MAVERICKS_BACKPORT */
}

// MAVERICKS_BACKPORT: the per-rendering-purpose IOSurface naming is not used on 10.9; return the default name.
IOSurface::Name IOSurface::nameForRenderingPurpose(RenderingPurpose)
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    switch (purpose) {
    case RenderingPurpose::Unspecified:
        return Name::ImageBufferShareableMapped;

    case RenderingPurpose::Canvas:
        return Name::Canvas;

    case RenderingPurpose::DOM:
        return Name::DOM;

    case RenderingPurpose::LayerBacking:
        return Name::LayerBacking;

    case RenderingPurpose::Snapshot:
        return Name::Snapshot;

    case RenderingPurpose::ShareableSnapshot:
        return Name::ShareableSnapshot;

    case RenderingPurpose::ShareableLocalSnapshot:
        return Name::ShareableLocalSnapshot;

    case RenderingPurpose::MediaPainting:
        return Name::MediaPainting;
    }

MAVERICKS_BACKPORT */
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
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    }
    return ts;
}

static TextStream& operator<<(TextStream& ts, SetNonVolatileResult state)
{
    switch (state) {
    case SetNonVolatileResult::Valid:
        ts << "valid"_s;
        break;
    case SetNonVolatileResult::Empty:
        ts << "empty"_s;
        break;
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, const IOSurface& surface)
{
    return ts << "IOSurface "_s << surface.surfaceID() << " name "_s << [surfaceNameToNSString(surface.name()) UTF8String] << " size "_s << surface.size() << " format "_s << (surface.m_format ? surface.m_format->format : IOSurface::Format::BGRX)
        << " compressed " << (surface.m_format ? (surface.m_format->useLosslessCompression == UseLosslessCompression::Yes) : false) << " state "_s << surface.state();
MAVERICKS_BACKPORT */
}

} // namespace WebCore
