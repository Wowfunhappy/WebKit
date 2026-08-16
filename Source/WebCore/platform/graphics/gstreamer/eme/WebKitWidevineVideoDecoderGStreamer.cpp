// MAVERICKS_BACKPORT: see WebKitWidevineVideoDecoderGStreamer.h.

#include "config.h"
#include "WebKitWidevineVideoDecoderGStreamer.h"

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "CDMProxyWidevine.h"
#include "GStreamerCommon.h"
#include "GStreamerEMEUtilities.h"
#include <wtf/Condition.h>
#include <wtf/Lock.h>
#include <wtf/Scope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/Vector.h>
#include <wtf/glib/WTFGType.h>

using namespace WebCore;

GST_DEBUG_CATEGORY_STATIC(webkit_media_widevine_video_decode_debug_category);
#define GST_CAT_DEFAULT webkit_media_widevine_video_decode_debug_category

static constexpr Seconds MaxSecondsToWaitForCDMProxy = 5_s;

static bool webKitMediaWidevineVideoDecodeIsAborting(WebKitMediaWidevineVideoDecode*);
static GstFlowReturn webKitMediaWidevineVideoDecodeDrain(GstVideoDecoder*);

// Tied to the element's lifetime: the key wait asks this whether it still has a reader.
class WidevineVideoDecodeClient final : public CDMProxyDecryptionClient {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(WidevineVideoDecodeClient);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(WidevineVideoDecodeClient);
public:
    explicit WidevineVideoDecodeClient(WebKitMediaWidevineVideoDecode* decoder)
        : m_decoder(decoder)
    {
    }
    ~WidevineVideoDecodeClient() = default;

    bool isAborting() final { return webKitMediaWidevineVideoDecodeIsAborting(m_decoder); }

private:
    WebKitMediaWidevineVideoDecode* m_decoder;
};

struct WebKitMediaWidevineVideoDecodePrivate {
    Lock lock;
    Condition condition;
    RefPtr<CDMProxyWidevine> cdmProxy WTF_GUARDED_BY_LOCK(lock);
    bool isFlushing WTF_GUARDED_BY_LOCK(lock) { false };
    bool isStopped WTF_GUARDED_BY_LOCK(lock) { false };
    std::unique_ptr<WidevineVideoDecodeClient> decryptionClient;

    GstVideoCodecState* inputState { nullptr };
    // The avcC as it arrived, the parameter sets it carries in Annex-B, the profile it names, and
    // how wide the length prefixes it describes are.
    Vector<uint8_t> codecData;
    Vector<uint8_t> parameterSets;
    cdm::VideoCodec codec { cdm::kUnknownVideoCodec };
    cdm::VideoCodecProfile profile { cdm::kUnknownVideoCodecProfile };
    unsigned nalLengthSize { 4 };
    bool decoderInitialized { false };
    cdm::EncryptionScheme decoderScheme { cdm::EncryptionScheme::kUnencrypted };
    GstVideoFormat outputFormat { GST_VIDEO_FORMAT_UNKNOWN };
    int outputWidth { 0 };
    int outputHeight { 0 };
};

