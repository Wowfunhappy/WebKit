#ifndef _IOSURFACE_OBJC_H_
#define _IOSURFACE_OBJC_H_

/* IOSurfaceObjC.h was added in macOS 10.12 */
/* On 10.9, IOSurface is available via C API only */
#include <IOSurface/IOSurface.h>

#ifdef __OBJC__
/* Minimal IOSurface Objective-C wrapper stub */
@interface IOSurface : NSObject
@end
#endif

#endif
