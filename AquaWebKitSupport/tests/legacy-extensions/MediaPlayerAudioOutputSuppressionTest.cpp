#include "config.h"
#include "MediaPlayerAudioOutputSuppression.h"
#include <gst/app/gstappsrc.h>
#include <gst/audio/audio.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <memory>

static void require(bool condition, const char* message)
{
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", message);
        exit(1);
    }
}

struct Sink {
    GstElement* pipeline;
    GstElement* source;
    GAsyncQueue* rendered { g_async_queue_new() };
    GstAudioInfo audio;

    Sink(WebCore::MediaPlayerAudioOutputSuppression& output, const char* format)
    {
        pipeline = gst_pipeline_new(nullptr);
        source = gst_element_factory_make("appsrc", nullptr);
        auto* sink = gst_element_factory_make("fakesink", nullptr);
        require(pipeline && source && sink, "create pipeline");
        gst_audio_info_init(&audio);
        gst_audio_info_set_format(&audio, gst_audio_format_from_string(format), 48000, 2, nullptr);
        auto* caps = gst_audio_info_to_caps(&audio);
        gst_app_src_set_caps(GST_APP_SRC(source), caps);
        gst_caps_unref(caps);
        g_object_set(source, "format", GST_FORMAT_TIME, nullptr);
        g_object_set(sink, "sync", FALSE, "async", FALSE, "signal-handoffs", TRUE, nullptr);
        output.configureSink(sink);
        g_signal_connect(sink, "handoff", G_CALLBACK(+[](GstElement*, GstBuffer* buffer, GstPad*, gpointer data) {
            g_async_queue_push(static_cast<GAsyncQueue*>(data), gst_buffer_ref(buffer));
        }), rendered);
        gst_bin_add_many(GST_BIN(pipeline), source, sink, nullptr);
        require(gst_element_link(source, sink), "link pipeline");
        require(gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE, "play pipeline");
    }

    ~Sink()
    {
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        g_async_queue_unref(rendered);
    }

    void push(bool suppressed, bool list = false)
    {
        auto* original = gst_buffer_new_allocate(nullptr, 32, nullptr);
        gst_buffer_memset(original, 0, 0x13, 32);
        GST_BUFFER_PTS(original) = 0;
        GST_BUFFER_DURATION(original) = GST_SECOND / 100;
        if (list) {
            auto* buffers = gst_buffer_list_new();
            gst_buffer_list_add(buffers, gst_buffer_ref(original));
            gst_buffer_list_add(buffers, gst_buffer_ref(original));
            require(gst_app_src_push_buffer_list(GST_APP_SRC(source), buffers) == GST_FLOW_OK, "push buffer list");
        } else
            require(gst_app_src_push_buffer(GST_APP_SRC(source), gst_buffer_ref(original)) == GST_FLOW_OK, "push buffer");
        for (unsigned i = 0; i < (list ? 2u : 1u); ++i) {
            auto* buffer = static_cast<GstBuffer*>(g_async_queue_timeout_pop(rendered, 5 * G_TIME_SPAN_SECOND));
            require(buffer, "rendered buffer arrives");
            unsigned char actual[32];
            require(gst_buffer_extract(buffer, 0, actual, sizeof(actual)) == sizeof(actual), "read rendered PCM");
            unsigned char expected = suppressed ? (GST_AUDIO_INFO_FORMAT(&audio) == GST_AUDIO_FORMAT_U8 ? 0x80 : 0) : 0x13;
            require(std::all_of(std::begin(actual), std::end(actual), [&](auto byte) { return byte == expected; }), "rendered PCM suppression state");
            require(GST_BUFFER_PTS(buffer) == 0 && GST_BUFFER_DURATION(buffer) == GST_SECOND / 100, "preserve rendering clock");
            gst_buffer_unref(buffer);
        }
        unsigned char capture[32];
        gst_buffer_extract(original, 0, capture, sizeof(capture));
        require(std::all_of(std::begin(capture), std::end(capture), [](auto byte) { return byte == 0x13; }), "upstream capture PCM remains unchanged");
        gst_buffer_unref(original);
    }

    void end()
    {
        gst_app_src_end_of_stream(GST_APP_SRC(source));
        auto* bus = gst_element_get_bus(pipeline);
        auto* message = gst_bus_timed_pop_filtered(bus, 5 * GST_SECOND, static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
        require(message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS, "natural EOS");
        gst_message_unref(message);
        gst_object_unref(bus);
    }
};

int main(int argc, char** argv)
{
    gst_init(&argc, &argv);
    for (auto* format : { "U8", "S16LE", "F32LE" }) {
        auto output = std::make_unique<WebCore::MediaPlayerAudioOutputSuppression>();
        {
            Sink first(*output, format);
            first.push(false);
            output->setSuppressed(true);
            first.push(true);
            first.push(true, true);
            first.end();
        }
        {
            Sink replay(*output, format);
            replay.push(true);
            require(gst_element_set_state(replay.pipeline, GST_STATE_READY) != GST_STATE_CHANGE_FAILURE, "flush output");
            require(gst_element_set_state(replay.pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE, "restart output");
            replay.push(true, true);
            output->setSuppressed(false);
            replay.push(false);
            output->setSuppressed(true);
            output.reset();
            replay.push(true);
            replay.end();
        }
        printf("PASS %s: buffers, lists, EOS/replay, rebuilt sink, un-suppression, state lifetime, upstream PCM\n", format);
    }
}
