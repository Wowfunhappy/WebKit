/* A file-backed HTTP GstPushSrc exercises playbin's network/queue2 path without
 * network I/O. Compare its non-flushing segment loops with the file/pull path. */
#include <gst/gst.h>
#include <gst/base/gstpushsrc.h>
#include <stdio.h>
#include <string.h>

typedef struct { GstPushSrc parent; gchar *uri; FILE *f; guint64 size; guint64 offset; } LocalHttpSrc;
typedef struct { GstPushSrcClass parent_class; } LocalHttpSrcClass;
static void local_http_src_uri_handler_init (gpointer g_iface, gpointer iface_data);
G_DEFINE_TYPE_WITH_CODE (LocalHttpSrc, local_http_src, GST_TYPE_PUSH_SRC,
    G_IMPLEMENT_INTERFACE (GST_TYPE_URI_HANDLER, local_http_src_uri_handler_init));
enum { PROP_0, PROP_LOCATION };
static GstStaticPadTemplate src_template = GST_STATIC_PAD_TEMPLATE ("src", GST_PAD_SRC, GST_PAD_ALWAYS, GST_STATIC_CAPS_ANY);

static const gchar *path_of (const gchar *uri)
{
  const gchar *p = strstr (uri, "://");
  if (!p) return uri;
  p = strchr (p + 3, '/');
  return p ? p : "/";
}

static gboolean lhs_start (GstBaseSrc *bsrc)
{
  LocalHttpSrc *s = (LocalHttpSrc *) bsrc;
  if (!s->uri) return FALSE;
  gchar *path = g_uri_unescape_string (path_of (s->uri), NULL);
  s->f = fopen (path, "rb");
  g_free (path);
  if (!s->f) {
    GST_ELEMENT_ERROR (s, RESOURCE, NOT_FOUND, ("not found"), ("%s", s->uri));
    return FALSE;
  }
  fseeko (s->f, 0, SEEK_END);
  s->size = ftello (s->f);
  fseeko (s->f, 0, SEEK_SET);
  s->offset = 0;
  return TRUE;
}

static gboolean lhs_stop (GstBaseSrc *bsrc)
{
  LocalHttpSrc *s = (LocalHttpSrc *) bsrc;
  if (s->f) fclose (s->f);
  s->f = NULL;
  return TRUE;
}

static gboolean lhs_get_size (GstBaseSrc *bsrc, guint64 *size) { *size = ((LocalHttpSrc *) bsrc)->size; return TRUE; }
static gboolean lhs_is_seekable (GstBaseSrc *bsrc) { return TRUE; }

static gboolean lhs_do_seek (GstBaseSrc *bsrc, GstSegment *segment)
{
  LocalHttpSrc *s = (LocalHttpSrc *) bsrc;
  s->offset = segment->start;
  if (s->f) fseeko (s->f, s->offset, SEEK_SET);
  segment->position = segment->start;
  segment->time = segment->start;
  return TRUE;
}

static GstFlowReturn lhs_create (GstPushSrc *psrc, GstBuffer **outbuf)
{
  LocalHttpSrc *s = (LocalHttpSrc *) psrc;
  GstBaseSrc *bsrc = GST_BASE_SRC (psrc);
  guint64 stop = bsrc->segment.stop;
  if (s->offset >= s->size || (stop != (guint64) -1 && s->offset >= stop))
    return GST_FLOW_EOS;
  guint64 len = 4096;
  if (s->offset + len > s->size) len = s->size - s->offset;
  if (stop != (guint64) -1 && s->offset + len > stop) len = stop - s->offset;
  GstBuffer *buf = gst_buffer_new_allocate (NULL, len, NULL);
  GstMapInfo map;
  gst_buffer_map (buf, &map, GST_MAP_WRITE);
  size_t got = fread (map.data, 1, len, s->f);
  gst_buffer_unmap (buf, &map);
  if (!got) { gst_buffer_unref (buf); return GST_FLOW_EOS; }
  gst_buffer_set_size (buf, got);
  GST_BUFFER_OFFSET (buf) = s->offset;
  s->offset += got;
  GST_BUFFER_OFFSET_END (buf) = s->offset;
  *outbuf = buf;
  return GST_FLOW_OK;
}

