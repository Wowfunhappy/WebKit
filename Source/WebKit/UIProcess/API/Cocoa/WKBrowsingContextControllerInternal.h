/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
 *
 * 10.9 backport: internal initializer so WKView can vend a
 * WKBrowsingContextController bound to its page. The legacy controller's
 * loading API was gutted upstream; the minimal surface QuickLook's
 * Web2.qldisplay uses is restored in WKBrowsingContextController.mm.
 */

#import "WKBrowsingContextController.h"

#if !TARGET_OS_IPHONE

#import <WebKit/WKBase.h>

@interface WKBrowsingContextController (Internal)
- (instancetype)_initWithPageRef:(WKPageRef)pageRef;
- (WKPageRef)_pageRefInternal;
@end

#endif // !TARGET_OS_IPHONE
