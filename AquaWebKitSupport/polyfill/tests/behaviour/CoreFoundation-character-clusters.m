// CFStringGetRangeOfCharacterClusterAtIndex: grapheme, composed-character and backward-deletion clusters
// over emoji sequences, flags, Hangul, combining marks, keycaps and scripts whose marks Backspace removes
// singly, for a CFString with a UTF-16 buffer and for an NSString subclass read in chunks.

#import <Foundation/Foundation.h>

#include <stdio.h>

typedef CF_ENUM(CFIndex, CFStringCharacterClusterType) {
    kCFStringGraphemeCluster = 1,
    kCFStringComposedCharacterCluster = 2,
    kCFStringCursorMovementCluster = 3,
    kCFStringBackwardDeletionCluster = 4
};
extern CFRange CFStringGetRangeOfCharacterClusterAtIndex(CFStringRef, CFIndex, CFStringCharacterClusterType);

@interface WKChunkedString : NSString {
    NSString *_backing;
}
- (instancetype)initWithString:(NSString *)string;
@end

@implementation WKChunkedString
- (instancetype)initWithString:(NSString *)string
{
    if ((self = [super init]))
        _backing = [string copy];
    return self;
}
- (void)dealloc
{
    [_backing release];
    [super dealloc];
}
- (NSUInteger)length { return _backing.length; }
- (unichar)characterAtIndex:(NSUInteger)index { return [_backing characterAtIndex:index]; }
- (void)getCharacters:(unichar *)buffer range:(NSRange)range { [_backing getCharacters:buffer range:range]; }
@end

static int failures;

typedef struct {
    const char *name;
    const UniChar *units;
    CFIndex length;
    const CFIndex *composed; // boundaries, 0 through length
    const CFIndex *deletion;
} Case;

static CFRange clusterAt(const CFIndex *boundaries, CFIndex index)
{
    CFIndex i = 0;
    while (boundaries[i + 1] <= index)
        ++i;
    return CFRangeMake(boundaries[i], boundaries[i + 1] - boundaries[i]);
}

static void check(const char *name, const char *variant, CFStringRef string, CFIndex length, CFStringCharacterClusterType type, const CFIndex *boundaries)
{
    for (CFIndex index = 0; index < length; ++index) {
        CFRange expected = clusterAt(boundaries, index);
        CFRange actual = CFStringGetRangeOfCharacterClusterAtIndex(string, index, type);
        if (actual.location != expected.location || actual.length != expected.length) {
            fprintf(stderr, "FAIL %s (%s, type %ld) index %ld: got %ld+%ld, expected %ld+%ld\n", name, variant, (long)type,
                (long)index, (long)actual.location, (long)actual.length, (long)expected.location, (long)expected.length);
            ++failures;
        }
    }
    CFRange past = CFStringGetRangeOfCharacterClusterAtIndex(string, length, type);
    if (past.location != kCFNotFound) {
        fprintf(stderr, "FAIL %s (%s, type %ld): index past the end gave %ld\n", name, variant, (long)type, (long)past.location);
        ++failures;
    }
}

static void run(const Case *c)
{
    CFStringRef flat = CFStringCreateWithCharactersNoCopy(NULL, c->units, c->length, kCFAllocatorNull);
    WKChunkedString *chunked = [[WKChunkedString alloc] initWithString:(NSString *)flat];
    if (!CFStringGetCharactersPtr(flat) || CFStringGetCharactersPtr((CFStringRef)chunked)) {
        fprintf(stderr, "FAIL %s: the two variants do not exercise both text paths\n", c->name);
        ++failures;
    }
    CFStringRef variants[] = { flat, (CFStringRef)chunked };
    const char *variantNames[] = { "buffer", "chunked" };
    for (int v = 0; v < 2; ++v) {
        check(c->name, variantNames[v], variants[v], c->length, kCFStringGraphemeCluster, c->composed);
        check(c->name, variantNames[v], variants[v], c->length, kCFStringComposedCharacterCluster, c->composed);
        check(c->name, variantNames[v], variants[v], c->length, kCFStringBackwardDeletionCluster, c->deletion);
    }
    [chunked release];
    CFRelease(flat);
}

#define UNITS(...) (const UniChar[]){ __VA_ARGS__ }
#define BOUNDS(...) (const CFIndex[]){ __VA_ARGS__ }
#define CASE(name, units, composed, deletion) { name, units, sizeof(units) / sizeof(UniChar), composed, deletion }

