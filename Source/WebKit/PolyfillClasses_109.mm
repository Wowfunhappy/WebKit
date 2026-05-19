// 10.9 backport: stub @implementations for ObjC classes that Safari 9.1.3
// references from WebKit.framework directly. These were previously provided by
// /Users/jonathan/Desktop/clang/polyfill_stubs.o but that put them in EVERY
// framework as duplicates and crashed libobjc. Defining them here lives in
// WebKit alone (so Safari's `Expected in: WebKit` import resolves) without
// duplicating into JSC + WebCore + WebKit.

#include "config.h"
#import <Foundation/Foundation.h>

@interface WKWebInspectorProxyObjCAdapter : NSObject @end
@implementation WKWebInspectorProxyObjCAdapter @end

@interface WebKeyGenerator : NSObject @end
@implementation WebKeyGenerator @end
