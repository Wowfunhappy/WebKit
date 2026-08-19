// Title-attribute tooltips for the reimplemented WKView.
//
// Safari 7 drives WebKit2 through WKView, whose page client is MavericksPageClient, so WebViewImpl's
// NSToolTipManager path is unused. This category carries WK1 WebHTMLView's classic mechanism over to
// WKView: MavericksPageClient::toolTipChanged calls -_wkSetToolTip:, which installs a wide-open
// -addToolTipRect: owned by self (answered by -view:stringForToolTip:) and sends synthetic
// mouseEntered:/mouseExited: to the NSToolTipManager tracking-rect owner it intercepted. The rect is
// wide enough that the mouse never physically crosses an edge, so those synthetic events are what arm
// the tooltip. The synthetic mouseEntered: MUST echo back the userData pointer NSToolTipManager passed
// to the -addTrackingRect: it makes under the hood (captured below): NSToolTipManager reads that
// userData in -mouseEntered: to identify which tooltip region was entered, and with anything else it
// calls -view:stringForToolTip: but displays nothing. State lives in associated objects (a category
// cannot add ivars), and this is its own file so WKViewMavericks.mm stays focused on the view itself.

#import "config.h"
#import "WKViewPrivate.h"

#if PLATFORM(MAC)

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

enum { WKToolTipTrackingRectTag = 0xBADFACE };

static const void* const wkToolTipKey = &wkToolTipKey;
static const void* const wkTrackingOwnerKey = &wkTrackingOwnerKey;
static const void* const wkTrackingUserDataKey = &wkTrackingUserDataKey;
static const void* const wkLastToolTipTagKey = &wkLastToolTipTagKey;

@implementation WKView (MavericksToolTip)

- (id)_wkToolTipOwnerForSendingMouseEvents
{
    if (id owner = objc_getAssociatedObject(self, wkTrackingOwnerKey))
        return owner;
    for (NSTrackingArea *trackingArea in self.trackingAreas) {
        static Class managerClass = NSClassFromString(@"NSToolTipManager");
        if ([trackingArea.owner class] == managerClass)
            return trackingArea.owner;
    }
    return nil;
}

- (void)_wkSendToolTipEnterExit:(NSEventType)type
{
    // Nothing matters except window, trackingNumber, and userData. The userData is the pointer
    // NSToolTipManager passed to -addTrackingRect: (captured below): NSToolTipManager reads it in
    // -mouseEntered: to identify which tooltip region was entered, so it MUST be echoed back or no
    // tooltip is shown. Mirrors -[WebHTMLView _sendToolTipMouseEntered].
    void *trackingUserData = [objc_getAssociatedObject(self, wkTrackingUserDataKey) pointerValue];
    NSEvent *fakeEvent = [NSEvent enterExitEventWithType:type
        location:NSMakePoint(0, 0) modifierFlags:0 timestamp:0
        windowNumber:[[self window] windowNumber] context:NULL eventNumber:0
        trackingNumber:WKToolTipTrackingRectTag userData:trackingUserData];
    id owner = [self _wkToolTipOwnerForSendingMouseEvents];
    if (type == NSEventTypeMouseEntered)
        [owner mouseEntered:fakeEvent];
    else
        [owner mouseExited:fakeEvent];
}

- (void)_wkSetToolTip:(NSString *)string
{
    NSString *toolTip = string.length ? string : nil;
    NSString *oldToolTip = objc_getAssociatedObject(self, wkToolTipKey);
    if (toolTip == oldToolTip || [toolTip isEqualToString:oldToolTip])
        return;
    if (oldToolTip)
        [self _wkSendToolTipEnterExit:NSEventTypeMouseExited];
    objc_setAssociatedObject(self, wkToolTipKey, toolTip, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (toolTip) {
        // See radar 3500217 for why we remove all tooltips rather than just the single one we created.
        [self removeAllToolTips];
        NSToolTipTag tag = [self addToolTipRect:NSMakeRect(-100000, -100000, 200000, 200000) owner:self userData:NULL];
        objc_setAssociatedObject(self, wkLastToolTipTagKey, @(tag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self _wkSendToolTipEnterExit:NSEventTypeMouseEntered];
    }
}

// Intercept the tracking rect -addToolTipRect: creates internally (owner = the private NSToolTipManager),
// returning a sentinel tag without a real rect so the tooltip is driven purely by the synthetic events
// above. WKView tracks the cursor via NSTrackingArea, not -addTrackingRect:, so these only ever see the
// tooltip system's calls. Mirrors -[WebHTMLView addTrackingRect:...].
- (NSTrackingRectTag)addTrackingRect:(NSRect)rect owner:(id)owner userData:(void *)data assumeInside:(BOOL)assumeInside
{
    objc_setAssociatedObject(self, wkTrackingOwnerKey, owner, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(self, wkTrackingUserDataKey, [NSValue valueWithPointer:data], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return WKToolTipTrackingRectTag;
}

- (NSTrackingRectTag)_addTrackingRect:(NSRect)rect owner:(id)owner userData:(void *)data assumeInside:(BOOL)assumeInside useTrackingNum:(int)tag
{
    objc_setAssociatedObject(self, wkTrackingOwnerKey, owner, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(self, wkTrackingUserDataKey, [NSValue valueWithPointer:data], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return WKToolTipTrackingRectTag;
}

- (void)_addTrackingRects:(NSRect *)rects owner:(id)owner userDataList:(void **)userDataList assumeInsideList:(BOOL *)assumeInsideList trackingNums:(NSTrackingRectTag *)trackingNums count:(int)count
{
    if (count > 0) {
        objc_setAssociatedObject(self, wkTrackingOwnerKey, owner, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(self, wkTrackingUserDataKey, [NSValue valueWithPointer:userDataList[0]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        trackingNums[0] = WKToolTipTrackingRectTag;
    }
}

- (void)removeTrackingRect:(NSTrackingRectTag)tag
{
    if (!tag)
        return;
    if (tag == WKToolTipTrackingRectTag) {
        objc_setAssociatedObject(self, wkTrackingOwnerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    [super removeTrackingRect:tag];
}

- (void)_removeTrackingRects:(NSTrackingRectTag *)tags count:(int)count
{
    for (int i = 0; i < count; ++i) {
        if (tags[i] == WKToolTipTrackingRectTag)
            objc_setAssociatedObject(self, wkTrackingOwnerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

// AppKit calls this on the -addToolTipRect: owner (self) to fetch the tooltip string.
ALLOW_DEPRECATED_IMPLEMENTATIONS_BEGIN
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data
ALLOW_DEPRECATED_IMPLEMENTATIONS_END
{
    return [[objc_getAssociatedObject(self, wkToolTipKey) copy] autorelease];
}

@end

#endif // PLATFORM(MAC)
