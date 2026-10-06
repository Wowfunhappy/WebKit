// Exercise the private resync function in the prepared dependency's real source.
#include "gsthlsdemux.c"
#include <stdio.h>

static void check_position(GstHLSDemux* demux, GstM3U8* playlist,
    GstClockTime position, gint64 sequence, GstClockTime fragmentPosition)
{
    playlist->sequence_position = position;
    gst_hls_demux_resync_playlist(demux, playlist, TRUE);
    g_assert_cmpint(playlist->sequence, ==, sequence);
    g_assert_cmpuint(playlist->sequence_position, ==, fragmentPosition);
    GstClockTime actualPosition = GST_CLOCK_TIME_NONE;
    GstM3U8MediaFile* fragment = gst_m3u8_get_next_fragment(playlist, TRUE,
        &actualPosition, NULL, NULL);
    if (sequence == 103) {
        g_assert_null(fragment);
        g_assert_null(playlist->current_file);
    } else {
        g_assert_nonnull(fragment);
        g_assert_cmpint(fragment->sequence, ==, sequence);
        g_assert_cmpuint(actualPosition, ==, fragmentPosition);
        gst_m3u8_media_file_unref(fragment);
    }
}

int main(int argc, char** argv)
{
    gst_init(&argc, &argv);
    hls_element_init(NULL);
    GstHLSDemux* demux = g_object_new(GST_TYPE_HLS_DEMUX, NULL);
    GstM3U8* playlist = gst_m3u8_new();
    gst_m3u8_set_uri(playlist, "https://media.invalid/variant.m3u8", NULL, NULL);
    g_assert_true(gst_m3u8_update(playlist, g_strdup(
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:9\n"
        "#EXT-X-MEDIA-SEQUENCE:100\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        "#EXTINF:8.008,\nfirst.ts\n#EXTINF:8.008,\nsecond.ts\n"
        "#EXTINF:8.008,\nthird.ts\n#EXT-X-ENDLIST\n")));

    // Newly loaded playlists cache the first node. Resync must select the
    // matching node even when another variant's boundaries differ by a frame.
    GstClockTime duration = GST_M3U8_MEDIA_FILE(playlist->files->data)->duration;
    check_position(demux, playlist, 8 * GST_SECOND, 101, duration);
    check_position(demux, playlist, 0, 100, 0);
    check_position(demux, playlist, 2 * duration, 102, 2 * duration);
    check_position(demux, playlist, 3 * duration, 103, 3 * duration);
    check_position(demux, playlist, 8 * GST_SECOND, 101, duration);
    gst_m3u8_unref(playlist);
    gst_object_unref(demux);
    puts("PASS: HLS resync selects matching cached fragments and end-of-playlist");
    return 0;
}
