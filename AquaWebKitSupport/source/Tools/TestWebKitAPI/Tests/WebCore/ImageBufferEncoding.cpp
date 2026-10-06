#include "config.h"

#include "Helpers/GraphicsTestUtilities.h"
#include "Helpers/Test.h"
#include "Helpers/WebCoreTestUtilities.h"
#include <WebCore/Color.h>
#include <WebCore/GraphicsContext.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/ImageUtilities.h>

namespace TestWebKitAPI {
using namespace WebCore;

static void checkEncodingPreservesCanvas(bool dataURL)
{
    for (auto mode : { RenderingMode::Unaccelerated, RenderingMode::Accelerated }) {
        auto buffer = ImageBuffer::create({ 16, 16 }, mode, RenderingPurpose::Canvas, 1, DestinationColorSpace::SRGB(), PixelFormat::BGRA8);
        ASSERT_NE(buffer, nullptr);
        ASSERT_EQ(mode, buffer->renderingMode());
        buffer->context().fillRect({ 0, 0, 16, 16 }, Color::red);
        if (dataURL)
            EXPECT_TRUE(encodeDataURL(RefPtr { buffer }, "image/png"_s).startsWith("data:image/png;base64,"_s));
        else
            EXPECT_FALSE(encodeData(RefPtr { buffer }, "image/png"_s).isEmpty());

        buffer->flushDrawingContext();
        EXPECT_TRUE(imageBufferPixelIs(Color::red, *buffer, { 8, 8 }));
        buffer->context().fillRect({ 0, 0, 16, 16 }, Color::blue);
        EXPECT_TRUE(imageBufferPixelIs(Color::blue, *buffer, { 8, 8 }));

        if (dataURL)
            EXPECT_TRUE(encodeDataURL(RefPtr { buffer }, "image/png"_s).startsWith("data:image/png;base64,"_s));
        else
            EXPECT_FALSE(encodeData(RefPtr { buffer }, "image/png"_s).isEmpty());
        buffer->flushDrawingContext();
        EXPECT_TRUE(imageBufferPixelIs(Color::blue, *buffer, { 8, 8 }));
    }
}

TEST(ImageBufferEncoding, SharedCanvasToData)
{
    checkEncodingPreservesCanvas(false);
    EXPECT_TRUE(encodeData(RefPtr<ImageBuffer> { }, "image/png"_s).isEmpty());
}

TEST(ImageBufferEncoding, SharedCanvasToDataURL)
{
    checkEncodingPreservesCanvas(true);
    EXPECT_EQ("data:,"_s, encodeDataURL(RefPtr<ImageBuffer> { }, "image/png"_s));
}

} // namespace TestWebKitAPI
