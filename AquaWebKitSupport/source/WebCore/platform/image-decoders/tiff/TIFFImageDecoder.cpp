// See TIFFImageDecoder.h.

#include "config.h"
#include "TIFFImageDecoder.h"

#if USE(TIFF)

#include "ColorTypes.h"
#include "ImageBackingStore.h"
#include "ScalableImageDecoderFrame.h"
#include "SharedBuffer.h"
#include <algorithm>
#include <climits>
#include <limits>
#include <tiffio.h>
#include <wtf/CheckedArithmetic.h>
#include <wtf/Noncopyable.h>
#include <wtf/StdLibExtras.h>

namespace WebCore {

namespace {

// The client interface libtiff reads the encoded bytes through: the buffer, with a cursor. Writing
// is refused; mapping hands the buffer over as it stands, because it already is contiguous memory.
// The buffer is held by reference rather than spanned, so the bytes cannot go out from under an
// open handle.
class TIFFStream {
    WTF_MAKE_NONCOPYABLE(TIFFStream);
public:
    explicit TIFFStream(const SharedBuffer& data)
        : m_data(data)
    {
    }

    static tmsize_t read(thandle_t handle, void* destination, tmsize_t size)
    {
        auto& stream = *static_cast<TIFFStream*>(handle);
        auto bytes = stream.m_data->span();
        if (size < 0 || stream.m_offset > bytes.size())
            return 0;
        size_t available = bytes.size() - stream.m_offset;
        size_t wanted = std::min<size_t>(available, static_cast<size_t>(size));
        memcpySpan(unsafeMakeSpan(static_cast<uint8_t*>(destination), wanted), bytes.subspan(stream.m_offset, wanted));
        stream.m_offset += wanted;
        return static_cast<tmsize_t>(wanted);
    }

    static tmsize_t write(thandle_t, void*, tmsize_t)
    {
        return 0;
    }

    static toff_t seek(thandle_t handle, toff_t offset, int whence)
    {
        auto& stream = *static_cast<TIFFStream*>(handle);
        CheckedSize position;
        switch (whence) {
        case SEEK_SET:
            position = CheckedSize(offset);
            break;
        case SEEK_CUR:
            position = CheckedSize(stream.m_offset) + CheckedSize(offset);
            break;
        case SEEK_END:
            position = CheckedSize(stream.m_data->size()) + CheckedSize(offset);
            break;
        default:
            return static_cast<toff_t>(-1);
        }
        if (position.hasOverflowed())
            return static_cast<toff_t>(-1);
        // Seeking past the end is legal and reads there return nothing, which is how a truncated
        // file reports itself to libtiff.
        stream.m_offset = position.value();
        return stream.m_offset;
    }

    static int close(thandle_t)
    {
        return 0;
    }

    static toff_t size(thandle_t handle)
    {
        return static_cast<TIFFStream*>(handle)->m_data->size();
    }

    // Declining the mapping is not a neutral choice. libtiff maps a file it opens itself, and its
    // uncompressed-tile sanity check compares the tile's byte count against tif_rawdatasize --
    // which, on the copying path, TIFFReadBufferSetup has rounded up to the next kilobyte
    // (tif_read.c). An uncompressed tile that is not a whole number of kilobytes then fails to read
    // with "Invalid tile byte count", where the same file read through a mapping decodes. Handing
    // the buffer over puts this decoder on the path libtiff itself takes, and saves the copy.
    // libtiff treats the mapped region as read-only, as it must for a file it mapped read-only;
    // the const_cast is that API's missing const, not permission to write.
    static int map(thandle_t handle, void** base, toff_t* size)
    {
        auto bytes = static_cast<TIFFStream*>(handle)->m_data->span();
        if (bytes.empty())
            return 0;
        *base = const_cast<uint8_t*>(bytes.data());
        *size = bytes.size();
        return 1;
    }

    static void unmap(thandle_t, void*, toff_t)
    {
    }

private:
    Ref<const SharedBuffer> m_data;
    size_t m_offset { 0 };
};

// Handlers per TIFF handle rather than libtiff's process-global ones: a malformed image is a
// decode failure this decoder reports through setFailed(), not a line on the process's stderr.
// Returning 1 tells libtiff the diagnostic is handled.
int silenceDiagnostic(TIFF*, void*, const char*, const char*, va_list)
{
    return 1;
}

class TIFFHandle {
    WTF_MAKE_NONCOPYABLE(TIFFHandle);
public:
    explicit TIFFHandle(const SharedBuffer& data)
        : m_stream(data)
    {
        auto* options = TIFFOpenOptionsAlloc();
        if (!options)
            return;
        TIFFOpenOptionsSetErrorHandlerExtR(options, silenceDiagnostic, nullptr);
        TIFFOpenOptionsSetWarningHandlerExtR(options, silenceDiagnostic, nullptr);
        m_tiff = TIFFClientOpenExt("image", "r", &m_stream, TIFFStream::read, TIFFStream::write,
            TIFFStream::seek, TIFFStream::close, TIFFStream::size, TIFFStream::map, TIFFStream::unmap, options);
        TIFFOpenOptionsFree(options);
    }

