// MAVERICKS_BACKPORT: this port's GStreamer configuration, applied through the environment knobs
// upstream already reads, so Source/WebCore/platform/graphics/gstreamer stays byte-upstream.
//
// libpolyfill.a is force-loaded into every WebKit binary, so this constructor runs at image load —
// well before gst_init(), GStreamerRegistryScanner's singleton, and registerWebKitGStreamerElements(),
// which are where both variables are read.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// True when `list` (a comma-separated protocol list) already contains `token` as a whole element,
// so "acid" does not count as "cid".
static int wk_list_contains(const char *list, const char *token)
{
    size_t tokenLength = strlen(token);
    for (const char *p = list; *p;) {
        while (*p == ' ' || *p == ',')
            p++;
        const char *end = strchr(p, ',');
        size_t length = end ? (size_t)(end - p) : strlen(p);
        while (length && p[length - 1] == ' ')
            length--;
        if (length == tokenLength && !strncmp(p, token, tokenLength))
            return 1;
        if (!end)
            break;
        p = end + 1;
    }
    return 0;
}

// WEBKIT_GST_ENABLE_HLS_SUPPORT: upstream leaves native HLS off unless this is "1", and off both skips
// the application/x-hls mapping in GStreamerRegistryScanner (so
// canPlayType("application/vnd.apple.mpegurl") answers "") and demotes the hlsdemux factory to
// GST_RANK_NONE in registerWebKitGStreamerElements. Without it a plain <video src="....m3u8"> fails
// with MEDIA_ERR_SRC_NOT_SUPPORTED; with it, MPEG-TS, fMP4/CMAF and AES-128 playlists all play.
// MavericksSupport/deps ships libgsthls, and the mapping stays gated on the demuxer being registered.
//
// WEBKIT_GST_ALLOWED_URI_PROTOCOLS: adds "cid" (Content-ID, RFC 2392) to isProtocolAllowed's set.
// GStreamer is the sole media engine here and Apple Mail renders inline audio/video attachments as
// <video>/<audio src="cid:...">; WebKitWebSrc loads those through WebCore's CachedResourceLoader, the
// same path that already resolves cid: for inline <img>, which performs its own origin checks. (#69)
//
// Both are set with overwrite=0 / merged, so an explicit setting in the environment still wins.
__attribute__((constructor)) static void wk_gstreamer_env_init(void)
{
    setenv("WEBKIT_GST_ENABLE_HLS_SUPPORT", "1", 0);

    // Upstream unions this list with its built-in protocol set, so append rather than replace:
    // clobbering it would drop protocols an embedder had already asked for.
    const char *existing = getenv("WEBKIT_GST_ALLOWED_URI_PROTOCOLS");
    if (!existing || !*existing) {
        setenv("WEBKIT_GST_ALLOWED_URI_PROTOCOLS", "cid", 1);
        return;
    }
    if (wk_list_contains(existing, "cid"))
        return;

    size_t size = strlen(existing) + sizeof(",cid");
    char *merged = (char *)malloc(size);
    if (!merged)
        return;
    snprintf(merged, size, "%s,cid", existing);
    setenv("WEBKIT_GST_ALLOWED_URI_PROTOCOLS", merged, 1);
    free(merged);
}