static GstStaticPadTemplate srcTemplate = GST_STATIC_PAD_TEMPLATE("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS("video/x-raw, format = (string) { I420, YV12 }"));

#define webkit_media_widevine_video_decode_parent_class parent_class
WEBKIT_DEFINE_TYPE(WebKitMediaWidevineVideoDecode, webkit_media_widevine_video_decode, GST_TYPE_VIDEO_DECODER)

static bool webKitMediaWidevineVideoDecodeIsAborting(WebKitMediaWidevineVideoDecode* self)
{
    Locker locker { self->priv->lock };
    return self->priv->isFlushing || self->priv->isStopped;
}

static GRefPtr<GstCaps> createSinkPadTemplateCaps()
{
    GRefPtr<GstCaps> caps = adoptGRef(gst_caps_new_empty());

    for (const auto& mediaType : GStreamerEMEUtilities::s_cencEncryptionMediaTypes) {
        if (!GStreamerEMEUtilities::isWidevineDecodedMediaType(mediaType))
            continue;
        gst_caps_append_structure(caps.get(), gst_structure_new("application/x-cenc",
            "original-media-type", G_TYPE_STRING, mediaType.characters(),
            "protection-system", G_TYPE_STRING, GStreamerEMEUtilities::s_WidevineUUID.characters(), nullptr));
    }

    // WebM carries no protection system in its caps, so these structures match any encrypted WebM
    // stream whatever encrypted it; the active key system picks between this element and the
    // ClearKey decryptor, in MediaPlayerPrivateGStreamer's autoplug-select handler.
    for (const auto& mediaType : GStreamerEMEUtilities::s_webmEncryptionMediaTypes) {
        if (!GStreamerEMEUtilities::isWidevineDecodedMediaType(mediaType))
            continue;
        gst_caps_append_structure(caps.get(), gst_structure_new("application/x-webm-enc",
            "original-media-type", G_TYPE_STRING, mediaType.characters(), nullptr));
    }

    return caps;
}

static cdm::VideoCodecProfile h264ProfileFromIdc(uint8_t profileIdc)
{
    switch (profileIdc) {
    case 66: return cdm::kH264ProfileBaseline;
    case 77: return cdm::kH264ProfileMain;
    case 88: return cdm::kH264ProfileExtended;
    case 100: return cdm::kH264ProfileHigh;
    case 110: return cdm::kH264ProfileHigh10;
    case 122: return cdm::kH264ProfileHigh422;
    case 244: return cdm::kH264ProfileHigh444Predictive;
    default: return cdm::kUnknownVideoCodecProfile;
    }
}

static cdm::VideoCodecProfile vp9ProfileFromCaps(const GstStructure* structure)
{
    auto profile = gstStructureGetString(structure, "profile"_s);
    if (profile == "0"_s)
        return cdm::kVP9Profile0;
    if (profile == "1"_s)
        return cdm::kVP9Profile1;
    if (profile == "2"_s)
        return cdm::kVP9Profile2;
    if (profile == "3"_s)
        return cdm::kVP9Profile3;
    return cdm::kUnknownVideoCodecProfile;
}

// The SPS and PPS the avcC carries, emitted as Annex-B so they can be put in front of a
// keyframe, plus the profile it names and the width of the length prefixes the bitstream uses.
static bool parseAVCDecoderConfigurationRecord(std::span<const uint8_t> record, Vector<uint8_t>& parameterSets, cdm::VideoCodecProfile& profile, unsigned& nalLengthSize)
{
    static constexpr std::array<uint8_t, 4> startCode { 0, 0, 0, 1 };

    if (record.size() < 7 || record[0] != 1)
        return false;

    profile = h264ProfileFromIdc(record[1]);
    nalLengthSize = (record[4] & 0x03) + 1;

    size_t position = 5;
    auto appendSets = [&](unsigned count) -> bool {
        for (unsigned index = 0; index < count; ++index) {
            if (position + 2 > record.size())
                return false;
            size_t length = (static_cast<size_t>(record[position]) << 8) | record[position + 1];
            position += 2;
            if (position + length > record.size())
                return false;
            parameterSets.append(std::span { startCode });
            parameterSets.append(record.subspan(position, length));
            position += length;
        }
        return true;
    };

    if (!appendSets(record[position++] & 0x1f))
        return false;
    if (position >= record.size())
        return false;
    return appendSets(record[position++]);
}

// Chromium's VerifySubsamplesMatchSize: a subsample table describes exactly the bytes of the
// sample it accompanies.
static bool subsamplesCoverSize(const Vector<cdm::SubsampleEntry>& subsamples, size_t size)
{
    uint64_t covered = 0;
    for (const auto& subsample : subsamples)
        covered += static_cast<uint64_t>(subsample.clear_bytes) + subsample.cipher_bytes;
    return covered == size;
}

// Chromium's AVC::ConvertFrameToAnnexB, with the subsample adjustment its MP4 parser makes: each
// length prefix becomes a four-byte start code, so the subsample holding it gains the difference.
// Which subsample that is comes from the sizes the sample arrived with, since |subsamples| grows
// underneath as the walk proceeds.
static bool convertToAnnexB(std::span<const uint8_t> input, unsigned nalLengthSize, std::span<const size_t> boundaries, std::span<const size_t> clearEnds, Vector<uint8_t>& output, Vector<cdm::SubsampleEntry>& subsamples)
{
    static constexpr std::array<uint8_t, 4> startCode { 0, 0, 0, 1 };
    int sizeAdjustment = static_cast<int>(startCode.size()) - static_cast<int>(nalLengthSize);

    // |boundaries| is where each subsample ends in the sample as it arrived, so a position in
    // |input| names a subsample however much the table has grown since.
    auto subsampleIndexAt = [&](size_t position) -> std::optional<size_t> {
        for (size_t index = 0; index < boundaries.size(); ++index) {
            if (position < boundaries[index])
                return index;
        }
        return std::nullopt;
    };

    size_t position = 0;
    while (position + nalLengthSize <= input.size()) {
        size_t nalLength = 0;
        for (unsigned byte = 0; byte < nalLengthSize; ++byte)
            nalLength = (nalLength << 8) | input[position + byte];

        if (!nalLength || position + nalLengthSize + nalLength > input.size())
            return false;

        if (!subsamples.isEmpty()) {
            // A length prefix outside everything the subsample table covers is a sample whose
            // table and bitstream disagree.
            auto index = subsampleIndexAt(position);
            if (!index)
                return false;
            // The prefix is read out of the sample, so it has to lie in the clear run of the
            // subsample that holds it; |clearEnds| is where that run ends in the arriving sample.
            if (position + nalLengthSize > clearEnds[*index])
                return false;
            subsamples[*index].clear_bytes += sizeAdjustment;
        }

        output.append(std::span { startCode });
        output.append(input.subspan(position + nalLengthSize, nalLength));
        position += nalLengthSize + nalLength;
    }

    if (position != input.size())
        return false;
    return subsamples.isEmpty() || subsamplesCoverSize(subsamples, output.size());
}

static bool isCDMProxyAvailable(WebKitMediaWidevineVideoDecode* self)
{
    Locker locker { self->priv->lock };
    return self->priv->cdmProxy;
}

static void attachCDMProxy(WebKitMediaWidevineVideoDecode* self, CDMProxy* proxy)
{
    Locker locker { self->priv->lock };

    // The proxy arrives as an untyped pointer from a GstContext that carries whichever CDM the
    // page created, so refuse anything that is not Widevine's rather than cast it.
    if (proxy && !GStreamerEMEUtilities::isWidevineKeySystem(proxy->keySystem())) {
        GST_DEBUG_OBJECT(self, "ignoring a %s CDM proxy", proxy->keySystem().utf8().data());
        return;
    }

    GST_DEBUG_OBJECT(self, "attaching CDMProxy %p", proxy);
    self->priv->cdmProxy = static_cast<CDMProxyWidevine*>(proxy);
    self->priv->condition.notifyOne();
}

static void installCDMProxyIfNotAvailable(WebKitMediaWidevineVideoDecode* self)
{
    if (isCDMProxyAvailable(self))
        return;

    GRefPtr<GstContext> context = adoptGRef(gst_element_get_context(GST_ELEMENT(self), "drm-cdm-proxy"));
    if (!context) {
        GST_DEBUG_OBJECT(self, "no drm-cdm-proxy context yet");
        return;
    }

    const GValue* value = gst_structure_get_value(gst_context_get_structure(context.get()), "cdm-proxy");
    if (value)
        attachCDMProxy(self, reinterpret_cast<CDMProxy*>(g_value_get_pointer(value)));
}

static gboolean webKitMediaWidevineVideoDecodeStart(GstVideoDecoder* decoder)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(decoder);
    Locker locker { self->priv->lock };
    self->priv->isStopped = false;
    self->priv->isFlushing = false;
    return TRUE;
}

