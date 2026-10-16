// -[NSControl sizeThatFits:] and -[NSTextField maximumNumberOfLines] / -setMaximumNumberOfLines:
// (polyfills/methods/AppKit.m), checked through the same rewritten sends ValidationBubbleMac makes:
//
//   1. the cap round-trips, and 0 is the default;
//   2. uncapped, sizeThatFits: is the cell's -cellSizeForBounds: at the proposed size, and wraps within the
//      proposed width;
//   3. measuring leaves the frame alone;
//   4. a 4-line cap on a longer wrapping message gives exactly the height 10.9's cell gives four lines of
//      that font, at a width no wider than the proposed width;
//   5. a cap above the message's line count changes nothing;
//   6. on five hard-broken lines, or four ending in a separator (LF, CRLF, U+2029), a 4-line cap gives the
//      4-line height; four lines, three with a trailing separator, and empty text keep their own size;
//   7. on a message mixing fonts, sizes and a CJK run, in borderless and bezeled cells, the capped size is the
//      size the cell itself gives the characters of the first N lines; each of those lines fits the proposed
//      width on its own, and the cell wraps the next unbreakable unit after each onto another line.
//
// The runner also runs it under -NSStringDrawingTypesetterBehavior 4, which every check must survive;
// argv names the behaviour the cells are expected to report.
#import <AppKit/AppKit.h>
#include <math.h>
#include <stdio.h>

// The 10.10/10.11 API ValidationBubbleMac sends; the polyfill answers it here.
#pragma clang diagnostic ignored "-Wunguarded-availability"

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-76s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

@interface NSCell (LineCapProbe)
- (NSTypesetterBehavior)_typesetterBehavior;
@end

// The character index just past each line of `cell` laid out at `bounds` with the cell's own typesetting.
static NSArray *lineEnds(NSCell *cell, NSRect bounds)
{
    NSTextStorage *storage = [[[NSTextStorage alloc] initWithAttributedString:[cell attributedStringValue]] autorelease];
    NSLayoutManager *layoutManager = [[[NSLayoutManager alloc] init] autorelease];
    [layoutManager setTypesetterBehavior:[cell _typesetterBehavior]];
    [layoutManager setUsesFontLeading:NO];
    NSTextContainer *container = [[[NSTextContainer alloc] initWithContainerSize:NSMakeSize(NSWidth([cell titleRectForBounds:bounds]), CGFLOAT_MAX)] autorelease];
    [container setLineFragmentPadding:2];
    [layoutManager addTextContainer:container];
    [storage addLayoutManager:layoutManager];
    NSRange glyphs = [layoutManager glyphRangeForTextContainer:container];
    NSMutableArray *ends = [NSMutableArray array];
    for (NSUInteger glyph = glyphs.location; glyph < NSMaxRange(glyphs);) {
        NSRange lineGlyphs;
        [layoutManager lineFragmentRectForGlyphAtIndex:glyph effectiveRange:&lineGlyphs];
        glyph = NSMaxRange(lineGlyphs);
        [ends addObject:@(NSMaxRange([layoutManager characterRangeForGlyphRange:NSMakeRange(glyphs.location, glyph - glyphs.location) actualGlyphRange:NULL]))];
    }
    return ends;
}

// Whether the line ending at `end` ends its paragraph, and where that paragraph's contents end.
static BOOL endsParagraph(NSString *string, NSUInteger end, NSUInteger *contentsEnd)
{
    NSUInteger paragraphEnd;
    [string getParagraphStart:NULL end:&paragraphEnd contentsEnd:contentsEnd forRange:NSMakeRange(end - 1, 1)];
    return paragraphEnd == end;
}

// The cell's own size for `range` of `text`, at `bounds`.
static NSSize measuredSize(NSCell *prototype, NSAttributedString *text, NSRange range, NSRect bounds)
{
    NSCell *cell = [[prototype copy] autorelease];
    [cell setAttributedStringValue:[text attributedSubstringFromRange:range]];
    return [cell cellSizeForBounds:bounds];
}

static NSUInteger trimTrailingWhitespace(NSString *string, NSUInteger start, NSUInteger end)
{
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (end > start && [whitespace characterIsMember:[string characterAtIndex:end - 1]])
        end--;
    return end;
}

