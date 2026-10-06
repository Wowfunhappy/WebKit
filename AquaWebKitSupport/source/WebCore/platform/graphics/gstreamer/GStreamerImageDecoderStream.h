#pragma once

#include "GStreamerElementHarness.h"
#include "SharedBuffer.h"

namespace WebCore {

// ImageDecoder receives cumulative buffers; a demuxer consumes an append-only byte stream.
class GStreamerImageDecoderStream {
public:
    enum class Status { Incomplete, Complete, Error };
    Status append(const FragmentedSharedBuffer&, bool allDataReceived, GStreamerElementHarness&, const RefPtr<GStreamerElementHarness>& decoder);

private:
    GRefPtr<GstCaps> m_caps;
    size_t m_bytesPushed { 0 };
    Status m_status { Status::Incomplete };
    bool m_receivedDecoderEOS { false };
};

}
