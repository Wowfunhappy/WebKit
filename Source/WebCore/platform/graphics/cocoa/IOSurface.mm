// 10.9 backport: minimal but functional IOSurface wrapper. Modern WebKit's
// version is heavily integrated with newer IOKit features (volatility,
// EDR/HDR, lossless compression, sharing primitives) that don't all exist on
// 10.9. We implement just enough for layer backing-store allocation +
// CGBitmapContext wrapping so the compositor pipeline can paint into surfaces.
#include "config.h"
#include "IOSurface.h"

#import "ColorSpaceCG.h"
#import "DestinationColorSpace.h"
#import "GraphicsContextCG.h"
#import "IOSurfacePool.h"
#import "PlatformScreen.h"
#import <CoreGraphics/CoreGraphics.h>
#import <wtf/FastMalloc.h>
#import <wtf/MachSendRight.h>
#import <wtf/RetainPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/spi/cocoa/IOSurfaceSPI.h>

namespace WebCore {

std::optional<IntSize> IOSurface::s_maximumSize;

IntSize IOSurface::maximumSize()
{
    if (s_maximumSize)
        return *s_maximumSize;
    return IntSize(8192, 8192);
}

void IOSurface::setMaximumSize(IntSize size)
{
    s_maximumSize = size;
}

size_t IOSurface::bytesPerRowAlignment()
{
    return 16;
}

void IOSurface::setBytesPerRowAlignment(size_t)
{
}

static unsigned bytesPerPixelForFormat(IOSurface::Format format)
{
    switch (format) {
    case IOSurface::Format::BGRA:
    case IOSurface::Format::BGRX:
    case IOSurface::Format::RGBA:
    case IOSurface::Format::RGBX:
        return 4;
    case IOSurface::Format::YUV422:
        return 2;
#if ENABLE(PIXEL_FORMAT_RGB10)
    case IOSurface::Format::RGB10:
        return 4;
#endif
#if ENABLE(PIXEL_FORMAT_RGB10A8)
    case IOSurface::Format::RGB10A8:
        return 5;
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    case IOSurface::Format::RGBA16F:
        return 8;
#endif
    }
    return 4;
}

static OSType pixelFormatTypeForFormat(IOSurface::Format format)
{
    switch (format) {
    case IOSurface::Format::BGRA:
    case IOSurface::Format::BGRX:
        return 'BGRA';
    case IOSurface::Format::RGBA:
    case IOSurface::Format::RGBX:
        return 'RGBA';
    case IOSurface::Format::YUV422:
        return '2vuy';
    default:
        return 'BGRA';
    }
}

IOSurface::IOSurface(IntSize size, const DestinationColorSpace& colorSpace, Name name, Format format, UseLosslessCompression, bool& success)
    : m_colorSpace(colorSpace)
    , m_size(size)
    , m_name(name)
{
    success = false;
    if (size.isEmpty())
        return;

    unsigned bpp = bytesPerPixelForFormat(format);
    size_t alignedBytesPerRow = (size.width() * bpp + bytesPerRowAlignment() - 1) & ~(bytesPerRowAlignment() - 1);
    m_totalBytes = alignedBytesPerRow * size.height();

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
    if (!m_surface)
        return;

    m_format = UsedFormat { format, UseLosslessCompression::No };
    success = true;
}

IOSurface::IOSurface(IOSurfaceRef surface, std::optional<DestinationColorSpace>&& colorSpace)
    : m_colorSpace(WTF::move(colorSpace))
    , m_size(IntSize(IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface)))
    , m_totalBytes(IOSurfaceGetAllocSize(surface))
    , m_surface(surface)
    , m_name(Name::Default)
{
}

IOSurface::~IOSurface() = default;

std::unique_ptr<IOSurface> IOSurface::create(IOSurfacePool*, IntSize size, const DestinationColorSpace& colorSpace, Name name, Format format, UseLosslessCompression compression)
{
    bool success = false;
    auto surface = std::unique_ptr<IOSurface>(new IOSurface(size, colorSpace, name, format, compression, success));
    if (!success)
        return nullptr;
    return surface;
}

std::unique_ptr<IOSurface> IOSurface::createFromSendRight(const WTF::MachSendRight&& sendRight)
{
    auto surfaceRef = adoptCF(IOSurfaceLookupFromMachPort(sendRight.sendRight()));
    if (!surfaceRef)
        return nullptr;
    return createFromSurface(surfaceRef.get(), std::nullopt);
}

std::unique_ptr<IOSurface> IOSurface::createFromSurface(IOSurfaceRef surface, std::optional<DestinationColorSpace>&& colorSpace)
{
    if (!surface)
        return nullptr;
    return std::unique_ptr<IOSurface>(new IOSurface(surface, WTF::move(colorSpace)));
}

