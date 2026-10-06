// The Widevine decryptor element, the sibling of webkitclearkey.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "WebKitCommonEncryptionDecryptorGStreamer.h"

G_BEGIN_DECLS

#define WEBKIT_TYPE_MEDIA_WV_DECRYPT          (webkit_media_widevine_decrypt_get_type())
#define WEBKIT_MEDIA_WV_DECRYPT(obj)          (G_TYPE_CHECK_INSTANCE_CAST((obj), WEBKIT_TYPE_MEDIA_WV_DECRYPT, WebKitMediaWidevineDecrypt))
#define WEBKIT_MEDIA_WV_DECRYPT_CLASS(klass)  (G_TYPE_CHECK_CLASS_CAST((klass), WEBKIT_TYPE_MEDIA_WV_DECRYPT, WebKitMediaWidevineDecryptClass))
#define WEBKIT_IS_MEDIA_WV_DECRYPT(obj)       (G_TYPE_CHECK_INSTANCE_TYPE((obj), WEBKIT_TYPE_MEDIA_WV_DECRYPT))
#define WEBKIT_IS_MEDIA_WV_DECRYPT_CLASS(obj) (G_TYPE_CHECK_CLASS_TYPE((klass), WEBKIT_TYPE_MEDIA_WV_DECRYPT))

typedef struct _WebKitMediaWidevineDecrypt        WebKitMediaWidevineDecrypt;
typedef struct _WebKitMediaWidevineDecryptClass   WebKitMediaWidevineDecryptClass;
struct WebKitMediaWidevineDecryptPrivate;

GType webkit_media_widevine_decrypt_get_type(void);

struct _WebKitMediaWidevineDecrypt {
    WebKitMediaCommonEncryptionDecrypt parent;

    WebKitMediaWidevineDecryptPrivate* priv;
};

struct _WebKitMediaWidevineDecryptClass {
    WebKitMediaCommonEncryptionDecryptClass parentClass;
};

G_END_DECLS

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
