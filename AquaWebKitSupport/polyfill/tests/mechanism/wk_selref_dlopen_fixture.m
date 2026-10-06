// The dlopen fixture for wk_selref_dlopen.m: one ObjC class in a dylib whose only dependencies are
// libobjc and libSystem, so loading it is a genuinely SINGLE-image dlopen batch. A system framework
// cannot play this role: dlopening one cascades further image loads, and each of those fires the
// add-image callback, whose deferred-ADD retry then rescues even a mechanism without the state-45
// drain — making the regression invisible. The no-subsequent-image case is exactly what this fixture
// exists to pin down.
#import <objc/NSObject.h>

@interface WKDrainProbeFixture : NSObject
@end

@implementation WKDrainProbeFixture
@end
