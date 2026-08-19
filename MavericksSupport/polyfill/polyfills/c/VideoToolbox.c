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
