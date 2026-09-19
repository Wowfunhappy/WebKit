// Color matching for packed RGB samples presented by Mavericks' AVSampleBufferDisplayLayer.
#ifndef WK_AVF_DISPLAY_COLOR_H
#define WK_AVF_DISPLAY_COLOR_H

#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

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

static CGColorSpaceRef wkAVFCopyImageColorSpace(CVPixelBufferRef buffer, CMFormatDescriptionRef format)
{
    CGColorSpaceRef space = (CGColorSpaceRef)CVBufferGetAttachment(buffer, kCVImageBufferCGColorSpaceKey, NULL);
    if (space)
        return CGColorSpaceRetain(space);
    // A format description can supply the colorimetry when its image has no overriding attachment.
    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
    CFMutableDictionaryRef attributes = extensions ? CFDictionaryCreateMutableCopy(NULL, 0, extensions)
        : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    NSDictionary *attachments = (NSDictionary *)CVBufferGetAttachments(buffer, kCVAttachmentMode_ShouldPropagate);
    for (id key in attachments)
        CFDictionarySetValue(attributes, key, [attachments objectForKey:key]);
    space = CVImageBufferCreateColorSpaceFromAttachments(attributes);
    CFRelease(attributes);
    return space ?: CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
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
    [_error release];
    [super dealloc];
}

- (NSInteger)status { return _status; }
- (NSError *)error { return _error; }

- (void)setStatus:(NSInteger)status error:(NSError *)error forLayer:(CALayer *)layer
{
    BOOL statusChanged = status != _status;
    BOOL errorChanged = error != _error;
    if (statusChanged)
        [layer willChangeValueForKey:@"status"];
    if (errorChanged)
        [layer willChangeValueForKey:@"error"];
    [error retain];
    [_error release];
    _error = error;
    _status = status;
    if (errorChanged)
        [layer didChangeValueForKey:@"error"];
    if (statusChanged)
        [layer didChangeValueForKey:@"status"];
}

- (void)flushForLayer:(CALayer *)layer
{
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
    }
    [self setStatus:0 error:nil forLayer:layer];
}

- (CMSampleBufferRef)fail:(NSInteger)code forLayer:(CALayer *)layer
{
    [self setStatus:2 error:[NSError errorWithDomain:NSOSStatusErrorDomain code:code userInfo:nil] forLayer:layer];
    return NULL;
}

- (CMSampleBufferRef)copySample:(CMSampleBufferRef)sample forLayer:(CALayer *)layer
{
    CVPixelBufferRef input = CMSampleBufferGetImageBuffer(sample);
    CGBitmapInfo bitmapInfo;
    if (!input || !CMSampleBufferDataIsReady(sample) || !wkAVFRGBBitmapInfo(CVPixelBufferGetPixelFormatType(input), &bitmapInfo))
        return (CMSampleBufferRef)CFRetain(sample);

    CGColorSpaceRef source = wkAVFCopyImageColorSpace(input, CMSampleBufferGetFormatDescription(sample));
    CGColorSpaceRef destination = [layer _retainColorSpace];
    if (!source || !destination || CFEqual(source, destination)) {
        CGColorSpaceRelease(source);
        CGColorSpaceRelease(destination);
        return (CMSampleBufferRef)CFRetain(sample);
    }
    if (!_converter || bitmapInfo != _bitmapInfo || !CFEqual(source, _source) || !CFEqual(destination, _destination)) {
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
        vImage_CGImageFormat to = { 8, 32, destination, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, 0, NULL, kCGRenderingIntentDefault };
        vImage_Error error;
        _converter = vImageConverter_CreateWithCGImageFormat(&from, &to, NULL, kvImageNoFlags, &error);
        if (!_converter) {
            CGColorSpaceRelease(source);
            CGColorSpaceRelease(destination);
            return [self fail:error forLayer:layer];
        }
    }
    CGColorSpaceRelease(source);
    CGColorSpaceRelease(destination);

    size_t width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input);
    if (!_pool || width != _width || height != _height) {
        if (_pool)
            CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
        _width = width;
        _height = height;
        NSDictionary *attributes = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width), (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        CVReturn status = CVPixelBufferPoolCreate(NULL, NULL, (CFDictionaryRef)attributes, &_pool);
        if (status)
            return [self fail:status forLayer:layer];
    }
    CVPixelBufferRef output = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &output);
    if (status)
        return [self fail:status forLayer:layer];
    status = CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    if (status) {
        CVPixelBufferRelease(output);
        return [self fail:status forLayer:layer];
    }
    status = CVPixelBufferLockBaseAddress(output, 0);
    if (status) {
        CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(output);
        return [self fail:status forLayer:layer];
    }
    vImage_Buffer from = { CVPixelBufferGetBaseAddress(input), height, width, CVPixelBufferGetBytesPerRow(input) };
    vImage_Buffer to = { CVPixelBufferGetBaseAddress(output), height, width, CVPixelBufferGetBytesPerRow(output) };
    vImage_Error error = vImageConvert_AnyToAny(_converter, &from, &to, NULL, kvImageNoFlags);
    CVPixelBufferUnlockBaseAddress(output, 0);
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    if (error) {
        CVPixelBufferRelease(output);
        return [self fail:error forLayer:layer];
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
        sampleStatus = CMVideoFormatDescriptionCreate(NULL, kCVPixelFormatType_32BGRA, (int32_t)width, (int32_t)height,
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
        return [self fail:sampleStatus forLayer:layer];

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
