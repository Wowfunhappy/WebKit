// The libheif call sequence HEIFImageDecoder makes, outside WebCore, for probing and fuzzing.
#include "heif_probe.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <libheif/heif.h>
#include <libheif/heif_aux_images.h>
#include <libheif/heif_items.h>
#include <libheif/heif_properties.h>
#include <algorithm>
#include <memory>
#include <set>
#include <vector>

namespace {

struct ContextDeleter { void operator()(heif_context* c) const { heif_context_free(c); } };
struct HandleDeleter { void operator()(heif_image_handle* h) const { heif_image_handle_release(h); } };
struct ImageDeleter { void operator()(heif_image* i) const { heif_image_release(i); } };
struct OptionsDeleter { void operator()(heif_decoding_options* o) const { heif_decoding_options_free(o); } };

constexpr uint64_t maxPixels = (1u << 29) - 1; // ImageBackingStore::isOverSize

void applyLimits(heif_context* context)
{
    heif_security_limits* limits = heif_context_get_security_limits(context);
    limits->max_image_size_pixels = maxPixels;
    limits->max_number_of_tiles = 4096;
    limits->max_bayer_pattern_pixels = 16 * 16;
    limits->max_items = 1000;
    limits->max_color_profile_size = 4 * 1024 * 1024;
    limits->max_memory_block_size = UINT64_C(1) << 30;
    limits->max_components = 4;
    limits->max_iloc_extents_per_item = 32;
    limits->max_size_entity_group = 64;
    limits->max_children_per_box = 100;
    limits->max_total_memory = UINT64_C(1) << 30;
    limits->max_sample_description_box_entries = 1024;
    limits->max_sample_group_description_box_entries = 1024;
    limits->max_sequence_frames = 1 << 20;
    limits->max_number_of_file_brands = 1000;
    limits->max_bad_pixels = 1000;
    limits->max_iso23001_17_pixel_size_bytes = 256;
}

std::string typeName(uint32_t type)
{
    char name[5] = { char(type >> 24), char(type >> 16), char(type >> 8), char(type), 0 };
    return name;
}

// Mirrors HEIFImageDecoder's isBuiltFromHEVC/isHEVCImage.
bool isBuiltFromHEVC(heif_context* context, heif_item_id item, std::set<heif_item_id>& visited, unsigned depth, std::string& types)
{
    if (!visited.insert(item).second)
        return true;
    uint32_t type = heif_item_get_item_type(context, item);
    if (types.size() < 200)
        types += (types.empty() ? "" : ",") + typeName(type);
    switch (type) {
    case heif_item_type_hvc1:
        return true;
    case heif_item_type_grid:
    case heif_fourcc('i', 'd', 'e', 'n'):
    case heif_fourcc('i', 'o', 'v', 'l'):
        break;
    default:
        return false;
    }
    if (depth == 8)
        return false;
    for (int index = 0; ; ++index) {
        uint32_t referenceType = 0;
        heif_item_id* references = nullptr;
        size_t count = heif_context_get_item_references(context, item, index, &referenceType, &references);
        if (!references)
            break;
        bool ok = true;
        if (referenceType == heif_fourcc('d', 'i', 'm', 'g')) {
            for (size_t i = 0; i < count && ok; ++i)
                ok = isBuiltFromHEVC(context, references[i], visited, depth + 1, types);
        }
        heif_release_item_references(context, &references);
        if (!ok)
            return false;
    }
    return true;
}

bool isHEVCImage(heif_context* context, heif_image_handle* primary, std::string& types)
{
    std::set<heif_item_id> visited;
    if (!isBuiltFromHEVC(context, heif_image_handle_get_item_id(primary), visited, 0, types))
        return false;
    int n = heif_image_handle_get_number_of_auxiliary_images(primary, LIBHEIF_AUX_IMAGE_FILTER_OMIT_DEPTH);
    if (n <= 0)
        return true;
    std::vector<heif_item_id> aux(n);
    int listed = heif_image_handle_get_list_of_auxiliary_image_IDs(primary, LIBHEIF_AUX_IMAGE_FILTER_OMIT_DEPTH, aux.data(), n);
    for (int i = 0; i < std::min(std::max(listed, 0), n); ++i) {
        if (!isBuiltFromHEVC(context, aux[i], visited, 0, types))
            return false;
    }
    return true;
}

} // namespace

