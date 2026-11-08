// The fixture for wk_selref_dlopen_category.m: two categories on classes the probe executable defines and
// one selector reference, built as a WebKit-marked bundle against that executable (-bundle_loader).
#import <objc/NSObject.h>
#import <objc/runtime.h>

@interface WKCategoryProbePlain : NSObject
@end

@interface WKCategoryProbeOverridden : NSObject
@end

@implementation WKCategoryProbePlain (WKCategoryProbeFixture)
- (int)selrefCategoryProbeValue { return 7; }
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation WKCategoryProbeOverridden (WKCategoryProbeFixture)
- (int)selrefCategoryProbeValue { return 8; }
@end
#pragma clang diagnostic pop

SEL wk_fixture_probe_selector(void)
{
    return @selector(selrefCategoryProbeValue);
}
