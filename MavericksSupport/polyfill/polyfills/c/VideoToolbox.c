// VideoToolbox: entry points and constants modern WebKit references that 10.9's VideoToolbox does not
// export. VTIsHardwareDecodeSupported lives in polyfills/shared/videotoolbox.c: GStreamer's applemedia
// plugin calls it too, so the deps builds compile the same source into their gap archive.
#include "wk_polyfill.h"

#include "../shared/wk_ycbcr.h"
#include <CoreFoundation/CoreFoundation.h>
#include <VideoToolbox/VideoToolbox.h>
#include <string.h>

// kVTVideoEncoderSpecification_RequiredLowLatency is a 10.13+ VideoToolbox encoder-spec key that
// libwebrtc's H.264/VP9 encoder references. Its real CFString value; 10.9's encoder ignores the key.
WK_POLYFILL_CONST("VideoToolbox", CFStringRef, kVTVideoEncoderSpecification_RequiredLowLatency, CFSTR("RequiredLowLatency"));

// VTRegisterSupplementalVideoDecoderIfAvailable (11.0+) registers the system's supplemental decoders
// for a codec type; 10.9 ships none, so there is nothing to register.
WK_POLYFILL_ABSENT("VideoToolbox", void, VTRegisterSupplementalVideoDecoderIfAvailable, (CMVideoCodecType codecType))
{
    (void)codecType;
}

// The constrained-baseline profile level (10.13+). 10.9 spells the same encoder configuration
// "H264_Baseline_AutoLevel": its baseline encoder writes profile_idc 66 with constraint_set1_flag
// set, which is a Constrained Baseline bitstream. Naming the 10.13 string instead makes
// VTSessionSetProperty answer kVTPropertyValueNotSupportedErr, after which the session emits sample
// buffers whose format description carries no parameter sets at all -- so
// H264CMSampleBufferToAnnexBBuffer rejects every frame and a WebRTC sender transmits nothing.
WK_POLYFILL_CONST("VideoToolbox", CFStringRef, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, CFSTR("H264_Baseline_AutoLevel"));

// The base-layer frame-rate fraction for temporal layering (10.15+). Real CFString value; 10.9's
// session rejects the unknown key, which the encoder treats as non-fatal.
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
    if (height >= 720)
        primaries = CFSTR("ITU_R_709_2");
    else if (width == 720 && height == 576)
        primaries = CFSTR("EBU_3213");
    else
        primaries = CFSTR("SMPTE_C");
    CFStringRef matrix = wk_ycbcr_default_matrix(width, height);
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


// VTPixelTransferSessionTransferImage converts an R'G'B' source that carries no colour data (no CG colour
// space, ICC profile, primaries or transfer function) into Y'CbCr with the matrix alone -- the session's
// destination matrix, else the one VTGetDefaultColorAttributesWithHints answers for the destination size --
// and tags the destination with that matrix and with any destination primaries and transfer function the
// session names. 10.9 converts such a source into 420v with BT.601 at every size and into 420f with
// full-range BT.709 luma over video-range BT.709 chroma, tags neither, and refuses the source
// (kVTInsufficientSourceColorDataErr) once the session names any destination colour property; its 420v
// BT.601 conversion is kept for a session that names none.
WK_SYSTEM_FN("VideoToolbox", OSStatus, VTSessionCopyProperty, (VTSessionRef, CFStringRef, CFAllocatorRef, void *));
WK_SYSTEM_FN("VideoToolbox", OSStatus, VTSessionSetProperty, (VTSessionRef, CFStringRef, CFTypeRef));
WK_SYSTEM_FN("VideoToolbox", OSStatus, VTPixelTransferSessionCreate, (CFAllocatorRef, VTPixelTransferSessionRef *));
WK_SYSTEM_FN("VideoToolbox", void, VTPixelTransferSessionInvalidate, (VTPixelTransferSessionRef));
WK_SYSTEM_FN("CoreVideo", CFTypeRef, CVBufferGetAttachment, (CVBufferRef, CFStringRef, CVAttachmentMode *));
WK_SYSTEM_FN("CoreVideo", void, CVBufferSetAttachment, (CVBufferRef, CFStringRef, CFTypeRef, CVAttachmentMode));

