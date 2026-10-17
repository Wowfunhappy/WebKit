// Native CALayer hierarchy semantics and capability detection remain intact with methods/QuartzCore.m loaded:
// sublayer insertion, replacement, reparenting (including through KVC) and removal behave natively, and
// CALayer answers no -usesWebKitBehavior/-setUsesWebKitBehavior:.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@interface CALayer (WKHierarchy)
@property BOOL usesWebKitBehavior;
@property BOOL sortsSublayers;
@end

static unsigned failures;
#define EXPECT(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); ++failures; } } while (0)

static void configure(CALayer *layer)
{
    EXPECT(![layer respondsToSelector:@selector(setUsesWebKitBehavior:)]);
}

static CATransformLayer *scene(void)
{
    CATransformLayer *group = [CATransformLayer layer];
    configure(group);
    CALayer *front = [CALayer layer];
    configure(front);
    CALayer *back = [CALayer layer];
    configure(back);
    group.sublayers = @[front, back];
    return group;
}

static void checkHierarchy(void)
{
    CALayer *parent = [CALayer layer];
    configure(parent);
    CATransformLayer *a = scene(), *b = scene(), *c = scene();
    CALayer *plain = [CALayer layer];
    [parent addSublayer:a];
    EXPECT(a.superlayer == parent);
    EXPECT([parent.sublayers isEqualToArray:@[a]]);
    [parent insertSublayer:b below:a];
    [parent insertSublayer:c above:a];
    EXPECT([parent.sublayers isEqualToArray:@[b, a, c]]);
    [parent insertSublayer:plain atIndex:1];
    EXPECT([parent.sublayers isEqualToArray:@[b, plain, a, c]]);
    [parent replaceSublayer:a with:b];
    EXPECT([parent.sublayers isEqualToArray:@[plain, b, c]]);
    EXPECT(!a.superlayer);
    parent.sublayers = @[c, b, plain];
    EXPECT([parent.sublayers isEqualToArray:@[c, b, plain]]);
    [c addSublayer:b];
    EXPECT(b.superlayer == c);
    EXPECT([parent.sublayers isEqualToArray:@[c, plain]]);
    [parent addSublayer:b];
    EXPECT(b.superlayer == parent);
    [b removeFromSuperlayer];
    EXPECT(!b.superlayer);
    parent.sortsSublayers = YES;
    EXPECT(c.superlayer == parent);
    parent.sortsSublayers = NO;
    EXPECT(c.superlayer == parent);
    parent.sublayers = nil;
    EXPECT(!c.superlayer);
    EXPECT(!parent.sublayers.count);
    @autoreleasepool {
        CATransformLayer *onlyOwnedByParent = [[CATransformLayer alloc] init];
        configure(onlyOwnedByParent);
        [parent addSublayer:onlyOwnedByParent];
        [onlyOwnedByParent release];
        [onlyOwnedByParent removeFromSuperlayer];
        EXPECT(!parent.sublayers.count);
    }
    EXPECT(![CALayer instancesRespondToSelector:NSSelectorFromString(@"usesWebKitBehavior")]);
    [parent addSublayer:a];
    CALayer *nativeParent = [CALayer layer];
    [nativeParent setValue:@[a] forKey:@"sublayers"];
    @try { EXPECT(!parent.sublayers.count); }
    @catch (NSException *e) { fprintf(stderr, "FAIL KVC reparent: %s\n", [[e description] UTF8String]); ++failures; }
}

int main(void)
{
    @autoreleasepool {
        [CATransaction setDisableActions:YES];
        checkHierarchy();
    }
    fprintf(stderr, "CALayer hierarchy: %u failures\n", failures);
    return failures ? 1 : 0;
}
