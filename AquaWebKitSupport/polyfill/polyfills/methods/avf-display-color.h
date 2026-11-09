// Color matching for the samples presented by Mavericks' AVSampleBufferDisplayLayer, which shows R'G'B'
// and Y'CbCr samples without matching them to its colour space.
#ifndef WK_AVF_DISPLAY_COLOR_H
#define WK_AVF_DISPLAY_COLOR_H

#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#include "../shared/wk_ycbcr.h"

@interface CALayer (WKAVFDisplayColorSpace)
- (CGColorSpaceRef)_retainColorSpace CF_RETURNS_RETAINED;
@end

static BOOL wkAVFRGBBitmapInfo(OSType type, CGBitmapInfo *info)
{
    switch (type) {
    case kCVPixelFormatType_32BGRA:
        *info = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
        return YES;
    case kCVPixelFormatType_32ARGB:
        *info = kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst;
        return YES;
    case kCVPixelFormatType_32RGBA:
        *info = kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast;
        return YES;
    case kCVPixelFormatType_32ABGR:
        *info = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedLast;
        return YES;
    default:
        return NO;
    }
}

// The 8-bit Y'CbCr formats with horizontally halved chroma, as sample offsets in their planes.
typedef struct {
    OSType type;
    bool fullRange;
    unsigned lumaPlane, cbPlane, crPlane;
    size_t lumaOffset, lumaStep, cbOffset, crOffset, chromaStep;
    unsigned chromaRowShift;
} WKAVFYCbCrLayout;

static const WKAVFYCbCrLayout *wkAVFYCbCrLayout(OSType type)
{
    static const WKAVFYCbCrLayout layouts[] = {
        { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, false, 0, 1, 1, 0, 1, 0, 1, 2, 1 },
        { kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, true, 0, 1, 1, 0, 1, 0, 1, 2, 1 },
        { kCVPixelFormatType_420YpCbCr8Planar, false, 0, 1, 2, 0, 1, 0, 0, 1, 1 },
        { kCVPixelFormatType_420YpCbCr8PlanarFullRange, true, 0, 1, 2, 0, 1, 0, 0, 1, 1 },
        { kCVPixelFormatType_422YpCbCr8, false, 0, 0, 0, 1, 2, 0, 2, 4, 0 },
        { kCVPixelFormatType_422YpCbCr8_yuvs, false, 0, 0, 0, 0, 2, 1, 3, 4, 0 },
    };
    for (size_t i = 0; i < sizeof(layouts) / sizeof(layouts[0]); ++i) {
        if (layouts[i].type == type)
            return &layouts[i];
    }
    return NULL;
}

static const uint8_t *wkAVFPlane(CVPixelBufferRef buffer, unsigned plane, size_t *stride)
{
    if (!CVPixelBufferIsPlanar(buffer)) {
        *stride = CVPixelBufferGetBytesPerRow(buffer);
        return CVPixelBufferGetBaseAddress(buffer);
    }
    *stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
    return CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
}

// The image's Y'CbCr matrix: its own, else its format description's, else the one VideoToolbox assumes for its size.
static CFStringRef wkAVFYCbCrMatrix(CVPixelBufferRef buffer, CMFormatDescriptionRef format)
{
    CFTypeRef matrix = CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL);
    if (!matrix && format)
        matrix = CMFormatDescriptionGetExtension(format, kCVImageBufferYCbCrMatrixKey);
    if (matrix && CFGetTypeID(matrix) == CFStringGetTypeID() && wk_ycbcr_coefficients((CFStringRef)matrix, false))
        return (CFStringRef)matrix;
    return wk_ycbcr_default_matrix(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer));
}

