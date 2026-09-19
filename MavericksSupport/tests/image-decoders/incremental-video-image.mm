#include "config.h"
#include <WebCore/BitmapImage.h>
#include <WebCore/ImageObserver.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/MainThread.h>
#include <Foundation/Foundation.h>
#include <cstdio>

using namespace WebCore;

class VideoImageObserver final : public ImageObserver {
public:
    explicit VideoImageObserver(const String& type) : m_type(type) { }
    URL sourceUrl() const final { return { }; }
    String mimeType() const final { return m_type; }
    long long expectedContentLength() const final { return 0; }
    void decodedSizeChanged(const Image&, long long) final { }
    void didDraw(const Image&) final { }
    void imageFrameAvailable(const Image&, ImageAnimatingState, const IntRect*, DecodingStatus) final { }
    void changedInRect(const Image&, const IntRect*) final { }
    void imageContentChanged(const Image&) final { }
    void scheduleRenderingUpdate(const Image&) final { }
private:
    String m_type;
};

int main(int argc, const char** argv)
{
    @autoreleasepool {
        WTF::initializeMainThread();
        if (argc != 3)
            return 2;
        NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        if (!data.length)
            return 2;
        auto bytes = std::span<const uint8_t>(static_cast<const uint8_t*>(data.bytes), data.length);
        unsigned failures = 0;
        unsigned completeFrameCount = 0;
        auto type = String::fromUTF8(argv[2]);
        for (size_t chunk : { bytes.size(), size_t(1024), size_t(16384), size_t(65536) }) {
            Ref observer = adoptRef(*new VideoImageObserver(type));
            Ref<Image> image = BitmapImage::create(observer.ptr());
            bool passed = true;
            for (size_t end = std::min(chunk, bytes.size());; end = std::min(end + chunk, bytes.size())) {
                bool allReceived = end == bytes.size();
                auto status = image->setData(SharedBuffer::create(bytes.first(end)), allReceived);
                passed &= status != EncodedDataStatus::Error;
                if (!allReceived) {
                    passed &= status != EncodedDataStatus::Complete;
                    // Repeated cumulative data must not replay bytes or drain the decoder.
                    passed &= image->setData(SharedBuffer::create(bytes.first(end)), false) == status;
                } else {
                    passed &= status == EncodedDataStatus::Complete && !image->size().isEmpty() && image->frameCount();
                    if (!completeFrameCount)
                        completeFrameCount = image->frameCount();
                    passed &= image->frameCount() == completeFrameCount;
                    passed &= image->setData(SharedBuffer::create(bytes), true) == EncodedDataStatus::Complete;
                    passed &= image->frameCount() == completeFrameCount;
                    break;
                }
            }
            printf("%s chunk=%zu frames=%u\n", passed ? "PASS" : "FAIL", chunk, image->frameCount());
            failures += !passed;
        }
        for (size_t length : { size_t(8), size_t(32) }) {
            Ref observer = adoptRef(*new VideoImageObserver(type));
            Ref<Image> image = BitmapImage::create(observer.ptr());
            auto prefix = bytes.first(std::min(length, bytes.size()));
            auto partial = image->setData(SharedBuffer::create(prefix), false);
            auto final = image->setData(SharedBuffer::create(prefix), true);
            bool passed = partial != EncodedDataStatus::Error && partial != EncodedDataStatus::Complete && final == EncodedDataStatus::Error;
            printf("%s incomplete-header=%zu partial=%d final=%d\n", passed ? "PASS" : "FAIL", length, static_cast<int>(partial), static_cast<int>(final));
            failures += !passed;
        }
        return failures ? 1 : 0;
    }
}