static gboolean webKitMediaWidevineVideoDecodeStop(GstVideoDecoder* decoder)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(decoder);
    RefPtr<CDMProxyWidevine> proxy;
    {
        Locker locker { self->priv->lock };
        self->priv->isStopped = true;
        self->priv->condition.notifyAll();
        proxy = self->priv->cdmProxy;
    }

    if (proxy && self->priv->decoderInitialized)
        proxy->deinitializeVideoDecoder();
    self->priv->decoderInitialized = false;
    if (self->priv->inputState) {
        gst_video_codec_state_unref(self->priv->inputState);
        self->priv->inputState = nullptr;
    }
    self->priv->codecData.clear();
    self->priv->parameterSets.clear();
    return TRUE;
}

static gboolean webKitMediaWidevineVideoDecodeFlush(GstVideoDecoder* decoder)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(decoder);
    RefPtr<CDMProxyWidevine> proxy;
    {
        Locker locker { self->priv->lock };
        proxy = self->priv->cdmProxy;
    }

    if (proxy && self->priv->decoderInitialized)
        proxy->resetVideoDecoder();
    return TRUE;
}

static gboolean webKitMediaWidevineVideoDecodeSetFormat(GstVideoDecoder* decoder, GstVideoCodecState* state)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(decoder);
    auto* priv = self->priv;

    if (priv->inputState)
        gst_video_codec_state_unref(priv->inputState);
    priv->inputState = gst_video_codec_state_ref(state);
    priv->codecData.clear();
    priv->parameterSets.clear();
    priv->codec = cdm::kUnknownVideoCodec;
    priv->profile = cdm::kUnknownVideoCodecProfile;
    priv->nalLengthSize = 4;

    auto* structure = gst_caps_get_structure(state->caps, 0);
    if (!structure) {
        GST_ERROR_OBJECT(self, "no structure in %" GST_PTR_FORMAT, state->caps);
        return FALSE;
    }

    if (gst_structure_has_name(structure, "video/x-vp9")) {
        // VP9 carries its own frame headers, so the decoder is configured from the caps alone.
        priv->codec = cdm::kCodecVp9;
        priv->profile = vp9ProfileFromCaps(structure);
    } else if (gst_structure_has_name(structure, "video/x-h264")) {
        priv->codec = cdm::kCodecH264;
        if (const GValue* codecData = gst_structure_get_value(structure, "codec_data")) {
            if (auto* buffer = gst_value_get_buffer(codecData)) {
                GstMappedBuffer mapped(buffer, GST_MAP_READ);
                if (!mapped || !parseAVCDecoderConfigurationRecord(mapped.span<uint8_t>(), priv->parameterSets, priv->profile, priv->nalLengthSize)) {
                    GST_ERROR_OBJECT(self, "unusable avcC in %" GST_PTR_FORMAT, state->caps);
                    return FALSE;
                }
                priv->codecData.append(mapped.span<uint8_t>());
            }
        }
    } else {
        GST_ERROR_OBJECT(self, "unsupported media type in %" GST_PTR_FORMAT, state->caps);
        return FALSE;
    }

    // A decoder already running has to be told about the new stream from the start.
    if (priv->decoderInitialized) {
        RefPtr<CDMProxyWidevine> proxy;
        {
            Locker locker { priv->lock };
            proxy = priv->cdmProxy;
        }
        if (proxy)
            proxy->deinitializeVideoDecoder();
        priv->decoderInitialized = false;
    }

    // The stream's own geometry, framerate, pixel aspect ratio and colorimetry are what downstream
    // is offered; a decoded frame of another size renegotiates from the same reference.
    auto* outputState = gst_video_decoder_set_output_state(decoder, GST_VIDEO_FORMAT_I420,
        GST_VIDEO_INFO_WIDTH(&state->info), GST_VIDEO_INFO_HEIGHT(&state->info), state);
    if (!outputState)
        return FALSE;
    gst_video_codec_state_unref(outputState);

    if (!gst_video_decoder_negotiate(decoder)) {
        GST_ERROR_OBJECT(self, "failed to negotiate output for %" GST_PTR_FORMAT, state->caps);
        return FALSE;
    }

    priv->outputFormat = GST_VIDEO_FORMAT_I420;
    priv->outputWidth = GST_VIDEO_INFO_WIDTH(&state->info);
    priv->outputHeight = GST_VIDEO_INFO_HEIGHT(&state->info);
    return TRUE;
}

