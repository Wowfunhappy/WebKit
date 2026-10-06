// The system side for wk_selref_replace_super.m: a class with a real -ping, in an image that carries no
// __wk_marker, so its sends are never rewritten — the way a system framework's are not.
#import <objc/NSObject.h>
#import "wk_selref_replace_super_fixture.h"

@implementation WKReplaceProbeSystem
- (int)ping { return 1; }
@end
