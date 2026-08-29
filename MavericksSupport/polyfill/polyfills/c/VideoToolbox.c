// VideoToolbox: entry points and constants modern WebKit references that 10.9's VideoToolbox does not
// export. VTIsHardwareDecodeSupported lives in polyfills/shared/videotoolbox.c: GStreamer's applemedia
// plugin calls it too, so the deps builds compile the same source into their gap archive.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <VideoToolbox/VideoToolbox.h>
#include <string.h>

// kVTVideoEncoderSpecification_RequiredLowLatency is a 10.13+
// VideoToolbox encoder-spec key. libwebrtc's VTB H.264/VP9 encoder (built with
// ENABLE_WEB_RTC) references it; WebCore resolves it via flat-namespace dynamic
// lookup, so without a definition dyld aborts Safari at launch ("Symbol not
// found: _kVTVideoEncoderSpecification_RequiredLowLatency"). Provide the real
// CFString value; on 10.9 the encoder simply ignores this unknown spec key.
WK_POLYFILL_CONST("VideoToolbox", CFStringRef, kVTVideoEncoderSpecification_RequiredLowLatency, CFSTR("RequiredLowLatency"));

// outcome by asking whether the codec is supported afterwards, which is answered above.
WK_POLYFILL_ABSENT("VideoToolbox", void, VTRegisterSupplementalVideoDecoderIfAvailable, (CMVideoCodecType codecType))
{
    (void)codecType;
}

// Two more encoder property keys libwebrtc's VideoToolbox H.264 encoder sets: the constrained-baseline
// profile level (10.13+) and the base-layer frame-rate fraction for temporal layering (10.15+). Real
// CFString values; 10.9's session rejects the unknown keys, which the encoder treats as non-fatal.
WK_POLYFILL_CONST("VideoToolbox", CFStringRef, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, CFSTR("H264_ConstrainedBaseline_AutoLevel"));
WK_POLYFILL_CONST("VideoToolbox", CFStringRef, kVTCompressionPropertyKey_BaseLayerFrameRateFraction, CFSTR("BaseLayerFrameRateFraction"));

// VTGetDefaultColorAttributesWithHints (10.11+) answers the colour attachments VideoToolbox assumes
// for untagged video of a given size: ITU-R BT.709 from 720 lines up, EBU 3213 primaries with the
// 601 matrix for 720x576 (PAL/SECAM), SMPTE C primaries with the 601 matrix for everything smaller
// (NTSC); the transfer function is BT.709 throughout. WebCore's FormatDescriptionUtilities fills a
// format description's missing colour attachments from it. The answers are the CoreVideo constants'
// string values (kCVImageBufferColorPrimaries_ITU_R_709_2 is "ITU_R_709_2", and so on -- read off
// this host, as CoreMedia.c does for its format-description keys), spelled as literals so the layer
// links into every image, CoreVideo client or not; the callers compare them with CFEqual.
WK_POLYFILL_ABSENT("VideoToolbox", OSStatus, VTGetDefaultColorAttributesWithHints, (CMVideoCodecType codecType, CFStringRef colorSpaceHint, size_t width, size_t height, CFStringRef* colorPrimariesOut, CFStringRef* transferFunctionOut, CFStringRef* yCbCrMatrixOut))
{
    (void)codecType; (void)colorSpaceHint;
    CFStringRef primaries;
    CFStringRef matrix;
    if (height >= 720) {
        primaries = CFSTR("ITU_R_709_2");
        matrix = CFSTR("ITU_R_709_2");
    } else if (width == 720 && height == 576) {
        primaries = CFSTR("EBU_3213");
        matrix = CFSTR("ITU_R_601_4");
    } else {
        primaries = CFSTR("SMPTE_C");
        matrix = CFSTR("ITU_R_601_4");
    }
    if (colorPrimariesOut)
        *colorPrimariesOut = primaries;
    if (transferFunctionOut)
        *transferFunctionOut = CFSTR("ITU_R_709_2");
    if (yCbCrMatrixOut)
        *yCbCrMatrixOut = matrix;
    return noErr;
}

// VTPixelBufferConformerCopyConformedPixelBuffer gained its ensureModifiable parameter after 10.9:
// here the export is (conformer, sourceBuffer, conformedBufferOut), and a caller using the modern
// four-argument shape lands its Boolean in the out-pointer register, which the implementation
// rejects with kVTParameterErr. This replacement serves the modern signature over the three-argument
// export. 10.9 answers a conformant source by retaining and returning that same buffer, so an
// ensureModifiable request substitutes a fresh deep copy of it.
// CoreVideo is looked up at runtime: images carrying this archive do not all link it.
WK_SYSTEM_FN("CoreVideo", CVReturn, CVPixelBufferCreate, (CFAllocatorRef, size_t, size_t, OSType, CFDictionaryRef, CVPixelBufferRef *));
WK_SYSTEM_FN("CoreVideo", CVReturn, CVPixelBufferLockBaseAddress, (CVPixelBufferRef, uint64_t));
WK_SYSTEM_FN("CoreVideo", CVReturn, CVPixelBufferUnlockBaseAddress, (CVPixelBufferRef, uint64_t));
WK_SYSTEM_FN("CoreVideo", OSType, CVPixelBufferGetPixelFormatType, (CVPixelBufferRef));
WK_SYSTEM_FN("CoreVideo", size_t, CVPixelBufferGetWidth, (CVPixelBufferRef));
WK_SYSTEM_FN("CoreVideo", size_t, CVPixelBufferGetHeight, (CVPixelBufferRef));
WK_SYSTEM_FN("CoreVideo", Boolean, CVPixelBufferIsPlanar, (CVPixelBufferRef));
WK_SYSTEM_FN("CoreVideo", size_t, CVPixelBufferGetPlaneCount, (CVPixelBufferRef));
WK_SYSTEM_FN("CoreVideo", void *, CVPixelBufferGetBaseAddressOfPlane, (CVPixelBufferRef, size_t));
WK_SYSTEM_FN("CoreVideo", size_t, CVPixelBufferGetBytesPerRowOfPlane, (CVPixelBufferRef, size_t));
WK_SYSTEM_FN("CoreVideo", size_t, CVPixelBufferGetHeightOfPlane, (CVPixelBufferRef, size_t));
WK_SYSTEM_FN("CoreVideo", void *, CVPixelBufferGetBaseAddress, (CVPixelBufferRef));
WK_SYSTEM_FN("CoreVideo", size_t, CVPixelBufferGetBytesPerRow, (CVPixelBufferRef));
WK_SYSTEM_FN("CoreVideo", void, CVBufferPropagateAttachments, (CVBufferRef, CVBufferRef));
WK_SYSTEM_FN("CoreVideo", void, CVPixelBufferRelease, (CVPixelBufferRef));

