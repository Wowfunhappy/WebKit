// The media types Google's CDM decodes for itself, shared by webkitwidevine and
// webkitwidevinevideodec.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <array>
#include <wtf/text/ASCIILiteral.h>

namespace WebCore {

// What Google's CDM recognises as a video bitstream and answers kNoKey for rather than decrypt:
// H.264, by the start code a four-byte AVCC length can read as, and VP9, by the sync code its
// keyframes carry. Those go to webkitwidevinevideodec, which has the CDM decode them, and are the
// media types webkitwidevine leaves out of its own caps.
inline constexpr std::array<ASCIILiteral, 2> s_widevineDecodedMediaTypes = { "video/x-h264"_s, "video/x-vp9"_s };

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
