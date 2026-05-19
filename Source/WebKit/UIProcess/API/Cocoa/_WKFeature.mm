// Minimal 10.9 backport: provide an @implementation so OBJC_CLASS_$__WKFeature
// resolves at link time. Subclasses (_WKExperimentalFeature, _WKInternalDebugFeature)
// reference the metaclass; they need a real class struct, not a stub.
#include "config.h"
#import "_WKFeatureInternal.h"

@implementation _WKFeature
- (NSString *)key { return @""; }
- (NSString *)name { return @""; }
- (WebFeatureStatus)status { return (WebFeatureStatus)0; }
- (WebFeatureCategory)category { return (WebFeatureCategory)0; }
- (NSString *)details { return @""; }
- (BOOL)defaultValue { return NO; }
- (BOOL)isHidden { return YES; }
@end
