// AppKit: stubs of the AppKit classes 10.9 does not have.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

WK_PRIV_CLASS(NSFilePromiseReceiver) @interface NSFilePromiseReceiver : NSObject @end
@implementation NSFilePromiseReceiver @end
WK_PRIV_ALIAS(NSFilePromiseReceiver);
// NSFilePromiseProvider (10.12+): the modern promised-file drag source. WebViewImpl's attachment-element
// drag-out builds one and hands it to -[NSDraggingItem initWithPasteboardWriter:]; on 10.9 the class
// binds as a nil weak import. The initializer tolerates the nil writer and returns a real item, and the
// items array builds fine — the throw comes inside -[NSView beginDraggingSessionWithItems:event:source:],
// where AppKit inserts each item's pasteboard WRITER into an internal mutable array and the nil one
// raises (NSInvalidArgumentException, -[__NSArrayM insertObject:atIndex:]: object cannot be nil —
// isolated step-by-step on this host), killing the UI process mid-drag. This stub holds the
// fileType/delegate/userInfo it is given and satisfies
// NSPasteboardWriting by writing nothing: 10.9 drop destinations only understand the classic
// PasteboardRef promise protocol, which AppKit's modern promise machinery never engages here, so the
// drag proceeds with no promise payload instead of throwing. (A classic NSFilesPromisePboardType
// bridge is possible if a WKWebView-backed view ever hosts attachment drags on this system — the
// Safari-facing WKView has its own classic promised-file path.)
WK_PRIV_CLASS(NSFilePromiseProvider) @interface NSFilePromiseProvider : NSObject <NSPasteboardWriting>
{
    NSString *_wkFileType;
    id _wkDelegate;
    id _wkUserInfo;
}
- (instancetype)initWithFileType:(NSString *)fileType delegate:(id)delegate;
- (NSString *)fileType;
- (id)delegate;
- (id)userInfo;
- (void)setUserInfo:(id)userInfo;
@end
@implementation NSFilePromiseProvider
- (instancetype)initWithFileType:(NSString *)fileType delegate:(id)delegate
{
    if (!(self = [super init]))
        return nil;
    _wkFileType = [fileType copy];
    _wkDelegate = delegate;
    return self;
}
- (void)dealloc
{
    [_wkFileType release];
    [_wkUserInfo release];
    [super dealloc];
}
- (NSString *)fileType { return _wkFileType; }
- (id)delegate { return _wkDelegate; }
- (id)userInfo { return _wkUserInfo; }
- (void)setUserInfo:(id)userInfo
{
    if (_wkUserInfo == userInfo)
        return;
    [_wkUserInfo release];
    _wkUserInfo = [userInfo retain];
}
- (NSArray *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    (void)pasteboard;
    return [NSArray array];
}
- (id)pasteboardPropertyListForType:(NSString *)type
{
    (void)type;
    return nil;
}
@end
WK_PRIV_ALIAS(NSFilePromiseProvider);

