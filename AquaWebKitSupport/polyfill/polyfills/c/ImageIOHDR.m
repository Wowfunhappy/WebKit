// HDR gain maps use native ColorSync float transforms and Core Image pixel storage/resampling.
#include "wk_polyfill.h"

// These entry points and constants are supplied by this polyfill archive.
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <ImageIO/ImageIO.h>
#include <ColorSync/ColorSync.h>
#include <dlfcn.h>
#include <math.h>
#include <objc/runtime.h>
#include <pthread.h>

extern const CFStringRef kCGImageAuxiliaryDataInfoMetadata;
extern const CFStringRef kCGImageAuxiliaryDataInfoColorSpace;
extern const CFStringRef kCGTargetColorSpace;
extern const CFStringRef kCGTargetHeadroom;
extern const CFStringRef kIOSurfaceContentHeadroom;
extern const CFStringRef kCGTargetPixelFormat;
extern const CFStringRef kCGFlexRangeAlternateColorSpace;
extern CFPropertyListRef CGColorSpaceCopyPropertyList(CGColorSpaceRef);
extern CGColorSpaceRef CGColorSpaceCreateWithPropertyList(CFPropertyListRef);
extern unsigned wk_colorSpaceTransferFunction(CGColorSpaceRef);

#define WK_CI_PATH "/System/Library/Frameworks/QuartzCore.framework/Frameworks/CoreImage.framework/CoreImage"
WK_SYSTEM_CONST(WK_CI_PATH, NSString*, kCIImageColorSpace);
WK_SYSTEM_CONST(WK_CI_PATH, NSString*, kCIContextUseSoftwareRenderer);
WK_SYSTEM_CONST(WK_CI_PATH, NSString*, kCIContextWorkingColorSpace);
WK_SYSTEM_CONST(WK_CI_PATH, int, kCIFormatRGBAf);
WK_SYSTEM_CONST(WK_CI_PATH, int, kCIFormatRGBAh);
WK_SYSTEM_CONST(WK_CI_PATH, int, kCIFormatBGRA8);
WK_SYSTEM_CONST(WK_CI_PATH, int, kCIFormatARGB8);
WK_SYSTEM_CONST(WK_CI_PATH, int, kCIFormatRGBA8);
WK_SYSTEM_CONST(WK_CI_PATH, int, kCIFormatL8);

WK_SYSTEM_FN("IOSurface", size_t, IOSurfaceGetWidth, (IOSurfaceRef));
WK_SYSTEM_FN("IOSurface", size_t, IOSurfaceGetHeight, (IOSurfaceRef));
WK_SYSTEM_FN("IOSurface", CFTypeRef, IOSurfaceCopyValue, (IOSurfaceRef, CFStringRef));
WK_SYSTEM_FN("IOSurface", void, IOSurfaceSetValue, (IOSurfaceRef, CFStringRef, CFTypeRef));
WK_SYSTEM_CONST("IOSurface", CFStringRef, kIOSurfaceColorSpace);
WK_SYSTEM_CONST("IOSurface", CFStringRef, kIOSurfaceICCProfile);

@protocol WKNativeHDRImage
+ (id)imageWithIOSurface:(IOSurfaceRef)surface options:(NSDictionary*)options;
+ (id)imageWithCVImageBuffer:(CVImageBufferRef)buffer options:(NSDictionary*)options;
+ (id)imageWithBitmapData:(NSData*)data bytesPerRow:(size_t)stride size:(CGSize)size format:(int)format colorSpace:(CGColorSpaceRef)space;
- (id)imageByApplyingTransform:(CGAffineTransform)transform;
@end
@protocol WKNativeHDRFilter
+ (id)filterWithName:(NSString*)name;
@end
@protocol WKNativeHDRContext
+ (id)contextWithOptions:(NSDictionary*)options;
- (void)render:(id)image toBitmap:(void*)data rowBytes:(ptrdiff_t)stride bounds:(CGRect)bounds format:(int)format colorSpace:(CGColorSpaceRef)space;
- (void)render:(id)image toIOSurface:(IOSurfaceRef)surface bounds:(CGRect)bounds colorSpace:(CGColorSpaceRef)space;
- (CGImageRef)createCGImage:(id)image fromRect:(CGRect)bounds format:(int)format colorSpace:(CGColorSpaceRef)space;
@end