typedef struct OpaqueVTPixelBufferConformer *VTPixelBufferConformerRef; // private VideoToolbox type, absent from the public headers
typedef OSStatus (*WKVTConformerCopyThreeArg)(VTPixelBufferConformerRef, CVPixelBufferRef, CVPixelBufferRef *);

static OSStatus wkVTPixelBufferDeepCopy(CVPixelBufferRef source, CVPixelBufferRef *copyOut)
{
    CVPixelBufferRef copy = NULL;
    CVReturn cvStatus = WK_SYSTEM(CVPixelBufferCreate)(kCFAllocatorDefault,
        WK_SYSTEM(CVPixelBufferGetWidth)(source), WK_SYSTEM(CVPixelBufferGetHeight)(source),
        WK_SYSTEM(CVPixelBufferGetPixelFormatType)(source), NULL, &copy);
    if (cvStatus != kCVReturnSuccess || !copy)
        return kVTAllocationFailedErr;

    WK_SYSTEM(CVPixelBufferLockBaseAddress)(source, 1 /* kCVPixelBufferLock_ReadOnly */);
    WK_SYSTEM(CVPixelBufferLockBaseAddress)(copy, 0);
    if (WK_SYSTEM(CVPixelBufferIsPlanar)(source)) {
        size_t planes = WK_SYSTEM(CVPixelBufferGetPlaneCount)(source);
        for (size_t plane = 0; plane < planes; ++plane) {
            const uint8_t *from = WK_SYSTEM(CVPixelBufferGetBaseAddressOfPlane)(source, plane);
            uint8_t *to = WK_SYSTEM(CVPixelBufferGetBaseAddressOfPlane)(copy, plane);
            size_t fromStride = WK_SYSTEM(CVPixelBufferGetBytesPerRowOfPlane)(source, plane);
            size_t toStride = WK_SYSTEM(CVPixelBufferGetBytesPerRowOfPlane)(copy, plane);
            size_t rows = WK_SYSTEM(CVPixelBufferGetHeightOfPlane)(source, plane);
            size_t stride = fromStride < toStride ? fromStride : toStride;
            for (size_t row = 0; row < rows; ++row)
                memcpy(to + row * toStride, from + row * fromStride, stride);
        }
    } else {
        const uint8_t *from = WK_SYSTEM(CVPixelBufferGetBaseAddress)(source);
        uint8_t *to = WK_SYSTEM(CVPixelBufferGetBaseAddress)(copy);
        size_t fromStride = WK_SYSTEM(CVPixelBufferGetBytesPerRow)(source);
        size_t toStride = WK_SYSTEM(CVPixelBufferGetBytesPerRow)(copy);
        size_t rows = WK_SYSTEM(CVPixelBufferGetHeight)(source);
        size_t stride = fromStride < toStride ? fromStride : toStride;
        for (size_t row = 0; row < rows; ++row)
            memcpy(to + row * toStride, from + row * fromStride, stride);
    }
    WK_SYSTEM(CVPixelBufferUnlockBaseAddress)(copy, 0);
    WK_SYSTEM(CVPixelBufferUnlockBaseAddress)(source, 1);
    WK_SYSTEM(CVBufferPropagateAttachments)((CVBufferRef)source, (CVBufferRef)copy);
    *copyOut = copy;
    return noErr;
}

WK_POLYFILL_REPLACES("VideoToolbox", OSStatus, VTPixelBufferConformerCopyConformedPixelBuffer, (VTPixelBufferConformerRef conformer, CVPixelBufferRef sourceBuffer, Boolean ensureModifiable, CVPixelBufferRef *conformedBufferOut))
{
    OSStatus status = ((WKVTConformerCopyThreeArg)WK_ORIGINAL(VTPixelBufferConformerCopyConformedPixelBuffer))(conformer, sourceBuffer, conformedBufferOut);
    if (status != noErr || !ensureModifiable || !conformedBufferOut || *conformedBufferOut != sourceBuffer)
        return status;

    CVPixelBufferRef copy = NULL;
    status = wkVTPixelBufferDeepCopy(sourceBuffer, &copy);
    if (status != noErr) {
        WK_SYSTEM(CVPixelBufferRelease)(*conformedBufferOut);
        *conformedBufferOut = NULL;
        return status;
    }
    WK_SYSTEM(CVPixelBufferRelease)(*conformedBufferOut);
    *conformedBufferOut = copy;
    return noErr;
}