WK_PRIV_CLASS(_NSScrollingMomentumCalculator) @interface _NSScrollingMomentumCalculator : NSObject @end
@implementation _NSScrollingMomentumCalculator @end
WK_PRIV_ALIAS(_NSScrollingMomentumCalculator);
// _NSScrollingPredominantAxisFilter (10.10+ AppKit): the scroll-gesture input filter
// WheelEventDeltaFilterMac drives on every wheel event. Its contract has two halves, both implemented
// here for real: (1) axis-lock — when a gesture runs predominantly along one axis, the cross-axis
// component of the outgoing delta is suppressed, so pages don't drift sideways under vertical
// scrolling jitter (the filtered delta is what EventHandler actually scrolls by); (2) velocity — a
// smoothed points-per-second estimate from the delta/timestamp stream, which scroll-snap momentum
// consumes. The lock is decided once per gesture, from the first few points of accumulated travel: a
// gesture at least 80% along one axis locks to it, anything more diagonal stays free; -reset (sent at
// each gesture boundary) starts the next decision fresh.
WK_PRIV_CLASS(_NSScrollingPredominantAxisFilter) @interface _NSScrollingPredominantAxisFilter : NSObject {
    double _accumulatedX;
    double _accumulatedY;
    NSTimeInterval _lastTimestamp;
    BOOL _haveTimestamp;
    NSPoint _velocity;
    int _axisDecision; // 0 = undecided, 1 = locked horizontal, 2 = locked vertical, -1 = free (diagonal)
}
- (void)filterInputDelta:(NSPoint)delta timestamp:(NSTimeInterval)timestamp outputDelta:(NSPoint *)outDelta velocity:(NSPoint *)outVelocity;
- (void)reset;
@end
@implementation _NSScrollingPredominantAxisFilter
- (void)filterInputDelta:(NSPoint)delta timestamp:(NSTimeInterval)timestamp outputDelta:(NSPoint *)outDelta velocity:(NSPoint *)outVelocity
{
    _accumulatedX += fabs(delta.x);
    _accumulatedY += fabs(delta.y);

    // Decide the gesture's lock once ~4pt of travel has been seen — early enough that a stray
    // first event doesn't choose, late enough that the direction is real.
    if (!_axisDecision) {
        double total = _accumulatedX + _accumulatedY;
        if (total >= 4) {
            double major = _accumulatedX > _accumulatedY ? _accumulatedX : _accumulatedY;
            if (major / total >= 0.8)
                _axisDecision = _accumulatedX > _accumulatedY ? 1 : 2;
            else
                _axisDecision = -1;
        }
    }

    NSPoint filtered = delta;
    if (_axisDecision == 1)
        filtered.y = 0;
    else if (_axisDecision == 2)
        filtered.x = 0;

    // Smooth the instantaneous delta/dt into the running estimate; the newest sample dominates so the
    // velocity tracks the finger, while single-event spikes are damped. A non-advancing or absurd
    // timestamp step (paused stream) contributes nothing.
    if (_haveTimestamp) {
        NSTimeInterval dt = timestamp - _lastTimestamp;
        if (dt > 0 && dt < 1) {
            const double alpha = 0.75;
            _velocity.x = alpha * (filtered.x / dt) + (1 - alpha) * _velocity.x;
            _velocity.y = alpha * (filtered.y / dt) + (1 - alpha) * _velocity.y;
        }
    }
    _lastTimestamp = timestamp;
    _haveTimestamp = YES;

    if (outDelta)
        *outDelta = filtered;
    if (outVelocity)
        *outVelocity = _velocity;
}
- (void)reset
{
    _accumulatedX = 0;
    _accumulatedY = 0;
    _lastTimestamp = 0;
    _haveTimestamp = NO;
    _velocity = NSZeroPoint;
    _axisDecision = 0;
}
@end
WK_PRIV_ALIAS(_NSScrollingPredominantAxisFilter);
// NSHapticFeedbackManager is 10.11+; on 10.9 the class is absent, so upstream's
// [[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:performanceTime:] would fail to
// bind _OBJC_CLASS_$_NSHapticFeedbackManager. Provide a no-op stub: defaultPerformer returns a shared
// instance whose performFeedbackPattern:performanceTime: does nothing (10.9 has no haptic hardware).
WK_PRIV_CLASS(NSHapticFeedbackManager) @interface NSHapticFeedbackManager : NSObject
+ (id)defaultPerformer;
- (void)performFeedbackPattern:(NSInteger)pattern performanceTime:(NSInteger)performanceTime;
@end
@implementation NSHapticFeedbackManager
+ (id)defaultPerformer
{
    static NSHapticFeedbackManager *performer;
    if (!performer)
        performer = [[self alloc] init];
    return performer;
}
- (void)performFeedbackPattern:(NSInteger)pattern performanceTime:(NSInteger)performanceTime { }
@end
WK_PRIV_ALIAS(NSHapticFeedbackManager);