static GstFlowReturn initializeDecoderIfNeeded(WebKitMediaWidevineVideoDecode* self, CDMProxyWidevine& proxy, cdm::EncryptionScheme scheme)
{
    auto* priv = self->priv;
    if (priv->decoderInitialized && priv->decoderScheme == scheme)
        return GST_FLOW_OK;

    if (priv->decoderInitialized) {
        GST_DEBUG_OBJECT(self, "the stream's encryption scheme changed, re-initializing the decoder");
        // Frames the CDM still holds for reorder are finished before it forgets them; a
        // deinitialize discards them and leaves their GstVideoCodecFrames with no path out.
        auto drained = webKitMediaWidevineVideoDecodeDrain(GST_VIDEO_DECODER(self));
        if (drained != GST_FLOW_OK)
            return drained;
        proxy.deinitializeVideoDecoder();
        priv->decoderInitialized = false;
    }

    if (!priv->inputState) {
        GST_ELEMENT_ERROR(self, STREAM, DECODE, ("The stream was never described to the decoder"), (nullptr));
        return GST_FLOW_NOT_NEGOTIATED;
    }

    cdm::VideoDecoderConfig_2 config { };
    config.codec = priv->codec;
    config.profile = priv->profile;
    config.format = cdm::kYv12;
    config.coded_size = { GST_VIDEO_INFO_WIDTH(&priv->inputState->info), GST_VIDEO_INFO_HEIGHT(&priv->inputState->info) };
    config.extra_data = priv->codecData.isEmpty() ? nullptr : priv->codecData.mutableSpan().data();
    config.extra_data_size = priv->codecData.size();
    config.encryption_scheme = scheme;

    auto status = proxy.initializeVideoDecoder(config);
    if (status != cdm::Status::kSuccess) {
        GST_ELEMENT_ERROR(self, STREAM, DECODE, ("The CDM has no video decoder for this stream"),
            ("%" GST_PTR_FORMAT " was refused with status %u", priv->inputState->caps, static_cast<unsigned>(status)));
        return GST_FLOW_NOT_SUPPORTED;
    }

    GST_DEBUG_OBJECT(self, "CDM video decoder initialized for %" GST_PTR_FORMAT, priv->inputState->caps);
    priv->decoderInitialized = true;
    priv->decoderScheme = scheme;
    return GST_FLOW_OK;
}

// What the sample says about its own encryption. Absent protection meta, or meta that says the
// sample is in the clear, is a buffer the CDM is handed unencrypted -- which is what a stream's
// clear lead looks like.
struct SampleProtection {
    cdm::EncryptionScheme scheme { cdm::EncryptionScheme::kUnencrypted };
    cdm::Pattern pattern { 0, 0 };
    GstBuffer* keyID { nullptr };
    GstBuffer* iv { nullptr };
    unsigned subsampleCount { 0 };
    GstBuffer* subsamples { nullptr };
};

