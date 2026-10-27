#import "config.h"
#import "LegacyExtensionTabCapture.h"

#import "ImageOptions.h"
#import "WebPageProxy.h"
#import <WebCore/CSSFilterRenderer.h>
#import <WebCore/FEGaussianBlur.h>
#import <WebCore/FilterResults.h>
#import <WebCore/GraphicsContext.h>
#import <WebCore/ImageBuffer.h>
#import <WebCore/ImageDecoder.h>
#import <WebCore/ImageUtilities.h>
#import <WebCore/IntRect.h>
#import <WebCore/NativeImage.h>
#import <WebCore/SharedBuffer.h>
#import <algorithm>
#import <cmath>
#import <wtf/CrossThreadCopier.h>
#import <wtf/MathExtras.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/RunLoop.h>
#import <wtf/WeakPtr.h>
#import <wtf/WorkQueue.h>

namespace WebKit::LegacyExtensions {

static constexpr auto unexpectedError = "An unexpected error occurred"_s;

// ext-tabs-base.js's answer for an area of a page it blurs.
static constexpr auto black1pxPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY2BgYPgPAAEEAQBwIGULAAAAAElFTkSuQmCC"_s;
static constexpr auto gray1pxJPEG = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAALCAABAAEBAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/ACj/2Q=="_s;

// ext-tabs-base.js's blurred capture (Firefox 153, mozilla-central a5f3cdbf64fc): the image scaled to fit
// 300 pixels, larger or smaller, on an opaque canvas, through the canvas filter blur(5px), and given the
// degradation of a JPEG of quality 0.2. The blur is WebCore's, as the canvas filter applies it.
static RetainPtr<CGImageRef> blurredCapture(CGImageRef image)
{
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (!width || !height)
        return nullptr;
    double cap = std::min(300. / width, 300. / height);
    WebCore::FloatRect bounds { 0, 0, static_cast<float>(std::ceil(width * cap)), static_cast<float>(std::ceil(height * cap)) };

    RefPtr source = WebCore::ImageBuffer::create(bounds.size(), WebCore::RenderingMode::Unaccelerated, WebCore::RenderingPurpose::Unspecified, 1, WebCore::DestinationColorSpace::SRGB(), WebCore::ImageBufferFormat { WebCore::PixelFormat::BGRA8 });
    RefPtr destination = WebCore::ImageBuffer::create(bounds.size(), WebCore::RenderingMode::Unaccelerated, WebCore::RenderingPurpose::Unspecified, 1, WebCore::DestinationColorSpace::SRGB(), WebCore::ImageBufferFormat { WebCore::PixelFormat::BGRA8 });
    RefPtr nativeImage = WebCore::NativeImage::create(RetainPtr { image });
    if (!source || !destination || !nativeImage)
        return nullptr;
    source->context().drawNativeImage(*nativeImage, bounds, WebCore::FloatRect { 0, 0, static_cast<float>(width), static_cast<float>(height) });

    Ref blur = WebCore::FEGaussianBlur::create(5, 5, WebCore::EdgeModeType::None);
    Ref filter = WebCore::CSSFilterRenderer::create({ WTF::move(blur) }, { .referenceBox = bounds, .filterRegion = bounds, .scale = { 1, 1 } }, WebCore::FilterRenderingMode::Software, { });
    WebCore::FilterResults results;
    destination->context().fillRect(bounds, WebCore::Color::black);
    destination->context().drawFilteredImageBuffer(source.get(), bounds, filter, results);
    RefPtr blurredImage = WebCore::ImageBuffer::sinkIntoNativeImage(WTF::move(destination));
    if (!blurredImage)
        return nullptr;
    RetainPtr blurred = blurredImage->platformImage();

    auto jpeg = WebCore::encodeData(blurred.get(), "image/jpeg"_s, 0.2);
    if (jpeg.isEmpty())
        return nullptr;
    Ref buffer = WebCore::SharedBuffer::create(WTF::move(jpeg));
    RefPtr decoder = WebCore::ImageDecoder::create(buffer, "image/jpeg"_s, WebCore::AlphaOption::Premultiplied, WebCore::GammaAndColorProfileOption::Applied);
    if (!decoder)
        return nullptr;
    decoder->setData(buffer, true);
    return decoder->createFrameImageAtIndex(decoder->primaryFrameIndex());
}

static WorkQueue& encodingQueue()
{
    static NeverDestroyed<Ref<WorkQueue>> queue { WorkQueue::create("org.webkit.LegacyExtensionTabCapture"_s) };
    return queue.get();
}

// The page is painted as WebPage::takeSnapshot paints it, which needs no window: the area is laid out and
// painted into a bitmap of `scale` pixels per CSS pixel times the page's zoom, as Firefox's drawSnapshot
// renders it. The image is encoded as canvas.toDataURL encodes one, off the main thread as WebKit's
// tabs.captureVisibleTab encodes it.
void captureTab(WebPageProxy& page, const TabCaptureOptions& options, BlurCapture blur, CompletionHandler<void(Expected<String, String>&&)>&& completionHandler)
{
    if (blur == BlurCapture::Yes && options.rect)
        return completionHandler(String { options.jpeg ? gray1pxJPEG : black1pxPNG });
    if (!page.hasRunningProcess() || page.viewSize().isEmpty())
        return completionHandler(makeUnexpected(String { "Cannot capture invisible tab"_s }));

    double deviceScaleFactor = page.deviceScaleFactor();
    double scale = options.scale && *options.scale ? *options.scale : deviceScaleFactor;
    double zoom = page.pageZoomFactor();
    if (!(scale > 0) || !std::isfinite(scale))
        return completionHandler(makeUnexpected(String { unexpectedError }));

    auto encode = [jpeg = options.jpeg, quality = options.quality.value_or(92) / 100, blur, completionHandler = WTF::move(completionHandler)](CGImageRef image) mutable {
        if (!image)
            return completionHandler(makeUnexpected(String { unexpectedError }));
        encodingQueue().dispatch([image = RetainPtr { image }, jpeg, quality, blur, completionHandler = WTF::move(completionHandler)]() mutable {
            if (blur == BlurCapture::Yes)
                image = blurredCapture(image.get());
            String dataURL;
            if (image)
                dataURL = WebCore::encodeDataURL(image.get(), jpeg ? "image/jpeg"_s : "image/png"_s, jpeg ? std::optional { quality } : std::nullopt);
            RunLoop::mainSingleton().dispatch([dataURL = crossThreadCopy(WTF::move(dataURL)), completionHandler = WTF::move(completionHandler)]() mutable {
                if (dataURL.isEmpty() || dataURL == "data:,"_s)
                    return completionHandler(makeUnexpected(String { unexpectedError }));
                completionHandler(WTF::move(dataURL));
            });
        });
    };

    if (options.rect) {
        WebCore::FloatRect contentsRect = *options.rect;
        contentsRect.scale(zoom);
        auto snapshotRect = WebCore::enclosingIntRect(contentsRect);
        WebCore::IntSize bitmapSize { clampTo<int>(std::ceil(contentsRect.width() * scale)), clampTo<int>(std::ceil(contentsRect.height() * scale)) };
        if (snapshotRect.isEmpty() || bitmapSize.isEmpty())
            return encode(nullptr);
        page.takeSnapshot(snapshotRect, bitmapSize, { }, WTF::move(encode));
        return;
    }

    // The visible viewport, whose size in contents pixels the web process knows: its snapshot's default
    // bitmap has the page's device scale factor, and another scale takes the size from a snapshot at one
    // bitmap pixel per contents pixel.
    if (scale == deviceScaleFactor) {
        page.takeSnapshot({ }, { }, SnapshotOption::VisibleContentRect, WTF::move(encode));
        return;
    }
    page.takeSnapshot({ }, { }, { SnapshotOption::VisibleContentRect, SnapshotOption::ExcludeDeviceScaleFactor }, [weakPage = WeakPtr { page }, scale, encode = WTF::move(encode)](CGImageRef viewport) mutable {
        RefPtr page = weakPage.get();
        if (!page || !viewport)
            return encode(nullptr);
        WebCore::IntSize bitmapSize { clampTo<int>(std::ceil(CGImageGetWidth(viewport) * scale)), clampTo<int>(std::ceil(CGImageGetHeight(viewport) * scale)) };
        if (bitmapSize.isEmpty())
            return encode(nullptr);
        page->takeSnapshot({ }, bitmapSize, SnapshotOption::VisibleContentRect, WTF::move(encode));
    });
}

} // namespace WebKit::LegacyExtensions
