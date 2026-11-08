// What a rewritten send reaches through an alias: the receiver's own implementation of the public selector
// as it is when the send happens, with the public selector as _cmd. A KVO-observed receiver (whose class
// the runtime replaced with a notifying subclass after the aliases were made) notifies its observer; a
// WebKit-image override's [super …] reaches the superclass exactly once; a REPLACE body under KVO still
// reaches the notifying setter; implementations exchanged or added after the first send run, through an
// alias and through a REPLACE call-through; and every way an argument or result travels survives the trip.
#include "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

typedef struct { double a, b, c; } WKAliasProbeBig;      // returned in memory
typedef struct { double a, b; } WKAliasProbeSmall;       // returned in xmm0:xmm1

// Eight bytes, but a non-trivial destructor makes the ABI return it through a hidden pointer, which no
// type encoding records.
struct WKAliasProbeHandle {
    long value;
    explicit WKAliasProbeHandle(long v) : value(v) { }
    WKAliasProbeHandle(const WKAliasProbeHandle& other) : value(other.value) { }
    ~WKAliasProbeHandle() { value = -1; }
};

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-70s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

// Registers the public selectors this probe sends; the target class never exists, so these bodies only
// make the names rewritten and aliased.
WK_POLYFILL_ADD_METHODS_ON(NSObject, "WKAliasProbeAbsentTarget")
- (void)setProbeValue:(id)value { }
- (void)noteProbeCall { }
- (WKAliasProbeBig)probeBigWithScale:(double)scale { WKAliasProbeBig big = { 0, 0, 0 }; return big; }
- (WKAliasProbeSmall)probeSmallWithScale:(double)scale { WKAliasProbeSmall small = { 0, 0 }; return small; }
- (double)probeSumOf:(double)a :(float)b :(int)c :(double)d :(long)e :(double)f :(double)g :(double)h :(double)i :(double)j :(long)k { return 0; }
- (WKAliasProbeHandle)probeHandle { return WKAliasProbeHandle(0); }
- (int)probeSwappedNumber { return 0; }
- (int)probeAddedNumber { return 0; }
@end

@interface WKAliasProbeModel : NSObject {
@public
    id _probeValue;
    const char *_lastCommand;
}
@property (nonatomic, assign) id probeValue;
@end

@implementation WKAliasProbeModel
- (id)probeValue { return _probeValue; }
- (void)setProbeValue:(id)value
{
    _lastCommand = sel_getName(_cmd);
    _probeValue = value;
}
- (WKAliasProbeBig)probeBigWithScale:(double)scale { WKAliasProbeBig big = { 1 * scale, 2 * scale, 3 * scale }; return big; }
- (WKAliasProbeSmall)probeSmallWithScale:(double)scale { WKAliasProbeSmall small = { 4 * scale, 5 * scale }; return small; }
- (double)probeSumOf:(double)a :(float)b :(int)c :(double)d :(long)e :(double)f :(double)g :(double)h :(double)i :(double)j :(long)k
{
    return a + b + c + d + e + f + g + h + i + j + k;
}
- (WKAliasProbeHandle)probeHandle { return WKAliasProbeHandle(42); }
@end

@interface WKAliasProbeBase : NSObject {
@public
    int _baseCalls;
}
- (void)noteProbeCall;
@end
@implementation WKAliasProbeBase
- (void)noteProbeCall { _baseCalls++; }
@end

@interface WKAliasProbeDerived : WKAliasProbeBase {
@public
    int _derivedCalls;
}
@end
@implementation WKAliasProbeDerived
- (void)noteProbeCall
{
    _derivedCalls++;
    [super noteProbeCall];
}
@end

@interface WKAliasProbeLeaf : WKAliasProbeDerived
@end
@implementation WKAliasProbeLeaf
@end

@interface WKAliasProbeSwap : NSObject
@end
@implementation WKAliasProbeSwap
- (int)probeSwappedNumber { return 1; }
- (int)probeSwapAlternate { return 2; }
@end

@interface WKAliasProbeAddBase : NSObject
@end
@implementation WKAliasProbeAddBase
- (int)probeAddedNumber { return 1; }
@end
@interface WKAliasProbeAddMiddle : WKAliasProbeAddBase
@end
@implementation WKAliasProbeAddMiddle
@end
@interface WKAliasProbeAddTip : WKAliasProbeAddMiddle
@end
@implementation WKAliasProbeAddTip
@end
static int addedNumber(id, SEL) { return 3; }

// A class under a REPLACE body that calls through, for an exchange after the first call.
@interface WKAliasProbeReplacedSwap : NSObject
@end
@implementation WKAliasProbeReplacedSwap
- (int)probeReplacedNumber { return 1; }
- (int)probeReplacedAlternate { return 2; }
@end

WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "WKAliasProbeReplacedSwap")
- (int)probeReplacedNumber
{
    return WK_ORIGINAL_METHOD(int, ()) + 100;
}
@end

// A class with its own setter, under a REPLACE body for that setter.
@interface WKAliasProbeReplaced : NSObject {
@public
    id _replacedValue;
    int _bodyCalls;
}
@property (nonatomic, assign) id replacedValue;
@end
@implementation WKAliasProbeReplaced
- (id)replacedValue { return _replacedValue; }
- (void)setReplacedValue:(id)value { _replacedValue = value; }
@end

WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "WKAliasProbeReplaced")
- (void)setReplacedValue:(id)value
{
    ((WKAliasProbeReplaced *)self)->_bodyCalls++;
    WK_ORIGINAL_METHOD(void, (id), value);
}
@end

@interface WKAliasProbeObserver : NSObject {
@public
    int _notifications;
}
@end
@implementation WKAliasProbeObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    _notifications++;
}
@end

int main(void)
{
    @autoreleasepool {
        printf("wk_selref_alias_dispatch: what rewritten sends reach through aliases\n");

        WKAliasProbeModel *model = [[WKAliasProbeModel alloc] init];
        WKAliasProbeObserver *observer = [[WKAliasProbeObserver alloc] init];
        [model setProbeValue:@"plain"];
        check(model->_lastCommand && !strcmp(model->_lastCommand, "setProbeValue:"), "the implementation sees the public selector as _cmd");

        [model addObserver:observer forKeyPath:@"probeValue" options:0 context:NULL];
        check(strncmp(object_getClassName(model), "NSKVONotifying_", 15) == 0, "test premise: the observed receiver's class was replaced by KVO");
        [model setProbeValue:@"observed"];
        check(observer->_notifications == 1, "a rewritten setter send to a KVO-observed receiver notifies");
        check(model.probeValue && [model.probeValue isEqual:@"observed"], "and the value is set");
        [model removeObserver:observer forKeyPath:@"probeValue"];

        WKAliasProbeDerived *derived = [[WKAliasProbeDerived alloc] init];
        [derived noteProbeCall];
        check(derived->_derivedCalls == 1 && derived->_baseCalls == 1, "an override's [super …] reaches the superclass exactly once");
        WKAliasProbeLeaf *leaf = [[WKAliasProbeLeaf alloc] init];
        [leaf noteProbeCall];
        check(leaf->_derivedCalls == 1 && leaf->_baseCalls == 1, "an inherited override's [super …] reaches the superclass exactly once");

        WKAliasProbeReplaced *replaced = [[WKAliasProbeReplaced alloc] init];
        WKAliasProbeObserver *replacedObserver = [[WKAliasProbeObserver alloc] init];
        [replaced addObserver:replacedObserver forKeyPath:@"replacedValue" options:0 context:NULL];
        [replaced setReplacedValue:@"replaced"];
        check(replaced->_bodyCalls == 1 && replacedObserver->_notifications == 1, "a REPLACE body on a KVO-observed receiver reaches the notifying setter");
        [replaced removeObserver:replacedObserver forKeyPath:@"replacedValue"];

        WKAliasProbeBig big = [model probeBigWithScale:2];
        check(big.a == 2 && big.b == 4 && big.c == 6, "a structure returned in memory comes back whole");
        WKAliasProbeSmall small = [model probeSmallWithScale:3];
        check(small.a == 12 && small.b == 15, "a structure returned in registers comes back whole");
        double sum = [model probeSumOf:1 :2 :3 :4 :5 :6 :7 :8 :9 :10 :11];
        check(sum == 66, "integer, vector and stack arguments arrive unchanged");
        WKAliasProbeHandle handle = [model probeHandle];
        check(handle.value == 42, "a small C++ object returned through a hidden pointer comes back whole");

        // The public selectors by name: this image's own @selector() references are rewritten too.
        WKAliasProbeSwap *swap = [[WKAliasProbeSwap alloc] init];
        int beforeSwap = [swap probeSwappedNumber];
        method_exchangeImplementations(class_getInstanceMethod([WKAliasProbeSwap class], sel_registerName("probeSwappedNumber")),
                                       class_getInstanceMethod([WKAliasProbeSwap class], @selector(probeSwapAlternate)));
        check(beforeSwap == 1 && [swap probeSwappedNumber] == 2, "an implementation exchanged after the first send runs");

        WKAliasProbeAddTip *tip = [[WKAliasProbeAddTip alloc] init];
        int beforeAdd = [tip probeAddedNumber];
        class_addMethod([WKAliasProbeAddMiddle class], sel_registerName("probeAddedNumber"), (IMP)addedNumber, "i@:");
        check(beforeAdd == 1 && [tip probeAddedNumber] == 3, "an override added to an intermediate class after the first send runs");

        WKAliasProbeReplacedSwap *replacedSwap = [[WKAliasProbeReplacedSwap alloc] init];
        int beforeReplacedSwap = [replacedSwap probeReplacedNumber];
        method_exchangeImplementations(class_getInstanceMethod([WKAliasProbeReplacedSwap class], sel_registerName("probeReplacedNumber")),
                                       class_getInstanceMethod([WKAliasProbeReplacedSwap class], @selector(probeReplacedAlternate)));
        check(beforeReplacedSwap == 101 && [replacedSwap probeReplacedNumber] == 102,
              "a REPLACE call-through reaches an implementation exchanged after the first call");
    }
    if (failures) {
        printf("wk_selref_alias_dispatch: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("wk_selref_alias_dispatch: all checks passed\n");
    return 0;
}
