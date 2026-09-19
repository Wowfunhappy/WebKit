#include "config.h"
#include "GStreamerImageDecoderStream.h"

#include <gst/base/gsttypefindhelper.h>

namespace WebCore {

GStreamerImageDecoderStream::Status GStreamerImageDecoderStream::append(const FragmentedSharedBuffer& data, bool allDataReceived, GStreamerElementHarness& parser, const RefPtr<GStreamerElementHarness>& decoder)
{
    if (m_status != Status::Incomplete)
        return m_status;
    if (data.size() < m_bytesPushed)
        return m_status = Status::Error;

    if (data.size() > m_bytesPushed) {
        auto bytes = data.makeContiguous()->createGBytes();
        auto buffer = adoptGRef(gst_buffer_new_wrapped_bytes(bytes.get()));
        if (!m_caps) {
            m_caps = adoptGRef(gst_type_find_helper_for_buffer(GST_OBJECT_CAST(parser.element()), buffer.get(), nullptr));
            if (!m_caps)
                return allDataReceived ? m_status = Status::Error : Status::Incomplete;
        }
        gst_buffer_resize(buffer.get(), m_bytesPushed, data.size() - m_bytesPushed);
        GST_BUFFER_OFFSET(buffer.get()) = m_bytesPushed;
        GST_BUFFER_OFFSET_END(buffer.get()) = data.size();
        if (!parser.pushSample(adoptGRef(gst_sample_new(buffer.get(), m_caps.get(), nullptr, nullptr))))
            return m_status = Status::Error;
        m_bytesPushed = data.size();
    }

    // EOS drains reordered pictures while retaining the decoder's state between network chunks.
    if (allDataReceived) {
        if (!m_caps)
            return m_status = Status::Error;
        // A demuxer can finish its input before EOS; completion comes from the decoder's output event.
        parser.pushEvent(adoptGRef(gst_event_new_eos()));
    }
    if (!decoder)
        return allDataReceived ? m_status = Status::Error : Status::Incomplete;

    decoder->processOutputSamples();
    for (auto& stream : decoder->outputStreams()) {
        while (auto event = stream->pullEvent()) {
            if (GST_EVENT_TYPE(event.get()) == GST_EVENT_EOS)
                m_receivedDecoderEOS = true;
        }
    }
    if (allDataReceived)
        m_status = m_receivedDecoderEOS ? Status::Complete : Status::Error;
    return m_status;
}

}
