/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
 *
 * 10.9 backport: internal accessor letting WKView pull the underlying
 * WKPageGroupRef out of a WKBrowsingContextGroup so it can route the legacy
 * -initWithFrame:processGroup:browsingContextGroup: initializer through the
 * existing -initWithFrame:contextRef:pageGroupRef: path.
 */

#import "WKBrowsingContextGroup.h"

#if !TARGET_OS_IPHONE

#import <WebKit/WKPageGroup.h>

@interface WKBrowsingContextGroup (Internal)
- (WKPageGroupRef)_pageGroupRef;
@end

#endif // !TARGET_OS_IPHONE