static void wk_loadHDRCoreImage(void)
{
    dlopen(WK_CI_PATH, RTLD_LAZY | RTLD_LOCAL);
}

static id<WKNativeHDRContext> wk_hdrContext(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_loadHDRCoreImage);
    return [(Class<WKNativeHDRContext>)objc_getClass("CIContext") contextWithOptions:@{
        WK_SYSTEM(kCIContextUseSoftwareRenderer): @YES,
        WK_SYSTEM(kCIContextWorkingColorSpace): [NSNull null]
    }];
}

static CFTypeRef wk_copyGainMapValue(CGImageMetadataRef metadata, CFStringRef namespaceURI, CFStringRef name)
{
    CFArrayRef tags = metadata ? CGImageMetadataCopyTags(metadata) : NULL;
    if (!tags)
        return NULL;
    CFTypeRef result = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(tags); ++i) {
        CGImageMetadataTagRef tag = (CGImageMetadataTagRef)CFArrayGetValueAtIndex(tags, i);
        CFStringRef uri = CGImageMetadataTagCopyNamespace(tag);
        CFStringRef tagName = CGImageMetadataTagCopyName(tag);
        if (uri && tagName && CFEqual(uri, namespaceURI) && CFEqual(tagName, name))
            result = CGImageMetadataTagCopyValue(tag) ?: CFRetain(kCFNull);
        if (uri)
            CFRelease(uri);
        if (tagName)
            CFRelease(tagName);
        if (result)
            break;
    }
    CFRelease(tags);
    return result;
}

static bool wk_hdrNumber(CFTypeRef value, double *number)
{
    if (!value)
        return false;
    double parsed;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        if (!CFNumberGetValue(value, kCFNumberDoubleType, &parsed) || !isfinite(parsed))
            return false;
    } else {
        if (CFGetTypeID(value) != CFStringGetTypeID())
            return false;
        char text[128];
        if (!CFStringGetCString(value, text, sizeof(text), kCFStringEncodingASCII))
            return false;
        char *end;
        parsed = strtod(text, &end);
        if (end == text)
            return false;
        while (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r')
            ++end;
        if (*end || !isfinite(parsed))
            return false;
    }
    *number = parsed;
    return true;
}

// Zero means absent, one means valid, and minus one means a malformed supplied property.
static int wk_gainMapNumbers(CGImageMetadataRef metadata, CFStringRef uri, CFStringRef name, double values[3])
{
    CFTypeRef value = wk_copyGainMapValue(metadata, uri, name);
    if (!value)
        return 0;
    double parsed[3];
    bool success;
    if (CFGetTypeID(value) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        success = count == 1 || count == 3;
        for (unsigned i = 0; success && i < 3; ++i) {
            CFTypeRef item = CFArrayGetValueAtIndex(value, count == 1 ? 0 : i);
            CFTypeRef tagValue = CFGetTypeID(item) == CGImageMetadataTagGetTypeID()
                ? CGImageMetadataTagCopyValue((CGImageMetadataTagRef)item) : NULL;
            success = wk_hdrNumber(tagValue ?: item, parsed + i);
            if (tagValue)
                CFRelease(tagValue);
        }
    } else {
        success = wk_hdrNumber(value, parsed);
        if (success)
            parsed[1] = parsed[2] = parsed[0];
    }
    CFRelease(value);
    if (!success)
        return -1;
    memcpy(values, parsed, sizeof(parsed));
    return 1;
}

static int wk_gainMapNumber(CGImageMetadataRef metadata, CFStringRef uri, CFStringRef name, double *number)
{
    CFTypeRef value = wk_copyGainMapValue(metadata, uri, name);
    if (!value)
        return 0;
    bool success = wk_hdrNumber(value, number);
    CFRelease(value);
    return success ? 1 : -1;
}

struct wk_gainMapParameters {
    bool apple;
    bool baseHDR;
    double headroom[2];
    double minimum[3], maximum[3], gamma[3], offsetSDR[3], offsetHDR[3];
};