static bool readSampleProtection(WebKitMediaWidevineVideoDecode* self, GstBuffer* buffer, SampleProtection& protection)
{
    auto* meta = reinterpret_cast<GstProtectionMeta*>(gst_buffer_get_protection_meta(buffer));
    if (!meta)
        return true;

    auto isEncrypted = gstStructureGet<bool>(meta->info, "encrypted"_s);
    auto ivSize = gstStructureGet<unsigned>(meta->info, "iv_size"_s);
    bool isCbcs = false;
    if (auto cipherMode = gstStructureGetString(meta->info, "cipher-mode"_s))
        isCbcs = WTF::equalIgnoringASCIICase(cipherMode.span(), "cbcs"_s);

    if (!ivSize && isCbcs)
        ivSize = gstStructureGet<unsigned>(meta->info, "constant_iv_size"_s);

    if (!isEncrypted || !*isEncrypted || !ivSize || !*ivSize)
        return true;

    protection.scheme = isCbcs ? cdm::EncryptionScheme::kCbcs : cdm::EncryptionScheme::kCenc;
    if (isCbcs) {
        protection.pattern.crypt_byte_block = gstStructureGet<unsigned>(meta->info, "crypt_byte_block"_s).value_or(0);
        protection.pattern.skip_byte_block = gstStructureGet<unsigned>(meta->info, "skip_byte_block"_s).value_or(0);
    }

    const GValue* value = gst_structure_get_value(meta->info, "kid");
    if (!value) {
        GST_ERROR_OBJECT(self, "no key id on an encrypted sample");
        return false;
    }
    protection.keyID = gst_value_get_buffer(value);

    value = gst_structure_get_value(meta->info, "iv");
    if (!value) {
        GST_ERROR_OBJECT(self, "no IV on an encrypted sample");
        return false;
    }
    protection.iv = gst_value_get_buffer(value);

    protection.subsampleCount = gstStructureGet<unsigned>(meta->info, "subsample_count"_s).value_or(0);
    if (protection.subsampleCount) {
        value = gst_structure_get_value(meta->info, "subsamples");
        if (!value) {
            GST_ERROR_OBJECT(self, "a positive subsample count with no subsamples");
            return false;
        }
        protection.subsamples = gst_value_get_buffer(value);
    }

    return protection.keyID && protection.iv;
}

static GstFlowReturn pushDecodedFrame(GstVideoDecoder* decoder, WidevineVideoFrame& decoded)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(decoder);
    auto* priv = self->priv;

    GstVideoFormat format;
    switch (decoded.Format()) {
    case cdm::kYv12:
        format = GST_VIDEO_FORMAT_YV12;
        break;
    case cdm::kI420:
        format = GST_VIDEO_FORMAT_I420;
        break;
    default:
        GST_ELEMENT_ERROR(self, STREAM, DECODE, ("The CDM decoded a frame this element cannot carry"), ("video format %u", static_cast<unsigned>(decoded.Format())));
        return GST_FLOW_NOT_SUPPORTED;
    }

    if (format != priv->outputFormat || decoded.Size().width != priv->outputWidth || decoded.Size().height != priv->outputHeight) {
        auto* state = gst_video_decoder_set_output_state(decoder, format, decoded.Size().width, decoded.Size().height, priv->inputState);
        if (!state || !gst_video_decoder_negotiate(decoder)) {
            if (state)
                gst_video_codec_state_unref(state);
            GST_ERROR_OBJECT(self, "failed to negotiate %dx%d output", decoded.Size().width, decoded.Size().height);
            return GST_FLOW_NOT_NEGOTIATED;
        }
        gst_video_codec_state_unref(state);
        priv->outputFormat = format;
        priv->outputWidth = decoded.Size().width;
        priv->outputHeight = decoded.Size().height;
    }

    GstVideoCodecState* outputState = gst_video_decoder_get_output_state(decoder);
    if (!outputState) {
        GST_ERROR_OBJECT(self, "no output state to map against");
        return GST_FLOW_NOT_NEGOTIATED;
    }

    // H.264 reorders, so the frame that comes out is rarely the one that just went in. The CDM
    // copies the opaque timestamp off the input, so it carries GStreamer's own frame number back.
    GstVideoCodecFrame* frame = gst_video_decoder_get_frame(decoder, static_cast<int>(decoded.Timestamp()));
    if (!frame) {
        GST_ERROR_OBJECT(self, "no pending frame numbered %" G_GINT64_FORMAT, decoded.Timestamp());
        gst_video_codec_state_unref(outputState);
        return GST_FLOW_ERROR;
    }

    auto result = gst_video_decoder_allocate_output_frame(decoder, frame);
    if (result != GST_FLOW_OK) {
        gst_video_codec_frame_unref(frame);
        gst_video_codec_state_unref(outputState);
        return result;
    }

    GstVideoFrame outputFrame;
    if (!gst_video_frame_map(&outputFrame, &outputState->info, frame->output_buffer, GST_MAP_WRITE)) {
        GST_ERROR_OBJECT(self, "failed to map the output frame");
        gst_video_codec_frame_unref(frame);
        gst_video_codec_state_unref(outputState);
        return GST_FLOW_ERROR;
    }
    gst_video_codec_state_unref(outputState);

    // GStreamer names YV12's planes in storage order, so the CDM's V plane is the second one.
    static constexpr std::array<cdm::VideoPlane, 3> i420Planes { cdm::kYPlane, cdm::kUPlane, cdm::kVPlane };
    static constexpr std::array<cdm::VideoPlane, 3> yv12Planes { cdm::kYPlane, cdm::kVPlane, cdm::kUPlane };
    const auto& planes = format == GST_VIDEO_FORMAT_YV12 ? yv12Planes : i420Planes;

    bool copied = true;
    for (unsigned index = 0; index < 3; ++index) {
        auto source = decoded.plane(planes[index]);
        unsigned sourceStride = decoded.Stride(planes[index]);
        auto* destination = static_cast<uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&outputFrame, index));
        int destinationStride = GST_VIDEO_FRAME_PLANE_STRIDE(&outputFrame, index);
        // Both layouts are 4:2:0: a full-size luma plane and two half-size chroma planes.
        int rows = index ? (decoded.Size().height + 1) / 2 : decoded.Size().height;
        int width = index ? (decoded.Size().width + 1) / 2 : decoded.Size().width;

        if (source.size() < static_cast<size_t>(sourceStride) * rows || sourceStride < static_cast<unsigned>(width)
            || destinationStride < width || rows > GST_VIDEO_FRAME_COMP_HEIGHT(&outputFrame, index)) {
            copied = false;
            break;
        }

        for (int row = 0; row < rows; ++row)
            memcpySpan(std::span { destination + static_cast<size_t>(row) * destinationStride, static_cast<size_t>(width) }, source.subspan(static_cast<size_t>(row) * sourceStride, width));
    }

    gst_video_frame_unmap(&outputFrame);

    if (!copied) {
        GST_ERROR_OBJECT(self, "the decoded frame does not cover %dx%d", decoded.Size().width, decoded.Size().height);
        gst_video_codec_frame_unref(frame);
        return GST_FLOW_ERROR;
    }

    return gst_video_decoder_finish_frame(decoder, frame);
}

