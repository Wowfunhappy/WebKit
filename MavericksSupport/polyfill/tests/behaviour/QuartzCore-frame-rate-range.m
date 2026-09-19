// -[CAAnimation preferredFrameRateRange] and -highFrameRateReason: each answers its default until set, then
// the value set, a copy of the animation carries both, and the class a host app sees has neither selector.

#import <QuartzCore/QuartzCore.h>

#include <stdio.h>

typedef uint32_t CAHighFrameRateReason;
@interface CAAnimation (WKHighFrameRateReason)
@property CAHighFrameRateReason highFrameRateReason;
@end

static int failures;

static void expectRange(const char *what, CAFrameRateRange range, float minimum, float maximum, float preferred)
{
    if (range.minimum == minimum && range.maximum == maximum && range.preferred == preferred)
        return;
    fprintf(stderr, "FAIL %s: {%g, %g, %g}, expected {%g, %g, %g}\n", what, range.minimum, range.maximum, range.preferred, minimum, maximum, preferred);
    ++failures;
}

static void expectReason(const char *what, CAHighFrameRateReason reason, CAHighFrameRateReason expected)
{
    if (reason == expected)
        return;
    fprintf(stderr, "FAIL %s: reason %u, expected %u\n", what, reason, expected);
    ++failures;
}

int main(void)
{
    @autoreleasepool {
        expectRange("CAFrameRateRangeDefault", CAFrameRateRangeDefault, 0, 0, 0);

        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        expectRange("unset range", animation.preferredFrameRateRange, 0, 0, 0);
        expectReason("unset reason", animation.highFrameRateReason, 0);

        animation.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
        animation.highFrameRateReason = (44 << 16) | 1;
        expectRange("set range", animation.preferredFrameRateRange, 80, 120, 120);
        expectReason("set reason", animation.highFrameRateReason, (44 << 16) | 1);

        CABasicAnimation *copy = [[animation copy] autorelease];
        expectRange("copied range", copy.preferredFrameRateRange, 80, 120, 120);
        expectReason("copied reason", copy.highFrameRateReason, (44 << 16) | 1);

        for (NSString *selector in @[ @"preferredFrameRateRange", @"setPreferredFrameRateRange:", @"highFrameRateReason", @"setHighFrameRateReason:" ]) {
            if ([CAAnimation instancesRespondToSelector:NSSelectorFromString(selector)]) {
                fprintf(stderr, "FAIL CAAnimation answers -%s to a host app\n", selector.UTF8String);
                ++failures;
            }
        }
    }
    if (failures)
        return 1;
    printf("frame rate range: all cases match\n");
    return 0;
}