static bool wk_gainMapParameters(CGImageMetadataRef metadata, struct wk_gainMapParameters *parameters)
{
    static const CFStringRef appleURI = CFSTR("http://ns.apple.com/HDRGainMap/1.0/");
    static const CFStringRef adobeURI = CFSTR("http://ns.adobe.com/hdr-gain-map/1.0/");
    memset(parameters, 0, sizeof(*parameters));
    CFTypeRef version = wk_copyGainMapValue(metadata, adobeURI, CFSTR("Version"));
    if (version) {
        bool supported = CFGetTypeID(version) == CFStringGetTypeID() && CFEqual(version, CFSTR("1.0"));
        CFRelease(version);
        if (!supported)
            return false;
        for (unsigned i = 0; i < 3; ++i) {
            parameters->gamma[i] = 1;
            parameters->offsetSDR[i] = parameters->offsetHDR[i] = 1.0 / 64;
        }
        if (wk_gainMapNumbers(metadata, adobeURI, CFSTR("GainMapMax"), parameters->maximum) != 1
            || wk_gainMapNumbers(metadata, adobeURI, CFSTR("GainMapMin"), parameters->minimum) < 0
            || wk_gainMapNumbers(metadata, adobeURI, CFSTR("Gamma"), parameters->gamma) < 0
            || wk_gainMapNumbers(metadata, adobeURI, CFSTR("OffsetSDR"), parameters->offsetSDR) < 0
            || wk_gainMapNumbers(metadata, adobeURI, CFSTR("OffsetHDR"), parameters->offsetHDR) < 0)
            return false;
        if (wk_gainMapNumber(metadata, adobeURI, CFSTR("HDRCapacityMin"), parameters->headroom) < 0)
            return false;
        if (wk_gainMapNumber(metadata, adobeURI, CFSTR("HDRCapacityMax"), parameters->headroom + 1) != 1)
            return false;
        CFTypeRef baseHDR = wk_copyGainMapValue(metadata, adobeURI, CFSTR("BaseRenditionIsHDR"));
        if (baseHDR) {
            bool isTrue = CFEqual(baseHDR, CFSTR("True")) || CFEqual(baseHDR, kCFBooleanTrue);
            bool isFalse = CFEqual(baseHDR, CFSTR("False")) || CFEqual(baseHDR, kCFBooleanFalse);
            CFRelease(baseHDR);
            if (!isTrue && !isFalse)
                return false;
            parameters->baseHDR = isTrue;
        }
        if (parameters->headroom[0] < 0 || parameters->headroom[1] <= parameters->headroom[0]
            || !isfinite(exp2(parameters->headroom[1])))
            return false;
        for (unsigned i = 0; i < 3; ++i) {
            if (parameters->gamma[i] <= 0 || parameters->maximum[i] < parameters->minimum[i]
                || parameters->offsetSDR[i] < 0 || parameters->offsetHDR[i] < 0
                || !isfinite(exp2(parameters->maximum[i])))
                return false;
        }
        return true;
    }
    version = wk_copyGainMapValue(metadata, appleURI, CFSTR("HDRGainMapVersion"));
    if (!version)
        return false;
    CFRelease(version);
    double headroom;
    if (wk_gainMapNumber(metadata, appleURI, CFSTR("HDRGainMapHeadroom"), &headroom) != 1 || headroom < 1)
        return false;
    parameters->apple = true;
    parameters->headroom[1] = log2(headroom);
    return true;
}

WK_POLYFILL_ABSENT("ImageIO", CGFloat, CGImageGetHDRGainMapHeadroom, (CGImageMetadataRef metadata, CFDictionaryRef options))
{
    (void)options;
    struct wk_gainMapParameters parameters;
    return wk_gainMapParameters(metadata, &parameters) ? exp2(parameters.headroom[1]) : 1;
}

static CGColorSpaceRef wk_copyHDRColorSpace(CFTypeRef value)
{
    if (!value)
        return NULL;
    if (CFGetTypeID(value) == CGColorSpaceGetTypeID())
        return CGColorSpaceRetain((CGColorSpaceRef)value);
    if (CFGetTypeID(value) == CFStringGetTypeID())
        return CGColorSpaceCreateWithName(value);
    return NULL;
}