static void lhs_set_property (GObject *o, guint id, const GValue *v, GParamSpec *p)
{
  LocalHttpSrc *s = (LocalHttpSrc *) o;
  if (id == PROP_LOCATION) { g_free (s->uri); s->uri = g_value_dup_string (v); }
}

static void lhs_get_property (GObject *o, guint id, GValue *v, GParamSpec *p)
{
  if (id == PROP_LOCATION) g_value_set_string (v, ((LocalHttpSrc *) o)->uri);
}

static void lhs_finalize (GObject *object)
{
  g_free (((LocalHttpSrc *) object)->uri);
  G_OBJECT_CLASS (local_http_src_parent_class)->finalize (object);
}

static void local_http_src_class_init (LocalHttpSrcClass *klass)
{
  GObjectClass *oc = G_OBJECT_CLASS (klass);
  GstElementClass *ec = GST_ELEMENT_CLASS (klass);
  GstBaseSrcClass *bc = GST_BASE_SRC_CLASS (klass);
  oc->set_property = lhs_set_property;
  oc->get_property = lhs_get_property;
  oc->finalize = lhs_finalize;
  g_object_class_install_property (oc, PROP_LOCATION, g_param_spec_string ("location", "l", "l", NULL, G_PARAM_READWRITE));
  gst_element_class_add_static_pad_template (ec, &src_template);
  gst_element_class_set_static_metadata (ec, "localhttpsrc", "Source/Network", "file-backed http push source", "probe");
  bc->start = lhs_start;
  bc->stop = lhs_stop;
  bc->get_size = lhs_get_size;
  bc->is_seekable = lhs_is_seekable;
  bc->do_seek = lhs_do_seek;
  GST_PUSH_SRC_CLASS (klass)->create = lhs_create;
}

static void local_http_src_init (LocalHttpSrc *s)
{
  gst_base_src_set_format (GST_BASE_SRC (s), GST_FORMAT_BYTES);
}

static GstURIType lhs_uri_get_type (GType type) { return GST_URI_SRC; }
static const gchar *const *lhs_uri_get_protocols (GType type) { static const gchar *p[] = { "http", "https", NULL }; return p; }
static gchar *lhs_uri_get_uri (GstURIHandler *h) { return g_strdup (((LocalHttpSrc *) h)->uri); }
static gboolean lhs_uri_set_uri (GstURIHandler *h, const gchar *uri, GError **e) { LocalHttpSrc *s = (LocalHttpSrc *) h; g_free (s->uri); s->uri = g_strdup (uri); return TRUE; }

static void local_http_src_uri_handler_init (gpointer g_iface, gpointer iface_data)
{
  GstURIHandlerInterface *iface = g_iface;
  iface->get_type = lhs_uri_get_type;
  iface->get_protocols = lhs_uri_get_protocols;
  iface->get_uri = lhs_uri_get_uri;
  iface->set_uri = lhs_uri_set_uri;
}

static GstElement *pipeline;
static GMainLoop *loop;
static GstClockTime segment_stop;
static GstClockTime last_video_pts = GST_CLOCK_TIME_NONE;
static guint video_loops, truncated_loops, completions;
static GstClockTime last_audio_pts = GST_CLOCK_TIME_NONE;
static GstClockTime last_audio_end = GST_CLOCK_TIME_NONE;
static guint audio_loops, truncated_audio_loops;
static gint video_complete, audio_complete;
static guint32 seek_seqnum;
static gboolean started, failed;
static guint created_seeks;
static gint destroyed_seeks;