// The layer owns one transform and one size-specific pool. Samples retain their output buffers while
// queued; releasing the layer releases the pool and its idle surfaces.
@interface WKAVFDisplayColor : NSObject {
    CGColorSpaceRef _source;
    CGColorSpaceRef _destination;
    CFDataRef _destinationProfile;
    CGBitmapInfo _bitmapInfo;
    vImageConverterRef _converter;
    CVPixelBufferPoolRef _pool;
    size_t _width;
    size_t _height;
    CFDictionaryRef _sourceColorAttachments;
    CGColorSpaceRef _derivedSource;
    uint8_t *_decoded;
    size_t _decodedSize;
    NSInteger _status;
    NSError *_error;
}
- (NSInteger)status;
- (NSError *)error;
- (void)setStatus:(NSInteger)status error:(NSError *)error forLayer:(CALayer *)layer;
- (void)flushForLayer:(CALayer *)layer;
- (CMSampleBufferRef)copySample:(CMSampleBufferRef)sample forLayer:(CALayer *)layer CF_RETURNS_RETAINED;
@end

@implementation WKAVFDisplayColor
- (void)dealloc
{
    CGColorSpaceRelease(_source);
    CGColorSpaceRelease(_destination);
    if (_destinationProfile)
        CFRelease(_destinationProfile);
    if (_converter)
        vImageConverter_Release(_converter);
    if (_pool)
        CVPixelBufferPoolRelease(_pool);
    if (_sourceColorAttachments)
        CFRelease(_sourceColorAttachments);
    CGColorSpaceRelease(_derivedSource);
    free(_decoded);
    [_error release];
    [super dealloc];
}

// The object's lock guards its fields only. Core Animation posts layer KVO while holding its own lock,
// so the layer's colour space is read and the layer's status notifications are posted outside it.
- (NSInteger)status
{
    @synchronized (self) {
        return _status;
    }
}

- (NSError *)error
{
    @synchronized (self) {
        return [[_error retain] autorelease];
    }
}

