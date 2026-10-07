#include "config.h"

#include "Helpers/Test.h"
#include <WebCore/ColorSpaceCG.h>
#include <WebCore/PlatformVideoColorSpace.h>
#include <WebCore/VideoFrameCV.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <wtf/cf/TypeCastsCF.h>

namespace TestWebKitAPI {
using namespace WebCore;

static RetainPtr<CGColorSpaceRef> makeCustomProfile()
{
    const CGFloat white[] = { .95047, 1, 1.08883 }, black[] = { 0, 0, 0 }, gamma[] = { 1.8, 1.8, 1.8 };
    const CGFloat matrix[] = { .4124, .2126, .0193, .3576, .7152, .1192, .1805, .0722, .9505 };
    return adoptCF(CGColorSpaceCreateCalibratedRGB(white, black, gamma, matrix));
}

static RefPtr<VideoFrameCV> makeRGBFrame(OSType format, CGColorSpaceRef profile, PlatformVideoColorSpace&& color, CFDataRef icc = nullptr)
{
    CVPixelBufferRef rawBuffer = nullptr;
    if (CVPixelBufferCreate(nullptr, 2, 2, format, nullptr, &rawBuffer) != kCVReturnSuccess)
        return nullptr;
    auto buffer = adoptCF(rawBuffer);
    if (profile)
        CVBufferSetAttachment(buffer.get(), kCVImageBufferCGColorSpaceKey, profile, kCVAttachmentMode_ShouldPropagate);
    if (icc)
        CVBufferSetAttachment(buffer.get(), kCVImageBufferICCProfileKey, icc, kCVAttachmentMode_ShouldPropagate);
    return VideoFrameCV::create({ }, false, VideoFrameRotation::None, WTF::move(buffer), WTF::move(color));
}

static CGColorSpaceRef profileOf(const VideoFrameCV& frame)
{
    return dynamic_cf_cast<CGColorSpaceRef>(CVBufferGetAttachment(frame.pixelBuffer(), kCVImageBufferCGColorSpaceKey, nullptr));
}

static unsigned grayInSRGB(CGColorSpaceRef sourceProfile)
{
    uint8_t source[] = { 128, 128, 128, 255 }, destination[4] { };
    auto provider = adoptCF(CGDataProviderCreateWithData(nullptr, source, sizeof(source), nullptr));
    auto image = adoptCF(CGImageCreate(1, 1, 8, 32, 4, sourceProfile, kCGImageAlphaLast | kCGBitmapByteOrder32Big, provider.get(), nullptr, false, kCGRenderingIntentDefault));
    auto srgb = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    auto context = adoptCF(CGBitmapContextCreate(destination, 1, 1, 8, 4, srgb.get(), kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big));
    EXPECT_NE(image, nullptr);
    EXPECT_NE(context, nullptr);
    if (!image || !context)
        return 0;
    CGContextDrawImage(context.get(), CGRectMake(0, 0, 1, 1), image.get());
    return destination[0];
}

TEST(GStreamerCocoaPixelBuffer, FactoryPreservesProducerProfileWithoutColorimetryOverride)
{
    auto custom = makeCustomProfile();
    ASSERT_NE(custom, nullptr);
    for (auto format : { kCVPixelFormatType_32ARGB, kCVPixelFormatType_32BGRA }) {
        for (auto range : { std::optional<bool> { }, std::optional<bool> { false }, std::optional<bool> { true } }) {
            PlatformVideoColorSpace color;
            color.fullRange = range;
            auto frame = makeRGBFrame(format, custom.get(), WTF::move(color));
            ASSERT_NE(frame, nullptr);
            EXPECT_EQ(profileOf(*frame), custom.get());
        }
    }
}

TEST(GStreamerCocoaPixelBuffer, FactorySynthesizesRawRGBProfileFromExplicitColorimetry)
{
    auto srgb = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    ASSERT_NE(srgb, nullptr);
    for (auto format : { kCVPixelFormatType_32ARGB, kCVPixelFormatType_32BGRA }) {
        auto frame = makeRGBFrame(format, nullptr, { PlatformVideoColorPrimaries::Bt709, PlatformVideoTransferCharacteristics::Iec6196621, PlatformVideoMatrixCoefficients::Rgb, true });
        ASSERT_NE(frame, nullptr);
        auto profile = profileOf(*frame);
        ASSERT_NE(profile, nullptr);
        EXPECT_TRUE(CFEqual(profile, srgb.get()));
        EXPECT_NEAR(grayInSRGB(profile), 128, 1);

        auto linearFrame = makeRGBFrame(format, nullptr, { PlatformVideoColorPrimaries::Bt709, PlatformVideoTransferCharacteristics::Linear, PlatformVideoMatrixCoefficients::Rgb, true });
        ASSERT_NE(linearFrame, nullptr);
        auto linearProfile = profileOf(*linearFrame);
        ASSERT_NE(linearProfile, nullptr);
        EXPECT_NEAR(grayInSRGB(linearProfile), 188, 2);
    }
}

TEST(GStreamerCocoaPixelBuffer, FactoryReplacesProducerProfileOnlyWithRepresentableOverride)
{
    auto custom = makeCustomProfile();
    auto srgb = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    ASSERT_NE(custom, nullptr);
    ASSERT_NE(srgb, nullptr);
    auto frame = makeRGBFrame(kCVPixelFormatType_32BGRA, custom.get(), { PlatformVideoColorPrimaries::Bt709, PlatformVideoTransferCharacteristics::Iec6196621, PlatformVideoMatrixCoefficients::Rgb, true });
    ASSERT_NE(frame, nullptr);
    ASSERT_NE(profileOf(*frame), nullptr);
    EXPECT_TRUE(CFEqual(profileOf(*frame), srgb.get()));
    EXPECT_FALSE(CFEqual(profileOf(*frame), custom.get()));

    auto hdrFrame = makeRGBFrame(kCVPixelFormatType_32BGRA, custom.get(), { PlatformVideoColorPrimaries::Bt2020, PlatformVideoTransferCharacteristics::SmpteSt2084, PlatformVideoMatrixCoefficients::Rgb, true });
    ASSERT_NE(hdrFrame, nullptr);
    EXPECT_EQ(profileOf(*hdrFrame), nullptr);

    auto unspecifiedFrame = makeRGBFrame(kCVPixelFormatType_32BGRA, nullptr, { });
    ASSERT_NE(unspecifiedFrame, nullptr);
    EXPECT_EQ(profileOf(*unspecifiedFrame), nullptr);
}

TEST(GStreamerCocoaPixelBuffer, FactoryLeavesICCBackedOverrideBehaviorUnchanged)
{
    auto custom = makeCustomProfile();
    ASSERT_NE(custom, nullptr);
    auto icc = adoptCF(CGColorSpaceCopyICCProfile(custom.get()));
    ASSERT_NE(icc, nullptr);
    auto frame = makeRGBFrame(kCVPixelFormatType_32BGRA, custom.get(), { PlatformVideoColorPrimaries::Bt709, PlatformVideoTransferCharacteristics::Iec6196621, PlatformVideoMatrixCoefficients::Rgb, true }, icc.get());
    ASSERT_NE(frame, nullptr);
    EXPECT_EQ(profileOf(*frame), nullptr);
    EXPECT_EQ(CVBufferGetAttachment(frame->pixelBuffer(), kCVImageBufferICCProfileKey, nullptr), icc.get());
}

} // namespace TestWebKitAPI
