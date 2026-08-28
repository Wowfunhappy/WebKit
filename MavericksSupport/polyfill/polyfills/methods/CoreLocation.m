// CoreLocation: Objective-C methods on CoreLocation classes that macOS 10.9 does not have. The class
// is not linked here, so the block names it by string.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// -[CLLocation floor] is 10.15+. 10.9's CoreLocation carries no floor information at all — there is no
// CLFloor class — so nil is the true answer, and GeolocationPositionData's `if (location.floor)` skips
// the level read exactly as it does for an outdoor fix on a modern OS. Named by class so this archive
// keeps no link-time dependency on CoreLocation.
WK_POLYFILL_ADD_METHODS_ON(NSObject, "CLLocation")
- (id)floor
{
    return nil;
}
@end

#pragma clang diagnostic pop
