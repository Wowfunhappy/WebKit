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

// IOMainPort (the macOS 12.0 rename of IOMasterPort) has no 10.9 runtime symbol; forward to
// IOMasterPort, which 10.9 ships. Both are declared in the 26.1 SDK's IOKitLib.h, so WebCore can call
// the upstream IOMainPort name unchanged (platform/graphics/mac/GraphicsChecksMac.cpp).
#include <IOKit/IOKitLib.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
kern_return_t IOMainPort(mach_port_t bootstrapPort, mach_port_t *mainPort) {
    return IOMasterPort(bootstrapPort, mainPort);
}
#pragma clang diagnostic pop

// Additional newer-OS C entry points absent at RUNTIME on 10.9, reached by unmodified upstream
// WebCore call sites. Each is declared either by WebKit's own PAL SPI header (the CG/CT ones) or by
// the 26.1 SDK (SQLite/Security); here we supply the missing definition via the classic 10.9 API so
// the upstream source links and runs (and its in-tree 10.9 workaround reverts to upstream).
#include <CoreText/CoreText.h>
#include <Security/Security.h>
#include <sqlite3.h>

// CTFontCreateForCharactersWithLanguage is itself CoreText SPI (declared in WebKit's PAL
// CoreTextSPI.h, not the public SDK headers); forward-declare it so the forwarding impl below compiles.
extern CTFontRef CTFontCreateForCharactersWithLanguage(CTFontRef currentFont, const UTF16Char *characters, CFIndex length, CFStringRef language, CFIndex *coveredLength);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// CGContextDrawPathDirect (10.13+): add the path and draw it (upstream passes a null bounding box).
void CGContextDrawPathDirect(CGContextRef context, CGPathDrawingMode mode, CGPathRef path, const CGRect *) {
    CGContextAddPath(context, path);
    CGContextDrawPath(context, mode);
}

// CGGradientCreateWithColorComponentsAndOptions (10.12+): the options dictionary only selects
// premultiplied-alpha interpolation (a nicety for stops fading to transparency). The classic
// CGGradientCreateWithColorComponents, which 10.9 does export, is identical for opaque stops.
CGGradientRef CGGradientCreateWithColorComponentsAndOptions(CGColorSpaceRef space, const CGFloat *components, const CGFloat *locations, size_t count, CFDictionaryRef) {
    return CGGradientCreateWithColorComponents(space, components, locations, count);
}

// CTFontCreateForCharactersWithLanguageAndOption (10.13+): the option only restricts fallback to
// system (non-user-installed) fonts. The classic CTFontCreateForCharactersWithLanguage returns the
// same fallback font on 10.9 and is present there.
CTFontRef CTFontCreateForCharactersWithLanguageAndOption(CTFontRef currentFont, const UTF16Char *characters, CFIndex length, CFStringRef language, unsigned long, CFIndex *coveredLength) {
    return CTFontCreateForCharactersWithLanguage(currentFont, characters, length, language, coveredLength);
}

// sqlite3_bind_blob64 (SQLite 3.8.7 / 10.10+): 10.9 ships SQLite 3.7; forward to sqlite3_bind_blob
// (WebKit blob lengths are always well under INT_MAX).
int sqlite3_bind_blob64(sqlite3_stmt *statement, int index, const void *data, sqlite3_uint64 length, void (*destructor)(void *)) {
    return sqlite3_bind_blob(statement, index, data, (int)length, destructor);
}

// SecTrustCopyCertificateChain lives in const_polyfill.c (the canonical definition — it must be in
// an object that every target's link already pulls, because the callers' references are WEAK
// imports, which do not pull archive members on their own).
#pragma clang diagnostic pop
