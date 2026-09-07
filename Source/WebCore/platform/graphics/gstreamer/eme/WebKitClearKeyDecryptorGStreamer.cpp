/* GStreamer ClearKey common encryption decryptor
 *
 * Copyright (C) 2016 Metrological
 * Copyright (C) 2016 Igalia S.L
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Suite 500,
 * Boston, MA 02110-1335, USA.
 */

// MAVERICKS_BACKPORT: see WebKitClearKeyDecryptorGStreamer.h. The pad templates are built from
// GStreamerEMEUtilities' media-type lists, the way the Thunder decryptor next door builds its own.

#include "config.h"
#include "WebKitClearKeyDecryptorGStreamer.h"

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "CDMProxyClearKey.h"
#include "GStreamerCommon.h"
#include "GStreamerEMEUtilities.h"
#include <wtf/glib/WTFGType.h>

using namespace WebCore;

struct WebKitMediaClearKeyDecryptPrivate {
    RefPtr<CDMProxyClearKey> cdmProxy;
};

static ASCIILiteral protectionSystemId(WebKitMediaCommonEncryptionDecrypt*);
static bool cdmProxyAttached(WebKitMediaCommonEncryptionDecrypt*, const RefPtr<CDMProxy>&);
static bool decrypt(WebKitMediaCommonEncryptionDecrypt*, GstBuffer* iv, GstBuffer* keyid, GstBuffer* sample, unsigned subSamplesCount, GstBuffer* subSamples);

GST_DEBUG_CATEGORY_STATIC(webkit_media_clear_key_decrypt_debug_category);
#define GST_CAT_DEFAULT webkit_media_clear_key_decrypt_debug_category

static GstStaticPadTemplate srcTemplate = GST_STATIC_PAD_TEMPLATE("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS(
        "video/webm; "
        "audio/webm; "
        "video/mp4; "
        "audio/mp4; "
        "audio/mpeg; "
        "audio/x-flac; "
        "audio/x-eac3; "
        "audio/x-ac3; "
        "video/x-h264; "
        "video/x-h265; "
        "video/x-vp9; video/x-vp8; "
        "video/x-av1; "
        "audio/x-opus; audio/x-vorbis"));

#define webkit_media_clear_key_decrypt_parent_class parent_class
WEBKIT_DEFINE_TYPE(WebKitMediaClearKeyDecrypt, webkit_media_clear_key_decrypt, WEBKIT_TYPE_MEDIA_CENC_DECRYPT)

static GRefPtr<GstCaps> createSinkPadTemplateCaps()
{
    GRefPtr<GstCaps> caps = adoptGRef(gst_caps_new_empty());

    for (const auto& mediaType : GStreamerEMEUtilities::s_cencEncryptionMediaTypes) {
        gst_caps_append_structure(caps.get(), gst_structure_new("application/x-cenc", "original-media-type", G_TYPE_STRING,
            mediaType.characters(), "protection-system", G_TYPE_STRING, GStreamerEMEUtilities::s_ClearKeyUUID.characters(), nullptr));
    }

    for (const auto& mediaType : GStreamerEMEUtilities::s_webmEncryptionMediaTypes) {
        gst_caps_append_structure(caps.get(), gst_structure_new("application/x-webm-enc", "original-media-type", G_TYPE_STRING,
            mediaType.characters(), nullptr));
    }

    GST_DEBUG("sink pad template caps %" GST_PTR_FORMAT, caps.get());

    return caps;
}

