#include <gst/gst.h>
#include <stdio.h>

typedef struct {
    GstPad *sink;
    gboolean deactivate;
} ProbeContext;

static GstFlowReturn countBuffer(GstPad *pad, GstObject *parent, GstBuffer *buffer)
{
    (void)parent;
    ++*(unsigned *)gst_pad_get_element_private(pad);
    gst_buffer_unref(buffer);
    return GST_FLOW_OK;
}

static GstPadProbeReturn linkDuringProbe(GstPad *pad, GstPadProbeInfo *info, gpointer data)
{
    (void)info;
    ProbeContext *context = data;
    if (context->deactivate)
        g_assert_true(gst_pad_set_active(pad, FALSE));
    g_assert_cmpint(gst_pad_link(pad, context->sink), ==, GST_PAD_LINK_OK);
    return GST_PAD_PROBE_REMOVE;
}

static void checkProbeDeactivation(void)
{
    for (unsigned blocking = 0; blocking < 2; ++blocking) {
        for (unsigned list = 0; list < 2; ++list) {
            for (unsigned deactivate = 0; deactivate < 2; ++deactivate) {
                GstPad *src = gst_pad_new("source", GST_PAD_SRC);
                GstPad *sink = gst_pad_new("sink", GST_PAD_SINK);
                unsigned received = 0;
                gst_pad_set_element_private(sink, &received);
                gst_pad_set_chain_function(sink, countBuffer);
                g_assert_true(gst_pad_set_active(src, TRUE));
                g_assert_true(gst_pad_set_active(sink, TRUE));
                gst_pad_push_event(src, gst_event_new_stream_start("probe-stream"));
                GstSegment segment;
                gst_segment_init(&segment, GST_FORMAT_TIME);
                gst_pad_push_event(src, gst_event_new_segment(&segment));
                ProbeContext context = {sink, deactivate};
                GstPadProbeType type = list ? GST_PAD_PROBE_TYPE_BUFFER_LIST : GST_PAD_PROBE_TYPE_BUFFER;
                if (blocking)
                    type |= GST_PAD_PROBE_TYPE_BLOCK;
                gst_pad_add_probe(src, type, linkDuringProbe, &context, NULL);
                GstFlowReturn result;
                if (list) {
                    GstBufferList *buffers = gst_buffer_list_new();
                    gst_buffer_list_add(buffers, gst_buffer_new());
                    result = gst_pad_push_list(src, buffers);
                } else
                    result = gst_pad_push(src, gst_buffer_new());
                g_assert_cmpint(result, ==, deactivate ? GST_FLOW_FLUSHING : GST_FLOW_OK);
                g_assert_cmpuint(received, ==, deactivate ? 0 : 1);
                gst_pad_unlink(src, sink);
                gst_pad_set_active(src, FALSE);
                gst_pad_set_active(sink, FALSE);
                gst_object_unref(src);
                gst_object_unref(sink);
            }
        }
    }
    puts("PASS buffer and buffer-list probes reject data after pad deactivation");
}

static int checkPadStates(void)
{
    GstElement *queue = gst_element_factory_make("multiqueue", NULL);
    g_assert_nonnull(queue);
    GstState states[] = {GST_STATE_NULL, GST_STATE_READY, GST_STATE_PAUSED, GST_STATE_PLAYING, GST_STATE_READY};
    int failed = 0;
    for (unsigned i = 0; i < G_N_ELEMENTS(states); ++i) {
        g_assert_cmpint(gst_element_set_state(queue, states[i]), !=, GST_STATE_CHANGE_FAILURE);
        GstPad *sink = gst_element_request_pad_simple(queue, "sink_%u");
        GstPad *src = gst_element_get_static_pad(queue, "src_0");
        gboolean expected = states[i] >= GST_STATE_PAUSED;
        printf("%s requested pads: sink=%d src=%d task=%d expected active=%d\n", gst_element_state_get_name(states[i]), gst_pad_is_active(sink), gst_pad_is_active(src), gst_pad_get_task_state(src), expected);
        failed |= gst_pad_is_active(sink) != expected || gst_pad_is_active(src) != expected;
        failed |= gst_pad_get_task_state(src) != (expected ? GST_TASK_STARTED : GST_TASK_STOPPED);
        gst_element_release_request_pad(queue, sink);
        gst_object_unref(sink);
        gst_object_unref(src);
    }
    gst_element_set_state(queue, GST_STATE_NULL);
    gst_object_unref(queue);
    return failed;
}

static gpointer announceStream(gpointer data)
{
    GstPad *pad = data;
    GstCaps *caps = gst_caps_from_string("audio/x-raw,format=S16LE,rate=48000,channels=1,layout=interleaved");
    GstStream *stream = gst_stream_new(GST_OBJECT_NAME(pad), caps, GST_STREAM_TYPE_AUDIO, GST_STREAM_FLAG_SELECT);
    GstStreamCollection *collection = gst_stream_collection_new(GST_OBJECT_NAME(pad));
    gst_stream_collection_add_stream(collection, gst_object_ref(stream));
    GstEvent *event = gst_event_new_stream_start(GST_OBJECT_NAME(pad));
    gst_event_set_stream(event, stream);
    gst_event_set_group_id(event, gst_util_group_id_next());
    gst_pad_push_event(pad, event);
    gst_pad_push_event(pad, gst_event_new_stream_collection(collection));
    gst_pad_push_event(pad, gst_event_new_caps(caps));
    GstSegment segment;
    gst_segment_init(&segment, GST_FORMAT_TIME);
    gst_pad_push_event(pad, gst_event_new_segment(&segment));
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, 1024, NULL);
    GST_BUFFER_PTS(buffer) = 0;
    gst_pad_push(pad, buffer);
    gst_caps_unref(caps);
    gst_object_unref(stream);
    gst_object_unref(collection);
    return NULL;
}

