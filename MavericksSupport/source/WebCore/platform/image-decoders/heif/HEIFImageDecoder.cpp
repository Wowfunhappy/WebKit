// See HEIFImageDecoder.h.

#include "config.h"
#include "HEIFImageDecoder.h"

#if USE(HEIF)

#include "ColorTypes.h"
#include "ImageBackingStore.h"
#include "ScalableImageDecoderFrame.h"
#include "SharedBuffer.h"
#include <libheif/heif.h>
#include <libheif/heif_aux_images.h>
#include <libheif/heif_items.h>
#include <wtf/HashSet.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>

#if USE(LCMS)
#include "LCMSUniquePtr.h"
#endif

namespace WebCore {

namespace {

struct HEIFContextDeleter {
    void operator()(heif_context* context) const { heif_context_free(context); }
};
struct HEIFImageHandleDeleter {
    void operator()(heif_image_handle* handle) const { heif_image_handle_release(handle); }
};
struct HEIFImageDeleter {
    void operator()(heif_image* image) const { heif_image_release(image); }
};
struct HEIFDecodingOptionsDeleter {
    void operator()(heif_decoding_options* options) const { heif_decoding_options_free(options); }
};
struct HEIFNCLXDeleter {
    void operator()(heif_color_profile_nclx* nclx) const { heif_nclx_color_profile_free(nclx); }
};

using HEIFContextPtr = std::unique_ptr<heif_context, HEIFContextDeleter>;
using HEIFImageHandlePtr = std::unique_ptr<heif_image_handle, HEIFImageHandleDeleter>;
using HEIFImagePtr = std::unique_ptr<heif_image, HEIFImageDeleter>;
using HEIFDecodingOptionsPtr = std::unique_ptr<heif_decoding_options, HEIFDecodingOptionsDeleter>;
using HEIFNCLXPtr = std::unique_ptr<heif_color_profile_nclx, HEIFNCLXDeleter>;

// The largest frame ImageBackingStore holds (ImageBackingStore::isOverSize).
constexpr uint64_t maximumPixelCount = (1u << 29) - 1;

// libheif checks every allocation it makes against these before making it. The context starts from
// the library's global limits, which allow 1-gigapixel images, 16 million grid tiles and 4 GB of
// memory; each field is stated here so a libheif update cannot widen one unseen.
void setSecurityLimits(heif_context* context)
{
    heif_security_limits* limits = heif_context_get_security_limits(context);
    limits->max_image_size_pixels = maximumPixelCount;
    // A 512x512-tile grid at the pixel limit above.
    limits->max_number_of_tiles = 4096;
    limits->max_bayer_pattern_pixels = 16 * 16;
    limits->max_items = 1000;
    limits->max_color_profile_size = 4 * 1024 * 1024;
    // The whole decode -- coded tiles, decoded planes and the RGBA conversion -- in one budget.
    limits->max_memory_block_size = UINT64_C(1) << 30;
    limits->max_total_memory = UINT64_C(1) << 30;
    limits->max_components = 4;
    limits->max_iloc_extents_per_item = 32;
    limits->max_size_entity_group = 64;
    limits->max_children_per_box = 100;
    limits->max_sample_description_box_entries = 1024;
    limits->max_sample_group_description_box_entries = 1024;
    // Sequence tracks are parsed alongside the still image even though only the still is decoded,
    // and a file carrying both is ordinary.
    limits->max_sequence_frames = 1 << 20;
    limits->max_number_of_file_brands = 1000;
    limits->max_bad_pixels = 1000;
    limits->max_iso23001_17_pixel_size_bytes = 256;
}

// libheif decodes whatever coding its backend offers, and FFmpeg decodes JPEG, JPEG 2000, AVC, VVC and
// AV1 as well as HEVC. HEIC is HEVC, so every coded item the primary image is built from -- the image
// itself, the items a grid, identity or overlay image derives from, and its alpha -- must be an HEVC
// item before anything is decoded. Thumbnails and depth maps are never decoded and are not examined.
constexpr unsigned maximumDerivationDepth = 8;
using ItemSet = HashSet<heif_item_id, IntHash<heif_item_id>, WTF::UnsignedWithZeroKeyHashTraits<heif_item_id>>;

bool isBuiltFromHEVC(heif_context* context, heif_item_id item, ItemSet& visited, unsigned depth)
{
    if (!visited.add(item).isNewEntry)
        return true;

    switch (heif_item_get_item_type(context, item)) {
    case heif_item_type_hvc1:
        return true;
    case heif_item_type_grid:
    case heif_fourcc('i', 'd', 'e', 'n'):
    case heif_fourcc('i', 'o', 'v', 'l'):
        break;
    default:
        return false;
    }
    if (depth == maximumDerivationDepth)
        return false;

    for (int index = 0; ; ++index) {
        uint32_t referenceType = 0;
        heif_item_id* references = nullptr;
        size_t count = heif_context_get_item_references(context, item, index, &referenceType, &references);
        // The array is allocated only for an index that names a reference entry.
        if (!references)
            break;
        bool derivedFromHEVC = true;
        if (referenceType == heif_fourcc('d', 'i', 'm', 'g')) {
            for (auto reference : unsafeMakeSpan(references, count)) {
                if (!isBuiltFromHEVC(context, reference, visited, depth + 1)) {
                    derivedFromHEVC = false;
                    break;
                }
            }
        }
        heif_release_item_references(context, &references);
        if (!derivedFromHEVC)
            return false;
    }
    return true;
}

bool isHEVCImage(heif_context* context, heif_image_handle* primaryImage)
{
    ItemSet visited;
    if (!isBuiltFromHEVC(context, heif_image_handle_get_item_id(primaryImage), visited, 0))
        return false;

    int auxiliaryCount = heif_image_handle_get_number_of_auxiliary_images(primaryImage, LIBHEIF_AUX_IMAGE_FILTER_OMIT_DEPTH);
    if (auxiliaryCount <= 0)
        return true;
    Vector<heif_item_id> auxiliaryImages(auxiliaryCount);
    int listed = heif_image_handle_get_list_of_auxiliary_image_IDs(primaryImage, LIBHEIF_AUX_IMAGE_FILTER_OMIT_DEPTH, auxiliaryImages.mutableSpan().data(), auxiliaryCount);
    for (auto auxiliaryImage : auxiliaryImages.span().first(std::clamp(listed, 0, auxiliaryCount))) {
        if (!isBuiltFromHEVC(context, auxiliaryImage, visited, 0))
            return false;
    }
    return true;
}

// The parsed file and its primary image. The context reads the bytes in place, so the buffer is held
// for as long as the context is.
struct HEIFFile {
    RefPtr<const SharedBuffer> data;
    HEIFContextPtr context;
    HEIFImageHandlePtr primaryImage;
};

std::optional<HEIFFile> openFile(const SharedBuffer& data)
{
    HEIFFile file { &data, HEIFContextPtr(heif_context_alloc()), nullptr };
    if (!file.context)
        return std::nullopt;
    setSecurityLimits(file.context.get());

    auto bytes = file.data->span();
    if (heif_context_read_from_memory_without_copy(file.context.get(), bytes.data(), bytes.size(), nullptr).code != heif_error_Ok)
        return std::nullopt;

    heif_image_handle* primaryImage = nullptr;
    if (heif_context_get_primary_image_handle(file.context.get(), &primaryImage).code != heif_error_Ok)
        return std::nullopt;
    file.primaryImage = HEIFImageHandlePtr(primaryImage);
    if (!isHEVCImage(file.context.get(), file.primaryImage.get()))
        return std::nullopt;
    return file;
}

#if USE(LCMS)
// An RGB profile built from ITU-T H.273 colour primaries and transfer characteristics. The code
// points it names are the SDR ones a still image carries; anything else, including the HDR transfer
// functions, gets no profile.
LCMSProfilePtr profileForNCLX(const heif_color_profile_nclx& nclx)
{
    const cmsCIExyY d65 { 0.3127, 0.3290, 1 };
    cmsCIExyYTRIPLE primaries;
    switch (nclx.color_primaries) {
    case heif_color_primaries_ITU_R_BT_709_5:
    case heif_color_primaries_unspecified:
        primaries = { { 0.640, 0.330, 1 }, { 0.300, 0.600, 1 }, { 0.150, 0.060, 1 } };
        break;
    case heif_color_primaries_ITU_R_BT_470_6_System_B_G:
        primaries = { { 0.640, 0.330, 1 }, { 0.290, 0.600, 1 }, { 0.150, 0.060, 1 } };
        break;
    case heif_color_primaries_ITU_R_BT_601_6:
    case heif_color_primaries_SMPTE_240M:
        primaries = { { 0.630, 0.340, 1 }, { 0.310, 0.595, 1 }, { 0.155, 0.070, 1 } };
        break;
    case heif_color_primaries_ITU_R_BT_2020_2_and_2100_0:
        primaries = { { 0.708, 0.292, 1 }, { 0.170, 0.797, 1 }, { 0.131, 0.046, 1 } };
        break;
    case heif_color_primaries_SMPTE_EG_432_1:
        primaries = { { 0.680, 0.320, 1 }, { 0.265, 0.690, 1 }, { 0.150, 0.060, 1 } };
        break;
    default:
        return nullptr;
    }

    // cmsBuildParametricToneCurve type 4: Y = (aX + b)^g for X >= d, Y = cX below it.
    std::array<double, 5> parameters;
    switch (nclx.transfer_characteristics) {
    case heif_transfer_characteristic_IEC_61966_2_1:
    case heif_transfer_characteristic_unspecified:
        parameters = { 2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045 };
        break;
    case heif_transfer_characteristic_ITU_R_BT_709_5:
    case heif_transfer_characteristic_ITU_R_BT_601_6:
    case heif_transfer_characteristic_ITU_R_BT_2020_2_10bit:
    case heif_transfer_characteristic_ITU_R_BT_2020_2_12bit:
        parameters = { 1 / 0.45, 1 / 1.099, 0.099 / 1.099, 1 / 4.5, 0.081 };
        break;
    case heif_transfer_characteristic_ITU_R_BT_470_6_System_M:
        parameters = { 2.2, 1, 0, 0, 0 };
        break;
    case heif_transfer_characteristic_ITU_R_BT_470_6_System_B_G:
        parameters = { 2.8, 1, 0, 0, 0 };
        break;
    case heif_transfer_characteristic_linear:
        parameters = { 1, 1, 0, 0, 0 };
        break;
    default:
        return nullptr;
    }

    auto* curve = cmsBuildParametricToneCurve(nullptr, 4, parameters.data());
    if (!curve)
        return nullptr;
    std::array<cmsToneCurve*, 3> curves { curve, curve, curve };
    auto profile = LCMSProfilePtr(cmsCreateRGBProfile(&d65, &primaries, curves.data()));
    cmsFreeToneCurve(curve);
    return profile;
}

bool isSRGB(const heif_color_profile_nclx& nclx)
{
    bool sRGBPrimaries = nclx.color_primaries == heif_color_primaries_ITU_R_BT_709_5 || nclx.color_primaries == heif_color_primaries_unspecified;
    bool sRGBTransfer = nclx.transfer_characteristics == heif_transfer_characteristic_IEC_61966_2_1 || nclx.transfer_characteristics == heif_transfer_characteristic_unspecified;
    return sRGBPrimaries && sRGBTransfer;
}

// The RGB profile the decoded samples are in: the ICC profile the colr box carries, or one built from
// its nclx primaries and transfer characteristics. sRGB nclx and an image without a colr box need
// none, which is what ImageBackingStore tags a frame with.
Vector<uint8_t> embeddedProfile(heif_image_handle* handle)
{
    Vector<uint8_t> profile;
    auto profileType = heif_image_handle_get_color_profile_type(handle);
    if (profileType == heif_color_profile_type_prof || profileType == heif_color_profile_type_rICC) {
        size_t size = heif_image_handle_get_raw_color_profile_size(handle);
        if (!size || !profile.tryReserveInitialCapacity(size))
            return { };
        profile.grow(size);
        if (heif_image_handle_get_raw_color_profile(handle, profile.mutableSpan().data()).code != heif_error_Ok)
            return { };
        return profile;
    }
    if (profileType != heif_color_profile_type_nclx)
        return { };

    heif_color_profile_nclx* nclx = nullptr;
    if (heif_image_handle_get_nclx_color_profile(handle, &nclx).code != heif_error_Ok || !nclx)
        return { };
    HEIFNCLXPtr nclxHolder(nclx);
    if (isSRGB(*nclx))
        return { };
    auto nclxProfile = profileForNCLX(*nclx);
    cmsUInt32Number size = 0;
    if (!nclxProfile || !cmsSaveProfileToMem(nclxProfile.get(), nullptr, &size) || !size || !profile.tryReserveInitialCapacity(size))
        return { };
    profile.grow(size);
    if (!cmsSaveProfileToMem(nclxProfile.get(), profile.mutableSpan().data(), &size))
        return { };
    profile.shrink(size);
    return profile;
}
#endif // USE(LCMS)

} // anonymous namespace

HEIFImageDecoder::HEIFImageDecoder(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    : ScalableImageDecoder(alphaOption, gammaAndColorProfileOption)
{
}

bool HEIFImageDecoder::matchesSignature(const FragmentedSharedBuffer& data)
{
    // The file-type box: size, 'ftyp', major brand, minor version, then compatible brands to the end
    // of the box. Its brands are all this reads, so it reads no further than a box of 64 of them.
    std::array<uint8_t, 16 + 64 * 4> header;
    if (data.size() < 16)
        return false;
    size_t available = std::min(data.size(), header.size());
    auto bytes = std::span { header }.first(available);
    data.copyTo(bytes);

    if (!spanHasPrefix(bytes.subspan(4), "ftyp"_span))
        return false;
    uint32_t boxSize = (uint32_t { bytes[0] } << 24) | (uint32_t { bytes[1] } << 16) | (uint32_t { bytes[2] } << 8) | bytes[3];
    if (boxSize < 16)
        return false;
    size_t end = std::min<size_t>(boxSize, available);

    auto isHEIFBrand = [](std::span<const uint8_t> brand) {
        for (auto name : { "heic"_span, "heix"_span, "heim"_span, "heis"_span, "hevc"_span, "hevx"_span, "hevm"_span, "hevs"_span, "mif1"_span, "mif2"_span, "msf1"_span }) {
            if (spanHasPrefix(brand, name))
                return true;
        }
        return false;
    };
    auto isAVIFBrand = [](std::span<const uint8_t> brand) {
        return spanHasPrefix(brand, "avif"_span) || spanHasPrefix(brand, "avis"_span);
    };

    bool heif = isHEIFBrand(bytes.subspan(8, 4));
    if (isAVIFBrand(bytes.subspan(8, 4)))
        return false;
    for (size_t offset = 16; offset + 4 <= end; offset += 4) {
        auto brand = bytes.subspan(offset, 4);
        if (isAVIFBrand(brand))
            return false;
        heif = heif || isHEIFBrand(brand);
    }
    return heif;
}

void HEIFImageDecoder::tryDecodeSize(bool allDataReceived)
{
    if (!allDataReceived)
        return;

    auto file = openFile(*m_data);
    if (!file) {
        setFailed();
        return;
    }

    // The size of the image as displayed, with its rotation and crop applied.
    int width = heif_image_handle_get_width(file->primaryImage.get());
    int height = heif_image_handle_get_height(file->primaryImage.get());
    if (width <= 0 || height <= 0) {
        setFailed();
        return;
    }
#if USE(CG) && USE(LCMS)
    if (!m_ignoreGammaAndColorProfile) {
        if (auto profile = embeddedProfile(file->primaryImage.get()); !profile.isEmpty())
            setEmbeddedRGBColorProfile(profile.span());
    }
#endif
    setSize(IntSize(width, height));
}

void HEIFImageDecoder::decode()
{
    if (failed())
        return;

    auto file = openFile(*m_data);
    if (!file) {
        setFailed();
        return;
    }
    auto* handle = file->primaryImage.get();

    HEIFDecodingOptionsPtr options(heif_decoding_options_alloc());
    if (!options) {
        setFailed();
        return;
    }
    options->convert_hdr_to_8bit = 1;

    heif_image* decodedImage = nullptr;
    if (heif_decode_image(handle, &decodedImage, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, options.get()).code != heif_error_Ok) {
        setFailed();
        return;
    }
    HEIFImagePtr image(decodedImage);

    IntSize frameSize = size();
    size_t stride = 0;
    const uint8_t* plane = heif_image_get_plane_readonly2(image.get(), heif_channel_interleaved, &stride);
    if (!plane || heif_image_get_width(image.get(), heif_channel_interleaved) != frameSize.width()
        || heif_image_get_height(image.get(), heif_channel_interleaved) != frameSize.height()
        || stride < static_cast<size_t>(frameSize.width()) * 4) {
        setFailed();
        return;
    }
    auto pixels = unsafeMakeSpan(plane, stride * static_cast<size_t>(frameSize.height() - 1) + static_cast<size_t>(frameSize.width()) * 4);

    auto& buffer = m_frameBufferCache[0];
    if (!buffer.initialize(frameSize, m_premultiplyAlpha)) {
        setFailed();
        return;
    }
    bool hasAlpha = heif_image_handle_has_alpha_channel(handle);
    bool premultipliedSource = hasAlpha && heif_image_handle_is_premultiplied_alpha(handle);
    buffer.setHasAlpha(hasAlpha);

    auto* backingStore = buffer.backingStore();
    for (int y = 0; y < frameSize.height(); ++y) {
        auto row = pixels.subspan(static_cast<size_t>(y) * stride, static_cast<size_t>(frameSize.width()) * 4);
        for (int x = 0; x < frameSize.width(); ++x) {
            auto sample = row.subspan(static_cast<size_t>(x) * 4, 4);
            uint8_t red = sample[0];
            uint8_t green = sample[1];
            uint8_t blue = sample[2];
            uint8_t alpha = hasAlpha ? sample[3] : 255;
            // setPixel takes unassociated samples.
            if (premultipliedSource && alpha && alpha < 255) {
                red = static_cast<uint8_t>(std::min<unsigned>(255, red * 255u / alpha));
                green = static_cast<uint8_t>(std::min<unsigned>(255, green * 255u / alpha));
                blue = static_cast<uint8_t>(std::min<unsigned>(255, blue * 255u / alpha));
            }
            backingStore->setPixel(backingStore->pixelAt(x, y), red, green, blue, alpha);
        }
    }

    buffer.setDecodingStatus(DecodingStatus::Complete);
}

ScalableImageDecoderFrame* HEIFImageDecoder::frameBufferAtIndex(size_t index)
{
    if (index || !isSizeAvailable())
        return nullptr;

    if (m_frameBufferCache.isEmpty())
        m_frameBufferCache.grow(1);

    auto* buffer = &m_frameBufferCache[0];
    if (!buffer->isComplete())
        decode();
    return buffer;
}

} // namespace WebCore

#endif // USE(HEIF)