static void seek_destroyed (gpointer unused, GstMiniObject *object)
{
  g_atomic_int_inc (&destroyed_seeks);
}

static gboolean finish (gpointer unused)
{
  g_main_loop_quit (loop);
  return G_SOURCE_REMOVE;
}

static gboolean finish_completed_streams (gpointer unused)
{
  if (g_atomic_int_get (&video_complete) && g_atomic_int_get (&audio_complete))
    g_main_loop_quit (loop);
  return G_SOURCE_REMOVE;
}

static gboolean timed_out (gpointer unused)
{
  g_printerr ("FAIL: segment looping timed out\n");
  failed = TRUE;
  return finish (NULL);
}

static void seek_segment (gboolean flush)
{
  GstSeekFlags flags = GST_SEEK_FLAG_SEGMENT | GST_SEEK_FLAG_ACCURATE;
  if (flush)
    flags |= GST_SEEK_FLAG_FLUSH;
  GstEvent *event = gst_event_new_seek (1.0, GST_FORMAT_TIME, flags,
      GST_SEEK_TYPE_SET, 0, GST_SEEK_TYPE_SET, segment_stop);
  seek_seqnum = gst_event_get_seqnum (event);
  ++created_seeks;
  gst_mini_object_weak_ref (GST_MINI_OBJECT (event), seek_destroyed, NULL);
  if (!gst_element_send_event (pipeline, event)) {
    g_printerr ("FAIL: segment seek refused\n");
    failed = TRUE;
    g_main_loop_quit (loop);
  }
}

/* Each handoff owns its stream's counters. Main reads them only after the
 * pipeline reaches NULL and joins the streaming threads. */
static void video_handoff (GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer unused)
{
  GstClockTime pts = GST_BUFFER_PTS (buffer);
  if (!GST_CLOCK_TIME_IS_VALID (pts))
    return;
  if (GST_CLOCK_TIME_IS_VALID (last_video_pts) && pts + GST_SECOND < last_video_pts) {
    ++video_loops;
    /* The fixture is approximately 30 fps; allow three frames at the boundary. */
    if (last_video_pts + 100 * GST_MSECOND < segment_stop
        || last_video_pts > segment_stop + 100 * GST_MSECOND)
      ++truncated_loops;
    g_print ("loop %u final frame %" GST_TIME_FORMAT "\n",
        video_loops, GST_TIME_ARGS (last_video_pts));
    if (video_loops == 3) {
      g_atomic_int_set (&video_complete, TRUE);
      g_idle_add (finish_completed_streams, NULL);
    }
  }
  last_video_pts = pts;
}

static void audio_handoff (GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer unused)
{
  GstClockTime pts = GST_BUFFER_PTS (buffer);
  if (!GST_CLOCK_TIME_IS_VALID (pts))
    return;
  if (GST_CLOCK_TIME_IS_VALID (last_audio_pts) && pts + GST_SECOND < last_audio_pts) {
    ++audio_loops;
    if (last_audio_end + 100 * GST_MSECOND < segment_stop
        || last_audio_end > segment_stop + 100 * GST_MSECOND)
      ++truncated_audio_loops;
    g_print ("audio loop %u final sample end %" GST_TIME_FORMAT "\n",
        audio_loops, GST_TIME_ARGS (last_audio_end));
    if (audio_loops == 3) {
      g_atomic_int_set (&audio_complete, TRUE);
      g_idle_add (finish_completed_streams, NULL);
    }
  }
  last_audio_pts = pts;
  last_audio_end = pts;
  if (GST_CLOCK_TIME_IS_VALID (GST_BUFFER_DURATION (buffer)))
    last_audio_end += GST_BUFFER_DURATION (buffer);
}