// NSVisualEffectView (10.10+): a vibrancy/backdrop view. 10.9's compositor has no backdrop blur, so
// the stub degrades the way a real 10.10 effect view degrades when vibrancy is unavailable (Reduce
// Transparency): it paints its MATERIAL's opaque fallback — a solid fill standing in for the blurred
// backdrop — rather than nothing at all. A stub that draws nothing is not that degradation: it leaves
// the effect view's clients backdropless, which for the datalist suggestions dropdown means a
// see-through suggestions list with the host window's 10.9 titlebar gradient showing through (#115).
// The remaining appearance knobs upstream sets (state / blending mode / emphasized / mask) accept
// their value and select the one look this OS can draw. Classref users today:
// WebDataListSuggestionsDropdownMac's dropdown backdrop (material Menu),
// WebCoreFullScreenPlaceholderView's dimming veil (material Popover), WKWebView's Screen Time
// snapshot blur (material UnderWindowBackground). (NSClassFromString(@"NSVisualEffectView") still
// answers nil by WK_PRIV_CLASS design — see the header comment — so probing code keeps taking its
// pre-class path.)
WK_PRIV_CLASS(NSVisualEffectView) @interface NSVisualEffectView : NSView {
    NSInteger _wkMaterial;
}
- (void)setMaterial:(NSInteger)material;
- (void)setState:(NSInteger)state;
- (void)setBlendingMode:(NSInteger)blendingMode;
- (void)setEmphasized:(BOOL)emphasized;
- (void)setMaskImage:(NSImage *)maskImage;
@end
@implementation NSVisualEffectView
- (void)setMaterial:(NSInteger)material
{
    _wkMaterial = material;
    [self setNeedsDisplay:YES];
}
// The solid stand-in for each material's backdrop, in this OS's palette. 10.9 draws its own menus
// white, so the light chrome materials map to white; everything else is the standard window/control
// background gray. The dark materials (Dark / UltraDark / HUDWindow) map to the HUD's near-black.
// No client in this tree passes a dark material today, but answering it wrongly-white would be a
// worse lie than answering it dark.
- (NSColor *)wkMaterialFallbackColor
{
    switch (_wkMaterial) {
    case 2:  // NSVisualEffectMaterialDark
    case 9:  // NSVisualEffectMaterialUltraDark
    case 13: // NSVisualEffectMaterialHUDWindow
        return [NSColor colorWithCalibratedWhite:0.15 alpha:1];
    case 5:  // NSVisualEffectMaterialMenu
    case 6:  // NSVisualEffectMaterialPopover
    case 17: // NSVisualEffectMaterialToolTip
        return [NSColor whiteColor];
    default: // AppearanceBased, Titlebar, Sidebar, WindowBackground, UnderWindowBackground, ...
        return [NSColor windowBackgroundColor];
    }
}
- (void)drawRect:(NSRect)dirtyRect
{
    [[self wkMaterialFallbackColor] set];
    NSRectFill(dirtyRect);
}
- (void)setState:(NSInteger)state { (void)state; }
- (void)setBlendingMode:(NSInteger)blendingMode { (void)blendingMode; }
- (void)setEmphasized:(BOOL)emphasized { (void)emphasized; }
- (void)setMaskImage:(NSImage *)maskImage { (void)maskImage; }
@end
WK_PRIV_ALIAS(NSVisualEffectView);

// NSColorSampler (10.14+): the screen colour-picker the Web Inspector's colour swatch opens ("pick colour
// from screen"). Implemented for real, not stubbed: every primitive it needs is present on 10.9 —
// CGDisplayCreateImageForRect, CGMainDisplayID, +[NSEvent addGlobalMonitorForEventsMatchingMask:handler:]
// (10.6) and -[NSBitmapImageRep colorAtX:y:] — verified by sampling a live pixel under the cursor on this
// host. What 10.9 lacks is only the magnifier loupe's *presentation*, not the ability to sample.
//
// Behaviour matches the real sampler's contract: the pointer becomes a crosshair, a click commits the colour
// under the cursor, Escape or a right-click cancels, and the handler is invoked exactly once — with the
// sampled NSColor on commit, or nil on cancel. Callers already handle nil, because cancelling is an ordinary
// outcome of the real API.
WK_PRIV_CLASS(NSColorSampler) @interface NSColorSampler : NSObject
- (void)showSamplerWithSelectionHandler:(void (^)(NSColor *selectedColor))selectionHandler;
@end

@implementation NSColorSampler {
    id _mouseMonitor;
    id _keyMonitor;
    id _localMonitor;
    NSCursor *_previousCursor;
    void (^_handler)(NSColor *);
}

// The pixel under the cursor, sampled straight off the display.
static NSColor *wkColorUnderCursor(void)
{
    CGEventRef event = CGEventCreate(NULL);
    if (!event)
        return nil;
    CGPoint location = CGEventGetLocation(event);
    CFRelease(event);

    CGImageRef image = CGDisplayCreateImageForRect(CGMainDisplayID(), CGRectMake(location.x, location.y, 1, 1));
    if (!image)
        return nil;
    NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];
    CGImageRelease(image);
    return [bitmap colorAtX:0 y:0];
}

