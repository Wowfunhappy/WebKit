// MAVERICKS_BACKPORT: keystone band-aid — ENABLE_ACCESSIBILITY_ISOLATED_TREE is flipped to 0 (in
// PlatformEnableCocoa.h) because the isolated-tree AX architecture needs post-10.9 AX threading/SPI. The
// real 4478-line wrapper is coupled to AXIsolatedTree/AXSearchManager/AXLiveRegionManager (compiled out by
// that flag), so it won't link; gut it to an empty wrapper class. Feature-disable, not an SDK gap.
// MAVERICKS_BACKPORT: SimpleRange.h include for the rangeForTextMarkerRange stub below; the gutted wrapper drops the real wrapper's transitive includes.
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
    // MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — empty attribute-name list; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
    return @[];
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — nil attribute value; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (id)accessibilityAttributeValue:(NSString *)attribute
{
    return nil;
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — attributes not settable; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (BOOL)accessibilityIsAttributeSettable:(NSString *)attribute
{
    return NO;
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — no-op setter; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (void)accessibilitySetValue:(id)value forAttribute:(NSString *)attribute
{
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     NSBezierPath *bezierPath = [NSBezierPath bezierPath];
//     CGPathApply(path, (__bridge void*)bezierPath, WebTransformCGPathToNSBezierPath);
//     return bezierPath;
// (end MAVERICKS_BACKPORT restored block)
}

- (NSArray *)accessibilityParameterizedAttributeNames
{
    // MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — empty parameterized-attribute list; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
    return @[];
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — nil parameterized value; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (id)accessibilityAttributeValue:(NSString *)attribute forParameter:(id)parameter
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#if ENABLE(MODEL_ELEMENT_ACCESSIBILITY)
    if (backingObject.isModel()) {
        auto modelChildren = backingObject.modelElementChildren();
        if (modelChildren.children.size()) {
            return createNSArray(WTF::move(modelChildren.children), [](auto&& child) -> id {
                return child.get();
            }).autorelease();
        }
    }
#endif

    if (!unignoredChildren.size()) {
        if (RetainPtr widgetChildren = renderWidgetChildren(backingObject))
            return widgetChildren.unsafeGet();
    }
MAVERICKS_BACKPORT */
    return nil;
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — empty action list; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (NSArray *)accessibilityActionNames
{
    return @[];
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — nil action description; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (NSString *)accessibilityActionDescription:(NSString *)action
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    if (backingObject.isEmptyGroup())
        return NSAccessibilityEmptyGroupSubrole;

    String subrole = backingObject.subrolePlatformString();
    if (!subrole.isEmpty())
        return subrole.createNSString();
MAVERICKS_BACKPORT */
    return nil;
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — no-op action; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (void)accessibilityPerformAction:(NSString *)action
{
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     return backingObject.datetimeAttributeValue().createNSString().autorelease();
// (end MAVERICKS_BACKPORT restored block)
}

- (BOOL)accessibilityIsIgnored
{
    // MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — element ignored; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
    return YES;
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — hit-test returns self; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (id)accessibilityHitTest:(NSPoint)point
{
    return self;
}

// MAVERICKS_BACKPORT: gutted-wrapper informal-AX stub — focused element is self; 10.9 AppKit gives NSObject no NSAccessibility default so the wrapper answers itself.
- (id)accessibilityFocusedUIElement
{
    return self;
}

// MAVERICKS_BACKPORT: closes the gutted WebAccessibilityObjectWrapper @implementation; the remaining upstream Mac AX methods are compiled out with the isolated-tree layer.
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
