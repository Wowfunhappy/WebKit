#include <gst/gst.h>
#include <stdio.h>

static void encoded_buffer(GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer context)
{
    (void)sink;
    (void)pad;
    g_assert_cmpuint(gst_buffer_get_size(buffer), >, 0);
    g_atomic_int_inc((gint *)context);
}

static void check_encoding(const char *profile)
{
    gchar *description = g_strdup_printf("videotestsrc num-buffers=4 ! "
        "video/x-raw,format=NV12,width=320,height=240,framerate=30/1 ! vtenc_h264 ! "
        "video/x-h264,profile=%s ! fakesink name=output signal-handoffs=true sync=false", profile);
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch(description, &error);
    g_free(description);
    g_assert_no_error(error);
    g_assert_nonnull(pipeline);
    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "output");
    gint encoded = 0;
    g_signal_connect(sink, "handoff", G_CALLBACK(encoded_buffer), &encoded);
    g_assert_cmpint(gst_element_set_state(pipeline, GST_STATE_PLAYING), !=, GST_STATE_CHANGE_FAILURE);
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message = gst_bus_timed_pop_filtered(bus, 10 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
    g_assert_nonnull(message);
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        gchar *debug = NULL;
        gst_message_parse_error(message, &error, &debug);
        g_printerr("Encoding %s failed: %s (%s)\n", profile, error->message, debug ? debug : "");
        g_free(debug);
        g_clear_error(&error);
    }
    g_assert_cmpint(GST_MESSAGE_TYPE(message), ==, GST_MESSAGE_EOS);
    g_assert_cmpint(g_atomic_int_get(&encoded), ==, 4);
    GstPad *pad = gst_element_get_static_pad(sink, "sink");
    GstCaps *outputCaps = gst_pad_get_current_caps(pad);
    g_assert_nonnull(outputCaps);
    g_assert_cmpstr(gst_structure_get_string(gst_caps_get_structure(outputCaps, 0), "profile"), ==, profile);
    printf("PASS H.264 requested %s, encoded profile %s\n", profile,
        gst_structure_get_string(gst_caps_get_structure(outputCaps, 0), "profile"));
    const GValue *codecData = gst_structure_get_value(gst_caps_get_structure(outputCaps, 0), "codec_data");
    g_assert_nonnull(codecData);
    GstMapInfo mapping = GST_MAP_INFO_INIT;
    g_assert_true(gst_buffer_map(gst_value_get_buffer(codecData), &mapping, GST_MAP_READ));
    g_assert_cmpuint(mapping.size, >=, 4);
    printf("H.264 avcC profile=%02x constraints=%02x level=%02x\n", mapping.data[1], mapping.data[2], mapping.data[3]);
    gst_buffer_unmap(gst_value_get_buffer(codecData), &mapping);
    gst_caps_unref(outputCaps);
    gst_object_unref(pad);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_message_unref(message);
    gst_object_unref(bus);
    gst_object_unref(sink);
    gst_object_unref(pipeline);
    printf("PASS H.264 profile %s encodes four frames\n", profile);
}

int main(int argc, char **argv)
{
    gst_init(&argc, &argv);
    if (argc == 2) {
        check_encoding(argv[1]);
        return 0;
    }
    GstElementFactory *factory = gst_element_factory_find("vtenc_h264");
    g_assert_nonnull(factory);
    GstCaps *caps = NULL;
    for (const GList *item = gst_element_factory_get_static_pad_templates(factory); item; item = item->next) {
        GstStaticPadTemplate *pad = item->data;
        if (pad->direction == GST_PAD_SRC) {
            caps = gst_static_pad_template_get_caps(pad);
            break;
        }
    }
    g_assert_nonnull(caps);
    const char *profiles[] = { "main", "baseline", "constrained-baseline", "high",
        "high-10", "high-4:2:2", "high-4:4:4", "extended" };
    for (unsigned i = 0; i < G_N_ELEMENTS(profiles); ++i) {
        GstCaps *requested = gst_caps_new_simple("video/x-h264", "profile", G_TYPE_STRING, profiles[i], NULL);
        gboolean supported = gst_caps_can_intersect(caps, requested);
        g_assert_cmpint(supported, ==, i < 4);
        printf("PASS H.264 profile %s supported=%d\n", profiles[i], supported);
        gst_caps_unref(requested);
    }
    GstCaps *fixed = gst_caps_fixate(gst_caps_copy(caps));
    g_assert_cmpstr(gst_structure_get_string(gst_caps_get_structure(fixed, 0), "profile"), ==, "main");
    puts("PASS unconstrained H.264 profile defaults to main");
    gst_caps_unref(fixed);
    gst_caps_unref(caps);
    gst_object_unref(factory);
    for (unsigned i = 0; i < 4; ++i)
        check_encoding(profiles[i]);
    return 0;
}