static GstFlowReturn webKitMediaWidevineVideoDecodeHandleFrame(GstVideoDecoder* decoder, GstVideoCodecFrame* frame)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(decoder);
    auto* priv = self->priv;

    // handle_frame owns the reference it is given; finish_frame takes one of its own.
    auto releaseFrame = makeScopeExit([frame] { gst_video_codec_frame_unref(frame); });

    RefPtr<CDMProxyWidevine> proxy;
    {
        Locker locker { priv->lock };
        if (priv->isFlushing)
            return GST_FLOW_FLUSHING;

        if (!priv->cdmProxy) {
            GST_DEBUG_OBJECT(self, "CDM not available, going to wait for it");
            priv->condition.waitFor(priv->lock, MaxSecondsToWaitForCDMProxy, [priv] {
                return priv->isFlushing || priv->cdmProxy || priv->isStopped;
            });
            if (priv->isFlushing)
                return GST_FLOW_FLUSHING;
            if (priv->isStopped)
                return GST_FLOW_OK;
            if (!priv->cdmProxy) {
                GST_ELEMENT_ERROR(self, STREAM, FAILED, ("CDMProxy was not retrieved in time"), (nullptr));
                return GST_FLOW_NOT_SUPPORTED;
            }
        }
        proxy = priv->cdmProxy;
    }

    SampleProtection protection;
    if (!readSampleProtection(self, frame->input_buffer, protection)) {
        GST_ELEMENT_ERROR(self, STREAM, DECRYPT, ("Incomplete protection metadata"), (nullptr));
        return GST_FLOW_NOT_SUPPORTED;
    }

    // The decoder is configured for the scheme the samples carry, which the caps do not say, so
    // it is initialized once the first sample has been read.
    auto initialized = initializeDecoderIfNeeded(self, *proxy, protection.scheme);
    if (initialized != GST_FLOW_OK)
        return initialized;

    GstMappedBuffer input(frame->input_buffer, GST_MAP_READ);
    if (!input) {
        GST_ERROR_OBJECT(self, "failed to map the input buffer");
        return GST_FLOW_ERROR;
    }

    Vector<cdm::SubsampleEntry> subsamples;
    if (protection.subsampleCount) {
        GstMappedBuffer mappedSubsamples(protection.subsamples, GST_MAP_READ);
        if (!mappedSubsamples) {
            GST_ERROR_OBJECT(self, "failed to map the subsample buffer");
            return GST_FLOW_ERROR;
        }
        if (!CDMProxyWidevine::parseSubsamples(mappedSubsamples.span<uint8_t>(), protection.subsampleCount, subsamples)) {
            GST_ELEMENT_ERROR(self, STREAM, DECRYPT, ("Subsample buffer too small for %u subsamples", protection.subsampleCount), (nullptr));
            return GST_FLOW_NOT_SUPPORTED;
        }
        if (!subsamplesCoverSize(subsamples, input.size())) {
            GST_ELEMENT_ERROR(self, STREAM, DECRYPT, ("Subsample table does not describe the %zu-byte sample", input.size()), (nullptr));
            return GST_FLOW_NOT_SUPPORTED;
        }
    }

    std::optional<GstMappedBuffer> mappedKeyID;
    std::optional<GstMappedBuffer> mappedIV;
    if (protection.scheme != cdm::EncryptionScheme::kUnencrypted) {
        mappedKeyID.emplace(protection.keyID, GST_MAP_READ);
        mappedIV.emplace(protection.iv, GST_MAP_READ);
        if (!*mappedKeyID || !*mappedIV) {
            GST_ERROR_OBJECT(self, "failed to map the key id or IV");
            return GST_FLOW_ERROR;
        }
    }

    // Taken before the parameter sets grow the first subsample, so the boundaries still describe
    // the sample the bitstream is walked over.
    Vector<size_t> boundaries;
    Vector<size_t> clearEnds;
    boundaries.reserveInitialCapacity(subsamples.size());
    clearEnds.reserveInitialCapacity(subsamples.size());
    size_t subsampleEnd = 0;
    for (const auto& subsample : subsamples) {
        clearEnds.append(subsampleEnd + subsample.clear_bytes);
        subsampleEnd += subsample.clear_bytes + subsample.cipher_bytes;
        boundaries.append(subsampleEnd);
    }

    // A VP9 frame is what its decoder takes; H.264 is length-prefixed and becomes the Annex-B
    // Chromium's parser produces before the CDM sees it.
    auto bitstream = input.span<uint8_t>();
    auto decoderInput = bitstream;
    Vector<uint8_t> converted;
    if (priv->codec == cdm::kCodecH264) {
        // The length prefixes an AVCC walk reads are only present in the clear, so an encrypted
        // sample must carry the subsample table that says where the clear bytes are.
        if (protection.scheme != cdm::EncryptionScheme::kUnencrypted && subsamples.isEmpty()) {
            GST_ELEMENT_ERROR(self, STREAM, DECRYPT, ("Whole-sample-encrypted H.264 carries no length prefixes to convert"), (nullptr));
            return GST_FLOW_NOT_SUPPORTED;
        }

        converted.reserveInitialCapacity(bitstream.size() + priv->parameterSets.size());

        // Every keyframe carries the parameter sets, so the decoder can start from any of them.
        // They are clear, so the first subsample grows by their size.
        bool isKeyframe = !GST_BUFFER_FLAG_IS_SET(frame->input_buffer, GST_BUFFER_FLAG_DELTA_UNIT);
        if (isKeyframe && !priv->parameterSets.isEmpty()) {
            converted.append(priv->parameterSets.span());
            if (!subsamples.isEmpty())
                subsamples[0].clear_bytes += priv->parameterSets.size();
        }

        if (!convertToAnnexB(bitstream, priv->nalLengthSize, boundaries.span(), clearEnds.span(), converted, subsamples)) {
            GST_ELEMENT_ERROR(self, STREAM, DECODE, ("Sample is not a %u-byte-length AVC bitstream", priv->nalLengthSize), (nullptr));
            return GST_FLOW_NOT_SUPPORTED;
        }
        decoderInput = converted.span();
    }

    CDMProxyWidevine::DecodeContext context;
    context.data = decoderInput;
    context.encryptionScheme = protection.scheme;
    context.pattern = protection.pattern;
    context.timestamp = frame->system_frame_number;
    context.cdmProxyDecryptionClient = WeakPtr { *priv->decryptionClient, EnableWeakPtrThreadingAssertions::No };
    if (protection.scheme != cdm::EncryptionScheme::kUnencrypted) {
        context.keyID = mappedKeyID->span<uint8_t>();
        context.iv = mappedIV->span<uint8_t>();
        context.subsamples = subsamples.span();
    }

    WidevineVideoFrame decoded;
    auto status = proxy->decryptAndDecodeFrame(context, decoded);

    {
        Locker locker { priv->lock };
        if (priv->isFlushing)
            return GST_FLOW_FLUSHING;
    }

    switch (status) {
    case cdm::Status::kSuccess:
        if (decoded.FrameBuffer())
            return pushDecodedFrame(decoder, decoded);
        [[fallthrough]];
    case cdm::Status::kNeedMoreData:
        // The decoder is holding this frame back; it comes out on a later call, matched by
        // timestamp, so it stays in the pending list.
        return GST_FLOW_OK;
    default:
        break;
    }

    GST_ELEMENT_ERROR(self, STREAM, DECRYPT, ("Decryption failed"), ("the CDM answered status %u", static_cast<unsigned>(status)));
    return GST_FLOW_NOT_SUPPORTED;
}