// 10.9 backport: createFromImage was dropped from this tree but is still called by
// WebViewImpl (swipe-navigation snapshots) and RemoteMediaPlayerProxy. Recreate the
// upstream behavior: allocate an sRGB IOSurface the size of the image and paint the
// CGImage into it through the surface's CG context.
std::unique_ptr<IOSurface> IOSurface::createFromImage(IOSurfacePool* pool, CGImageRef image)
{
    if (!image)
        return nullptr;

    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (!width || !height)
        return nullptr;

    auto surface = IOSurface::create(pool, IntSize(static_cast<int>(width), static_cast<int>(height)), DestinationColorSpace::SRGB());
    if (!surface)
        return nullptr;

    auto surfaceContext = surface->createPlatformContext();
    if (!surfaceContext)
        return nullptr;

    CGContextDrawImage(surfaceContext.get(), CGRectMake(0, 0, width, height), image);
    CGContextFlush(surfaceContext.get());

    return surface;
}

void IOSurface::moveToPool(std::unique_ptr<IOSurface>&&, IOSurfacePool*)
{
}

WTF::MachSendRight IOSurface::createSendRight() const
{
    if (!m_surface)
        return { };
    mach_port_t p = IOSurfaceCreateMachPort(m_surface.get());
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[IOSurface::createSendRight] surface=%p port=0x%x\n", m_surface.get(), (unsigned)p); fclose(_d);}}
    return WTF::MachSendRight::adopt(p);
}

// 10.9 backport: override the libpolyfill.a stub for IOSurface::createImage. The polyfill stub
// calls CGIOSurfaceContextCreateImage, which fails ("invalid context ... serious error") on the
// CGBitmapContext returned by createPlatformContext below — every page paint logged the spam, and
// the returned CGImageRef was null so consumers got blank images. Use CGBitmapContextCreateImage
// which works on bitmap contexts (createPlatformContext is the only producer of these contexts).
RetainPtr<CGImageRef> IOSurface::createImage(CGContextRef ctx)
{
    if (ctx)
        return adoptCF(CGBitmapContextCreateImage(ctx));
    return { };
}

RetainPtr<CGContextRef> IOSurface::createPlatformContext(PlatformDisplayID, std::optional<CGImageAlphaInfo>)
{
    if (!m_surface)
        return nullptr;
    if (IOSurfaceLock(m_surface.get(), 0, nullptr) != kIOReturnSuccess)
        return nullptr;
    void* base = IOSurfaceGetBaseAddress(m_surface.get());
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(m_surface.get());
    auto cs = m_colorSpace.value_or(DestinationColorSpace::SRGB());
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
    IOSurfaceRef surfaceForCallback = m_surface.get();
    CFRetain(surfaceForCallback);
    auto context = adoptCF(CGBitmapContextCreateWithData(base, m_size.width(), m_size.height(), 8, bytesPerRow, cs.platformColorSpace(), bitmapInfo, [](void* info, void*) {
        auto* s = static_cast<IOSurfaceRef>(info);
        IOSurfaceUnlock(s, 0, nullptr);
        CFRelease(s);
    }, surfaceForCallback));
    if (!context) {
        IOSurfaceUnlock(surfaceForCallback, 0, nullptr);
        CFRelease(surfaceForCallback);
        return nullptr;
    }
    return context;
}

DestinationColorSpace IOSurface::colorSpace()
{
    return m_colorSpace.value_or(DestinationColorSpace::SRGB());
}

IOSurfaceID IOSurface::surfaceID() const
{
    return m_surface ? IOSurfaceGetID(m_surface.get()) : 0;
}

size_t IOSurface::bytesPerRow() const
{
    return m_surface ? IOSurfaceGetBytesPerRow(m_surface.get()) : 0;
}

IOSurfaceSeed IOSurface::seed() const
{
    return m_surface ? IOSurfaceGetSeed(m_surface.get()) : 0;
}

bool IOSurface::isInUse() const
{
    return m_surface ? IOSurfaceIsInUse(m_surface.get()) : false;
}

bool IOSurface::isVolatile() const
{
    return false;
}

SetNonVolatileResult IOSurface::setVolatile(bool)
{
    return static_cast<SetNonVolatileResult>(0);
}

SetNonVolatileResult IOSurface::state() const
{
    return static_cast<SetNonVolatileResult>(0);
}

void IOSurface::setOwnershipIdentity(const ProcessIdentity&)
{
}

void IOSurface::setOwnershipIdentity(IOSurfaceRef, const ProcessIdentity&)
{
}

IOSurface::Name IOSurface::nameForRenderingPurpose(RenderingPurpose)
{
    return Name::Default;
}

RetainPtr<id> IOSurface::asCAIOSurfaceLayerContents() const
{
#ifdef __OBJC__
    if (!m_surface)
        return nullptr;
    // 10.9 backport: CALayer.contents = IOSurface is unreliable on Mavericks. Snapshot
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
    // 10.9 backport: cs.platformColorSpace() can return NULL on Mavericks (CG fails to
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
