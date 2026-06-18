// MAVERICKS_BACKPORT: keystone band-aid — ENABLE_ACCESSIBILITY_ISOLATED_TREE is flipped to 0 (in
// PlatformEnableCocoa.h) because the isolated-tree AX architecture needs post-10.9 AX threading/SPI. The
// real 4478-line wrapper is coupled to AXIsolatedTree/AXSearchManager/AXLiveRegionManager (compiled out by
// that flag), so it won't link; gut it to an empty wrapper class. Feature-disable, not an SDK gap.
#import "config.h"
#import <Foundation/Foundation.h>
@interface WebAccessibilityObjectWrapper : NSObject @end
@implementation WebAccessibilityObjectWrapper @end