WK_POLYFILL_ABSENT("ImageIO", OSStatus, CGImageCreatePixelBufferAttributesForHDRTarget, (uint32_t target, CFDictionaryRef attributes, CFDictionaryRef options, CFDictionaryRef *output))
{
    if (!output)
        return -50;
    *output = NULL;
    if (!attributes || target < 1 || target > 3)
        return -50;
    CFMutableDictionaryRef result = CFDictionaryCreateMutableCopy(NULL, 0, attributes);
    if (!result)
        return -108;
    CFTypeRef format = options ? CFDictionaryGetValue(options, kCGTargetPixelFormat) : NULL;
    uint32_t defaultFormat = target == 1 ? kCVPixelFormatType_32BGRA : target == 2 ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_OneComponent8;
    CFNumberRef formatNumber = format && CFGetTypeID(format) == CFNumberGetTypeID()
        ? CFRetain(format) : CFNumberCreate(NULL, kCFNumberSInt32Type, &defaultFormat);
    CFDictionarySetValue(result, kCVPixelBufferPixelFormatTypeKey, formatNumber);
    CFRelease(formatNumber);
    CGColorSpaceRef space = wk_copyHDRColorSpace(options ? CFDictionaryGetValue(options, kCGTargetColorSpace) : NULL);
    if (!space && target == 2)
        space = wk_copyHDRColorSpace(options ? CFDictionaryGetValue(options, kCGFlexRangeAlternateColorSpace) : NULL);
    if (!space)
        space = CGColorSpaceCreateWithName(target == 2 ? CFSTR("kCGColorSpaceExtendedLinearSRGB") : kCGColorSpaceSRGB);
    if (!space) {
        CFRelease(result);
        return -50;
    }
    CFDictionarySetValue(result, kCVImageBufferCGColorSpaceKey, space);
    CGColorSpaceRelease(space);
    *output = result;
    return 0;
}

static id wk_gainMapImage(CVPixelBufferRef, id);

WK_POLYFILL_ABSENT("ImageIO", CGImageRef, CGImageCreateFromIOSurface, (IOSurfaceRef surface, CFDictionaryRef options))
{
    if (!surface)
        return NULL;
    @autoreleasepool {
        id<WKNativeHDRContext> context = wk_hdrContext();
        CGColorSpaceRef space = wk_copyHDRColorSpace(options ? CFDictionaryGetValue(options, kCGTargetColorSpace) : NULL);
        if (!space) {
            CFTypeRef properties = WK_SYSTEM(IOSurfaceCopyValue)(surface, WK_SYSTEM(kIOSurfaceColorSpace));
            if (properties) {
                space = CGColorSpaceCreateWithPropertyList(properties);
                CFRelease(properties);
            }
        }
        if (!space) {
            CFTypeRef profile = WK_SYSTEM(IOSurfaceCopyValue)(surface, WK_SYSTEM(kIOSurfaceICCProfile));
            if (profile) {
                if (CFGetTypeID(profile) == CFDataGetTypeID())
                    space = CGColorSpaceCreateWithICCProfile(profile);
                CFRelease(profile);
            }
        }
        if (!space)
            space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CVPixelBufferRef buffer = NULL;
        if (!context || CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &buffer)) {
            CGColorSpaceRelease(space);
            return NULL;
        }
        id image = wk_gainMapImage(buffer, (id)space);
        CGImageRef result = image ? [context createCGImage:image fromRect:CGRectMake(0, 0, WK_SYSTEM(IOSurfaceGetWidth)(surface), WK_SYSTEM(IOSurfaceGetHeight)(surface)) format:WK_SYSTEM(kCIFormatRGBAf) colorSpace:space] : NULL;
        CFRelease(buffer);
        CGColorSpaceRelease(space);
        return result;
    }
}

