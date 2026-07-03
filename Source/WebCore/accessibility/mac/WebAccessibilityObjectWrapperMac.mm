// MAVERICKS_BACKPORT: keystone band-aid — ENABLE_ACCESSIBILITY_ISOLATED_TREE is flipped to 0 (in
// PlatformEnableCocoa.h) because the isolated-tree AX architecture needs post-10.9 AX threading/SPI. The
// real 4478-line wrapper is coupled to AXIsolatedTree/AXSearchManager/AXLiveRegionManager (compiled out by
// that flag), so it won't link; gut it to an empty wrapper class. Feature-disable, not an SDK gap.
#import "config.h"
#import "SimpleRange.h"
#import "WebAccessibilityObjectWrapperMac.h"
#import <pal/spi/mac/HIServicesSPI.h>
#import <Foundation/Foundation.h>
// MAVERICKS_BACKPORT: bare wrapper subclass + trimmed imports replace the real 4478-line wrapper,
// which is coupled to the isolated-tree AX classes compiled out on this port (see header above).
// It inherits WebAccessibilityObjectWrapperBase (fully compiled), so AXObjectCache::attachWrapper's
// -initWithAccessibilityObject: and the base attach/detach/axBackingObject plumbing work; only the
// Mac NSAccessibility attribute layer is absent (AppKit's NSObject informal AX protocol answers
// those with defaults).
@implementation WebAccessibilityObjectWrapper

// MAVERICKS_BACKPORT: 10.9 AppKit does not implement the informal NSAccessibility protocol on
// NSObject, so without these a plain attribute query on the wrapper raises unrecognized-selector
// and kills WebContent (e.g. WKAccessibilityWebPageObjectBase's accessibilityFocusedUIElement,
// WebKitTestRunner's accessibilityController). Answer the legacy informal protocol with empty
// values so assistive queries degrade gracefully while the attribute layer is feature-disabled.
- (NSArray *)accessibilityAttributeNames
{
    return @[];
}

- (id)accessibilityAttributeValue:(NSString *)attribute
{
    return nil;
}

- (BOOL)accessibilityIsAttributeSettable:(NSString *)attribute
{
    return NO;
}

- (void)accessibilitySetValue:(id)value forAttribute:(NSString *)attribute
{
}

- (NSArray *)accessibilityParameterizedAttributeNames
{
    return @[];
}

- (id)accessibilityAttributeValue:(NSString *)attribute forParameter:(id)parameter
{
    return nil;
}

- (NSArray *)accessibilityActionNames
{
    return @[];
}

- (NSString *)accessibilityActionDescription:(NSString *)action
{
    return nil;
}

- (void)accessibilityPerformAction:(NSString *)action
{
}

- (BOOL)accessibilityIsIgnored
{
    return YES;
}

- (id)accessibilityHitTest:(NSPoint)point
{
    return self;
}

- (id)accessibilityFocusedUIElement
{
    return self;
}

@end

// MAVERICKS_BACKPORT: minimal namespace + forward-decl for the graceful stub below; the real
// wrapper's AXObjectCache uses (and #includes) are gone with the gutted implementation.
namespace WebCore {

class AXObjectCache; // MAVERICKS_BACKPORT: forward-decl for the gutted wrapper's graceful stub below.

// MAVERICKS_BACKPORT: the real rangeForTextMarkerRange lives in the gutted 4478-line wrapper above. Provide
// a graceful stub so the symbol resolves — AccessibilityObjectCocoa.mm's attributedStringForTextMarkerRange
// (the VoiceOver "read text" path) calls it. With the AX wrapper disabled it yields no range, so the
// attributed string is nil (AX degrades gracefully) instead of a dyld-halt on the undefined symbol.
std::optional<SimpleRange> rangeForTextMarkerRange(AXObjectCache*, AXTextMarkerRangeRef)
{
    return std::nullopt; // MAVERICKS_BACKPORT: AX disabled → no marker range (graceful nil, no dyld-halt).
}

// MAVERICKS_BACKPORT: closes the WebCore namespace of this gutted wrapper translation unit.
} // namespace WebCore
