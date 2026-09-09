// TIFF decoding for the Mavericks backport, on libtiff.
//
// WebCore has decoders for every image format it draws except this one, because the ports that
// carry the ScalableImageDecoder set have never supported TIFF. This build needs it: it hands no
// image bytes to 10.9's ImageIO, and TIFF is how macOS moves images between applications --
// Pasteboard::write(PasteboardImage) writes public.tiff, and Pasteboard::read hands image/tiff to
// the editor -- so copy-image and paste-image both pass through here, as does an <img> whose
// resource is a TIFF.
//
// ScalableImageDecoder::create dispatches to it on the TIFF byte-order-and-version signature.

#pragma once

#if USE(TIFF)

#include "IntSize.h"
#include "ScalableImageDecoder.h"
#include <wtf/Lock.h>
#include <wtf/Vector.h>

namespace WebCore {

class TIFFImageDecoder final : public ScalableImageDecoder {
public:
    static Ref<ScalableImageDecoder> create(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    {
        return adoptRef(*new TIFFImageDecoder(alphaOption, gammaAndColorProfileOption));
    }

    String filenameExtension() const override { return "tiff"_s; }

    // One frame per TIFF directory, each with its own dimensions: a multi-page TIFF is a page
    // sequence, not an animation, so the repetition count stays the base class's None.
    size_t frameCount() const override;
    IntSize frameSizeAtIndex(size_t, SubsamplingLevel) const override;
    ScalableImageDecoderFrame* frameBufferAtIndex(size_t) override;

private:
    TIFFImageDecoder(AlphaOption, GammaAndColorProfileOption);

    // libtiff reads through a client interface that seeks freely over the whole file, and a TIFF's
    // directory chain routinely sits at its end, so nothing is parsed until every byte is here.
    void tryDecodeSize(bool allDataReceived) override;

    bool readDirectories();
    void decode(size_t index);

    struct Directory {
        IntSize size;
        // The directory's own file offset. Selecting a page by it (TIFFSetSubDirectory) costs one
        // seek; selecting it by index walks the chain from the head, which over a page count the
        // file itself chooses is quadratic.
        uint64_t offset { 0 };
    };

    // Written once, while ScalableImageDecoder::setData holds the base's lock, and read afterwards
    // from the decoding thread. Its own lock rather than the base's: createFrameImageAtIndex calls
    // frameBufferAtIndex with the base lock already held, so anything reachable from there that
    // took that lock again would deadlock. Nothing here ever takes the base lock, so the two are
    // always acquired in that one order.
    mutable Lock m_directoriesLock;
    Vector<Directory, 1> m_directories WTF_GUARDED_BY_LOCK(m_directoriesLock);
};

} // namespace WebCore

#endif // USE(TIFF)