static CGColorSpaceRef wk_createLinearGainMapSpace(CGColorSpaceRef space)
{
    if (!space || CGColorSpaceGetModel(space) != kCGColorSpaceModelRGB)
        return NULL;
    CGColorSpaceRef xyz = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceGenericXYZ"));
    float primaries[16] = { 0 };
    CGContextRef context = CGBitmapContextCreate(primaries, 4, 1, 32, sizeof(primaries), xyz,
        kCGBitmapFloatComponents | kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(xyz);
    if (!context)
        return NULL;
    CGContextSetRenderingIntent(context, kCGRenderingIntentRelativeColorimetric);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    for (unsigned i = 0; i < 4; ++i) {
        CGFloat rgba[] = { i == 0, i == 1, i == 2, 1 };
        CGColorRef primary = CGColorCreate(space, rgba);
        CGContextSetFillColorWithColor(context, primary);
        CGContextFillRect(context, CGRectMake(i, 0, 1, 1));
        CGColorRelease(primary);
    }
    CGContextRelease(context);
    double m[9];
    for (unsigned row = 0; row < 3; ++row) {
        for (unsigned column = 0; column < 3; ++column)
            m[3 * row + column] = primaries[4 * column + row] - primaries[12 + row];
    }
    double inverse[] = {
        m[4]*m[8]-m[5]*m[7], m[2]*m[7]-m[1]*m[8], m[1]*m[5]-m[2]*m[4],
        m[5]*m[6]-m[3]*m[8], m[0]*m[8]-m[2]*m[6], m[2]*m[3]-m[0]*m[5],
        m[3]*m[7]-m[4]*m[6], m[1]*m[6]-m[0]*m[7], m[0]*m[4]-m[1]*m[3]
    };
    double determinant = m[0]*inverse[0]+m[1]*inverse[3]+m[2]*inverse[6];
    if (!isfinite(determinant) || determinant == 0)
        return NULL;
    const CGFloat white[] = { .9642, 1, .8249 }, gamma[] = { 1, 1, 1 };
    CGFloat matrix[9];
    for (unsigned column = 0; column < 3; ++column) {
        double scale = (inverse[3 * column] * white[0] + inverse[3 * column + 1] * white[1] + inverse[3 * column + 2] * white[2]) / determinant;
        for (unsigned row = 0; row < 3; ++row)
            matrix[3 * column + row] = m[3 * row + column] * scale;
    }
    return CGColorSpaceCreateCalibratedRGB(white, NULL, gamma, matrix);
}

static int wk_ciFormat(OSType format)
{
    switch (format) {
    case kCVPixelFormatType_32BGRA: return WK_SYSTEM(kCIFormatBGRA8);
    case kCVPixelFormatType_32ARGB: return WK_SYSTEM(kCIFormatARGB8);
    case kCVPixelFormatType_32RGBA: return WK_SYSTEM(kCIFormatRGBA8);
    case kCVPixelFormatType_64RGBAHalf: return WK_SYSTEM(kCIFormatRGBAh);
    case kCVPixelFormatType_128RGBAFloat: return WK_SYSTEM(kCIFormatRGBAf);
    case kCVPixelFormatType_OneComponent8: return WK_SYSTEM(kCIFormatL8);
    default: return 0;
    }
}

static id wk_gainMapImage(CVPixelBufferRef buffer, id colorSpace)
{
    Class<WKNativeHDRImage> imageClass = (Class<WKNativeHDRImage>)objc_getClass("CIImage");
    int format = wk_ciFormat(CVPixelBufferGetPixelFormatType(buffer));
    if (!format)
        return [imageClass imageWithCVImageBuffer:buffer options:@{ WK_SYSTEM(kCIImageColorSpace): colorSpace }];
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly))
        return nil;
    size_t stride = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer);
    NSData *data = [NSData dataWithBytes:CVPixelBufferGetBaseAddress(buffer) length:stride * height];
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return [imageClass imageWithBitmapData:data bytesPerRow:stride size:CGSizeMake(CVPixelBufferGetWidth(buffer), height)
        format:format colorSpace:colorSpace == [NSNull null] ? NULL : (CGColorSpaceRef)colorSpace];
}