HEIFProbeResult heif_probe_decode(const uint8_t* data, size_t size)
{
    HEIFProbeResult result;
    std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
    if (!context) {
        result.error = "alloc";
        return result;
    }
    applyLimits(context.get());
    const char* threads = getenv("HEIF_THREADS");
    if (threads)
        heif_context_set_max_decoding_threads(context.get(), atoi(threads));

    heif_error error = heif_context_read_from_memory_without_copy(context.get(), data, size, nullptr);
    if (error.code) {
        result.error = error.message;
        return result;
    }
    heif_image_handle* rawHandle = nullptr;
    error = heif_context_get_primary_image_handle(context.get(), &rawHandle);
    if (error.code) {
        result.error = error.message;
        return result;
    }
    std::unique_ptr<heif_image_handle, HandleDeleter> handle(rawHandle);
    if (!isHEVCImage(context.get(), handle.get(), result.itemTypes)) {
        result.error = "refused item type";
        return result;
    }

    int width = heif_image_handle_get_width(handle.get());
    int height = heif_image_handle_get_height(handle.get());
    if (width <= 0 || height <= 0 || uint64_t(width) * uint64_t(height) > maxPixels) {
        result.error = "size";
        return result;
    }
    result.hasAlpha = heif_image_handle_has_alpha_channel(handle.get());
    result.premultiplied = heif_image_handle_is_premultiplied_alpha(handle.get());
    result.lumaBits = heif_image_handle_get_luma_bits_per_pixel(handle.get());
    result.isGrid = heif_item_get_item_type(context.get(), heif_image_handle_get_item_id(handle.get())) == heif_item_type_grid;
    heif_property_id transforms[8];
    result.transformed = heif_item_get_transformation_properties(context.get(), heif_image_handle_get_item_id(handle.get()), transforms, 8);

    switch (heif_image_handle_get_color_profile_type(handle.get())) {
    case heif_color_profile_type_nclx: {
        heif_color_profile_nclx* nclx = nullptr;
        if (!heif_image_handle_get_nclx_color_profile(handle.get(), &nclx).code && nclx) {
            char buf[64];
            snprintf(buf, sizeof(buf), "nclx(%d/%d/%d/%d)", nclx->color_primaries, nclx->transfer_characteristics, nclx->matrix_coefficients, nclx->full_range_flag);
            result.profile = buf;
            heif_nclx_color_profile_free(nclx);
        }
        break;
    }
    case heif_color_profile_type_prof:
    case heif_color_profile_type_rICC: {
        size_t iccSize = heif_image_handle_get_raw_color_profile_size(handle.get());
        std::vector<uint8_t> icc(iccSize);
        if (iccSize && !heif_image_handle_get_raw_color_profile(handle.get(), icc.data()).code)
            result.profile = "icc(" + std::to_string(iccSize) + ")";
        break;
    }
    default:
        result.profile = "none";
    }

    std::unique_ptr<heif_decoding_options, OptionsDeleter> options(heif_decoding_options_alloc());
    options->convert_hdr_to_8bit = 1;

    heif_image* rawImage = nullptr;
    error = heif_decode_image(handle.get(), &rawImage, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, options.get());
    if (error.code) {
        result.error = error.message;
        return result;
    }
    std::unique_ptr<heif_image, ImageDeleter> image(rawImage);

    int decodedWidth = heif_image_get_width(image.get(), heif_channel_interleaved);
    int decodedHeight = heif_image_get_height(image.get(), heif_channel_interleaved);
    size_t stride = 0;
    const uint8_t* plane = heif_image_get_plane_readonly2(image.get(), heif_channel_interleaved, &stride);
    if (!plane || decodedWidth <= 0 || decodedHeight <= 0 || stride < size_t(decodedWidth) * 4
        || uint64_t(decodedWidth) * uint64_t(decodedHeight) > maxPixels) {
        result.error = "plane";
        return result;
    }
    // Every pixel read once, as the copy into the backing store does.
    uint32_t sum = 2166136261u;
    for (int y = 0; y < decodedHeight; ++y) {
        const uint8_t* row = plane + size_t(y) * stride;
        for (int x = 0; x < decodedWidth * 4; ++x)
            sum = (sum ^ row[x]) * 16777619u;
    }
    if (decodedWidth != width || decodedHeight != height) {
        char buf[64];
        snprintf(buf, sizeof(buf), "handle %dx%d != decoded %dx%d", width, height, decodedWidth, decodedHeight);
        result.error = buf;
        return result;
    }
    result.width = decodedWidth;
    result.height = decodedHeight;
    result.checksum = sum;
    result.ok = true;
    return result;
}