static CFTypeRef wkVTSessionCopyProperty(VTSessionRef session, CFStringRef key, CFTypeID type)
{
    CFTypeRef value = NULL;
    if (WK_SYSTEM(VTSessionCopyProperty)(session, key, kCFAllocatorDefault, &value) != noErr || !value)
        return NULL;
    if (CFGetTypeID(value) != type) {
        CFRelease(value);
        return NULL;
    }
    return value;
}

static void wkConvertRGB32ToBiPlanar(CVPixelBufferRef source, CVPixelBufferRef destination, const int32_t *coefficients, bool fullRange)
{
    WK_SYSTEM(CVPixelBufferLockBaseAddress)(source, 1 /* kCVPixelBufferLock_ReadOnly */);
    WK_SYSTEM(CVPixelBufferLockBaseAddress)(destination, 0);
    wk_ycbcr_convert_rgb32(WK_SYSTEM(CVPixelBufferGetBaseAddress)(source), WK_SYSTEM(CVPixelBufferGetBytesPerRow)(source),
        WK_SYSTEM(CVPixelBufferGetPixelFormatType)(source) == kCVPixelFormatType_32ARGB,
        WK_SYSTEM(CVPixelBufferGetBaseAddressOfPlane)(destination, 0), WK_SYSTEM(CVPixelBufferGetBytesPerRowOfPlane)(destination, 0),
        WK_SYSTEM(CVPixelBufferGetBaseAddressOfPlane)(destination, 1), WK_SYSTEM(CVPixelBufferGetBytesPerRowOfPlane)(destination, 1),
        WK_SYSTEM(CVPixelBufferGetWidth)(destination), WK_SYSTEM(CVPixelBufferGetHeight)(destination), coefficients, fullRange);
    WK_SYSTEM(CVPixelBufferUnlockBaseAddress)(destination, 0);
    WK_SYSTEM(CVPixelBufferUnlockBaseAddress)(source, 1);
}

