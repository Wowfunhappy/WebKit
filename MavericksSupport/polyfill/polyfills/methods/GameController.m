// GameController: Objective-C methods on GameController classes that macOS 10.9 does not have. The
// framework is soft-linked by WebCore, so the block names the class by string.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDDevice.h>
#import <objc/runtime.h>

@interface NSObject (WKGameControllerDeviceRef)
- (instancetype)initWithDeviceRef:(IOHIDDeviceRef)device;
@end

// ---------------------------------------------------------------------------------------------------
// +[GCController supportsHIDDevice:] is macOS 11+. 10.9's GCControllerManager matches every HID device
// and keeps the ones -[_GCController initWithDeviceRef:] accepts (the Apple Remote and MFi gamepad
// profiles); that initializer returns nil for any other device. Asking the same initializer gives
// HIDGamepadProvider the answer 10.9's framework acts on.
WK_POLYFILL_ADD_METHODS_ON(NSObject, "GCController")
+ (BOOL)supportsHIDDevice:(IOHIDDeviceRef)device
{
    if (!device)
        return NO;
    id controller = [[objc_getClass("_GCController") alloc] initWithDeviceRef:device];
    BOOL supported = controller != nil;
    [controller release];
    return supported;
}
@end
