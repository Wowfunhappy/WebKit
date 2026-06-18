/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
 *
 * 10.9 backport: internal accessor letting WKView pull the underlying
 * WKContextRef (WebProcessPool) out of a WKProcessGroup so it can route the
 * legacy -initWithFrame:processGroup:browsingContextGroup: initializer through
 * the existing -initWithFrame:contextRef:pageGroupRef: path.
 */

#import "WKProcessGroup.h"

#if !TARGET_OS_IPHONE

#import <WebKit/WKContext.h>

@interface WKProcessGroup (Internal)
- (WKContextRef)_contextRef;
@end

#endif // !TARGET_OS_IPHONE