// Chromium empties the decoder by sending it an empty input buffer and taking frames until it
// asks for more data. Anything the CDM was holding back comes out here.
static GstFlowReturn webKitMediaWidevineVideoDecodeDrain(GstVideoDecoder* decoder)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(decoder);
    auto* priv = self->priv;

    RefPtr<CDMProxyWidevine> proxy;
    {
        Locker locker { priv->lock };
        proxy = priv->cdmProxy;
    }

    if (!proxy || !priv->decoderInitialized)
        return GST_FLOW_OK;

    for (;;) {
        CDMProxyWidevine::DecodeContext context;
        context.encryptionScheme = cdm::EncryptionScheme::kUnencrypted;

        WidevineVideoFrame decoded;
        auto status = proxy->decryptAndDecodeFrame(context, decoded);

        if (status == cdm::Status::kNeedMoreData)
            return GST_FLOW_OK;

        if (status != cdm::Status::kSuccess) {
            GST_ELEMENT_ERROR(self, STREAM, DECODE, ("Draining the decoder failed"), ("the CDM answered status %u", static_cast<unsigned>(status)));
            return GST_FLOW_ERROR;
        }

        if (!decoded.FrameBuffer())
            return GST_FLOW_OK;

        auto result = pushDecodedFrame(decoder, decoded);
        if (result != GST_FLOW_OK)
            return result;
    }
}

