#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <stdio.h>

static void check_first_frame_without_flush(const char* path)
{
    gchar* contents = NULL;
    gsize length = 0;
    g_assert(g_file_get_contents(path, &contents, &length, NULL));
    /* First access unit from WPT's videoDecoder-codec-specific-setup.js. */
    const gsize firstFrameSize = 4175;
    g_assert(length >= firstFrameSize);
    GError* error = NULL;
    GstElement* pipeline = gst_parse_launch("appsrc name=source format=time ! h264parse ! vtdec ! video/x-raw,format=NV12 ! appsink name=sink sync=false async=false", &error);
    g_assert_no_error(error);
    g_assert(pipeline);
    GstElement* source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
    GstElement* sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    GstCaps* caps = gst_caps_from_string("video/x-h264,stream-format=byte-stream,alignment=au,width=320,height=240");
    gst_app_src_set_caps(GST_APP_SRC(source), caps);
    gst_caps_unref(caps);
    g_assert(gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE);
    GstBuffer* buffer = gst_buffer_new_allocate(NULL, firstFrameSize, NULL);
    gst_buffer_fill(buffer, 0, contents, firstFrameSize);
    GST_BUFFER_PTS(buffer) = GST_BUFFER_DTS(buffer) = 0;
    GST_BUFFER_DURATION(buffer) = GST_SECOND / 30;
    g_assert(gst_app_src_push_buffer(GST_APP_SRC(source), buffer) == GST_FLOW_OK);
    GstSample* sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 5 * GST_SECOND);
    g_assert_nonnull(sample);
    g_assert_cmpuint(GST_BUFFER_PTS(gst_sample_get_buffer(sample)), ==, 0);
    gst_sample_unref(sample);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(source);
    gst_object_unref(sink);
    gst_object_unref(pipeline);
    g_free(contents);
    puts("PASS first H.264 frame delivered without flush");
}

int main(int argc, char** argv)
{
    gst_init(&argc, &argv);
    g_assert(argc == 3);
    check_first_frame_without_flush(argv[2]);
    gchar* contents = NULL;
    gsize length = 0;
    g_assert(g_file_get_contents(argv[1], &contents, &length, NULL));
    /* Access units and timestamps from http/tests/webcodecs/h264-reordering-annexB.html. */
    const guint64 frames[][3] = {
        { 41, 41, 25145 }, { 125, 25170, 27313 }, { 83, 27338, 28656 },
        { 208, 28681, 29700 }, { 166, 29725, 30560 }, { 291, 30585, 31486 }
    };
    const guint64 expected[] = { 41, 83, 125, 166, 208, 291 };
    GError* error = NULL;
    GstElement* pipeline = gst_parse_launch("appsrc name=source format=time ! h264parse ! vtdec ! video/x-raw,format=NV12 ! appsink name=sink sync=false async=false", &error);
    g_assert_no_error(error);
    g_assert(pipeline);
    GstElement* source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
    GstElement* sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    GstCaps* caps = gst_caps_from_string("video/x-h264,stream-format=byte-stream,alignment=au,width=640,height=480");
    gst_app_src_set_caps(GST_APP_SRC(source), caps);
    gst_caps_unref(caps);
    g_assert(gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE);
    for (unsigned i = 0; i < G_N_ELEMENTS(frames); ++i) {
        g_assert(frames[i][1] < frames[i][2] && frames[i][2] <= length);
        gsize size = frames[i][2] - frames[i][1];
        GstBuffer* buffer = gst_buffer_new_allocate(NULL, size, NULL);
        gst_buffer_fill(buffer, 0, contents + frames[i][1], size);
        GST_BUFFER_PTS(buffer) = GST_BUFFER_DTS(buffer) = frames[i][0];
        GST_BUFFER_DURATION(buffer) = 1;
        if (i)
            GST_BUFFER_FLAG_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT);
        g_assert(gst_app_src_push_buffer(GST_APP_SRC(source), buffer) == GST_FLOW_OK);
    }
    g_assert(gst_app_src_end_of_stream(GST_APP_SRC(source)) == GST_FLOW_OK);
    unsigned failures = 0, count = 0;
    for (;;) {
        GstSample* sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 10 * GST_SECOND);
        if (!sample)
            break;
        GstClockTime timestamp = GST_BUFFER_PTS(gst_sample_get_buffer(sample));
        printf("frame%u pts%" G_GUINT64_FORMAT " expected%" G_GUINT64_FORMAT "\n", count, timestamp, count < G_N_ELEMENTS(expected) ? expected[count] : GST_CLOCK_TIME_NONE);
        failures += count >= G_N_ELEMENTS(expected) || timestamp != expected[count];
        ++count;
        gst_sample_unref(sample);
    }
    GstBus* bus = gst_element_get_bus(pipeline);
    GstMessage* message = gst_bus_timed_pop_filtered(bus, GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
    if (!message)
        ++failures;
    else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        gchar* debug = NULL;
        gst_message_parse_error(message, &error, &debug);
        fprintf(stderr, "%s: %s\n", error->message, debug ? debug : "");
        g_clear_error(&error);
        g_free(debug);
        ++failures;
    }
    if (message)
        gst_message_unref(message);
    gst_object_unref(bus);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(source);
    gst_object_unref(sink);
    gst_object_unref(pipeline);
    g_free(contents);
    return failures || count != G_N_ELEMENTS(expected);
}
