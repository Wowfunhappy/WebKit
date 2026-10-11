// The media types Google's CDM decodes for itself, shared by webkitwidevine and
// webkitwidevinevideodec.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <array>
#include <wtf/text/ASCIILiteral.h>

namespace WebCore {

// The video codecs the CDM's manifest names in x-cdm-codecs. As in Chromium, encrypted video the
// CDM can decode is decoded by the CDM: its Decrypt() is not a path for video. These go to
// webkitwidevinevideodec, which has the CDM decode them, and are the media types webkitwidevine
// leaves out of its own caps.
inline constexpr std::array<ASCIILiteral, 4> s_widevineDecodedMediaTypes = { "video/x-h264"_s, "video/x-vp8"_s, "video/x-vp9"_s, "video/x-av1"_s };

inline bool isWidevineDecodedMediaType(ASCIILiteral mediaType)
{
    for (auto& decoded : s_widevineDecodedMediaTypes) {
        if (mediaType == decoded)
            return true;
    }
    return false;
}

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