int main(void)
{
    @autoreleasepool {
        const UniChar heartBandage[] = { 0x2764, 0xFE0F, 0x200D, 0xD83E, 0xDE79 };
        const UniChar runner[] = { 0xD83C, 0xDFC3, 0xD83C, 0xDFFB, 0x200D, 0x2640, 0xFE0F };
        const UniChar family[] = { 0xD83D, 0xDC68, 0x200D, 0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDC67 };
        const UniChar twoModifiers[] = { 0xD83D, 0xDC66, 0xD83C, 0xDFFE, 0xD83C, 0xDFFB };
        const UniChar flags[] = { 0xD83C, 0xDDFA, 0xD83C, 0xDDF8, 0xD83C, 0xDDEC };
        const UniChar tagFlag[] = { 0xD83C, 0xDFF4, 0xDB40, 0xDC67, 0xDB40, 0xDC62, 0xDB40, 0xDC65, 0xDB40, 0xDC6E, 0xDB40, 0xDC67, 0xDB40, 0xDC7F };
        const UniChar marks[] = { 'a', 0x0301, 0x0302, 'b' };
        const UniChar hangul[] = { 0x1100, 0x1161, 0x11A8, 0xAC00, 0x11A8 };
        const UniChar keycaps[] = { '1', 0xFE0F, 0x20E3, '#', 0x20E3 };
        const UniChar conjunct[] = { 0x0915, 0x094D, 0x0937, 0x093F };
        const UniChar arabic[] = { 0x0628, 0x064E, 0x0651 };
        const UniChar arabicLatinMark[] = { 'x', 0x0628, 0x0301, 0x0628, 0x064E, 0x0300 };
        const UniChar thai[] = { 0x0E01, 0x0E33, 0x0E48 };
        const UniChar halfwidth[] = { 0xFF76, 0xFF9E };
        const UniChar crlf[] = { 'a', '\r', '\n', 'b' };
        const Case cases[] = {
            CASE("heart ZWJ adhesive bandage", heartBandage, BOUNDS(0, 5), BOUNDS(0, 5)),
            CASE("runner, skin tone, ZWJ, female sign", runner, BOUNDS(0, 7), BOUNDS(0, 7)),
            CASE("ZWJ family", family, BOUNDS(0, 8), BOUNDS(0, 8)),
            CASE("two skin tone modifiers", twoModifiers, BOUNDS(0, 6), BOUNDS(0, 6)),
            CASE("flag pair then a lone regional indicator", flags, BOUNDS(0, 4, 6), BOUNDS(0, 4, 6)),
            CASE("tag sequence flag", tagFlag, BOUNDS(0, 14), BOUNDS(0, 14)),
            CASE("combining marks", marks, BOUNDS(0, 3, 4), BOUNDS(0, 3, 4)),
            CASE("Hangul jamo and syllable", hangul, BOUNDS(0, 3, 5), BOUNDS(0, 3, 5)),
            CASE("keycaps", keycaps, BOUNDS(0, 3, 5), BOUNDS(0, 3, 5)),
            CASE("Devanagari conjunct", conjunct, BOUNDS(0, 4), BOUNDS(0, 1, 2, 3, 4)),
            CASE("Arabic harakat", arabic, BOUNDS(0, 3), BOUNDS(0, 1, 2, 3)),
            CASE("Arabic with non-Arabic marks", arabicLatinMark, BOUNDS(0, 1, 3, 6), BOUNDS(0, 1, 3, 4, 6)),
            CASE("Thai", thai, BOUNDS(0, 3), BOUNDS(0, 1, 2, 3)),
            CASE("halfwidth katakana voiced mark", halfwidth, BOUNDS(0, 2), BOUNDS(0, 2)),
            CASE("CR LF", crlf, BOUNDS(0, 1, 3, 4), BOUNDS(0, 1, 3, 4)),
        };
        for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); ++i)
            run(&cases[i]);

        // Longer than the chunk the chunked path reads: a family straddling a chunk edge, a run of 41
        // regional indicators whose pairing depends on text before the chunk, and one 102-unit cluster.
        enum { Prefix = 61, Indicators = 41, Marks = 101 };
        UniChar straddle[Prefix + 8 + 1];
        CFIndex straddleBounds[Prefix + 3];
        for (CFIndex i = 0; i < Prefix; ++i) {
            straddle[i] = 'a';
            straddleBounds[i] = i;
        }
        memcpy(straddle + Prefix, family, sizeof(family));
        straddle[Prefix + 8] = 'b';
        straddleBounds[Prefix] = Prefix;
        straddleBounds[Prefix + 1] = Prefix + 8;
        straddleBounds[Prefix + 2] = Prefix + 9;
        const Case straddleCase = { "family across a chunk edge", straddle, Prefix + 9, straddleBounds, straddleBounds };
        run(&straddleCase);

        UniChar indicators[Indicators * 2];
        CFIndex indicatorBounds[Indicators / 2 + 2];
        for (CFIndex i = 0; i < Indicators; ++i) {
            indicators[2 * i] = 0xD83C;
            indicators[2 * i + 1] = 0xDDE6 + i % 26;
        }
        for (CFIndex i = 0; i <= Indicators / 2; ++i)
            indicatorBounds[i] = 4 * i;
        indicatorBounds[Indicators / 2 + 1] = Indicators * 2;
        const Case indicatorCase = { "41 regional indicators", indicators, Indicators * 2, indicatorBounds, indicatorBounds };
        run(&indicatorCase);

        UniChar stacked[Marks + 1];
        stacked[0] = 'e';
        for (CFIndex i = 1; i < Marks; ++i)
            stacked[i] = 0x0301;
        stacked[Marks] = 'f';
        const Case stackedCase = { "100 stacked marks", stacked, Marks + 1, BOUNDS(0, Marks, Marks + 1), BOUNDS(0, Marks, Marks + 1) };
        run(&stackedCase);

        // Cursor-movement clusters are 10.9's: the ZWJ sequence stays in pieces.
        CFStringRef cursor = CFStringCreateWithCharacters(NULL, heartBandage, 5);
        CFRange movement = CFStringGetRangeOfCharacterClusterAtIndex(cursor, 2, kCFStringCursorMovementCluster);
        if (movement.location != 2 || movement.length != 1) {
            fprintf(stderr, "FAIL cursor movement cluster: got %ld+%ld, expected 10.9's 2+1\n", (long)movement.location, (long)movement.length);
            ++failures;
        }
        CFRelease(cursor);
    }
    if (failures)
        return 1;
    printf("character clusters: all cases match\n");
    return 0;
}