- (void)wkFinishWithColor:(NSColor *)color
{
    if (!_handler)
        return;   // already finished; the handler must run exactly once

    if (_mouseMonitor) { [NSEvent removeMonitor:_mouseMonitor]; _mouseMonitor = nil; }
    if (_keyMonitor) { [NSEvent removeMonitor:_keyMonitor]; _keyMonitor = nil; }
    if (_localMonitor) { [NSEvent removeMonitor:_localMonitor]; _localMonitor = nil; }
    [NSCursor unhide];
    [_previousCursor set];
    [_previousCursor release];
    _previousCursor = nil;

    void (^handler)(NSColor *) = _handler;
    _handler = nil;
    handler(color);
    [handler release];
    [self autorelease];   // balances the retain taken in -showSamplerWithSelectionHandler:
}

- (void)showSamplerWithSelectionHandler:(void (^)(NSColor *))selectionHandler
{
    if (!selectionHandler)
        return;
    if (_handler) {       // already sampling; the real API ignores a second request
        selectionHandler(nil);
        return;
    }

    _handler = [selectionHandler copy];
    [self retain];        // stay alive until the handler runs, as the real sampler does
    _previousCursor = [[NSCursor currentCursor] retain];
    [[NSCursor crosshairCursor] set];

    // Global monitors see events destined for other applications, which is the point: the user is
    // sampling anywhere on screen, usually outside this app. The local monitor covers our own windows,
    // which global monitors deliberately skip.
    _mouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSLeftMouseDownMask | NSRightMouseDownMask)
        handler:^(NSEvent *event) {
            [self wkFinishWithColor:([event type] == NSRightMouseDown) ? nil : wkColorUnderCursor()];
        }];
    _localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSLeftMouseDownMask | NSRightMouseDownMask | NSKeyDownMask)
        handler:^NSEvent *(NSEvent *event) {
            if ([event type] == NSKeyDown) {
                if ([event keyCode] != 53)   // Escape
                    return event;
                [self wkFinishWithColor:nil];
                return nil;
            }
            [self wkFinishWithColor:([event type] == NSRightMouseDown) ? nil : wkColorUnderCursor()];
            return nil;                       // swallow the click that committed the sample
        }];
    _keyMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSKeyDownMask
        handler:^(NSEvent *event) {
            if ([event keyCode] == 53)
                [self wkFinishWithColor:nil];
        }];
}

- (void)dealloc
{
    if (_mouseMonitor) [NSEvent removeMonitor:_mouseMonitor];
    if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
    if (_localMonitor) [NSEvent removeMonitor:_localMonitor];
    [_previousCursor release];
    [_handler release];
    [super dealloc];
}

@end
WK_PRIV_ALIAS(NSColorSampler);

// NSServicesRolloverButtonCell (AppKit SPI, absent on 10.9): the little rollover button WebKit draws on
// an image when ENABLE(SERVICE_CONTROLS) is on, which opens the sharing-services menu. It is an
// NSButtonCell subclass, and NSButtonCell is 10.0 API, so the inherited half — sizing (-cellSize),
// bezel style, and all the drawing WebKit does through -drawWithFrame:inView: — is the real AppKit
// implementation, not a stand-in. Only the two SPI additions need supplying:
//
//   +serviceRolloverButtonCellForStyle: is a convenience constructor; the caller immediately sets the
//   bezel style it wants (ControlFactoryMac sets NSBezelStyleRoundedDisclosure), so a plain instance is
//   what the real one hands back for WebKit's purposes.
//
//   -rectForBounds:preferredEdge: reports where the services menu should be anchored. With no system
//   sharing-menu geometry to consult on 10.9, the cell's own bounds is the honest answer: the menu is
//   anchored on the button itself.
//
// WebKit reaches this one by CLASSREF (`[NSServicesRolloverButtonCell serviceRolloverButtonCellForStyle:]`),
// and the classref binds two-level to AppKit, which is where the build SDK declares the class. That is why
// libpolyfill_classes.dylib REEXPORTS AppKit and stage-frameworks.sh repoints each WebKit binary's AppKit
// load command at it — the same capture the four other reexported frameworks already use. Without that the
// alias below is never consulted and dyld fails the whole process at load with
// "Symbol not found: _OBJC_CLASS_$_NSServicesRolloverButtonCell".
WK_PRIV_CLASS(NSServicesRolloverButtonCell) @interface NSServicesRolloverButtonCell : NSButtonCell
+ (NSServicesRolloverButtonCell *)serviceRolloverButtonCellForStyle:(NSInteger)style;
- (NSRect)rectForBounds:(NSRect)bounds preferredEdge:(NSRectEdge)preferredEdge;
@end

@implementation NSServicesRolloverButtonCell