// GstVideoDecoder builds its input state through gst_video_info_from_caps, which reads a raw or
// coded media type, so the base class is handed the caps of the stream underneath the encryption.
// The protection metadata each sample carries is what decryption runs on.
static gboolean webKitMediaWidevineVideoDecodeSinkEvent(GstVideoDecoder* decoder, GstEvent* event)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(decoder);
    auto* priv = self->priv;

    switch (GST_EVENT_TYPE(event)) {
    case GST_EVENT_CAPS: {
        GstCaps* caps = nullptr;
        gst_event_parse_caps(event, &caps);

        GRefPtr<GstCaps> decryptedCaps = adoptGRef(gst_caps_copy(caps));
        auto* structure = gst_caps_get_structure(decryptedCaps.get(), 0);
        auto originalMediaType = gstStructureGetString(structure, "original-media-type"_s);
        gst_structure_set_name(structure, originalMediaType.utf8());
        gst_structure_remove_fields(structure, "protection-system", "original-media-type", "encryption-algorithm", "encoding-scope", "cipher-mode", nullptr);

        GST_DEBUG_OBJECT(self, "caps %" GST_PTR_FORMAT " carry %" GST_PTR_FORMAT, caps, decryptedCaps.get());
        gst_event_unref(event);
        return GST_VIDEO_DECODER_CLASS(parent_class)->sink_event(decoder, gst_event_new_caps(decryptedCaps.get()));
    }
    case GST_EVENT_CUSTOM_DOWNSTREAM_OOB:
        if (gst_event_has_name(event, "attempt-to-decrypt")) {
            GST_DEBUG_OBJECT(self, "handling attempt-to-decrypt");
            installCDMProxyIfNotAvailable(self);
            gst_event_unref(event);
            return TRUE;
        }
        break;
    case GST_EVENT_FLUSH_START: {
        Locker locker { priv->lock };
        priv->isFlushing = true;
        priv->condition.notifyAll();
        if (priv->cdmProxy)
            priv->cdmProxy->abortWaitingForKey();
        break;
    }
    case GST_EVENT_FLUSH_STOP: {
        Locker locker { priv->lock };
        priv->isFlushing = false;
        break;
    }
    default:
        break;
    }

    return GST_VIDEO_DECODER_CLASS(parent_class)->sink_event(decoder, event);
}

static void webKitMediaWidevineVideoDecodeSetContext(GstElement* element, GstContext* context)
{
    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(element);

    if (gst_context_has_context_type(context, "drm-cdm-proxy")) {
        const GValue* value = gst_structure_get_value(gst_context_get_structure(context), "cdm-proxy");
        attachCDMProxy(self, value ? reinterpret_cast<CDMProxy*>(g_value_get_pointer(value)) : nullptr);
        return;
    }

    GST_ELEMENT_CLASS(parent_class)->set_context(element, context);
}

static void constructed(GObject* object)
{
    G_OBJECT_CLASS(parent_class)->constructed(object);

    auto* self = WEBKIT_MEDIA_WV_VIDEO_DECODE(object);
    self->priv->decryptionClient = makeUnique<WidevineVideoDecodeClient>(self);
}

static void webkit_media_widevine_video_decode_class_init(WebKitMediaWidevineVideoDecodeClass* klass)
{
    GST_DEBUG_CATEGORY_INIT(webkit_media_widevine_video_decode_debug_category, "webkitwidevinevideodec", 0, "Widevine video decoder");

    G_OBJECT_CLASS(klass)->constructed = constructed;

    GstElementClass* elementClass = GST_ELEMENT_CLASS(klass);
    elementClass->set_context = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeSetContext);

    GRefPtr<GstCaps> sinkPadTemplateCaps = createSinkPadTemplateCaps();
    gst_element_class_add_pad_template(elementClass, gst_pad_template_new("sink", GST_PAD_SINK, GST_PAD_ALWAYS, sinkPadTemplateCaps.get()));
    gst_element_class_add_pad_template(elementClass, gst_static_pad_template_get(&srcTemplate));

    gst_element_class_set_static_metadata(elementClass,
        "Decrypt and decode H.264 and VP9 encrypted with Widevine Common Encryption",
        "Codec/Decoder/Video",
        "Decrypts and decodes H.264 and VP9 that has been encrypted using Widevine Common Encryption.",
        "Jonathan");

    GstVideoDecoderClass* decoderClass = GST_VIDEO_DECODER_CLASS(klass);
    decoderClass->start = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeStart);
    decoderClass->stop = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeStop);
    decoderClass->flush = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeFlush);
    decoderClass->set_format = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeSetFormat);
    decoderClass->handle_frame = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeHandleFrame);
    decoderClass->drain = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeDrain);
    decoderClass->finish = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeDrain);
    decoderClass->sink_event = GST_DEBUG_FUNCPTR(webKitMediaWidevineVideoDecodeSinkEvent);
}

#undef GST_CAT_DEFAULT

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
