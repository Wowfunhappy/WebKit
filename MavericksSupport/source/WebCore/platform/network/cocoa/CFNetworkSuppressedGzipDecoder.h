// Decodes response bodies that CFNetwork hands back still gzip-compressed.
// ContentEncodingSniffingPolicy::Disable asks CFNetwork to decode Content-Encoding regardless of what
// the response looks like, by way of kCFURLRequestContentDecoderSkipURLCheck; 10.9 CFNetwork has no
// such key, so both the ResourceHandle and the NetworkDataTask paths inflate those bodies themselves.

#pragma once

#include "PlatformExportMacros.h"
#include <optional>
#include <span>
#include <wtf/Noncopyable.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>
#include <zlib.h>

namespace WebCore {

class ResourceResponse;

class CFNetworkSuppressedGzipDecoder {
    WTF_MAKE_NONCOPYABLE(CFNetworkSuppressedGzipDecoder);
    WTF_MAKE_TZONE_ALLOCATED(CFNetworkSuppressedGzipDecoder);
public:
    WEBCORE_EXPORT static bool responseBodyIsStillGzipped(const ResourceResponse&);

    WEBCORE_EXPORT CFNetworkSuppressedGzipDecoder();
    WEBCORE_EXPORT ~CFNetworkSuppressedGzipDecoder();

    // The bytes this chunk decodes to, or nullopt once the body cannot be decoded.
    WEBCORE_EXPORT std::optional<Vector<uint8_t>> decode(std::span<const uint8_t>);

    bool failed() const { return m_failed; }
    // True when the bytes fed so far end partway through a gzip member. gzip permits concatenated
    // members (RFC 1952), so a body that ends at a member boundary is complete.
    bool isTruncated() const { return m_sawInput && m_inMember; }

private:
    z_stream m_stream;
    bool m_initialized { false };
    bool m_sawInput { false };
    bool m_inMember { false };
    bool m_failed { false };
};

} // namespace WebCore