+ (NSServicesRolloverButtonCell *)serviceRolloverButtonCellForStyle:(NSInteger)style
{
    (void)style;
    return [[[self alloc] init] autorelease];
}

- (NSRect)rectForBounds:(NSRect)bounds preferredEdge:(NSRectEdge)preferredEdge
{
    (void)preferredEdge;
    return bounds;
}

@end
WK_PRIV_ALIAS(NSServicesRolloverButtonCell);

// NSAccessibilityCustomAction (10.13+): one named, invocable action on an accessibility element, which
// -[WebAccessibilityObjectWrapper accessibilityCustomActions] builds one of per aria-actions target.
// The class is a value object — a name plus the handler block that runs the action — and that pair is
// all WebKit and its test harness construct or read.
WK_PRIV_CLASS(NSAccessibilityCustomAction) @interface NSAccessibilityCustomAction : NSObject {
    NSString *_name;
    BOOL (^_handler)(void);
    id _target;
    SEL _selector;
}
- (instancetype)initWithName:(NSString *)name handler:(BOOL (^)(void))handler;
- (instancetype)initWithName:(NSString *)name target:(id)target selector:(SEL)selector;
@property (copy) NSString *name;
@property (copy) BOOL (^handler)(void);
@property (assign) id target;
@property SEL selector;
@end

@implementation NSAccessibilityCustomAction

- (instancetype)initWithName:(NSString *)name handler:(BOOL (^)(void))handler
{
    if (!(self = [super init]))
        return nil;
    _name = [name copy];
    _handler = [handler copy];
    return self;
}

// The other way to build one: the action is performed by sending the selector to the target, and
// -handler stays nil, which is how the two forms are told apart.
- (instancetype)initWithName:(NSString *)name target:(id)target selector:(SEL)selector
{
    if (!(self = [super init]))
        return nil;
    _name = [name copy];
    _target = target;
    _selector = selector;
    return self;
}

- (void)dealloc
{
    [_name release];
    [_handler release];
    [super dealloc];
}

- (id)target { return _target; }
- (void)setTarget:(id)target { _target = target; }
- (SEL)selector { return _selector; }
- (void)setSelector:(SEL)selector { _selector = selector; }

- (NSString *)name { return _name; }

- (void)setName:(NSString *)name
{
    if (_name == name)
        return;
    [_name release];
    _name = [name copy];
}

- (BOOL (^)(void))handler { return _handler; }

- (void)setHandler:(BOOL (^)(void))handler
{
    if (_handler == handler)
        return;
    [_handler release];
    _handler = [handler copy];
}

@end
WK_PRIV_ALIAS(NSAccessibilityCustomAction);

// NSPreviewRepresentingActivityItem (13.0+): an item to share, wrapped with the title and artwork the
// modern share sheet draws above it. WebContextMenuProxyMac::createShareMenuItem wraps the page's
// image in one for the Share submenu of a right-click.
//
// 10.9's NSSharingServicePicker takes any NSPasteboardWriting and has no preview area to draw the
// title or artwork in, so forwarding the pasteboard protocol to the wrapped item gives the picker
// exactly the item upstream means to share: measured with +[NSSharingService sharingServicesForItems:],
// the wrapper and the bare item offer the same services.
@class NSItemProvider;

WK_PRIV_CLASS(NSPreviewRepresentingActivityItem) @interface NSPreviewRepresentingActivityItem : NSObject <NSPasteboardWriting> {
    id _item;
    NSString *_title;
    NSItemProvider *_imageProvider;
    NSItemProvider *_iconProvider;
}
- (instancetype)initWithItem:(id)item title:(NSString *)title image:(NSImage *)image icon:(NSImage *)icon;
- (instancetype)initWithItem:(id)item title:(NSString *)title imageProvider:(NSItemProvider *)imageProvider iconProvider:(NSItemProvider *)iconProvider;
- (instancetype)initWithItem:(id)item linkMetadata:(id)linkMetadata;
@property (readonly) id item;
@property (readonly, copy) NSString *title;
@property (readonly) NSItemProvider *imageProvider;
@property (readonly) NSItemProvider *iconProvider;
@end

// The artwork is carried as NSItemProviders, which is the shape the class vends it in; the image/icon
// initializer wraps each one under the type -[NSImage TIFFRepresentation] produces.
@interface NSItemProvider : NSObject
- (instancetype)initWithItem:(id)item typeIdentifier:(NSString *)typeIdentifier;
@end

