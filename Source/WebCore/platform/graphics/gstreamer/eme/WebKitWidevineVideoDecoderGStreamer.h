// MAVERICKS_BACKPORT: the Widevine video decoder element. Google's CDM answers kNoKey for a
// sample its Decrypt() recognises as a video bitstream; encoded video goes through its own
// decoder instead, which is the path Chromium drives it on.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <gst/video/gstvideodecoder.h>

G_BEGIN_DECLS

#define WEBKIT_TYPE_MEDIA_WV_VIDEO_DECODE          (webkit_media_widevine_video_decode_get_type())
#define WEBKIT_MEDIA_WV_VIDEO_DECODE(obj)          (G_TYPE_CHECK_INSTANCE_CAST((obj), WEBKIT_TYPE_MEDIA_WV_VIDEO_DECODE, WebKitMediaWidevineVideoDecode))
#define WEBKIT_MEDIA_WV_VIDEO_DECODE_CLASS(klass)  (G_TYPE_CHECK_CLASS_CAST((klass), WEBKIT_TYPE_MEDIA_WV_VIDEO_DECODE, WebKitMediaWidevineVideoDecodeClass))
#define WEBKIT_IS_MEDIA_WV_VIDEO_DECODE(obj)       (G_TYPE_CHECK_INSTANCE_TYPE((obj), WEBKIT_TYPE_MEDIA_WV_VIDEO_DECODE))
#define WEBKIT_IS_MEDIA_WV_VIDEO_DECODE_CLASS(obj) (G_TYPE_CHECK_CLASS_TYPE((klass), WEBKIT_TYPE_MEDIA_WV_VIDEO_DECODE))

typedef struct _WebKitMediaWidevineVideoDecode      WebKitMediaWidevineVideoDecode;
typedef struct _WebKitMediaWidevineVideoDecodeClass WebKitMediaWidevineVideoDecodeClass;
struct WebKitMediaWidevineVideoDecodePrivate;

GType webkit_media_widevine_video_decode_get_type(void);

struct _WebKitMediaWidevineVideoDecode {
    GstVideoDecoder parent;

    WebKitMediaWidevineVideoDecodePrivate* priv;
};

struct _WebKitMediaWidevineVideoDecodeClass {
    GstVideoDecoderClass parentClass;
};

G_END_DECLS

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
