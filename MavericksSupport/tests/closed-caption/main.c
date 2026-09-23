#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    gst_init(&argc, &argv);
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch("appsrc name=source format=time ! ccconverter ! closedcaption/x-cea-608,format=raw ! cea608tott ! application/x-subtitle-vtt ! appsink name=sink sync=false async=false", &error);
    if (error) {
        fprintf(stderr, "%s\n", error->message);
        g_error_free(error);
        if (pipeline)
            gst_object_unref(pipeline);
        return 1;
    }
    GstElement *source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    GstCaps *caps = gst_caps_from_string("closedcaption/x-cea-608,format=raw,framerate=30/1");
    gst_app_src_set_caps(GST_APP_SRC(source), caps);
    gst_caps_unref(caps);
    gst_element_set_state(pipeline, GST_STATE_PLAYING);

    /* Pop-on caption: load "Hi", display at one second, erase at three seconds. */
    const unsigned char packets[][2] = { { 0x94, 0x20 }, { 0x94, 0xae }, { 0x94, 0x70 }, { 0xc8, 0xe9 }, { 0x94, 0x2f }, { 0x94, 0x2c } };
    const GstClockTime timestamps[] = { 0, GST_SECOND / 30, GST_SECOND / 15, GST_SECOND / 10, GST_SECOND, 3 * GST_SECOND };
    for (unsigned i = 0; i < G_N_ELEMENTS(packets); ++i) {
        GstBuffer *buffer = gst_buffer_new_allocate(NULL, 2, NULL);
        gst_buffer_fill(buffer, 0, packets[i], 2);
        GST_BUFFER_PTS(buffer) = timestamps[i];
        GST_BUFFER_DURATION(buffer) = GST_SECOND / 30;
        if (gst_app_src_push_buffer(GST_APP_SRC(source), buffer) != GST_FLOW_OK)
            return 2;
    }
    gst_app_src_end_of_stream(GST_APP_SRC(source));
    GString *output = g_string_new(NULL);
    gboolean cueTiming = FALSE;
    GstSample *sample;
    while ((sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 5 * GST_SECOND))) {
        GstBuffer *buffer = gst_sample_get_buffer(sample);
        GstMapInfo map;
        gst_buffer_map(buffer, &map, GST_MAP_READ);
        g_string_append_len(output, (const char *)map.data, map.size);
        if (GST_BUFFER_DURATION_IS_VALID(buffer))
            cueTiming = GST_BUFFER_PTS(buffer) == GST_SECOND && GST_BUFFER_DURATION(buffer) == 2 * GST_SECOND;
        gst_buffer_unmap(buffer, &map);
        gst_sample_unref(sample);
    }
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *failure = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
    gboolean success = !failure && cueTiming && !strcmp(output->str, "WEBVTT\r\n\r\n00:00:01.000 --> 00:00:03.000\r\nHi\r\n\r\n");
    printf("%s CEA-608 to WebVTT: cue text, timestamp and duration\n%s", success ? "PASS" : "FAIL", output->str);
    if (failure) {
        gchar *debug = NULL;
        gst_message_parse_error(failure, &error, &debug);
        fprintf(stderr, "%s: %s\n", error->message, debug ? debug : "");
        g_clear_error(&error);
        g_free(debug);
        gst_message_unref(failure);
    }
    g_string_free(output, TRUE);
    gst_object_unref(bus);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(source);
    gst_object_unref(sink);
    gst_object_unref(pipeline);
    return success ? 0 : 1;
}