// 10.9's display layer declares no status or error. Their values for KVC, and so for KVO's change
// dictionaries, live in the layer's own style dictionary, which CALayer consults for a key it does not define.
static void wkAVFSetLayerValue(CALayer *layer, NSString *key, id value)
{
    NSMutableDictionary *style = [[layer.style mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    if (value)
        [style setObject:value forKey:key];
    else
        [style removeObjectForKey:key];
    layer.style = style;
}

- (void)setStatus:(NSInteger)status error:(NSError *)error forLayer:(CALayer *)layer
{
    BOOL statusChanged;
    BOOL errorChanged;
    @synchronized (self) {
        statusChanged = status != _status;
        errorChanged = error != _error;
    }
    if (statusChanged)
        [layer willChangeValueForKey:@"status"];
    if (errorChanged)
        [layer willChangeValueForKey:@"error"];
    @synchronized (self) {
        [error retain];
        [_error release];
        _error = error;
        _status = status;
    }
    if (statusChanged)
        wkAVFSetLayerValue(layer, @"status", @(status));
    if (errorChanged)
        wkAVFSetLayerValue(layer, @"error", error);
    if (errorChanged)
        [layer didChangeValueForKey:@"error"];
    if (statusChanged)
        [layer didChangeValueForKey:@"status"];
}

- (void)flushForLayer:(CALayer *)layer
{
    @synchronized (self) {
        if (_pool) {
            CVPixelBufferPoolRelease(_pool);
            _pool = NULL;
        }
    }
    [self setStatus:0 error:nil forLayer:layer];
}

- (CMSampleBufferRef)fail:(NSInteger)code failure:(NSInteger *)failure
{
    *failure = code;
    return NULL;
}

// An image's own CG colour space, else the one its colour attachments describe, taken from the image and
// then its format description. The description is a function of those values, so it is kept for the next
// image that carries the same ones. An image that describes none is sRGB.
- (CGColorSpaceRef)copySourceColorSpace:(CVPixelBufferRef)buffer format:(CMFormatDescriptionRef)format CF_RETURNS_RETAINED
{
    CGColorSpaceRef space = (CGColorSpaceRef)CVBufferGetAttachment(buffer, kCVImageBufferCGColorSpaceKey, NULL);
    if (space)
        return CGColorSpaceRetain(space);
    CFStringRef keys[] = { kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferGammaLevelKey, kCVImageBufferYCbCrMatrixKey, kCVImageBufferICCProfileKey };
    CFMutableDictionaryRef colorAttachments = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        CFTypeRef value = CVBufferGetAttachment(buffer, keys[i], NULL);
        if (!value && format)
            value = CMFormatDescriptionGetExtension(format, keys[i]);
        if (value)
            CFDictionarySetValue(colorAttachments, keys[i], value);
    }
    if (!_sourceColorAttachments || !CFEqual(colorAttachments, _sourceColorAttachments)) {
        if (_sourceColorAttachments)
            CFRelease(_sourceColorAttachments);
        CGColorSpaceRelease(_derivedSource);
        _sourceColorAttachments = CFRetain(colorAttachments);
        _derivedSource = CVImageBufferCreateColorSpaceFromAttachments(colorAttachments) ?: CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    }
    CFRelease(colorAttachments);
    return CGColorSpaceRetain(_derivedSource);
}

- (CMSampleBufferRef)copySample:(CMSampleBufferRef)sample forLayer:(CALayer *)layer
{
    CGColorSpaceRef destination = [layer _retainColorSpace];
    NSInteger failure = 0;
    CMSampleBufferRef result;
    @synchronized (self) {
        result = [self copySample:sample toColorSpace:destination failure:&failure];
    }
    CGColorSpaceRelease(destination);
    if (!result)
        [self setStatus:2 error:[NSError errorWithDomain:NSOSStatusErrorDomain code:failure userInfo:nil] forLayer:layer];
    return result;
}

- (CMSampleBufferRef)copySample:(CMSampleBufferRef)sample toColorSpace:(CGColorSpaceRef)destination failure:(NSInteger *)failure CF_RETURNS_RETAINED
{
    CVPixelBufferRef input = CMSampleBufferGetImageBuffer(sample);
    CGBitmapInfo bitmapInfo = 0;
    const WKAVFYCbCrLayout *ycbcr = NULL;
    if (!input || !CMSampleBufferDataIsReady(sample))
        return (CMSampleBufferRef)CFRetain(sample);
    if (!wkAVFRGBBitmapInfo(CVPixelBufferGetPixelFormatType(input), &bitmapInfo)) {
        ycbcr = wkAVFYCbCrLayout(CVPixelBufferGetPixelFormatType(input));
        if (!ycbcr)
            return (CMSampleBufferRef)CFRetain(sample);
        // Y'CbCr decodes into opaque 32ARGB, which is then matched.
        bitmapInfo = kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipFirst;
    }

    CMFormatDescriptionRef sampleFormat = CMSampleBufferGetFormatDescription(sample);
    CGColorSpaceRef source = [self copySourceColorSpace:input format:sampleFormat];
    bool matches = source && destination && !CFEqual(source, destination);
    if (!destination || (!ycbcr && !matches)) {
        CGColorSpaceRelease(source);
        return (CMSampleBufferRef)CFRetain(sample);
    }
    if (matches && (!_converter || bitmapInfo != _bitmapInfo || !CFEqual(source, _source) || !CFEqual(destination, _destination))) {
        if (_converter)
            vImageConverter_Release(_converter);
        CGColorSpaceRelease(_source);
        CGColorSpaceRelease(_destination);
        _source = CGColorSpaceRetain(source);
        _destination = CGColorSpaceRetain(destination);
        if (_destinationProfile)
            CFRelease(_destinationProfile);
        _destinationProfile = CGColorSpaceCopyICCProfile(destination);
        _bitmapInfo = bitmapInfo;
        vImage_CGImageFormat from = { 8, 32, source, bitmapInfo, 0, NULL, kCGRenderingIntentDefault };
        // The output is 32ARGB, the format Mavericks' layer conforms every frame to before display.
        vImage_CGImageFormat to = { 8, 32, destination, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst, 0, NULL, kCGRenderingIntentDefault };
        vImage_Error error;
        _converter = vImageConverter_CreateWithCGImageFormat(&from, &to, NULL, kvImageNoFlags, &error);
        if (!_converter) {
            CGColorSpaceRelease(source);
            return [self fail:error failure:failure];
        }
    }
    if (!matches && (!_destination || !CFEqual(destination, _destination))) {
        CGColorSpaceRelease(_destination);
        _destination = CGColorSpaceRetain(destination);
        if (_destinationProfile)
            CFRelease(_destinationProfile);
        _destinationProfile = CGColorSpaceCopyICCProfile(destination);
    }
    CGColorSpaceRelease(source);

    size_t width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input);
    if (!_pool || width != _width || height != _height) {
        if (_pool)
            CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
        _width = width;
        _height = height;
        NSDictionary *attributes = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32ARGB),
            (id)kCVPixelBufferWidthKey: @(width), (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        CVReturn status = CVPixelBufferPoolCreate(NULL, NULL, (CFDictionaryRef)attributes, &_pool);
        if (status)
            return [self fail:status failure:failure];
    }
    CVPixelBufferRef output = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &output);
    if (status)
        return [self fail:status failure:failure];
    status = CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    if (status) {
        CVPixelBufferRelease(output);
        return [self fail:status failure:failure];
    }
    status = CVPixelBufferLockBaseAddress(output, 0);
    if (status) {
        CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(output);
        return [self fail:status failure:failure];
    }
    vImage_Buffer from = { CVPixelBufferGetBaseAddress(input), height, width, CVPixelBufferGetBytesPerRow(input) };
    vImage_Buffer to = { CVPixelBufferGetBaseAddress(output), height, width, CVPixelBufferGetBytesPerRow(output) };
    vImage_Error error = kvImageNoError;
    if (ycbcr) {
        // Decoded straight into the output when no match follows, else into a frame the match reads.
        if (matches && _decodedSize < width * height * 4) {
            free(_decoded);
            _decodedSize = width * height * 4;
            _decoded = malloc(_decodedSize);
        }
        vImage_Buffer decoded = matches ? (vImage_Buffer) { _decoded, height, width, width * 4 } : to;
        int32_t inverse[9];
        size_t lumaStride, cbStride, crStride;
        const uint8_t *luma = wkAVFPlane(input, ycbcr->lumaPlane, &lumaStride);
        const uint8_t *cb = wkAVFPlane(input, ycbcr->cbPlane, &cbStride);
        const uint8_t *cr = wkAVFPlane(input, ycbcr->crPlane, &crStride);
        if (!decoded.data || !luma || !cb || !cr || !wk_ycbcr_inverse_coefficients(wkAVFYCbCrMatrix(input, sampleFormat), ycbcr->fullRange, inverse))
            error = kvImageInternalError;
        else {
            wk_ycbcr_convert_to_argb(luma + ycbcr->lumaOffset, lumaStride, ycbcr->lumaStep, cb + ycbcr->cbOffset, cr + ycbcr->crOffset,
                cbStride, ycbcr->chromaStep, ycbcr->chromaRowShift, decoded.data, decoded.rowBytes, width, height, inverse, ycbcr->fullRange);
            if (matches)
                error = vImageConvert_AnyToAny(_converter, &decoded, &to, NULL, kvImageNoFlags);
        }
    } else
        error = vImageConvert_AnyToAny(_converter, &from, &to, NULL, kvImageNoFlags);
    CVPixelBufferUnlockBaseAddress(output, 0);
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    if (error) {
        CVPixelBufferRelease(output);
        return [self fail:error failure:failure];
    }

    CVBufferRemoveAllAttachments(output);
    // Geometry may be expressed by the format description instead of the image attachments.
    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(CMSampleBufferGetFormatDescription(sample));
    for (id key in (NSArray *)CMVideoFormatDescriptionGetExtensionKeysCommonWithImageBuffers()) {
        CFTypeRef value = extensions ? CFDictionaryGetValue(extensions, key) : NULL;
        if (value)
            CVBufferSetAttachment(output, (CFStringRef)key, value, kCVAttachmentMode_ShouldPropagate);
    }
    CVBufferPropagateAttachments(input, output);
    CVBufferRemoveAttachment(output, kCVImageBufferColorPrimariesKey);
    CVBufferRemoveAttachment(output, kCVImageBufferTransferFunctionKey);
    CVBufferRemoveAttachment(output, kCVImageBufferGammaLevelKey);
    CVBufferRemoveAttachment(output, kCVImageBufferYCbCrMatrixKey);
    CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, _destination, kCVAttachmentMode_ShouldPropagate);
    if (_destinationProfile)
        CVBufferSetAttachment(output, kCVImageBufferICCProfileKey, _destinationProfile, kCVAttachmentMode_ShouldPropagate);
    else
        CVBufferRemoveAttachment(output, kCVImageBufferICCProfileKey);

    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef result = NULL;
    CMSampleTimingInfo timing;
    OSStatus sampleStatus = CMVideoFormatDescriptionCreateForImageBuffer(NULL, output, &format);
    if (!sampleStatus) {
        NSMutableDictionary *merged = extensions ? [[(NSDictionary *)extensions mutableCopy] autorelease] : [NSMutableDictionary dictionary];
        [merged removeObjectForKey:(id)kCVImageBufferColorPrimariesKey];
        [merged removeObjectForKey:(id)kCVImageBufferTransferFunctionKey];
        [merged removeObjectForKey:(id)kCVImageBufferGammaLevelKey];
        [merged removeObjectForKey:(id)kCVImageBufferYCbCrMatrixKey];
        [merged removeObjectForKey:(id)kCVImageBufferICCProfileKey];
        [merged addEntriesFromDictionary:(NSDictionary *)CMFormatDescriptionGetExtensions(format)];
        CFRelease(format);
        format = NULL;
        sampleStatus = CMVideoFormatDescriptionCreate(NULL, kCVPixelFormatType_32ARGB, (int32_t)width, (int32_t)height,
            (CFDictionaryRef)merged, &format);
    }
    if (!sampleStatus)
        sampleStatus = CMSampleBufferGetSampleTimingInfo(sample, 0, &timing);
    if (!sampleStatus)
        sampleStatus = CMSampleBufferCreateForImageBuffer(NULL, output, YES, NULL, NULL, format, &timing, &result);
    if (format)
        CFRelease(format);
    CVPixelBufferRelease(output);
    if (!result)
        return [self fail:sampleStatus failure:failure];

    for (CMAttachmentMode mode = kCMAttachmentMode_ShouldNotPropagate; mode <= kCMAttachmentMode_ShouldPropagate; ++mode) {
        CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(NULL, sample, mode);
        if (attachments) {
            CMSetAttachments(result, attachments, mode);
            CFRelease(attachments);
        }
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, NO);
    if (attachments && CFArrayGetCount(attachments)) {
        CFArrayRef copied = CMSampleBufferGetSampleAttachmentsArray(result, YES);
        [(NSMutableDictionary *)CFArrayGetValueAtIndex(copied, 0) addEntriesFromDictionary:(NSDictionary *)CFArrayGetValueAtIndex(attachments, 0)];
    }
    CMTime outputTime = CMSampleBufferGetOutputPresentationTimeStamp(sample);
    if (CMTIME_IS_VALID(outputTime))
        CMSampleBufferSetOutputPresentationTimeStamp(result, outputTime);
    return result;
}
@end

static const void *const wkAVFDisplayColorKey = &wkAVFDisplayColorKey;
#endif
