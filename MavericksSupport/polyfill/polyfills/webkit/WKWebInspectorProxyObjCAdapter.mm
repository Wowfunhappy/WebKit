// WebKit.framework: stub @implementations for ObjC classes that Safari 9.1.3 imports from
// WebKit.framework directly, so its `Expected in: WebKit` bind resolves.
//
// A class belongs here when WebKit is the one framework in the process that defines it. Each ObjC
// class must have exactly one definition across every framework a process loads — two registrations
// of the same name is a libobjc hazard — so a class that some other framework already implements
// for real is reached from there instead. WebKeyGenerator is the example: WebKitLegacy implements
// it in mac/Misc/WebKeyGenerator.mm, and that is the definition Safari binds.

#import <Foundation/Foundation.h>

@interface WKWebInspectorProxyObjCAdapter : NSObject @end
@implementation WKWebInspectorProxyObjCAdapter @end

