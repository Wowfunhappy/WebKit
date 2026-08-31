// The contentInsets application mechanism (polyfills/scrollview-inset-tile.h, wired to WebKit's
// -contentInsets / -setContentInsets: sends by polyfills/methods/AppKit.m): wkScrollViewSetContentInsets re-classes the
// scroll view into a dynamic subclass whose -tile lays the stored insets out. This probe compiles that
// same single definition and is the KVO-coexistence guarantee for the override:
//
//   1. a non-zero set insets the clip view once (and the getter round-trips the stored value);
//   2. with KVO's isa-swizzle stacked ON TOP of the dynamic subclass, -tile still terminates and still
//      applies the insets exactly once — the override's super-dispatch is anchored at the class that
//      defines it, where an object_getClass(self)-derived super send resolves to the KVO-stacked class
//      itself and recurses without bound;
//   3. a repeat non-zero set with KVO stacked leaves the ancestry with exactly one inset subclass (the
//      concrete class name no longer carries the marker prefix, so a name check alone re-classes again
//      and doubles the padding).
#import "scrollview-inset-tile.h"

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

@interface WKInsetsProbeObserver : NSObject
@end
@implementation WKInsetsProbeObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    (void)keyPath; (void)object; (void)change; (void)context;
}
@end

static int insetSubclassesInAncestry(id object)
{
    int count = 0;
    for (Class ancestor = object_getClass(object); ancestor; ancestor = class_getSuperclass(ancestor)) {
        if (strncmp(class_getName(ancestor), wkInsetTileClassPrefix, sizeof(wkInsetTileClassPrefix) - 1) == 0)
            count++;
    }
    return count;
}

int main(void)
{
    @autoreleasepool {
        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
        [scrollView setDocumentView:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 400)]];

        wkScrollViewSetContentInsets(scrollView, NSEdgeInsetsMake(4, 0, 4, 0));
        NSRect clip = [[scrollView contentView] frame];
        check(insetSubclassesInAncestry(scrollView) == 1, "non-zero set installs the inset subclass");
        check(clip.size.height == 92 && clip.origin.y == 4, "insets (4,0,4,0) applied once by -tile");
        NSEdgeInsets stored = wkScrollViewContentInsets(scrollView);
        check(stored.top == 4 && stored.bottom == 4 && stored.left == 0 && stored.right == 0,
              "getter round-trips the stored insets");

        // KVO stacks its NSKVONotifying_ subclass on top of the inset subclass.
        WKInsetsProbeObserver *observer = [[WKInsetsProbeObserver alloc] init];
        [scrollView addObserver:observer forKeyPath:@"hidden" options:0 context:NULL];
        check(strncmp(class_getName(object_getClass(scrollView)), "NSKVONotifying_", strlen("NSKVONotifying_")) == 0,
              "KVO isa-swizzle is stacked on the inset subclass");

        [scrollView tile];
        clip = [[scrollView contentView] frame];
        check(clip.size.height == 92 && clip.origin.y == 4, "-tile under KVO terminates, insets applied once");

        wkScrollViewSetContentInsets(scrollView, NSEdgeInsetsMake(6, 0, 6, 0));
        clip = [[scrollView contentView] frame];
        check(insetSubclassesInAncestry(scrollView) == 1, "repeat set under KVO stacks no second subclass");
        check(clip.size.height == 88 && clip.origin.y == 6, "updated insets (6,0,6,0) applied once");

        [scrollView removeObserver:observer forKeyPath:@"hidden"];
        [scrollView tile];
        clip = [[scrollView contentView] frame];
        check(clip.size.height == 88 && clip.origin.y == 6, "insets survive KVO removal");
    }
    if (failures) {
        fprintf(stderr, "AppKit-scrollview-insets: %d failure(s)\n", failures);
        return 1;
    }
    printf("AppKit-scrollview-insets: all checks passed\n");
    return 0;
}