static gboolean bus_message (GstBus *bus, GstMessage *message, gpointer unused)
{
  switch (GST_MESSAGE_TYPE (message)) {
  case GST_MESSAGE_ASYNC_DONE:
    if (!started) {
      started = TRUE;
      seek_segment (TRUE);
    }
    break;
  case GST_MESSAGE_SEGMENT_DONE: {
    GstFormat format;
    gint64 position;
    gst_message_parse_segment_done (message, &format, &position);
    if (format != GST_FORMAT_TIME || position != segment_stop
        || gst_message_get_seqnum (message) != seek_seqnum) {
      g_printerr ("FAIL: incorrect segment completion format, position or sequence\n");
      failed = TRUE;
      g_main_loop_quit (loop);
      break;
    }
    ++completions;
    seek_segment (FALSE);
    break;
  }
  case GST_MESSAGE_EOS:
    g_printerr ("FAIL: EOS during segment playback\n");
    failed = TRUE;
    g_main_loop_quit (loop);
    break;
  case GST_MESSAGE_ERROR: {
    GError *error = NULL;
    gchar *debug = NULL;
    gst_message_parse_error (message, &error, &debug);
    g_printerr ("FAIL: %s (%s)\n", error->message, debug ? debug : "");
    g_clear_error (&error);
    g_free (debug);
    failed = TRUE;
    g_main_loop_quit (loop);
    break;
  }
  default:
    break;
  }
  return G_SOURCE_CONTINUE;
}

int main (int argc, char **argv)
{
  gst_init (&argc, &argv);
  if (argc != 3)
    return 2;
  segment_stop = g_ascii_strtod (argv[2], NULL) * GST_SECOND;
  gst_element_register (NULL, "localhttpsrc", GST_RANK_PRIMARY + 1000,
      local_http_src_get_type ());
  pipeline = gst_element_factory_make ("playbin", NULL);
  GstElement *audio_sink = gst_element_factory_make ("fakesink", NULL);
  GstElement *video_bin = gst_parse_bin_from_description (
      "capsfilter caps=video/x-raw ! fakesink name=video sync=true signal-handoffs=true", TRUE, NULL);
  if (!pipeline || !audio_sink || !video_bin)
    return 1;
  GstElement *video_sink = gst_bin_get_by_name (GST_BIN (video_bin), "video");
  g_signal_connect (video_sink, "handoff", G_CALLBACK (video_handoff), NULL);
  gst_object_unref (video_sink);
  g_object_set (audio_sink, "sync", TRUE, "signal-handoffs", TRUE, NULL);
  g_signal_connect (audio_sink, "handoff", G_CALLBACK (audio_handoff), NULL);
  g_object_set (pipeline, "uri", argv[1], "audio-sink", audio_sink, "video-sink", video_bin, NULL);
  loop = g_main_loop_new (NULL, FALSE);
  GstBus *bus = gst_element_get_bus (pipeline);
  guint watch = gst_bus_add_watch (bus, bus_message, NULL);
  guint timer = g_timeout_add_seconds (35, timed_out, NULL);
  if (gst_element_set_state (pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
    failed = TRUE;
  if (!failed)
    g_main_loop_run (loop);
  gst_element_set_state (pipeline, GST_STATE_NULL);
  if (g_main_context_find_source_by_id (NULL, timer))
    g_source_remove (timer);
  g_source_remove (watch);
  gst_object_unref (bus);
  gst_object_unref (pipeline);
  g_main_loop_unref (loop);
  gboolean passed = !failed && video_loops >= 3 && !truncated_loops && completions >= 3
      && audio_loops >= 3 && !truncated_audio_loops
      && created_seeks == g_atomic_int_get (&destroyed_seeks);
  g_print ("seek events: %u created, %d released\n", created_seeks, g_atomic_int_get (&destroyed_seeks));
  g_print ("%s: %u video loops (%u truncated), %u audio loops (%u truncated), %u TIME completions\n",
      passed ? "PASS" : "FAIL", video_loops, truncated_loops,
      audio_loops, truncated_audio_loops, completions);
  return passed ? 0 : 1;
}
