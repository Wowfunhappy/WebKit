// NSScrollView content insets (polyfills/methods/scrollview-inset-tile.h, wired to WebKit's -contentInsets /
// -setContentInsets: / -tile sends by polyfills/methods/AppKit.m), checked against AppKit's contract through
// the same rewritten sends WebKit makes:
//
//   1. the clip view keeps its tiled frame and a view at the leading edges moves to minus the leading insets
//      on both axes, so -documentVisibleRect includes the obscured margins and a point below the inset maps
//      to its offset from the inset;
//   2. scrolling reaches the trailing insets past the document's end, and no further;
//   3. every sibling -tile lays out (scrollers, rulers, table header, corner view) is inset on both axes;
//   4. a subclass's -tile override sees the inset siblings after [super tile], whether WebKit or AppKit sent
//      -tile, and the insets are applied once;
//   5. a scrolled view keeps its position when the insets change, and clearing them returns the range to
//      the document;
//   6. with KVO's isa-swizzle stacked on top of the dynamic subclasses the overrides terminate, apply once,
//      and a repeat set stacks no second subclass.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>

// -contentInsets / -setContentInsets: are the 10.10 API WebKit sends; the polyfill answers them here.
#pragma clang diagnostic ignored "-Wunguarded-availability"

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-76s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

@interface WKInsetsProbeDocumentView : NSView
@end
@implementation WKInsetsProbeDocumentView
- (BOOL)isFlipped { return YES; }
@end

// A scroll view subclass that lays itself out from its scrollers after [super tile], the way
// WebDynamicScrollBarsView does.
@interface WKInsetsProbeSubclassScrollView : NSScrollView
@property (nonatomic) NSRect scrollerFrameSeenAfterSuperTile;
@end
@implementation WKInsetsProbeSubclassScrollView
- (void)tile
{
    [super tile];
    self.scrollerFrameSeenAfterSuperTile = [[self verticalScroller] frame];
}
@end

// A scroll view that, from the -reflectScrolledClipView: AppKit sends inside its -tile, tiles another
// scroll view and itself, the way WebDynamicScrollBarsView's -updateScrollers re-tiles subframes and itself.
@interface WKInsetsProbeNestingScrollView : NSScrollView
@property (nonatomic, assign) NSScrollView *nestedScrollView;
@property (nonatomic) BOOL nesting;
@property (nonatomic) int nestedTiles;
@end
@implementation WKInsetsProbeNestingScrollView
- (void)reflectScrolledClipView:(NSClipView *)clipView
{
    [super reflectScrolledClipView:clipView];
    if (self.nesting || !self.nestedScrollView)
        return;
    self.nesting = YES;
    [self.nestedScrollView tile];
    ((void (*)(id, SEL))objc_msgSend)(self.nestedScrollView, sel_registerName("tile"));
    [self tile];
    self.nestedTiles++;
    self.nesting = NO;
}
@end

@interface WKInsetsProbeObserver : NSObject
@end
@implementation WKInsetsProbeObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    (void)keyPath; (void)object; (void)change; (void)context;
}
@end

static int subclassesWithPrefix(id object, const char *prefix)
{
    int count = 0;
    for (Class ancestor = object_getClass(object); ancestor; ancestor = class_getSuperclass(ancestor)) {
        if (!strncmp(class_getName(ancestor), prefix, strlen(prefix)))
            count++;
    }
    return count;
}

// -tile as AppKit sends it: by the public selector, which the polyfill's rewrite never touches.
static void appKitTile(NSScrollView *scrollView)
{
    ((void (*)(id, SEL))objc_msgSend)(scrollView, sel_registerName("tile"));
}

