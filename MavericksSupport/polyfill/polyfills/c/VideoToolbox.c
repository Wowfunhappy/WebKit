// VideoToolbox: entry points and constants modern WebKit references that 10.9's VideoToolbox does not
// export. VTIsHardwareDecodeSupported lives in polyfills/shared/videotoolbox.c: GStreamer's applemedia
// plugin calls it too, so the deps builds compile the same source into their gap archive.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <VideoToolbox/VideoToolbox.h>

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
