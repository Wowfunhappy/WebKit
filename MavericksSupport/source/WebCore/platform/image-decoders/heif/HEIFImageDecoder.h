// HEIC/HEIF still-image decoding for the Mavericks backport, on libheif.
//
// Upstream Cocoa ports decode HEIF through ImageIO, which this build never hands image bytes to, and
// the ScalableImageDecoder ports carry no HEIF decoder at all. libheif parses the container and
// decodes its HEVC-coded items through FFmpeg's hevc decoder, compiled into libheif as its only
// backend (deps/build_deps.sh).
//
// The decoder shows the primary image: a single coded item or a grid of them, with its alpha
// auxiliary image, its transformative properties (clap, irot, imir) applied, and its colour profile
// attached to the image. Image sequence tracks are ImageDecoderGStreamer's (HAVE(HEIF_IMAGE_SEQUENCE)).
//
// ScalableImageDecoder::create dispatches to it on the file-type box's brands.

#pragma once

#if USE(HEIF)

#include "ScalableImageDecoder.h"

namespace WebCore {

class FragmentedSharedBuffer;

class HEIFImageDecoder final : public ScalableImageDecoder {
public:
    static Ref<ScalableImageDecoder> create(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    {
        return adoptRef(*new HEIFImageDecoder(alphaOption, gammaAndColorProfileOption));
    }

    // True for an ISO base media file whose file-type box names a HEIF image brand and no AVIF one;
    // AVIF files carry HEIF brands too and belong to AVIFImageDecoder.
    static bool matchesSignature(const FragmentedSharedBuffer&);

    String filenameExtension() const final { return "heic"_s; }
    ScalableImageDecoderFrame* frameBufferAtIndex(size_t) final;

private:
    HEIFImageDecoder(AlphaOption, GammaAndColorProfileOption);

    // The meta box that describes the items may follow the media data it indexes, so nothing is
    // parsed until every byte is here.
    void tryDecodeSize(bool allDataReceived) final;
    void decode();
};

} // namespace WebCore

#endif // USE(HEIF)