    ~TIFFHandle()
    {
        if (m_tiff)
            TIFFClose(m_tiff);
    }

    TIFF* get() const { return m_tiff; }

private:
    TIFFStream m_stream;
    TIFF* m_tiff { nullptr };
};

// TIFFRGBAImageBegin allocates the conversion tables the get routine needs, and TIFFRGBAImageEnd
// is the only thing that frees them.
class TIFFRGBAImageScope {
    WTF_MAKE_NONCOPYABLE(TIFFRGBAImageScope);
public:
    explicit TIFFRGBAImageScope(TIFF* tiff)
    {
        // 1024 is the size libtiff declares for this parameter (tiffio.h: `char[1024]`); the name
        // it uses for it internally is not in the installed headers. The text is discarded --
        // a failure here is a decode failure, reported by the caller through setFailed().
        char message[1024] = "";
        m_begun = TIFFRGBAImageOK(tiff, message) && TIFFRGBAImageBegin(&m_image, tiff, 0, message);
    }

    ~TIFFRGBAImageScope()
    {
        if (m_begun)
            TIFFRGBAImageEnd(&m_image);
    }

    bool begun() const { return m_begun; }
    TIFFRGBAImage& image() { return m_image; }

private:
    TIFFRGBAImage m_image { };
    bool m_begun { false };
};

} // anonymous namespace

TIFFImageDecoder::TIFFImageDecoder(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    : ScalableImageDecoder(alphaOption, gammaAndColorProfileOption)
{
}

size_t TIFFImageDecoder::frameCount() const
{
    Locker locker { m_directoriesLock };
    return m_directories.size();
}

IntSize TIFFImageDecoder::frameSizeAtIndex(size_t index, SubsamplingLevel) const
{
    Locker locker { m_directoriesLock };
    return index < m_directories.size() ? m_directories[index].size : ScalableImageDecoder::size();
}

bool TIFFImageDecoder::readDirectories()
{
    TIFFHandle handle(*m_data);
    if (!handle.get())
        return false;

    Locker locker { m_directoriesLock };
    // A directory this cannot use ends the sequence rather than the decode: a file whose second
    // page is unreadable still has a first page, which is what an <img> or a paste shows.
    do {
        uint32_t width = 0;
        uint32_t height = 0;
        if (!TIFFGetField(handle.get(), TIFFTAG_IMAGEWIDTH, &width) || !TIFFGetField(handle.get(), TIFFTAG_IMAGELENGTH, &height))
            break;
        if (!width || !height || width > static_cast<uint32_t>(INT_MAX) || height > static_cast<uint32_t>(INT_MAX))
            break;

        IntSize frameSize(width, height);
        if (ImageBackingStore::isOverSize(frameSize))
            break;

        m_directories.append({ frameSize, TIFFCurrentDirOffset(handle.get()) });
        // TIFF addresses directories with tdir_t, so nothing past that range is a page at all.
        if (m_directories.size() > std::numeric_limits<tdir_t>::max())
            break;
    } while (TIFFReadDirectory(handle.get()));

    return !m_directories.isEmpty();
}

void TIFFImageDecoder::tryDecodeSize(bool allDataReceived)
{
    if (!allDataReceived)
        return;

    if (!readDirectories()) {
        {
            Locker locker { m_directoriesLock };
            m_directories.clear();
        }
        setFailed();
        return;
    }

    setSize(frameSizeAtIndex(0, SubsamplingLevel::Default));
}

void TIFFImageDecoder::decode(size_t index)
{
    if (failed())
        return;

    IntSize frameSize;
    uint64_t directoryOffset = 0;
    {
        Locker locker { m_directoriesLock };
        frameSize = m_directories[index].size;
        directoryOffset = m_directories[index].offset;
    }

    TIFFHandle handle(*m_data);
    if (!handle.get() || !TIFFSetSubDirectory(handle.get(), directoryOffset)) {
        setFailed();
        return;
    }

    TIFFRGBAImageScope scope(handle.get());
    if (!scope.begun()) {
        setFailed();
        return;
    }
    auto& image = scope.image();
    image.req_orientation = ORIENTATION_TOPLEFT;

    // libtiff turns the file's orientation into the requested one within each window it fills, so
    // the windows of a bottom-origin file come back individually flipped but in file order.
    // Placing window k at the mirrored y is what makes the whole frame right side up.
    bool bottomOrigin = image.orientation == ORIENTATION_BOTLEFT || image.orientation == ORIENTATION_BOTRIGHT
        || image.orientation == ORIENTATION_LEFTBOT || image.orientation == ORIENTATION_RIGHTBOT;

    // The window is the file's own decode unit -- a strip, or a row of tiles -- which is the block
    // libtiff has to hold to produce any part of it. Converting the whole frame in one call would
    // put a second full-size raster beside the backing store, sized by two header fields.
    uint32_t windowRows = 0;
    if (TIFFIsTiled(handle.get()))
        TIFFGetFieldDefaulted(handle.get(), TIFFTAG_TILELENGTH, &windowRows);
    else
        TIFFGetFieldDefaulted(handle.get(), TIFFTAG_ROWSPERSTRIP, &windowRows);
    if (!windowRows || windowRows > static_cast<uint32_t>(frameSize.height()))
        windowRows = frameSize.height();

    auto windowPixels = CheckedSize(frameSize.width()) * CheckedSize(windowRows);
    if (windowPixels.hasOverflowed()) {
        setFailed();
        return;
    }

    Vector<uint32_t> raster;
    if (!raster.tryReserveCapacity(windowPixels.value())) {
        setFailed();
        return;
    }

    auto& buffer = m_frameBufferCache[index];
    if (!buffer.initialize(frameSize, m_premultiplyAlpha)) {
        setFailed();
        return;
    }
    // libtiff's own reading of the extra samples, which treats an unspecified extra sample on a
    // more-than-three-sample image as alpha and writes non-opaque values for it. Deciding this
    // from the tag alone would let the frame claim to be opaque over pixels that are not.
    // (EXTRASAMPLE_UNSPECIFIED is the zero TIFFRGBAImageBegin leaves when it finds no alpha.)
    buffer.setHasAlpha(image.alpha != EXTRASAMPLE_UNSPECIFIED);

    auto* backingStore = buffer.backingStore();
    for (uint32_t row = 0; row < static_cast<uint32_t>(frameSize.height()); row += windowRows) {
        uint32_t rows = std::min<uint32_t>(windowRows, static_cast<uint32_t>(frameSize.height()) - row);
        // The rows libtiff could not read are left untouched, so each window starts transparent.
        raster.fill(0, static_cast<size_t>(frameSize.width()) * rows);

        image.row_offset = static_cast<int>(row);
        image.col_offset = 0;
        if (!TIFFRGBAImageGet(&image, raster.mutableSpan().data(), static_cast<uint32_t>(frameSize.width()), rows)) {
            setFailed();
            return;
        }

        int destinationY = bottomOrigin ? frameSize.height() - static_cast<int>(row + rows) : static_cast<int>(row);
        auto rasterSpan = raster.span();
        for (uint32_t y = 0; y < rows; ++y) {
            for (int x = 0; x < frameSize.width(); ++x) {
                uint32_t pixel = rasterSpan[static_cast<size_t>(y) * frameSize.width() + x];
                uint8_t red = TIFFGetR(pixel);
                uint8_t green = TIFFGetG(pixel);
                uint8_t blue = TIFFGetB(pixel);
                uint8_t alpha = TIFFGetA(pixel);
                auto& destination = backingStore->pixelAt(x, destinationY + static_cast<int>(y));
                if (m_premultiplyAlpha) {
                    // libtiff hands back associated alpha whatever the file stores (tif_getimage.c
                    // scales unassociated colour channels through its UaToAa table), and associated
                    // is what a premultiplied frame holds -- so the samples are already the answer.
                    destination = PackedColor::ARGB { SRGBA<uint8_t> { red, green, blue, alpha } }.value;
                    continue;
                }
                // An unpremultiplied frame wants the channels unscaled again.
                if (alpha && alpha < 255) {
                    red = static_cast<uint8_t>(std::min<unsigned>(255, red * 255u / alpha));
                    green = static_cast<uint8_t>(std::min<unsigned>(255, green * 255u / alpha));
                    blue = static_cast<uint8_t>(std::min<unsigned>(255, blue * 255u / alpha));
                }
                backingStore->setPixel(destination, red, green, blue, alpha);
            }
        }
    }

    buffer.setDecodingStatus(DecodingStatus::Complete);
}

ScalableImageDecoderFrame* TIFFImageDecoder::frameBufferAtIndex(size_t index)
{
    size_t count = frameCount();
    if (index >= count)
        return nullptr;

    if (m_frameBufferCache.size() < count)
        m_frameBufferCache.grow(count);

    auto* buffer = &m_frameBufferCache[index];
    if (!buffer->isComplete())
        decode(index);
    return buffer;
}

} // namespace WebCore

#endif // USE(TIFF)