// Reproduce a track announcement after decodebin3's multiqueue child reaches
// READY and before decodebin3 deactivates its inputs and frees the stream slots.
static void checkDecodebinTeardown(void)
{
    for (unsigned i = 0; i < 1000; ++i) {
        GstElement *bin = gst_element_factory_make("decodebin3", NULL);
        g_assert_nonnull(bin);
        GstElement *mq = NULL;
        GstIterator *it = gst_bin_iterate_elements(GST_BIN(bin));
        GValue value = G_VALUE_INIT;
        while (gst_iterator_next(it, &value) == GST_ITERATOR_OK) {
            GstElement *child = g_value_get_object(&value);
            if (g_str_has_prefix(GST_ELEMENT_NAME(child), "multiqueue"))
                mq = gst_object_ref(child);
            g_value_reset(&value);
        }
        g_value_unset(&value);
        gst_iterator_free(it);
        g_assert_nonnull(mq);
        GstPad *sink = gst_element_get_static_pad(bin, "sink");
        GstPad *src = gst_pad_new("src", GST_PAD_SRC);
        gst_pad_set_active(src, TRUE);
        g_assert_cmpint(gst_pad_link(src, sink), ==, GST_PAD_LINK_OK);
        g_assert_cmpint(gst_element_set_state(bin, GST_STATE_PAUSED), !=, GST_STATE_CHANGE_FAILURE);
        // Recreate the child READY phase of the parent's PAUSED-to-READY transition.
        g_assert_cmpint(gst_element_set_state(mq, GST_STATE_READY), !=, GST_STATE_CHANGE_FAILURE);
        GThread *thread = g_thread_new("incoming-stream", announceStream, src);
        // A newly announced track can arrive before the bin deactivates its inputs.
        g_thread_join(thread);
        g_assert_cmpint(gst_element_set_state(bin, GST_STATE_READY), !=, GST_STATE_CHANGE_FAILURE);
        gst_pad_unlink(src, sink);
        gst_pad_set_active(src, FALSE);
        gst_object_unref(src);
        gst_object_unref(sink);
        gst_object_unref(mq);
        gst_element_set_state(bin, GST_STATE_NULL);
        gst_object_unref(bin);
    }
    puts("PASS 1000 decodebin track announcements during teardown");
}

static void checkConcurrentTeardown(void)
{
    for (unsigned i = 0; i < 1000; ++i) {
        GstElement *bin = gst_element_factory_make("decodebin3", NULL);
        g_assert_nonnull(bin);
        GstPad *sinks[] = {gst_element_get_static_pad(bin, "sink"), gst_element_request_pad_simple(bin, "sink_%u")};
        GstPad *sources[] = {gst_pad_new("first", GST_PAD_SRC), gst_pad_new("second", GST_PAD_SRC)};
        for (unsigned j = 0; j < 2; ++j) {
            gst_pad_set_active(sources[j], TRUE);
            g_assert_cmpint(gst_pad_link(sources[j], sinks[j]), ==, GST_PAD_LINK_OK);
        }
        g_assert_cmpint(gst_element_set_state(bin, GST_STATE_PAUSED), !=, GST_STATE_CHANGE_FAILURE);
        announceStream(sources[0]);
        GThread *thread = g_thread_new("incoming-track", announceStream, sources[1]);
        g_assert_cmpint(gst_element_set_state(bin, GST_STATE_READY), !=, GST_STATE_CHANGE_FAILURE);
        g_thread_join(thread);
        for (unsigned j = 0; j < 2; ++j) {
            gst_pad_unlink(sources[j], sinks[j]);
            gst_pad_set_active(sources[j], FALSE);
            gst_object_unref(sources[j]);
        }
        gst_element_release_request_pad(bin, sinks[1]);
        gst_object_unref(sinks[0]);
        gst_object_unref(sinks[1]);
        gst_element_set_state(bin, GST_STATE_NULL);
        gst_object_unref(bin);
    }
    puts("PASS 1000 concurrent decodebin track announcements and teardowns");
}

int main(int argc, char **argv)
{
    g_log_set_always_fatal(G_LOG_FATAL_MASK | G_LOG_LEVEL_WARNING | G_LOG_LEVEL_CRITICAL);
    gst_init(&argc, &argv);
    if (argc == 2 && !g_strcmp0(argv[1], "probe")) {
        checkProbeDeactivation();
        return 0;
    }
    if (argc == 2 && !g_strcmp0(argv[1], "concurrent")) {
        checkConcurrentTeardown();
        return 0;
    }
    if (argc == 2 && !g_strcmp0(argv[1], "decodebin")) {
        checkDecodebinTeardown();
        return 0;
    }
    checkProbeDeactivation();
    if (checkPadStates())
        return 1;
    checkDecodebinTeardown();
    checkConcurrentTeardown();
    return 0;
}