#define WK_COLORSYNC_PATH "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/ColorSync.framework/ColorSync"
WK_SYSTEM_FN(WK_COLORSYNC_PATH, CFTypeRef, ColorSyncProfileCreate, (CFDataRef, CFErrorRef*));
WK_SYSTEM_FN(WK_COLORSYNC_PATH, CFTypeRef, ColorSyncTransformCreate, (CFArrayRef, CFDictionaryRef));
WK_SYSTEM_FN(WK_COLORSYNC_PATH, bool, ColorSyncTransformConvert, (CFTypeRef, size_t, size_t, void*, unsigned, uint32_t, size_t, const void*, unsigned, uint32_t, size_t, CFDictionaryRef));
WK_SYSTEM_CONST(WK_COLORSYNC_PATH, CFStringRef, kColorSyncProfile);
WK_SYSTEM_CONST(WK_COLORSYNC_PATH, CFStringRef, kColorSyncRenderingIntent);
WK_SYSTEM_CONST(WK_COLORSYNC_PATH, CFStringRef, kColorSyncRenderingIntentRelative);
WK_SYSTEM_CONST(WK_COLORSYNC_PATH, CFStringRef, kColorSyncTransformTag);
WK_SYSTEM_CONST(WK_COLORSYNC_PATH, CFStringRef, kColorSyncTransformDeviceToPCS);
WK_SYSTEM_CONST(WK_COLORSYNC_PATH, CFStringRef, kColorSyncTransformPCSToDevice);

static bool wk_convertHDRPixels(CGColorSpaceRef source, CGColorSpaceRef destination, float *pixels, size_t width, size_t height)
{
    CFDataRef sourceData = CGColorSpaceCopyICCProfile(source), destinationData = CGColorSpaceCopyICCProfile(destination);
    CFTypeRef sourceProfile = sourceData ? WK_SYSTEM(ColorSyncProfileCreate)(sourceData, NULL) : NULL;
    CFTypeRef destinationProfile = destinationData ? WK_SYSTEM(ColorSyncProfileCreate)(destinationData, NULL) : NULL;
    if (sourceData)
        CFRelease(sourceData);
    if (destinationData)
        CFRelease(destinationData);
    CFTypeRef transform = NULL;
    if (sourceProfile && destinationProfile) {
        NSArray *sequence = @[
            @{ (id)WK_SYSTEM(kColorSyncProfile): (id)sourceProfile,
               (id)WK_SYSTEM(kColorSyncRenderingIntent): (id)WK_SYSTEM(kColorSyncRenderingIntentRelative),
               (id)WK_SYSTEM(kColorSyncTransformTag): (id)WK_SYSTEM(kColorSyncTransformDeviceToPCS) },
            @{ (id)WK_SYSTEM(kColorSyncProfile): (id)destinationProfile,
               (id)WK_SYSTEM(kColorSyncRenderingIntent): (id)WK_SYSTEM(kColorSyncRenderingIntentRelative),
               (id)WK_SYSTEM(kColorSyncTransformTag): (id)WK_SYSTEM(kColorSyncTransformPCSToDevice) }
        ];
        transform = WK_SYSTEM(ColorSyncTransformCreate)((CFArrayRef)sequence, NULL);
    }
    if (sourceProfile)
        CFRelease(sourceProfile);
    if (destinationProfile)
        CFRelease(destinationProfile);
    if (!transform)
        return false;
    size_t stride = width * 4 * sizeof(float);
    float *row = malloc(stride);
    bool success = row != NULL;
    for (size_t y = 0; success && y < height; ++y) {
        success = WK_SYSTEM(ColorSyncTransformConvert)(transform, width, 1, row, kColorSync32BitFloat, kColorSyncByteOrder32Little | kColorSyncAlphaPremultipliedLast, stride,
            pixels + 4 * width * y, kColorSync32BitFloat, kColorSyncByteOrder32Little | kColorSyncAlphaPremultipliedLast, stride, NULL);
        if (success)
            memcpy(pixels + 4 * width * y, row, stride);
    }
    free(row);
    CFRelease(transform);
    return success;
}

static bool wk_hdrReferenceWhite(CGColorSpaceRef space, CGColorSpaceRef linear, double *white)
{
    unsigned transfer = wk_colorSpaceTransferFunction(space);
    *white = 1;
    if (transfer != 16 && transfer != 18)
        return true;
    // ISO HDR reference white is 203 cd/m^2 in PQ and a 75% HLG signal.
    float encoded = transfer == 16 ? .5806888810416109f : .75f;
    float pixel[] = { encoded, encoded, encoded, 1 };
    if (!wk_convertHDRPixels(space, linear, pixel, 1, 1))
        return false;
    *white = (pixel[0] + pixel[1] + pixel[2]) / 3.0;
    return isfinite(*white) && *white > 0;
}

