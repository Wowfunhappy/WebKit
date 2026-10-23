#include "config.h"
#include "AdaptiveStreamGStreamer.h"
#include "GStreamerCommon.h"

namespace WebCore {

static bool queryAdaptiveStream(GstElement* pipeline, GstQuery* query)
{
    auto adaptiveType = g_type_from_name("GstAdaptiveDemux2");
    if (!pipeline || !GST_IS_BIN(pipeline) || !adaptiveType)
        return false;

    auto* iterator = gst_bin_iterate_recurse(GST_BIN(pipeline));
    GValue item = G_VALUE_INIT;
    bool result = false;
    bool done = false;
    while (!done) {
        switch (gst_iterator_next(iterator, &item)) {
        case GST_ITERATOR_OK: {
            auto* element = GST_ELEMENT(g_value_get_object(&item));
            if (g_type_is_a(G_OBJECT_TYPE(element), adaptiveType)) {
                if (gst_element_query(element, query)) {
                    result = true;
                    done = true;
                }
            }
            g_value_reset(&item);
            break;
        }
        case GST_ITERATOR_RESYNC:
            gst_iterator_resync(iterator);
            break;
        case GST_ITERATOR_ERROR:
        case GST_ITERATOR_DONE:
            done = true;
            break;
        }
    }
    if (G_VALUE_TYPE(&item))
        g_value_unset(&item);
    gst_iterator_free(iterator);
    return result;
}

std::optional<bool> adaptiveStreamIsLive(GstElement* pipeline)
{
    GRefPtr<GstQuery> query = adoptGRef(gst_query_new_duration(GST_FORMAT_TIME));
    if (!queryAdaptiveStream(pipeline, query.get()))
        return std::nullopt;
    gint64 duration = 0;
    gst_query_parse_duration(query.get(), nullptr, &duration);
    return duration == -1;
}

std::optional<PlatformTimeRanges> adaptiveStreamSeekable(GstElement* pipeline)
{
    GRefPtr<GstQuery> query = adoptGRef(gst_query_new_seeking(GST_FORMAT_TIME));
    if (!queryAdaptiveStream(pipeline, query.get()))
        return std::nullopt;
    gboolean seekable = false;
    gint64 start = 0;
    gint64 end = 0;
    gst_query_parse_seeking(query.get(), nullptr, &seekable, &start, &end);
    PlatformTimeRanges ranges;
    if (seekable && start >= 0 && end > start)
        ranges.add(MediaTime(start, GST_SECOND), MediaTime(end, GST_SECOND));
    return ranges;
}

}