static NSScrollView *makeScrollView(Class scrollViewClass, NSView *documentView)
{
    NSScrollView *scrollView = [[scrollViewClass alloc] initWithFrame:NSMakeRect(0, 0, 300, 600)];
    [scrollView setScrollerStyle:NSScrollerStyleLegacy];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setDocumentView:documentView];
    return scrollView;
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];

        // 1, 2, 5 and 6 on a plain scroll view.
        WKInsetsProbeDocumentView *document = [[WKInsetsProbeDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 2000)];
        NSScrollView *scrollView = makeScrollView([NSScrollView class], document);
        [scrollView setHasHorizontalScroller:YES];
        NSClipView *clipView = [scrollView contentView];
        NSRect untiledClipFrame = [clipView frame];
        NSRect untiledVertical = [[scrollView verticalScroller] frame];
        NSRect untiledHorizontal = [[scrollView horizontalScroller] frame];

        [scrollView setContentInsets:NSEdgeInsetsMake(100, 50, 20, 30)];
        check(NSEqualRects([clipView frame], untiledClipFrame), "the clip view keeps its tiled frame");
        check(NSEqualPoints([clipView bounds].origin, NSMakePoint(-50, -100)), "a view at the leading edges moves to minus the leading insets");
        NSRect visible = [scrollView documentVisibleRect];
        check(visible.origin.x == -50 && visible.origin.y == -100 && NSEqualSizes(visible.size, untiledClipFrame.size),
            "documentVisibleRect includes the obscured margins");
        NSPoint mapped = [document convertPoint:NSMakePoint(65, 115) fromView:scrollView];
        check(mapped.x == 15 && mapped.y == 15, "a point inside the insets maps to its offset from them");
        NSEdgeInsets stored = [scrollView contentInsets];
        check(stored.top == 100 && stored.left == 50 && stored.bottom == 20 && stored.right == 30, "the getter round-trips the stored insets");

        NSRect vertical = [[scrollView verticalScroller] frame];
        check(vertical.origin.x == untiledVertical.origin.x - 30 && vertical.origin.y == untiledVertical.origin.y + 100
            && vertical.size.height == untiledVertical.size.height - 120 && vertical.size.width == untiledVertical.size.width,
            "the vertical scroller is inset from the top, bottom and right");
        NSRect horizontal = [[scrollView horizontalScroller] frame];
        check(horizontal.origin.y == untiledHorizontal.origin.y - 20 && horizontal.origin.x == untiledHorizontal.origin.x + 50
            && horizontal.size.width == untiledHorizontal.size.width - 80 && horizontal.size.height == untiledHorizontal.size.height,
            "the horizontal scroller is inset from the bottom, left and right");

        [document scrollPoint:NSMakePoint(5000, 5000)];
        NSSize clipSize = [clipView bounds].size;
        check(NSEqualPoints([clipView bounds].origin, NSMakePoint(1000 + 30 - clipSize.width, 2000 + 20 - clipSize.height)),
            "scrolling stops at the trailing insets past the document's end");
        [document scrollPoint:NSMakePoint(-500, -500)];
        check(NSEqualPoints([clipView bounds].origin, NSMakePoint(-50, -100)), "scrolling stops at the leading insets");

        [document scrollPoint:NSMakePoint(200, 300)];
        [scrollView setContentInsets:NSEdgeInsetsMake(60, 10, 0, 0)];
        check(NSEqualPoints([clipView bounds].origin, NSMakePoint(200, 300)), "a scrolled view keeps its position when the insets change");

        [document scrollPoint:NSMakePoint(-500, -500)];
        [scrollView setContentInsets:NSEdgeInsetsMake(0, 0, 0, 0)];
        check(NSEqualPoints([clipView bounds].origin, NSZeroPoint), "clearing the insets returns a view at the leading edges to the document's origin");
        [document scrollPoint:NSMakePoint(-500, -500)];
        check(NSEqualPoints([clipView bounds].origin, NSZeroPoint), "cleared insets constrain scrolling to the document");
        check(NSEqualRects([[scrollView verticalScroller] frame], untiledVertical), "cleared insets leave the scrollers where AppKit tiles them");

        WKInsetsProbeObserver *observer = [[WKInsetsProbeObserver alloc] init];
        [scrollView addObserver:observer forKeyPath:@"hidden" options:0 context:NULL];
        [clipView addObserver:observer forKeyPath:@"hidden" options:0 context:NULL];
        check(!strncmp(class_getName(object_getClass(scrollView)), "NSKVONotifying_", strlen("NSKVONotifying_"))
            && !strncmp(class_getName(object_getClass(clipView)), "NSKVONotifying_", strlen("NSKVONotifying_")),
            "KVO isa-swizzles are stacked on the inset subclasses");
        [scrollView setContentInsets:NSEdgeInsetsMake(40, 0, 0, 0)];
        appKitTile(scrollView);
        check(subclassesWithPrefix(scrollView, "WKInsetScrollView_") == 1 && subclassesWithPrefix(clipView, "WKInsetClipView_") == 1,
            "a repeat set under KVO stacks no second subclass");
        check([clipView bounds].origin.y == -40, "-tile and -constrainBoundsRect: under KVO apply the insets");
        check([[scrollView verticalScroller] frame].origin.y == untiledVertical.origin.y + 40, "AppKit's -tile under KVO insets the scroller once");
        [scrollView removeObserver:observer forKeyPath:@"hidden"];
        [clipView removeObserver:observer forKeyPath:@"hidden"];
        appKitTile(scrollView);
        check([clipView bounds].origin.y == -40, "the insets survive KVO removal");

        // 3: the table header, corner view and rulers.
        NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 600, 800)];
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"a"];
        [column setWidth:500];
        [table addTableColumn:column];
        NSScrollView *tableScrollView = makeScrollView([NSScrollView class], table);
        [tableScrollView setHasHorizontalScroller:YES];
        [tableScrollView setHasHorizontalRuler:YES];
        [tableScrollView setHasVerticalRuler:YES];
        [tableScrollView setRulersVisible:YES];
        [tableScrollView tile];
        NSView *headerClip = [[table headerView] superview];
        NSView *cornerView = [table cornerView];
        NSRect untiledHeader = [headerClip frame];
        NSRect untiledCorner = [cornerView frame];
        NSRect untiledHorizontalRuler = [[tableScrollView horizontalRulerView] frame];
        NSRect untiledVerticalRuler = [[tableScrollView verticalRulerView] frame];
        [tableScrollView setContentInsets:NSEdgeInsetsMake(25, 12, 8, 6)];
        NSRect header = [headerClip frame];
        check(header.origin.y == untiledHeader.origin.y + 25 && header.origin.x == untiledHeader.origin.x + 12
            && header.size.width == untiledHeader.size.width - 18 && header.size.height == untiledHeader.size.height,
            "the table header is inset from the top, left and right");
        NSRect corner = [cornerView frame];
        check(corner.origin.y == untiledCorner.origin.y + 25 && corner.origin.x == untiledCorner.origin.x - 6
            && NSEqualSizes(corner.size, untiledCorner.size), "the corner view is inset from the top and right");
        NSRect horizontalRuler = [[tableScrollView horizontalRulerView] frame];
        check(horizontalRuler.origin.y == untiledHorizontalRuler.origin.y + 25 && horizontalRuler.origin.x == untiledHorizontalRuler.origin.x + 12
            && horizontalRuler.size.width == untiledHorizontalRuler.size.width - 18, "the horizontal ruler is inset from the top, left and right");
        NSRect verticalRuler = [[tableScrollView verticalRulerView] frame];
        check(verticalRuler.origin.x == untiledVerticalRuler.origin.x + 12 && verticalRuler.origin.y == untiledVerticalRuler.origin.y + 25
            && verticalRuler.size.height == untiledVerticalRuler.size.height - 33, "the vertical ruler is inset from the left, top and bottom");

        // 4: a subclass's own layout after [super tile].
        WKInsetsProbeDocumentView *subclassDocument = [[WKInsetsProbeDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 300, 2000)];
        WKInsetsProbeSubclassScrollView *subclassScrollView = (WKInsetsProbeSubclassScrollView *)makeScrollView([WKInsetsProbeSubclassScrollView class], subclassDocument);
        NSRect subclassUntiled = [[subclassScrollView verticalScroller] frame];
        [subclassScrollView setContentInsets:NSEdgeInsetsMake(70, 0, 10, 0)];
        [subclassScrollView tile];
        check(subclassScrollView.scrollerFrameSeenAfterSuperTile.origin.y == subclassUntiled.origin.y + 70,
            "WebKit's -tile: the subclass sees the inset scroller after [super tile]");
        check([[subclassScrollView verticalScroller] frame].origin.y == subclassUntiled.origin.y + 70, "WebKit's -tile insets the scroller once");
        appKitTile(subclassScrollView);
        check(subclassScrollView.scrollerFrameSeenAfterSuperTile.origin.y == subclassUntiled.origin.y + 70,
            "AppKit's -tile: the subclass sees the inset scroller after [super tile]");
        check([[subclassScrollView verticalScroller] frame].origin.y == subclassUntiled.origin.y + 70, "AppKit's -tile insets the scroller once");

        // 7: tiles nested inside a tile, across scroll views and on the same one.
        WKInsetsProbeDocumentView *outerDocument = [[WKInsetsProbeDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 300, 2000)];
        WKInsetsProbeNestingScrollView *outer = (WKInsetsProbeNestingScrollView *)makeScrollView([WKInsetsProbeNestingScrollView class], outerDocument);
        WKInsetsProbeDocumentView *innerDocument = [[WKInsetsProbeDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 300, 2000)];
        NSScrollView *inner = makeScrollView([NSScrollView class], innerDocument);
        NSRect outerUntiled = [[outer verticalScroller] frame];
        NSRect innerUntiled = [[inner verticalScroller] frame];
        [inner setContentInsets:NSEdgeInsetsMake(30, 0, 0, 0)];
        [outer setContentInsets:NSEdgeInsetsMake(50, 0, 0, 0)];
        outer.nestedScrollView = inner;
        // -tile reflects the clip view, and so nests here, when it resizes it.
        [outer setAutoresizesSubviews:NO];
        [outer setFrameSize:NSMakeSize(300, 610)];
        [outer tile];
        check(outer.nestedTiles > 0, "WebKit's -tile: the probe tiled views from inside the outer tile");
        check([[outer verticalScroller] frame].origin.y == outerUntiled.origin.y + 50 && NSMaxY([[outer verticalScroller] frame]) == 610,
            "WebKit's -tile: the outer view's scroller is inset after nested tiles");
        check([[inner verticalScroller] frame].origin.y == innerUntiled.origin.y + 30, "WebKit's -tile: the nested view's scroller is inset");
        int nestedBefore = outer.nestedTiles;
        [outer setFrameSize:NSMakeSize(300, 620)];
        appKitTile(outer);
        check(outer.nestedTiles > nestedBefore, "AppKit's -tile: the probe tiled views from inside the outer tile");
        check([[outer verticalScroller] frame].origin.y == outerUntiled.origin.y + 50 && NSMaxY([[outer verticalScroller] frame]) == 620,
            "AppKit's -tile: the outer view's scroller is inset after nested tiles");
        check([[inner verticalScroller] frame].origin.y == innerUntiled.origin.y + 30, "AppKit's -tile: the nested view's scroller is inset");
    }
    if (failures) {
        fprintf(stderr, "AppKit-scrollview-insets: %d failure(s)\n", failures);
        return 1;
    }
    printf("AppKit-scrollview-insets: all checks passed\n");
    return 0;
}