@implementation NSPreviewRepresentingActivityItem

- (instancetype)initWithItem:(id)item title:(NSString *)title imageProvider:(NSItemProvider *)imageProvider iconProvider:(NSItemProvider *)iconProvider
{
    if (!(self = [super init]))
        return nil;
    _item = [item retain];
    _title = [title copy];
    _imageProvider = [imageProvider retain];
    _iconProvider = [iconProvider retain];
    return self;
}

- (instancetype)initWithItem:(id)item title:(NSString *)title image:(NSImage *)image icon:(NSImage *)icon
{
    NSItemProvider *imageProvider = image ? [[[NSItemProvider alloc] initWithItem:image typeIdentifier:@"public.tiff"] autorelease] : nil;
    NSItemProvider *iconProvider = icon ? [[[NSItemProvider alloc] initWithItem:icon typeIdentifier:@"public.tiff"] autorelease] : nil;
    return [self initWithItem:item title:title imageProvider:imageProvider iconProvider:iconProvider];
}

- (instancetype)initWithItem:(id)item linkMetadata:(id)linkMetadata
{
    return [self initWithItem:item
                        title:[linkMetadata respondsToSelector:@selector(title)] ? [linkMetadata title] : nil
                imageProvider:nil
                 iconProvider:nil];
}

- (void)dealloc
{
    [_item release];
    [_title release];
    [_imageProvider release];
    [_iconProvider release];
    [super dealloc];
}

- (id)item { return _item; }
- (NSString *)title { return _title; }
- (NSItemProvider *)imageProvider { return _imageProvider; }
- (NSItemProvider *)iconProvider { return _iconProvider; }

- (NSArray *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    return [_item respondsToSelector:@selector(writableTypesForPasteboard:)] ? [_item writableTypesForPasteboard:pasteboard] : [NSArray array];
}

- (id)pasteboardPropertyListForType:(NSString *)type
{
    return [_item respondsToSelector:@selector(pasteboardPropertyListForType:)] ? [_item pasteboardPropertyListForType:type] : nil;
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSString *)type pasteboard:(NSPasteboard *)pasteboard
{
    return [_item respondsToSelector:@selector(writingOptionsForType:pasteboard:)] ? [_item writingOptionsForType:type pasteboard:pasteboard] : 0;
}

@end
WK_PRIV_ALIAS(NSPreviewRepresentingActivityItem);

// Touch Bar objects retain their configuration while the hardware is unavailable.
// Private runtime names keep host applications' availability probes negative.
WK_PRIV_CLASS(NSTouchBarItem) @interface NSTouchBarItem : NSObject
@property (readonly, copy) NSString *identifier;
@property float visibilityPriority;
@property (retain) NSView *view;
@property (retain) NSViewController *viewController;
@property (copy) NSString *customizationLabel;
- (instancetype)initWithIdentifier:(NSString *)identifier;
- (BOOL)isVisible;
@end
@implementation NSTouchBarItem
- (instancetype)initWithIdentifier:(NSString *)identifier
{
    if (!(self = [super init]))
        return nil;
    _identifier = [identifier copy];
    _customizationLabel = [@"" copy];
    return self;
}
- (BOOL)isVisible { return NO; }
- (void)dealloc
{
    [_identifier release];
    [_view release];
    [_viewController release];
    [_customizationLabel release];
    [super dealloc];
}
@end
WK_PRIV_ALIAS(NSTouchBarItem);