static void webkit_media_clear_key_decrypt_class_init(WebKitMediaClearKeyDecryptClass* klass)
{
    GST_DEBUG_CATEGORY_INIT(webkit_media_clear_key_decrypt_debug_category, "webkitclearkey", 0, "ClearKey decryptor");

    GstElementClass* elementClass = GST_ELEMENT_CLASS(klass);
    GRefPtr<GstCaps> sinkPadTemplateCaps = createSinkPadTemplateCaps();
    gst_element_class_add_pad_template(elementClass, gst_pad_template_new("sink", GST_PAD_SINK, GST_PAD_ALWAYS, sinkPadTemplateCaps.get()));
    gst_element_class_add_pad_template(elementClass, gst_static_pad_template_get(&srcTemplate));

    gst_element_class_set_static_metadata(elementClass,
        "Decrypt content encrypted using ISOBMFF ClearKey Common Encryption",
        GST_ELEMENT_FACTORY_KLASS_DECRYPTOR,
        "Decrypts media that has been encrypted using ISOBMFF ClearKey Common Encryption.",
        "Philippe Normand <philn@igalia.com>");

    WebKitMediaCommonEncryptionDecryptClass* cencClass = WEBKIT_MEDIA_CENC_DECRYPT_CLASS(klass);
    cencClass->protectionSystemId = GST_DEBUG_FUNCPTR(protectionSystemId);
    cencClass->cdmProxyAttached = GST_DEBUG_FUNCPTR(cdmProxyAttached);
    cencClass->decrypt = GST_DEBUG_FUNCPTR(decrypt);
}

static ASCIILiteral protectionSystemId(WebKitMediaCommonEncryptionDecrypt*)
{
    return GStreamerEMEUtilities::s_ClearKeyUUID;
}

static bool cdmProxyAttached(WebKitMediaCommonEncryptionDecrypt* self, const RefPtr<CDMProxy>& cdmProxy)
{
    WebKitMediaClearKeyDecryptPrivate* priv = WEBKIT_MEDIA_CK_DECRYPT(self)->priv;
    priv->cdmProxy = static_cast<CDMProxyClearKey*>(cdmProxy.get());
    return priv->cdmProxy;
}

static bool decrypt(WebKitMediaCommonEncryptionDecrypt* self, GstBuffer* ivBuffer, GstBuffer* keyIDBuffer, GstBuffer* buffer, unsigned subsampleCount, GstBuffer* subsamplesBuffer)
{
    WebKitMediaClearKeyDecryptPrivate* priv = WEBKIT_MEDIA_CK_DECRYPT(self)->priv;

    if (!ivBuffer || !keyIDBuffer || !buffer) {
        GST_ERROR_OBJECT(self, "invalid decrypt() parameter");
        return false;
    }

    WebCore::GstMappedBuffer mappedIVBuffer(ivBuffer, GST_MAP_READ);
    if (!mappedIVBuffer) {
        GST_ERROR_OBJECT(self, "failed to map IV buffer");
        return false;
    }

    WebCore::GstMappedBuffer mappedKeyIdBuffer(keyIDBuffer, GST_MAP_READ);
    if (!mappedKeyIdBuffer) {
        GST_ERROR_OBJECT(self, "Failed to map key id buffer");
        return false;
    }

    WebCore::GstMappedBuffer mappedBuffer(buffer, GST_MAP_READWRITE);
    if (!mappedBuffer) {
        GST_ERROR_OBJECT(self, "Failed to map buffer");
        return false;
    }

    // The subsample mapping outlives the context it feeds: cencDecrypt() below reads through
    // context.subsamplesBuffer.
    std::optional<WebCore::GstMappedBuffer> mappedSubsamplesBuffer;

    CDMProxyClearKey::cencDecryptContext context = { };
    context.keyID = mappedKeyIdBuffer.data();
    context.keyIDSizeInBytes = mappedKeyIdBuffer.size();
    context.iv = mappedIVBuffer.data();
    context.ivSizeInBytes = mappedIVBuffer.size();
    context.encryptedBuffer = mappedBuffer.data();
    context.encryptedBufferSizeInBytes = mappedBuffer.size();
    context.numSubsamples = subsampleCount;
    if (!subsampleCount)
        context.subsamplesBuffer = nullptr;
    else {
        ASSERT(subsamplesBuffer);
        mappedSubsamplesBuffer.emplace(subsamplesBuffer, GST_MAP_READ);
        if (!*mappedSubsamplesBuffer) {
            GST_ERROR_OBJECT(self, "Failed to map subsample buffer");
            return false;
        }
        context.subsamplesBuffer = mappedSubsamplesBuffer->data();
        context.subsamplesBufferSizeInBytes = mappedSubsamplesBuffer->size();
    }
    context.cdmProxyDecryptionClient = webKitMediaCommonEncryptionDecryptGetCDMProxyDecryptionClient(self);

    return priv->cdmProxy->cencDecrypt(context);
}

#undef GST_CAT_DEFAULT

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
