// Flush-start arrives while a probe on a source pad is running for a sticky event. The event must not
// reach the peer, and must reach it after flush-stop.
#include <gst/gst.h>
#include <stdio.h>
#include <string.h>

static GMutex lock;
static GCond condition;
static gboolean entered;
static gboolean released;
static GstPad* source;
static GstPad* sink;
static gboolean linkInProbe;
static GString* peerEvents;
static int laterProbeCaps;

static void waitInProbe(void)
{
    g_mutex_lock(&lock);
    entered = TRUE;
    g_cond_broadcast(&condition);
    while (!released)
        g_cond_wait(&condition, &lock);
    g_mutex_unlock(&lock);
}

static GstPadProbeReturn blockProbe(GstPad*, GstPadProbeInfo* info, gpointer)
{
    if (GST_EVENT_TYPE(GST_PAD_PROBE_INFO_EVENT(info)) != GST_EVENT_CAPS)
        return GST_PAD_PROBE_PASS;
    waitInProbe();
    return GST_PAD_PROBE_PASS;
}

static GstPadProbeReturn eventProbe(GstPad*, GstPadProbeInfo* info, gpointer)
{
    if (GST_EVENT_TYPE(GST_PAD_PROBE_INFO_EVENT(info)) != GST_EVENT_CAPS)
        return GST_PAD_PROBE_OK;
    ++laterProbeCaps;
    if (linkInProbe && !GST_PAD_PEER(sink) && !entered) {
        waitInProbe();
        gst_pad_link_full(source, sink, GST_PAD_LINK_CHECK_NOTHING);
    }
    return GST_PAD_PROBE_OK;
}

static gboolean sinkEvent(GstPad*, GstObject*, GstEvent* event)
{
    g_string_append_printf(peerEvents, "%s ", GST_EVENT_TYPE_NAME(event));
    gst_event_unref(event);
    return TRUE;
}

static gpointer pushCaps(gpointer)
{
    GstCaps* caps = gst_caps_new_empty_simple("video/x-h264");
    GST_PAD_STREAM_LOCK(source);
    gst_pad_push_event(source, gst_event_new_stream_start("stream"));
    gst_pad_push_event(source, gst_event_new_caps(caps));
    GST_PAD_STREAM_UNLOCK(source);
    gst_caps_unref(caps);
    return nullptr;
}

static int run(gboolean inBlockProbe)
{
    entered = released = FALSE;
    laterProbeCaps = 0;
    linkInProbe = !inBlockProbe;
    g_string_truncate(peerEvents, 0);
    source = gst_pad_new("src", GST_PAD_SRC);
    sink = gst_pad_new("sink", GST_PAD_SINK);
    gst_pad_set_event_function(sink, sinkEvent);
    gst_pad_set_active(source, TRUE);
    gst_pad_set_active(sink, TRUE);
    if (inBlockProbe) {
        gst_pad_link_full(source, sink, GST_PAD_LINK_CHECK_NOTHING);
        gst_pad_add_probe(source, GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, blockProbe, nullptr, nullptr);
    }
    gst_pad_add_probe(source, GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, eventProbe, nullptr, nullptr);

    GThread* thread = g_thread_new("push", pushCaps, nullptr);
    g_mutex_lock(&lock);
    while (!entered)
        g_cond_wait(&condition, &lock);
    g_mutex_unlock(&lock);
    gst_pad_push_event(source, gst_event_new_flush_start());
    g_mutex_lock(&lock);
    released = TRUE;
    g_cond_broadcast(&condition);
    g_mutex_unlock(&lock);
    g_thread_join(thread);

    const char* name = inBlockProbe ? "block-probe" : "event-probe";
    int failures = 0;
    if (strstr(peerEvents->str, "caps")) {
        printf("FAIL %s: caps reached the peer during the flush: %s\n", name, peerEvents->str);
        ++failures;
    }
    if (inBlockProbe && laterProbeCaps) {
        printf("FAIL %s: a later probe group saw caps during the flush\n", name);
        ++failures;
    }

    g_string_truncate(peerEvents, 0);
    gst_pad_push_event(source, gst_event_new_flush_stop(TRUE));
    GstSegment segment;
    gst_segment_init(&segment, GST_FORMAT_TIME);
    GST_PAD_STREAM_LOCK(source);
    gst_pad_push_event(source, gst_event_new_segment(&segment));
    GST_PAD_STREAM_UNLOCK(source);
    if (!strstr(peerEvents->str, "caps") || !strstr(peerEvents->str, "segment")) {
        printf("FAIL %s: caps and segment did not follow flush-stop: %s\n", name, peerEvents->str);
        ++failures;
    }

    if (!failures)
        printf("PASS %s: after flush-stop: %s\n", name, peerEvents->str);
    gst_pad_unlink(source, sink);
    gst_pad_set_active(source, FALSE);
    gst_pad_set_active(sink, FALSE);
    gst_object_unref(source);
    gst_object_unref(sink);
    return failures;
}

int main(int argc, char** argv)
{
    gst_init(&argc, &argv);
    peerEvents = g_string_new(nullptr);
    int failures = run(FALSE);
    failures += run(TRUE);
    return failures ? 1 : 0;
}
