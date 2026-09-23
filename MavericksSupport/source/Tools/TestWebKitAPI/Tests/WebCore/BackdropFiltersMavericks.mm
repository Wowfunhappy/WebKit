#include "config.h"

#include "Helpers/Test.h"
#include <WebCore/FilterOperations.h>
#include <WebCore/PlatformCAAnimation.h>
#include <WebCore/PlatformCAFilters.h>
#import <WebCore/WebBackdropLayerMavericks.h>

namespace TestWebKitAPI {
using namespace WebCore;

TEST(BackdropFiltersMavericks, NativePropertiesAndBackendRouting)
{
    RetainPtr backdrop = adoptNS([[WebBackdropLayerMavericks alloc] init]);
    RetainPtr foreground = adoptNS([[CALayer alloc] init]);
    FilterOperations blur { { BlurFilterOperation::create(8) } };
    PlatformCAFilters::setFiltersOnLayer(foreground.get(), blur, true);
    ASSERT_EQ(1U, [[foreground filters] count]);
    EXPECT_EQ(0U, [[foreground backgroundFilters] count]);

    // Native foreground and background properties remain independent on the private layer.
    [backdrop setFilters:[foreground filters]];
    EXPECT_EQ(1U, [[backdrop filters] count]);
    EXPECT_EQ(0U, [[backdrop backgroundFilters] count]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), blur, true);
    EXPECT_EQ(1U, [[backdrop filters] count]);
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), { }, true);
    EXPECT_EQ(1U, [[backdrop filters] count]);
    EXPECT_EQ(0U, [[backdrop backgroundFilters] count]);

    [foreground setBackgroundFilters:[foreground filters]];
    PlatformCAFilters::setFiltersOnLayer(foreground.get(), { }, true);
    EXPECT_EQ(0U, [[foreground filters] count]);
    EXPECT_EQ(1U, [[foreground backgroundFilters] count]);
}

TEST(BackdropFiltersMavericks, AnimationKeyPaths)
{
    auto foreground = PlatformCAAnimation::makeKeyPath(AnimatedProperty::Filter, FilterOperation::Type::Blur, 2);
    auto backdrop = PlatformCAAnimation::makeKeyPath(AnimatedProperty::WebkitBackdropFilter, FilterOperation::Type::Blur, 2);
    EXPECT_EQ("filters.filter_2.inputRadius"_s, foreground);
    EXPECT_EQ("backgroundFilters.filter_2.inputRadius"_s, backdrop);
    EXPECT_TRUE(PlatformCAAnimation::isValidKeyPath(foreground));
    EXPECT_TRUE(PlatformCAAnimation::isValidKeyPath(backdrop));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters.filter_.inputRadius"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters.filter_-1.inputRadius"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters.filter_0.invalidProperty"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters.filter_0.inputRadius.extra"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath(backdrop, PlatformCAAnimation::AnimationType::Group));
}

} // namespace TestWebKitAPI
