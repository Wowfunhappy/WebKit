#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <stdio.h>
#include <string.h>

static unsigned frames;
static GChecksum *checksum;

static void collect(GstElement *sink)
{
    GstSample *sample;
    while ((sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 200 * GST_MSECOND))) {
        GstMapInfo map;
        gst_buffer_map(gst_sample_get_buffer(sample), &map, GST_MAP_READ);
        g_checksum_update(checksum, map.data, map.size);
        gst_buffer_unmap(gst_sample_get_buffer(sample), &map);
        ++frames;
        gst_sample_unref(sample);
    }
}

static void append(GstElement *source, const char *bytes, gsize size, gsize chunk)
{
    for (gsize offset = 0; offset < size; offset += chunk) {
        gsize length = MIN(chunk, size - offset);
        GstBuffer *buffer = gst_buffer_new_allocate(NULL, length, NULL);
        gst_buffer_fill(buffer, 0, bytes + offset, length);
        g_assert_cmpint(gst_app_src_push_buffer(GST_APP_SRC(source), buffer), ==, GST_FLOW_OK);
    }
}

int main(int argc, char **argv)
{
    gst_init(&argc, &argv);
    if (argc != 4)
        return 2;
    char *bytes = NULL;
    gsize size = 0;
    if (!g_file_get_contents(argv[1], &bytes, &size, NULL))
        return 3;
    gsize chunk = strtoul(argv[2], NULL, 10);
    if (!chunk)
        chunk = size;

    unsigned expectedFrames = 0;
    gsize lastFrame = 0, resyncOffset = 0;
    for (gsize offset = 0; offset < size;) {
        const unsigned char *header = (const unsigned char *)bytes + offset;
        if (size - offset < 7 || header[0] != 0xff || (header[1] & 0xf6) != 0xf0)
            return 4;
        gsize length = ((header[3] & 3) << 11) | (header[4] << 3) | (header[5] >> 5);
        if (length < 7 || length > size - offset)
            return 5;
        lastFrame = offset;
        offset += length;
        if (++expectedFrames == 3)
            resyncOffset = offset;
    }
    gboolean partial = !strcmp(argv[3], "partial");
    gboolean truncated = !strcmp(argv[3], "truncated");
    gboolean resync = !strcmp(argv[3], "resync");
    char *expectedHash = g_compute_checksum_for_data(G_CHECKSUM_SHA256, (const guchar *)bytes, truncated ? lastFrame : size);
    checksum = g_checksum_new(G_CHECKSUM_SHA256);

#ifdef PROBE_AAC_PARSER
    /* Optional standalone dependency-source validation before the production recipe builds. */
    extern GType gst_aac_parse_get_type(void);
    gst_element_register(NULL, "probeaacparse", GST_RANK_NONE, gst_aac_parse_get_type());
    const char *parserName = "probeaacparse";
#else
    const char *parserName = "aacparse";
#endif
    GstElement *pipeline = gst_pipeline_new(NULL);
    GstElement *source = gst_element_factory_make("appsrc", NULL);
    GstElement *parser = gst_element_factory_make(parserName, NULL);
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (!source || !parser || !sink)
        return 6;
    GstCaps *caps = gst_caps_new_simple("audio/mpeg", "mpegversion", G_TYPE_INT, 4, "stream-format", G_TYPE_STRING, "adts", NULL);
    gst_app_src_set_caps(GST_APP_SRC(source), caps);
    gst_caps_unref(caps);
    g_object_set(source, "format", GST_FORMAT_TIME, NULL);
    g_object_set(sink, "sync", FALSE, "async", FALSE, NULL);
    gst_bin_add_many(GST_BIN(pipeline), source, parser, sink, NULL);
    if (!gst_element_link_many(source, parser, sink, NULL))
        return 7;
    gst_element_set_state(pipeline, GST_STATE_PLAYING);

    if (resync) {
        append(source, bytes, resyncOffset, chunk);
        append(source, "NOTAACHEADER", 11, 11);
        append(source, bytes + resyncOffset, size - resyncOffset, chunk);
    } else
        append(source, bytes, size - (partial || truncated), chunk);
    collect(sink);
    gboolean success = TRUE;
    if (partial) {
        success &= frames == expectedFrames - 1;
        printf("Incomplete final frame: %u/%u complete frames\n", frames, expectedFrames - 1);
        append(source, bytes + size - 1, 1, 1);
        collect(sink);
    }
    if (truncated)
        --expectedFrames;
    success &= frames == expectedFrames;
    printf("Before EOS: %u/%u frames\n", frames, expectedFrames);
    gst_app_src_end_of_stream(GST_APP_SRC(source));
    collect(sink);
    success &= frames == expectedFrames && !strcmp(expectedHash, g_checksum_get_string(checksum));
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *error = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
    success &= !error;
    if (error)
        gst_message_unref(error);
    gst_object_unref(bus);
    printf("%s chunk=%zu mode=%s frames=%u sha256=%s\n", success ? "PASS" : "FAIL", chunk, argv[3], frames, g_checksum_get_string(checksum));
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    g_checksum_free(checksum);
    g_free(expectedHash);
    g_free(bytes);
    return success ? 0 : 1;
}