// The source scaled and cropped into 32BGRA at the destination's size by a session carrying the caller's
// geometry and none of its colour properties, which 10.9 would refuse for an untagged source.
typedef OSStatus (*WKVTPixelTransferFunction)(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
static OSStatus wkResampleRGB32(WKVTPixelTransferFunction transfer, VTPixelTransferSessionRef session, CVPixelBufferRef source, CVPixelBufferRef destination, CVPixelBufferRef *resampledOut)
{
    VTPixelTransferSessionRef geometrySession = NULL;
    OSStatus status = WK_SYSTEM(VTPixelTransferSessionCreate)(kCFAllocatorDefault, &geometrySession);
    if (status != noErr)
        return status;
    CFStringRef geometryKeys[] = { CFSTR("ScalingMode"), CFSTR("DestinationCleanAperture"), CFSTR("DestinationPixelAspectRatio"), CFSTR("DownsamplingMode") };
    for (size_t i = 0; i < sizeof(geometryKeys) / sizeof(geometryKeys[0]); ++i) {
        CFTypeRef value = NULL;
        if (WK_SYSTEM(VTSessionCopyProperty)(session, geometryKeys[i], kCFAllocatorDefault, &value) == noErr && value) {
            WK_SYSTEM(VTSessionSetProperty)(geometrySession, geometryKeys[i], value);
            CFRelease(value);
        }
    }
    CVPixelBufferRef resampled = NULL;
    status = WK_SYSTEM(CVPixelBufferCreate)(kCFAllocatorDefault, WK_SYSTEM(CVPixelBufferGetWidth)(destination), WK_SYSTEM(CVPixelBufferGetHeight)(destination), kCVPixelFormatType_32BGRA, NULL, &resampled);
    if (status == kCVReturnSuccess && resampled)
        status = transfer(geometrySession, source, resampled);
    else
        status = kVTAllocationFailedErr;
    WK_SYSTEM(VTPixelTransferSessionInvalidate)(geometrySession);
    CFRelease(geometrySession);
    if (status != noErr) {
        if (resampled)
            WK_SYSTEM(CVPixelBufferRelease)(resampled);
        return status;
    }
    *resampledOut = resampled;
    return noErr;
}

WK_POLYFILL_REPLACES("VideoToolbox", OSStatus, VTPixelTransferSessionTransferImage, (VTPixelTransferSessionRef session, CVPixelBufferRef source, CVPixelBufferRef destination))
{
    OSType sourceFormat = source ? WK_SYSTEM(CVPixelBufferGetPixelFormatType)(source) : 0;
    OSType destinationFormat = destination ? WK_SYSTEM(CVPixelBufferGetPixelFormatType)(destination) : 0;
    bool fullRange = destinationFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    CFStringRef sourceColorKeys[] = { CFSTR("CGColorSpace"), CFSTR("CVImageBufferICCProfile"), CFSTR("CVImageBufferColorPrimaries"), CFSTR("CVImageBufferTransferFunction") };
    bool sourceHasColorData = false;
    for (size_t i = 0; source && i < sizeof(sourceColorKeys) / sizeof(sourceColorKeys[0]); ++i)
        sourceHasColorData |= !!WK_SYSTEM(CVBufferGetAttachment)((CVBufferRef)source, sourceColorKeys[i], NULL);
    if ((sourceFormat != kCVPixelFormatType_32ARGB && sourceFormat != kCVPixelFormatType_32BGRA)
        || (!fullRange && destinationFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        || sourceHasColorData)
        return WK_ORIGINAL(VTPixelTransferSessionTransferImage)(session, source, destination);

    CFTypeRef sessionMatrix = wkVTSessionCopyProperty(session, CFSTR("DestinationYCbCrMatrix"), CFStringGetTypeID());
    CFTypeRef sessionPrimaries = wkVTSessionCopyProperty(session, CFSTR("DestinationColorPrimaries"), CFStringGetTypeID());
    CFTypeRef sessionTransfer = wkVTSessionCopyProperty(session, CFSTR("DestinationTransferFunction"), CFStringGetTypeID());
    CFStringRef matrix = sessionMatrix ? (CFStringRef)sessionMatrix : wk_ycbcr_default_matrix(WK_SYSTEM(CVPixelBufferGetWidth)(destination), WK_SYSTEM(CVPixelBufferGetHeight)(destination));
    const int32_t *coefficients = wk_ycbcr_coefficients(matrix, fullRange);
    bool sessionNamesColor = sessionMatrix || sessionPrimaries || sessionTransfer;

    OSStatus status;
    if (!coefficients || (!sessionNamesColor && !fullRange && CFEqual(matrix, CFSTR("ITU_R_601_4"))))
        status = WK_ORIGINAL(VTPixelTransferSessionTransferImage)(session, source, destination);
    else {
        CVPixelBufferRef rgb = source;
        status = noErr;
        if (WK_SYSTEM(CVPixelBufferGetWidth)(source) != WK_SYSTEM(CVPixelBufferGetWidth)(destination)
            || WK_SYSTEM(CVPixelBufferGetHeight)(source) != WK_SYSTEM(CVPixelBufferGetHeight)(destination)
            || WK_SYSTEM(CVBufferGetAttachment)((CVBufferRef)source, CFSTR("CVCleanAperture"), NULL))
            status = wkResampleRGB32(WK_ORIGINAL(VTPixelTransferSessionTransferImage), session, source, destination, &rgb);
        if (status == noErr) {
            wkConvertRGB32ToBiPlanar(rgb, destination, coefficients, fullRange);
            if (rgb != source)
                WK_SYSTEM(CVPixelBufferRelease)(rgb);
        }
    }

    if (status == noErr && coefficients) {
        WK_SYSTEM(CVBufferSetAttachment)((CVBufferRef)destination, CFSTR("CVImageBufferYCbCrMatrix"), matrix, kCVAttachmentMode_ShouldPropagate);
        if (sessionPrimaries)
            WK_SYSTEM(CVBufferSetAttachment)((CVBufferRef)destination, CFSTR("CVImageBufferColorPrimaries"), sessionPrimaries, kCVAttachmentMode_ShouldPropagate);
        if (sessionTransfer)
            WK_SYSTEM(CVBufferSetAttachment)((CVBufferRef)destination, CFSTR("CVImageBufferTransferFunction"), sessionTransfer, kCVAttachmentMode_ShouldPropagate);
    }
    if (sessionMatrix)
        CFRelease(sessionMatrix);
    if (sessionPrimaries)
        CFRelease(sessionPrimaries);
    if (sessionTransfer)
        CFRelease(sessionTransfer);
    return status;
}
