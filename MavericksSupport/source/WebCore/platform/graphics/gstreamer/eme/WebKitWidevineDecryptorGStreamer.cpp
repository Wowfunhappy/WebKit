// See WebKitWidevineDecryptorGStreamer.h.

#include "config.h"
#include "WebKitWidevineDecryptorGStreamer.h"

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "CDMProxyWidevine.h"
#include "GStreamerCommon.h"
#include "GStreamerEMEUtilities.h"
#include <wtf/glib/WTFGType.h>

using namespace WebCore;

struct WebKitMediaWidevineDecryptPrivate {
    RefPtr<CDMProxyWidevine> cdmProxy;
};

static ASCIILiteral protectionSystemId(WebKitMediaCommonEncryptionDecrypt*);
static bool cdmProxyAttached(WebKitMediaCommonEncryptionDecrypt*, const RefPtr<CDMProxy>&);
static bool decrypt(WebKitMediaCommonEncryptionDecrypt*, GstBuffer* iv, GstBuffer* keyid, GstBuffer* sample, unsigned subSamplesCount, GstBuffer* subSamples);

GST_DEBUG_CATEGORY_STATIC(webkit_media_widevine_decrypt_debug_category);
#define GST_CAT_DEFAULT webkit_media_widevine_decrypt_debug_category

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

#define webkit_media_widevine_decrypt_parent_class parent_class
WEBKIT_DEFINE_TYPE(WebKitMediaWidevineDecrypt, webkit_media_widevine_decrypt, WEBKIT_TYPE_MEDIA_CENC_DECRYPT)

static GRefPtr<GstCaps> createSinkPadTemplateCaps()
{
    GRefPtr<GstCaps> caps = adoptGRef(gst_caps_new_empty());

    for (const auto& mediaType : GStreamerEMEUtilities::s_cencEncryptionMediaTypes) {
        if (GStreamerEMEUtilities::isWidevineDecodedMediaType(mediaType))
            continue;

        gst_caps_append_structure(caps.get(), gst_structure_new("application/x-cenc", "original-media-type", G_TYPE_STRING,
            mediaType.characters(), "protection-system", G_TYPE_STRING, GStreamerEMEUtilities::s_WidevineUUID.characters(), nullptr));
    }

    // WebM carries no protection system in its caps, so these structures match any encrypted
    // WebM stream; the active key system picks between this element and the ClearKey one.
    for (const auto& mediaType : GStreamerEMEUtilities::s_webmEncryptionMediaTypes) {
        if (GStreamerEMEUtilities::isWidevineDecodedMediaType(mediaType))
            continue;

        gst_caps_append_structure(caps.get(), gst_structure_new("application/x-webm-enc", "original-media-type", G_TYPE_STRING,
            mediaType.characters(), nullptr));
    }

    GST_DEBUG("sink pad template caps %" GST_PTR_FORMAT, caps.get());

    return caps;
}

static void webkit_media_widevine_decrypt_class_init(WebKitMediaWidevineDecryptClass* klass)
{
    GST_DEBUG_CATEGORY_INIT(webkit_media_widevine_decrypt_debug_category, "webkitwidevine", 0, "Widevine decryptor");

    GstElementClass* elementClass = GST_ELEMENT_CLASS(klass);
    GRefPtr<GstCaps> sinkPadTemplateCaps = createSinkPadTemplateCaps();
    gst_element_class_add_pad_template(elementClass, gst_pad_template_new("sink", GST_PAD_SINK, GST_PAD_ALWAYS, sinkPadTemplateCaps.get()));
    gst_element_class_add_pad_template(elementClass, gst_static_pad_template_get(&srcTemplate));

    gst_element_class_set_static_metadata(elementClass,
        "Decrypt content encrypted using Widevine Common Encryption",
        GST_ELEMENT_FACTORY_KLASS_DECRYPTOR,
        "Decrypts media that has been encrypted using Widevine Common Encryption.",
        "Jonathan");

    WebKitMediaCommonEncryptionDecryptClass* cencClass = WEBKIT_MEDIA_CENC_DECRYPT_CLASS(klass);
    cencClass->protectionSystemId = GST_DEBUG_FUNCPTR(protectionSystemId);
    cencClass->cdmProxyAttached = GST_DEBUG_FUNCPTR(cdmProxyAttached);
    cencClass->decrypt = GST_DEBUG_FUNCPTR(decrypt);
}

static ASCIILiteral protectionSystemId(WebKitMediaCommonEncryptionDecrypt*)
{
    return GStreamerEMEUtilities::s_WidevineUUID;
}

