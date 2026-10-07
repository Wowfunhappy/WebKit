// GStreamer: this port's GStreamer configuration, applied through the environment knobs
// upstream already reads, so Source/WebCore/platform/graphics/gstreamer stays byte-upstream.
//
// libpolyfill.a is force-loaded into every WebKit binary, so this constructor runs at image load —
// well before gst_init(), GStreamerRegistryScanner's singleton, and registerWebKitGStreamerElements(),
// which are where these variables are read.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Length of a list element's key: the text before its ':' (a "feature:rank" pair), or all of it.
static size_t wk_key_length(const char *element, size_t length)
{
    const char *colon = memchr(element, ':', length);
    return colon ? (size_t)(colon - element) : length;
}

// Adds `element` to the comma-separated list in `variable` unless an element with the same key is
// already there, so an explicit setting in the environment wins and "acid" does not count as "cid".
static void wk_merge_list_element(const char *variable, const char *element)
{
    const char *existing = getenv(variable);
    if (!existing || !*existing) {
        setenv(variable, element, 1);
        return;
    }

    size_t keyLength = wk_key_length(element, strlen(element));
    for (const char *p = existing; *p;) {
        while (*p == ' ' || *p == ',')
            p++;
        const char *end = strchr(p, ',');
        size_t length = end ? (size_t)(end - p) : strlen(p);
        size_t existingKeyLength = wk_key_length(p, length);
        while (existingKeyLength && p[existingKeyLength - 1] == ' ')
            existingKeyLength--;
        if (existingKeyLength == keyLength && !strncmp(p, element, keyLength))
            return;
        if (!end)
            break;
        p = end + 1;
    }

    size_t size = strlen(existing) + 1 + strlen(element) + 1;
    char *merged = (char *)malloc(size);
    if (!merged)
        return;
    snprintf(merged, size, "%s,%s", existing, element);
    setenv(variable, merged, 1);
    free(merged);
}

// WEBKIT_GST_ENABLE_HLS_SUPPORT: upstream leaves native HLS off unless this is "1", and off both skips
// the application/x-hls mapping in GStreamerRegistryScanner (so
// canPlayType("application/vnd.apple.mpegurl") answers "") and demotes the hlsdemux factory to
// GST_RANK_NONE in registerWebKitGStreamerElements. Without it a plain <video src="....m3u8"> fails
// with MEDIA_ERR_SRC_NOT_SUPPORTED; with it, MPEG-TS, fMP4/CMAF and AES-128 playlists all play.
// AquaWebKitSupport/deps ships libgsthls, and the mapping stays gated on the demuxer being registered.
//
// WEBKIT_GST_ALLOWED_URI_PROTOCOLS: adds "cid" (Content-ID, RFC 2392) to isProtocolAllowed's set.
// GStreamer is the sole media engine here and Apple Mail renders inline audio/video attachments as
// <video>/<audio src="cid:...">; WebKitWebSrc loads those through WebCore's CachedResourceLoader, the
// same path that already resolves cid: for inline <img>, which performs its own origin checks. (#69)
//
// GST_PLUGIN_FEATURE_RANK + WEBKIT_GST_CAN_PLAY_USAC: the AAC decoder is gst-plugins-bad's fdkaacdec
// on the FDK AAC library AquaWebKitSupport/deps ships, ranked above gst-libav's avdec_aac. FDK decodes
// the object types AudioToolbox does (LC, HE-AAC v1/v2, LD, ELD) and MPEG-D USAC (xHE-AAC) including
// its LPD speech core, which avdec_aac lacks; with it in place GStreamerRegistryScanner may answer
// for "mp4a.40.42", which upstream maps only on this variable or a decoder advertising
// stream-format=usac.
//
// All are set with overwrite=0 / merged, so an explicit setting in the environment still wins.
__attribute__((constructor)) static void wk_gstreamer_env_init(void)
{
    setenv("WEBKIT_GST_ENABLE_HLS_SUPPORT", "1", 0);
    setenv("WEBKIT_GST_CAN_PLAY_USAC", "1", 0);

    // Upstream unions this list with its built-in protocol set, so append rather than replace:
    // clobbering it would drop protocols an embedder had already asked for.
    wk_merge_list_element("WEBKIT_GST_ALLOWED_URI_PROTOCOLS", "cid");

    // GST_RANK_PRIMARY + 1.
    wk_merge_list_element("GST_PLUGIN_FEATURE_RANK", "fdkaacdec:257");
}
