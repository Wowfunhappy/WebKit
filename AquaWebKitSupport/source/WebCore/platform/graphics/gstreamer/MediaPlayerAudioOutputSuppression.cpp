#include "config.h"
#include "MediaPlayerAudioOutputSuppression.h"

#include "GStreamerCommon.h"
#include <gst/audio/audio.h>

namespace WebCore {
void MediaPlayerAudioOutputSuppression::configureSink(GstElement* sink)
{
    GRefPtr pad = adoptGRef(gst_element_get_static_pad(sink, "sink"));
    RELEASE_ASSERT(pad);
    gst_pad_add_probe(pad.get(), static_cast<GstPadProbeType>(GST_PAD_PROBE_TYPE_BUFFER | GST_PAD_PROBE_TYPE_BUFFER_LIST), [](GstPad* pad, GstPadProbeInfo* info, gpointer data) -> GstPadProbeReturn {
        auto& suppressed = *static_cast<std::shared_ptr<std::atomic<bool>>*>(data);
        if (!suppressed->load())
            return GST_PAD_PROBE_OK;
        auto failed = [&] {
            GRefPtr sink = adoptGRef(gst_pad_get_parent_element(pad));
            if (sink)
                GST_ELEMENT_ERROR(sink.get(), STREAM, FAILED, ("Unable to silence inline audio"), (nullptr));
            return GST_PAD_PROBE_DROP;
        };
        GRefPtr caps = adoptGRef(gst_pad_get_current_caps(pad));
        GstAudioInfo audio;
        gst_audio_info_init(&audio);
        if (!caps || !gst_audio_info_from_caps(&audio, caps.get()))
            return failed();
        auto silence = [&](GstBuffer* original) -> GstBuffer* {
            if (!gst_buffer_get_size(original))
                return gst_buffer_ref(original);
            GRefPtr buffer = adoptGRef(gst_buffer_copy_deep(original));
            if (!buffer)
                return nullptr;
            GstMappedBuffer mapped(buffer.get(), GST_MAP_WRITE);
            if (!mapped)
                return nullptr;
            gst_audio_format_info_fill_silence(audio.finfo, mapped.data(), mapped.size());
            return buffer.leakRef();
        };
        if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER_LIST) {
            auto* original = gst_pad_probe_info_get_buffer_list(info);
            auto* list = gst_buffer_list_copy(original);
            for (unsigned i = 0; i < gst_buffer_list_length(list); ++i) {
                auto* buffer = silence(gst_buffer_list_get(list, i));
                if (!buffer) {
                    gst_buffer_list_unref(list);
                    return failed();
                }
                gst_buffer_list_remove(list, i, 1);
                gst_buffer_list_insert(list, i, buffer);
            }
            GST_PAD_PROBE_INFO_DATA(info) = list;
            gst_buffer_list_unref(original);
        } else {
            auto* original = gst_pad_probe_info_get_buffer(info);
            auto* buffer = silence(original);
            if (!buffer)
                return failed();
            GST_PAD_PROBE_INFO_DATA(info) = buffer;
            gst_buffer_unref(original);
        }
        return GST_PAD_PROBE_OK;
    }, new std::shared_ptr<std::atomic<bool>>(m_suppressed), [](gpointer data) { delete static_cast<std::shared_ptr<std::atomic<bool>>*>(data); });
}
}
