/*
 * 10.9 backport: stub for the ISO BMFF (fragmented-MP4) Media Source parser.
 *
 * The real software fMP4 parser (replacing AVStreamDataParser/libwebm, absent on
 * 10.9) is not yet implemented; see the "Implement MSE SourceBufferParserISOBMFF
 * for 10.9" task. SourceBufferParser.cpp dispatches MSE content here; with this
 * stub, isContentTypeSupported() reports IsNotSupported so create() is never
 * reached, i.e. MSE is inert rather than crashing. Replacing this header (and
 * adding the .cpp back to SourcesCocoa.txt) lights MSE up.
 */
#pragma once

#if ENABLE(MEDIA_SOURCE)

#include "SourceBufferParser.h"
#include <wtf/RefPtr.h>

namespace WebCore {

class ContentType;

class SourceBufferParserISOBMFF {
public:
    static MediaPlayerEnums::SupportsType isContentTypeSupported(const ContentType&)
    {
        return MediaPlayerEnums::SupportsType::IsNotSupported;
    }

    static RefPtr<SourceBufferParser> create() { return nullptr; }
};

} // namespace WebCore

#endif // ENABLE(MEDIA_SOURCE)