static NSTextField *label(NSString *string, CGFloat fontSize)
{
    NSTextField *field = [[[NSTextField alloc] init] autorelease];
    [field setEditable:NO];
    [field setDrawsBackground:NO];
    [field setBordered:NO];
    [field setStringValue:string];
    [field setFont:[NSFont systemFontOfSize:fontSize]];
    [[field cell] setTruncatesLastVisibleLine:YES];
    return field;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSInteger behaviour = [[label(@"x", 13) cell] _typesetterBehavior];
        NSInteger expectedBehaviour = [[NSUserDefaults standardUserDefaults] objectForKey:@"NSStringDrawingTypesetterBehavior"]
            ? [[NSUserDefaults standardUserDefaults] integerForKey:@"NSStringDrawingTypesetterBehavior"] : behaviour;
        printf("  cell typesetter behaviour %ld\n", (long)behaviour);
        check(behaviour == expectedBehaviour, "the cells use the string-drawing behaviour this run asks for");
        (void)argc;
        (void)argv;
        NSString *message = @"Please fill out this field. This is a deliberately long validation message that wraps "
            "across many lines at a width of a few hundred points, and keeps going for a while longer still so "
            "that even the widest bubble needs more than four lines to show all of it. 東京都の天気は晴れ。";

        NSTextField *field = label(message, 13);
        check([field maximumNumberOfLines] == 0, "maximumNumberOfLines defaults to 0");
        [field setMaximumNumberOfLines:4];
        check([field maximumNumberOfLines] == 4, "maximumNumberOfLines round-trips");
        [field setMaximumNumberOfLines:0];

        NSRect frame = NSMakeRect(7, 9, 11, 13);
        [field setFrame:frame];
        NSSize uncapped = [field sizeThatFits:NSMakeSize(200, CGFLOAT_MAX)];
        NSSize cellSize = [[field cell] cellSizeForBounds:NSMakeRect(0, 0, 200, CGFLOAT_MAX)];
        printf("  uncapped at 200: %s, cell %s\n", NSStringFromSize(uncapped).UTF8String, NSStringFromSize(cellSize).UTF8String);
        check(NSEqualSizes(uncapped, cellSize), "uncapped sizeThatFits: is the cell's cellSizeForBounds:");
        check(uncapped.width <= 200 && uncapped.height > 4 * 17, "uncapped message wraps within 200pt");
        check(NSEqualRects([field frame], frame), "sizeThatFits: leaves the frame alone");

        for (NSNumber *fontSize in @[ @11, @13, @16 ]) {
            for (NSNumber *width in @[ @150, @200, @300 ]) {
                CGFloat w = [width doubleValue];
                NSTextField *capped = label(message, [fontSize doubleValue]);
                [capped setMaximumNumberOfLines:4];
                [capped setFrame:frame];
                NSSize size = [capped sizeThatFits:NSMakeSize(w, CGFLOAT_MAX)];
                CGFloat fourLines = [[label(@"x\nx\nx\nx", [fontSize doubleValue]) cell] cellSizeForBounds:NSMakeRect(0, 0, w, CGFLOAT_MAX)].height;
                char what[128];
                snprintf(what, sizeof what, "%2.0fpt at %3.0f: 4-line cap = 4-line height %.1f (got %s)", [fontSize doubleValue], w, fourLines, NSStringFromSize(size).UTF8String);
                check(size.height == fourLines, what);
                snprintf(what, sizeof what, "%2.0fpt at %3.0f: capped width %.1f within the proposed width", [fontSize doubleValue], w, size.width);
                check(size.width > 0 && size.width <= w, what);
                check(NSEqualRects([capped frame], frame), "capped sizeThatFits: leaves the frame alone");
            }
        }

        NSTextField *twoLines = label(@"Please fill out this field before submitting the form.", 13);
        NSSize twoLinesUncapped = [twoLines sizeThatFits:NSMakeSize(150, CGFLOAT_MAX)];
        [twoLines setMaximumNumberOfLines:4];
        NSSize twoLinesCapped = [twoLines sizeThatFits:NSMakeSize(150, CGFLOAT_MAX)];
        check(twoLinesUncapped.height > 17 && NSEqualSizes(twoLinesCapped, twoLinesUncapped), "a cap above the line count changes nothing");

        for (NSString *separator in @[ @"\n", @"\r\n", @"\u2029" ]) {
            NSArray *words = @[ @"one", @"two", @"three", @"four", @"five" ];
            NSTextField *hardBreaks = label([words componentsJoinedByString:separator], 13);
            NSSize uncappedHardBreaks = [hardBreaks sizeThatFits:NSMakeSize(300, CGFLOAT_MAX)];
            [hardBreaks setMaximumNumberOfLines:4];
            NSSize cappedHardBreaks = [hardBreaks sizeThatFits:NSMakeSize(300, CGFLOAT_MAX)];
            CGFloat fourLines = [[label([@[ @"x", @"x", @"x", @"x" ] componentsJoinedByString:separator], 13) cell] cellSizeForBounds:NSMakeRect(0, 0, 300, CGFLOAT_MAX)].height;
            char what[160];
            snprintf(what, sizeof what, "5 lines split by %s, cap 4: height %.1f = 4-line height %.1f < uncapped %.1f",
                [separator isEqualToString:@"\n"] ? "LF" : [separator isEqualToString:@"\r\n"] ? "CRLF" : "U+2029", cappedHardBreaks.height, fourLines, uncappedHardBreaks.height);
            check(cappedHardBreaks.height == fourLines && cappedHardBreaks.height < uncappedHardBreaks.height, what);

            NSArray *letters = @[ @"a", @"b", @"c", @"d" ];
            NSString *trailing = [[letters componentsJoinedByString:separator] stringByAppendingString:separator];
            NSTextField *trailingSeparator = label(trailing, 13);
            NSSize uncappedTrailing = [trailingSeparator sizeThatFits:NSMakeSize(300, CGFLOAT_MAX)];
            [trailingSeparator setMaximumNumberOfLines:4];
            NSSize cappedTrailing = [trailingSeparator sizeThatFits:NSMakeSize(300, CGFLOAT_MAX)];
            snprintf(what, sizeof what, "4 lines ending in %s, cap 4: height %.1f = 4-line height %.1f < uncapped %.1f",
                [separator isEqualToString:@"\n"] ? "LF" : [separator isEqualToString:@"\r\n"] ? "CRLF" : "U+2029", cappedTrailing.height, fourLines, uncappedTrailing.height);
            check(cappedTrailing.height == fourLines && cappedTrailing.height < uncappedTrailing.height, what);
        }
        for (NSString *string in @[ @"a\nb\nc\nd", @"a\nb\nc\n" ]) {
            NSTextField *field = label(string, 13);
            NSSize uncapped = [field sizeThatFits:NSMakeSize(300, CGFLOAT_MAX)];
            [field setMaximumNumberOfLines:4];
            NSSize cappedSize = [field sizeThatFits:NSMakeSize(300, CGFLOAT_MAX)];
            char what[160];
            snprintf(what, sizeof what, "%s, cap 4: height %.1f = uncapped %.1f", [string isEqualToString:@"a\nb\nc\nd"] ? "a LF b LF c LF d" : "a LF b LF c LF",
                cappedSize.height, uncapped.height);
            check(NSEqualSizes(cappedSize, uncapped), what);
        }
        NSTextField *empty = label(@"", 13);
        NSSize uncappedEmpty = [empty sizeThatFits:NSMakeSize(300, CGFLOAT_MAX)];
        [empty setMaximumNumberOfLines:4];
        check(NSEqualSizes([empty sizeThatFits:NSMakeSize(300, CGFLOAT_MAX)], uncappedEmpty), "empty text, cap 4: the cell's own size");

        NSString *runs[] = { @"Please fill out this field before ", @"submitting the ", @"form \u2014 the value \u201cmust\u201d include an ellipsis\u2026 and ",
            @"\u65e5\u672c\u8a9e\u306e\u30c6\u30ad\u30b9\u30c8\u3082\u542b\u3080\u3002", @" Then ", @"keep going for a while longer still, so that it wraps a lot." };
        NSString *runFonts[] = { @"LucidaGrande", @"LucidaGrande", @"Times-Roman", @"HiraKakuProN-W3", @"Helvetica", @"LucidaGrande" };
        CGFloat runSizes[] = { 13, 22, 15, 10, 18, 11 };
        NSMutableAttributedString *mixed = [[[NSMutableAttributedString alloc] init] autorelease];
        for (int i = 0; i < 6; i++)
            [mixed appendAttributedString:[[[NSAttributedString alloc] initWithString:runs[i] attributes:@{ NSFontAttributeName: [NSFont fontWithName:runFonts[i] size:runSizes[i]] }] autorelease]];
        for (int bezeled = 0; bezeled < 2; bezeled++) {
            for (NSNumber *width in @[ @150, @200, @300 ]) {
                for (NSNumber *cap in @[ @2, @4 ]) {
                    CGFloat w = [width doubleValue];
                    NSInteger lines = [cap integerValue];
                    NSTextField *field = label(@"", 13);
                    [field setBezeled:bezeled];
                    [field setAttributedStringValue:mixed];
                    [field setMaximumNumberOfLines:lines];
                    NSCell *cell = [field cell];
                    NSAttributedString *text = [cell attributedStringValue];
                    NSString *string = [text string];
                    NSRect bounds = NSMakeRect(0, 0, w, CGFLOAT_MAX);
                    NSArray *ends = lineEnds(cell, bounds);
                    char what[200];
                    snprintf(what, sizeof what, "%s mixed fonts at %3.0f wrap past %ld lines (%lu)", bezeled ? "bezeled" : "borderless", w, (long)lines, (unsigned long)[ends count]);
                    check([ends count] > (NSUInteger)lines, what);
                    if ([ends count] <= (NSUInteger)lines)
                        continue;

                    NSUInteger prefixEnd = [ends[lines - 1] unsignedIntegerValue];
                    NSUInteger contentsEnd;
                    if (endsParagraph(string, prefixEnd, &contentsEnd))
                        prefixEnd = contentsEnd;
                    NSSize size = [field sizeThatFits:bounds.size];
                    NSSize expected = measuredSize(cell, text, NSMakeRange(0, prefixEnd), bounds);
                    NSSize whole = [cell cellSizeForBounds:bounds];
                    snprintf(what, sizeof what, "%s mixed fonts at %3.0f, cap %ld: %s = first lines' cell size %s (whole %s)", bezeled ? "bezeled" : "borderless",
                        w, (long)lines, NSStringFromSize(size).UTF8String, NSStringFromSize(expected).UTF8String, NSStringFromSize(whole).UTF8String);
                    check(NSEqualSizes(size, expected) && size.height < whole.height && size.width <= whole.width, what);

                    // Each of the first lines fits the proposed width on its own, and the cell itself moves the next
                    // unbreakable unit after it onto another line, or that unit would not fit beside it.
                    BOOL linesFit = YES;
                    BOOL nextUnitWraps = YES;
                    NSUInteger start = 0;
                    for (NSInteger line = 0; line < lines; line++) {
                        NSUInteger end = [ends[line] unsignedIntegerValue];
                        NSUInteger nextEnd = [ends[line + 1] unsignedIntegerValue];
                        CGFloat lineWidth = measuredSize(cell, text, NSMakeRange(start, trimTrailingWhitespace(string, start, end) - start), NSMakeRect(0, 0, 100000, CGFLOAT_MAX)).width;
                        if (lineWidth > w) {
                            linesFit = NO;
                            printf("    line %ld is %.1f wide\n", (long)line + 1, lineWidth);
                        }
                        NSUInteger ignored;
                        if (!endsParagraph(string, end, &ignored)) {
                            NSUInteger nextUnit = nextEnd;
                            for (NSUInteger index = end + 1; index < nextEnd; index++) {
                                if ([text lineBreakBeforeIndex:index withinRange:NSMakeRange(end + 1, index - end)] == index) {
                                    nextUnit = index;
                                    break;
                                }
                            }
                            CGFloat withNextWidth = measuredSize(cell, text, NSMakeRange(start, trimTrailingWhitespace(string, start, nextUnit) - start), NSMakeRect(0, 0, 100000, CGFLOAT_MAX)).width;
                            if (withNextWidth <= w && measuredSize(cell, text, NSMakeRange(0, nextUnit), bounds).height <= measuredSize(cell, text, NSMakeRange(0, end), bounds).height) {
                                nextUnitWraps = NO;
                                printf("    the unit after line %ld stays on it\n", (long)line + 1);
                            }
                        }
                        start = end;
                    }
                    snprintf(what, sizeof what, "%s mixed fonts at %3.0f, cap %ld: each line alone fits the proposed width", bezeled ? "bezeled" : "borderless", w, (long)lines);
                    check(linesFit, what);
                    snprintf(what, sizeof what, "%s mixed fonts at %3.0f, cap %ld: the cell wraps the next unit after each line", bezeled ? "bezeled" : "borderless", w, (long)lines);
                    check(nextUnitWraps, what);
                }
            }
        }
    }
    return failures ? 1 : 0;
}
