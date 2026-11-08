// The fixture for wk_selref_dlopen_category.m: two categories on classes the probe executable defines,
// built as a bundle against that executable (-bundle_loader).
#import <objc/NSObject.h>

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
