#include "config.h"
#include "AdaptiveStreamGStreamer.h"

namespace WebCore {

std::optional<bool> legacyAdaptiveStreamIsLive(GstElement* pipeline)
{
    auto adaptiveType = g_type_from_name("GstAdaptiveDemux");
    if (!pipeline || !GST_IS_BIN(pipeline) || !adaptiveType)
        return std::nullopt;

    auto* iterator = gst_bin_iterate_recurse(GST_BIN(pipeline));
    GValue item = G_VALUE_INIT;
    std::optional<bool> result;
    bool done = false;
    while (!done) {
        switch (gst_iterator_next(iterator, &item)) {
        case GST_ITERATOR_OK: {
            auto* element = GST_ELEMENT(g_value_get_object(&item));
            if (g_type_is_a(G_OBJECT_TYPE(element), adaptiveType)) {
                gint64 duration = 0;
                if (gst_element_query_duration(element, GST_FORMAT_TIME, &duration)) {
                    result = duration == -1;
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

}