@class NSTouchBar;
@protocol WKTouchBarDelegate <NSObject>
- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSString *)identifier;
@end
WK_PRIV_CLASS(NSTouchBar) @interface NSTouchBar : NSObject
@property (copy) NSString *customizationIdentifier;
@property (copy) NSArray *customizationAllowedItemIdentifiers;
@property (copy) NSArray *customizationRequiredItemIdentifiers;
@property (copy) NSArray *defaultItemIdentifiers;
@property (copy) NSString *principalItemIdentifier;
@property (copy) NSString *escapeKeyReplacementItemIdentifier;
@property (retain) NSTouchBarItem *escapeKeyReplacementItem;
@property (copy) NSSet *templateItems;
@property (weak) id<WKTouchBarDelegate> delegate;
- (NSTouchBarItem *)itemForIdentifier:(NSString *)identifier;
- (NSArray *)itemIdentifiers;
- (NSArray *)items;
- (BOOL)isVisible;
@end
@implementation NSTouchBar {
    NSMutableDictionary *_resolvedItems;
}
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _customizationAllowedItemIdentifiers = [@[] copy];
    _customizationRequiredItemIdentifiers = [@[] copy];
    _defaultItemIdentifiers = [@[] copy];
    _templateItems = [[NSSet alloc] init];
    _resolvedItems = [[NSMutableDictionary alloc] init];
    return self;
}
- (NSTouchBarItem *)itemForIdentifier:(NSString *)identifier
{
    if (!identifier)
        return nil;
    for (NSTouchBarItem *item in _templateItems) {
        if ([item.identifier isEqual:identifier])
            return item;
    }
    NSTouchBarItem *item = _resolvedItems[identifier];
    if (!item && [_delegate respondsToSelector:@selector(touchBar:makeItemForIdentifier:)]) {
        item = [_delegate touchBar:self makeItemForIdentifier:identifier];
        if (item)
            _resolvedItems[identifier] = item;
    }
    return item;
}
- (NSArray *)itemIdentifiers { return [[_defaultItemIdentifiers copy] autorelease]; }
- (NSArray *)items
{
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *identifier in self.itemIdentifiers) {
        NSTouchBarItem *item = [self itemForIdentifier:identifier];
        if (item)
            [items addObject:item];
    }
    return items;
}
- (BOOL)isVisible { return NO; }
- (void)dealloc
{
    [_customizationIdentifier release];
    [_customizationAllowedItemIdentifiers release];
    [_customizationRequiredItemIdentifiers release];
    [_defaultItemIdentifiers release];
    [_principalItemIdentifier release];
    [_escapeKeyReplacementItemIdentifier release];
    [_escapeKeyReplacementItem release];
    [_templateItems release];
    [_resolvedItems release];
    [super dealloc];
}
@end
WK_PRIV_ALIAS(NSTouchBar);

WK_PRIV_CLASS(NSCandidateListTouchBarItem) @interface NSCandidateListTouchBarItem : NSTouchBarItem
@property (weak) NSView *client;
@property (weak) id delegate;
@property (getter=isCollapsed) BOOL collapsed;
@property BOOL allowsCollapsing;
@property BOOL allowsTextInputContextCandidates;
@property (copy) NSAttributedString *(^attributedStringForCandidate)(id, NSInteger);
@property (readonly, copy) NSArray *candidates;
- (BOOL)isCandidateListVisible;
- (void)updateWithInsertionPointVisibility:(BOOL)visible;
- (void)setCandidates:(NSArray *)candidates forSelectedRange:(NSRange)range inString:(NSString *)string;
- (void)setCandidates:(NSArray *)candidates forSelectedRange:(NSRange)range inString:(NSString *)string rect:(NSRect)rect view:(NSView *)view completionHandler:(void (^)(id))completion;
@end
@implementation NSCandidateListTouchBarItem {
    NSString *_originalString;
    NSRange _selectedRange;
    void (^_completion)(id);
}
- (instancetype)initWithIdentifier:(NSString *)identifier
{
    if (!(self = [super initWithIdentifier:identifier]))
        return nil;
    _candidates = [@[] copy];
    _allowsCollapsing = YES;
    _allowsTextInputContextCandidates = YES;
    return self;
}
- (BOOL)isCandidateListVisible { return NO; }
- (void)updateWithInsertionPointVisibility:(BOOL)visible { (void)visible; }
- (void)setCandidates:(NSArray *)candidates forSelectedRange:(NSRange)range inString:(NSString *)string
{
    NSArray *copy = [candidates copy];
    [_candidates release];
    _candidates = copy;
    NSString *original = [string copy];
    [_originalString release];
    _originalString = original;
    _selectedRange = range;
}
- (void)setCandidates:(NSArray *)candidates forSelectedRange:(NSRange)range inString:(NSString *)string rect:(NSRect)rect view:(NSView *)view completionHandler:(void (^)(id))completion
{
    [self setCandidates:candidates forSelectedRange:range inString:string];
    self.client = view;
    void (^copy)(id) = [completion copy];
    [_completion release];
    _completion = copy;
    (void)rect;
}
- (void)dealloc
{
    [_candidates release];
    [_originalString release];
    [_completion release];
    [_attributedStringForCandidate release];
    [super dealloc];
}
@end
WK_PRIV_ALIAS(NSCandidateListTouchBarItem);

