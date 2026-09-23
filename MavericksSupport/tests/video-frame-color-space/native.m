#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include <stdio.h>
#include <string.h>

// Exercise the native 10.9 input contract independently of WebKit's polyfills.
static OSStatus transfer(CGColorSpaceRef colorSpace, unsigned char *luma)
{
    CVPixelBufferRef source = NULL, target = NULL;
    VTPixelTransferSessionRef session = NULL;
    CVReturn status = CVPixelBufferCreate(NULL, 200, 200, kCVPixelFormatType_32BGRA, NULL, &source);
    if (status)
        return status;
    status = CVPixelBufferCreate(NULL, 200, 200, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &target);
    if (status) {
        CFRelease(source);
        return status;
    }
    CVPixelBufferLockBaseAddress(source, 0);
    memset(CVPixelBufferGetBaseAddress(source), 128, CVPixelBufferGetDataSize(source));
    CVPixelBufferUnlockBaseAddress(source, 0);
    if (colorSpace)
        CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey, colorSpace, kCVAttachmentMode_ShouldPropagate);
    OSStatus result = VTPixelTransferSessionCreate(NULL, &session);
    if (!result)
        result = VTSessionSetProperty(session, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
    if (!result)
        result = VTSessionSetProperty(session, kVTPixelTransferPropertyKey_DestinationTransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2);
    if (!result)
        result = VTSessionSetProperty(session, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
    if (!result)
        result = VTPixelTransferSessionTransferImage(session, source, target);
    if (!result) {
        CVPixelBufferLockBaseAddress(target, 0);
        *luma = *(unsigned char *)CVPixelBufferGetBaseAddressOfPlane(target, 0);
        CVPixelBufferUnlockBaseAddress(target, 0);
    }
    if (session)
        CFRelease(session);
    CFRelease(source);
    CFRelease(target);
    return result;
}

int main(void)
{
    CGFloat white[] = { .95047, 1, 1.08883 }, black[] = { 0, 0, 0 }, gamma[] = { 1.8, 1.8, 1.8 };
    CGFloat matrix[] = { .4124, .2126, .0193, .3576, .7152, .1192, .1805, .0722, .9505 };
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef custom = CGColorSpaceCreateCalibratedRGB(white, black, gamma, matrix);
    if (!srgb || !custom)
        return 2;
    unsigned char missingY = 0, srgbY = 0, customY = 0;
    OSStatus missingStatus = transfer(NULL, &missingY);
    OSStatus srgbStatus = transfer(srgb, &srgbY);
    OSStatus customStatus = transfer(custom, &customY);
    CFRelease(srgb);
    CFRelease(custom);
    printf("untagged status=%d; sRGB status=%d luma=%u; custom gamma1.8 status=%d luma=%u\n", (int)missingStatus, (int)srgbStatus, srgbY, (int)customStatus, customY);
    // The custom profile must affect the conversion; silently using sRGB fails.
    int passed = missingStatus == kVTInsufficientSourceColorDataErr && !srgbStatus && !customStatus && srgbY != customY;
    puts(passed ? "PASS native source color-space contract" : "FAIL native source color-space contract");
    return !passed;
}