WK_POLYFILL_ABSENT("ImageIO", OSStatus, CGImageApplyHDRGainMap, (CVPixelBufferRef input, CVPixelBufferRef gainMap, CVPixelBufferRef output, CFDictionaryRef options))
{
    if (!input || !gainMap || !output || !options)
        return -50;
    struct wk_gainMapParameters parameters;
    if (!wk_gainMapParameters((CGImageMetadataRef)CFDictionaryGetValue(options, kCGImageAuxiliaryDataInfoMetadata), &parameters))
        return -50;
    size_t width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input);
    size_t gainWidth = CVPixelBufferGetWidth(gainMap), gainHeight = CVPixelBufferGetHeight(gainMap);
    if (!width || !height || !gainWidth || !gainHeight || width != CVPixelBufferGetWidth(output) || height != CVPixelBufferGetHeight(output)
        || width > SIZE_MAX / (4 * sizeof(float)) || height > SIZE_MAX / (width * 4 * sizeof(float)))
        return -50;
    @autoreleasepool {
        id<WKNativeHDRContext> rawContext = wk_hdrContext();
        if (!rawContext)
            return -108;
        int outputFormat = wk_ciFormat(CVPixelBufferGetPixelFormatType(output));
        if (!outputFormat)
            return kCVReturnInvalidPixelFormat;
        CGColorSpaceRef sourceSpace = wk_copyHDRColorSpace(CVBufferGetAttachment(input, kCVImageBufferCGColorSpaceKey, NULL));
        if (!sourceSpace)
            sourceSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGColorSpaceRef mathSpace = wk_copyHDRColorSpace(CFDictionaryGetValue(options, kCGImageAuxiliaryDataInfoColorSpace));
        if (!mathSpace)
            mathSpace = CGColorSpaceRetain(sourceSpace);
        CGColorSpaceRef linear = wk_createLinearGainMapSpace(mathSpace);
        CGColorSpaceRelease(mathSpace);
        CGColorSpaceRef destination = wk_copyHDRColorSpace(CVBufferGetAttachment(output, kCVImageBufferCGColorSpaceKey, NULL));
        if (!destination && linear)
            destination = CGColorSpaceRetain(linear);
        if (!linear || !destination) {
            CGColorSpaceRelease(sourceSpace);
            if (linear)
                CGColorSpaceRelease(linear);
            if (destination)
                CGColorSpaceRelease(destination);
            return -50;
        }
        size_t stride = width * 4 * sizeof(float), length = stride * height;
        NSMutableData *pixels = [NSMutableData dataWithLength:length];
        NSMutableData *gains = [NSMutableData dataWithLength:length];
        Class<WKNativeHDRImage> imageClass = (Class<WKNativeHDRImage>)objc_getClass("CIImage");
        id image = wk_gainMapImage(input, [NSNull null]);
        id<WKNativeHDRImage> gain = wk_gainMapImage(gainMap, [NSNull null]);
        id clamp = [(Class<WKNativeHDRFilter>)objc_getClass("CIFilter") filterWithName:@"CIAffineClamp"];
        [clamp setValue:gain forKey:@"inputImage"];
        [clamp setValue:[NSAffineTransform transform] forKey:@"inputTransform"];
        gain = [clamp valueForKey:@"outputImage"];
        gain = [gain imageByApplyingTransform:CGAffineTransformMakeScale((double)width / gainWidth, (double)height / gainHeight)];
        if (!image || !gain) {
            CGColorSpaceRelease(destination);
            CGColorSpaceRelease(linear);
            CGColorSpaceRelease(sourceSpace);
            return kCVReturnInvalidPixelFormat;
        }
        CGRect bounds = CGRectMake(0, 0, width, height);
        [rawContext render:image toBitmap:[pixels mutableBytes] rowBytes:stride bounds:bounds format:WK_SYSTEM(kCIFormatRGBAf) colorSpace:NULL];
        if (!wk_convertHDRPixels(sourceSpace, linear, [pixels mutableBytes], width, height)) {
            CGColorSpaceRelease(destination);
            CGColorSpaceRelease(linear);
            CGColorSpaceRelease(sourceSpace);
            return -50;
        }
        [rawContext render:gain toBitmap:[gains mutableBytes] rowBytes:stride bounds:bounds format:WK_SYSTEM(kCIFormatRGBAf) colorSpace:NULL];
        double headroom = exp2(parameters.headroom[1]);
        wk_hdrNumber(CVBufferGetAttachment(output, kIOSurfaceContentHeadroom, NULL), &headroom);
        wk_hdrNumber(CFDictionaryGetValue(options, kCGTargetHeadroom), &headroom);
        if (headroom < 1)
            headroom = 1;
        double weight = parameters.headroom[1] > parameters.headroom[0]
            ? fmin(1, fmax(0, (log2(headroom) - parameters.headroom[0]) / (parameters.headroom[1] - parameters.headroom[0]))) : 0;
        if (parameters.baseHDR)
            weight -= 1;
        double inputWhite, outputScale;
        if (!wk_hdrReferenceWhite(sourceSpace, linear, &inputWhite) || !wk_hdrReferenceWhite(destination, linear, &outputScale)) {
            CGColorSpaceRelease(destination);
            CGColorSpaceRelease(linear);
            CGColorSpaceRelease(sourceSpace);
            return -50;
        }
        double inputScale = 1 / inputWhite;
        float *pixel = [pixels mutableBytes], *map = [gains mutableBytes];
        for (size_t i = 0; i < width * height; ++i) {
            double alpha = pixel[4 * i + 3];
            for (unsigned c = 0; c < 3; ++c) {
                double value = fmin(1, fmax(0, map[4 * i + (parameters.apple ? 0 : c)]));
                double boost;
                if (parameters.apple) {
                    double linearGain = value < .081 ? value / 4.5 : pow((value + .099) / 1.099, 1 / .45);
                    boost = pow(1 + (exp2(parameters.headroom[1]) - 1) * linearGain, weight);
                } else {
                    double logGain = parameters.minimum[c] + (parameters.maximum[c] - parameters.minimum[c]) * pow(value, 1 / parameters.gamma[c]);
                    boost = exp2(logGain * weight);
                }
                double before = parameters.baseHDR ? parameters.offsetHDR[c] : parameters.offsetSDR[c];
                double after = parameters.baseHDR ? parameters.offsetSDR[c] : parameters.offsetHDR[c];
                double base = pixel[4 * i + c] * inputScale;
                pixel[4 * i + c] = outputScale * (weight == 0 ? base : (base + before * alpha) * boost - after * alpha);
            }
        }
        if (!wk_convertHDRPixels(linear, destination, [pixels mutableBytes], width, height)) {
            CGColorSpaceRelease(destination);
            CGColorSpaceRelease(linear);
            CGColorSpaceRelease(sourceSpace);
            return -50;
        }
        id reconstructed = [imageClass imageWithBitmapData:pixels bytesPerRow:stride size:CGSizeMake(width, height) format:WK_SYSTEM(kCIFormatRGBAf) colorSpace:NULL];
        if (!reconstructed) {
            CGColorSpaceRelease(destination);
            CGColorSpaceRelease(linear);
            CGColorSpaceRelease(sourceSpace);
            return -108;
        }
        CVReturn result = CVPixelBufferLockBaseAddress(output, 0);
        if (result == kCVReturnSuccess) {
            [rawContext render:reconstructed toBitmap:CVPixelBufferGetBaseAddress(output) rowBytes:CVPixelBufferGetBytesPerRow(output) bounds:bounds format:outputFormat colorSpace:NULL];
            CVPixelBufferUnlockBaseAddress(output, 0);
            CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, destination, kCVAttachmentMode_ShouldPropagate);
            IOSurfaceRef surface = CVPixelBufferGetIOSurface(output);
            if (surface) {
                CFPropertyListRef properties = CGColorSpaceCopyPropertyList(destination);
                if (properties) {
                    WK_SYSTEM(IOSurfaceSetValue)(surface, WK_SYSTEM(kIOSurfaceColorSpace), properties);
                    CFRelease(properties);
                }
            }
        }
        CGColorSpaceRelease(destination);
        CGColorSpaceRelease(linear);
        CGColorSpaceRelease(sourceSpace);
        return result;
    }
}