WK_PRIV_CLASS(NSCustomTouchBarItem) @interface NSCustomTouchBarItem : NSTouchBarItem @end
@implementation NSCustomTouchBarItem @end
WK_PRIV_ALIAS(NSCustomTouchBarItem);

WK_PRIV_CLASS(NSColorPickerTouchBarItem) @interface NSColorPickerTouchBarItem : NSTouchBarItem
@property (copy) NSColor *color;
@property BOOL showsAlpha;
@property (copy) NSArray *allowedColorSpaces;
@property (retain) NSColorList *colorList;
@property (weak) id target;
@property SEL action;
@property (getter=isEnabled) BOOL enabled;
@end
@implementation NSColorPickerTouchBarItem
- (instancetype)initWithIdentifier:(NSString *)identifier
{
    if (!(self = [super initWithIdentifier:identifier]))
        return nil;
    _color = [[NSColor blackColor] copy];
    _enabled = YES;
    return self;
}
+ (instancetype)colorPickerWithIdentifier:(NSString *)identifier { return [[[self alloc] initWithIdentifier:identifier] autorelease]; }
+ (instancetype)textColorPickerWithIdentifier:(NSString *)identifier { return [self colorPickerWithIdentifier:identifier]; }
+ (instancetype)strokeColorPickerWithIdentifier:(NSString *)identifier { return [self colorPickerWithIdentifier:identifier]; }
+ (instancetype)colorPickerWithIdentifier:(NSString *)identifier buttonImage:(NSImage *)image
{
    (void)image;
    return [self colorPickerWithIdentifier:identifier];
}
- (void)dealloc
{
    [_color release];
    [_allowedColorSpaces release];
    [_colorList release];
    [super dealloc];
}
@end
WK_PRIV_ALIAS(NSColorPickerTouchBarItem);

WK_PRIV_CLASS(NSGroupTouchBarItem) @interface NSGroupTouchBarItem : NSTouchBarItem
@property (retain) NSTouchBar *groupTouchBar;
@end
@implementation NSGroupTouchBarItem
- (instancetype)initWithIdentifier:(NSString *)identifier
{
    if (!(self = [super initWithIdentifier:identifier]))
        return nil;
    _groupTouchBar = [[NSTouchBar alloc] init];
    return self;
}
+ (instancetype)groupItemWithIdentifier:(NSString *)identifier items:(NSArray *)items
{
    NSGroupTouchBarItem *item = [[[self alloc] initWithIdentifier:identifier] autorelease];
    item.groupTouchBar.templateItems = [NSSet setWithArray:items];
    item.groupTouchBar.defaultItemIdentifiers = [items valueForKey:@"identifier"];
    return item;
}
- (void)dealloc { [_groupTouchBar release]; [super dealloc]; }
@end
WK_PRIV_ALIAS(NSGroupTouchBarItem);

WK_PRIV_CLASS(NSPopoverTouchBarItem) @interface NSPopoverTouchBarItem : NSTouchBarItem
@property (retain) NSTouchBar *popoverTouchBar;
@property (retain) NSView *collapsedRepresentation;
@property (retain) NSImage *collapsedRepresentationImage;
@property (copy) NSString *collapsedRepresentationLabel;
@property (retain) NSTouchBar *pressAndHoldTouchBar;
@property BOOL showsCloseButton;
@end
@implementation NSPopoverTouchBarItem
- (void)showPopover:(id)sender { (void)sender; }
- (void)dismissPopover:(id)sender { (void)sender; }
- (void)dealloc
{
    [_popoverTouchBar release];
    [_collapsedRepresentation release];
    [_collapsedRepresentationImage release];
    [_collapsedRepresentationLabel release];
    [_pressAndHoldTouchBar release];
    [super dealloc];
}
@end
WK_PRIV_ALIAS(NSPopoverTouchBarItem);

WK_PRIV_CLASS(NSTextTouchBarItemController) @interface NSTextTouchBarItemController : NSObject
@property (retain) NSViewController *textListViewController;
@property BOOL usesNarrowTextStyleItem;
@end
@implementation NSTextTouchBarItemController
- (NSColorPickerTouchBarItem *)colorPickerItem { return nil; }
- (NSSegmentedControl *)textStyle { return nil; }
- (NSSegmentedControl *)textAlignments { return nil; }
- (NSTouchBarItem *)itemForIdentifier:(NSString *)identifier { (void)identifier; return nil; }
- (void)dealloc { [_textListViewController release]; [super dealloc]; }
@end
WK_PRIV_ALIAS(NSTextTouchBarItemController);