static bool cdmProxyAttached(WebKitMediaCommonEncryptionDecrypt* self, const RefPtr<CDMProxy>& cdmProxy)
{
    WebKitMediaWidevineDecryptPrivate* priv = WEBKIT_MEDIA_WV_DECRYPT(self)->priv;

    // The proxy arrives as an untyped pointer from a GstContext that carries whichever CDM the
    // page created, so refuse anything that is not Widevine's rather than cast it.
    if (cdmProxy && !GStreamerEMEUtilities::isWidevineKeySystem(cdmProxy->keySystem())) {
        GST_DEBUG_OBJECT(self, "ignoring a %s CDM proxy", cdmProxy->keySystem().utf8().data());
        priv->cdmProxy = nullptr;
        return false;
    }

    priv->cdmProxy = static_cast<CDMProxyWidevine*>(cdmProxy.get());
    return priv->cdmProxy;
}

// The common decryptor keeps the protection meta on the buffer for the duration of this
// call, so the encryption scheme and its pattern are read straight from it rather than
// widening the vfunc every backend shares.
static void readEncryptionScheme(GstBuffer* buffer, cdm::EncryptionScheme& scheme, cdm::Pattern& pattern)
{
    scheme = cdm::EncryptionScheme::kCenc;
    pattern = { 0, 0 };

    auto* protectionMeta = reinterpret_cast<GstProtectionMeta*>(gst_buffer_get_protection_meta(buffer));
    if (!protectionMeta)
        return;

    auto cipherMode = WebCore::gstStructureGetString(protectionMeta->info, "cipher-mode"_s);
    if (!cipherMode || !WTF::equalIgnoringASCIICase(cipherMode.span(), "cbcs"_s))
        return;

    scheme = cdm::EncryptionScheme::kCbcs;
    pattern.crypt_byte_block = WebCore::gstStructureGet<unsigned>(protectionMeta->info, "crypt_byte_block"_s).value_or(0);
    pattern.skip_byte_block = WebCore::gstStructureGet<unsigned>(protectionMeta->info, "skip_byte_block"_s).value_or(0);
}

static bool decrypt(WebKitMediaCommonEncryptionDecrypt* self, GstBuffer* ivBuffer, GstBuffer* keyIDBuffer, GstBuffer* buffer, unsigned subsampleCount, GstBuffer* subsamplesBuffer)
{
    WebKitMediaWidevineDecryptPrivate* priv = WEBKIT_MEDIA_WV_DECRYPT(self)->priv;

    if (!priv->cdmProxy) {
        GST_ERROR_OBJECT(self, "no Widevine CDM proxy attached");
        return false;
    }

    if (!ivBuffer || !keyIDBuffer || !buffer) {
        GST_ERROR_OBJECT(self, "invalid decrypt() parameter");
        return false;
    }

    if (subsampleCount && !subsamplesBuffer) {
        GST_ERROR_OBJECT(self, "invalid decrypt() subsamples parameter");
        return false;
    }

    WebCore::GstMappedBuffer mappedIVBuffer(ivBuffer, GST_MAP_READ);
    if (!mappedIVBuffer) {
        GST_ERROR_OBJECT(self, "failed to map IV buffer");
        return false;
    }

    WebCore::GstMappedBuffer mappedKeyIDBuffer(keyIDBuffer, GST_MAP_READ);
    if (!mappedKeyIDBuffer) {
        GST_ERROR_OBJECT(self, "failed to map key id buffer");
        return false;
    }

    WebCore::GstMappedBuffer mappedBuffer(buffer, GST_MAP_READWRITE);
    if (!mappedBuffer) {
        GST_ERROR_OBJECT(self, "failed to map buffer");
        return false;
    }

    // The mapping has to outlive the context it feeds.
    std::optional<WebCore::GstMappedBuffer> mappedSubsamplesBuffer;

    CDMProxyWidevine::DecryptionContext context;
    context.keyID = mappedKeyIDBuffer.span<uint8_t>();
    context.iv = mappedIVBuffer.span<uint8_t>();
    context.data = mappedBuffer.mutableSpan<uint8_t>();
    context.numSubsamples = subsampleCount;
    if (subsampleCount) {
        mappedSubsamplesBuffer.emplace(subsamplesBuffer, GST_MAP_READ);
        if (!*mappedSubsamplesBuffer) {
            GST_ERROR_OBJECT(self, "failed to map subsample buffer");
            return false;
        }
        context.subsamples = mappedSubsamplesBuffer->span<uint8_t>();
    }
    readEncryptionScheme(buffer, context.encryptionScheme, context.pattern);
    context.cdmProxyDecryptionClient = webKitMediaCommonEncryptionDecryptGetCDMProxyDecryptionClient(self);

    return priv->cdmProxy->decrypt(context);
}

#undef GST_CAT_DEFAULT

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
