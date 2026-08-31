// Foundation: stubs of the Foundation classes 10.9 does not have.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

// NSPresentationIntent (Foundation, 12.0+): the semantic-structure metadata an attributed string
// carries alongside its visual attributes (this block is a quote / a header of level N / table cell
// (r,c) ...). It is a pure immutable data holder — Foundation attaches no behavior to it — so the
// class is reimplementable in full. WebKit's uses: HTMLConverter builds a blockquote intent chain
// (+blockQuoteIntentWithIdentity:nestedInsideIntent:, -parentIntent) and stores it under
// NSPresentationIntentAttributeName (see c/Foundation.m); WebKit IPC (CoreIPCPresentationIntent) reads
// every property below and rebuilds the intent on the other side through the same factory methods.
// The kind values mirror the modern SDK's NSPresentationIntentKind declaration order (this file
// compiles against the 10.9 headers, which lack the enum).
typedef NS_ENUM(NSInteger, WKPolyfillNSPresentationIntentKind) {
    WKPolyfillNSPresentationIntentKindParagraph,
    WKPolyfillNSPresentationIntentKindHeader,
    WKPolyfillNSPresentationIntentKindOrderedList,
    WKPolyfillNSPresentationIntentKindUnorderedList,
    WKPolyfillNSPresentationIntentKindListItem,
    WKPolyfillNSPresentationIntentKindCodeBlock,
    WKPolyfillNSPresentationIntentKindBlockQuote,
    WKPolyfillNSPresentationIntentKindThematicBreak,
    WKPolyfillNSPresentationIntentKindTable,
    WKPolyfillNSPresentationIntentKindTableHeaderRow,
    WKPolyfillNSPresentationIntentKindTableRow,
    WKPolyfillNSPresentationIntentKindTableCell,
};
WK_PRIV_CLASS(NSPresentationIntent) @interface NSPresentationIntent : NSObject <NSCopying, NSSecureCoding> {
    NSInteger _intentKind;
    NSInteger _identity;
    NSPresentationIntent *_parentIntent;
    NSInteger _headerLevel;
    NSInteger _ordinal;
    NSString *_languageHint;
    NSArray *_columnAlignments;
    NSInteger _columnCount;
    NSInteger _row;
    NSInteger _column;
}
@property (readonly) NSInteger intentKind;
@property (readonly) NSInteger identity;
@property (readonly, retain) NSPresentationIntent *parentIntent;
@property (readonly) NSInteger headerLevel;
@property (readonly) NSInteger ordinal;
@property (readonly, copy) NSString *languageHint;
@property (readonly, copy) NSArray *columnAlignments;
@property (readonly) NSInteger columnCount;
@property (readonly) NSInteger row;
@property (readonly) NSInteger column;
@end
@implementation NSPresentationIntent
@synthesize intentKind = _intentKind;
@synthesize identity = _identity;
@synthesize parentIntent = _parentIntent;
@synthesize headerLevel = _headerLevel;
@synthesize ordinal = _ordinal;
@synthesize languageHint = _languageHint;
@synthesize columnAlignments = _columnAlignments;
@synthesize columnCount = _columnCount;
@synthesize row = _row;
@synthesize column = _column;
- (instancetype)_initWithKind:(NSInteger)kind identity:(NSInteger)identity parent:(NSPresentationIntent *)parent
{
    if ((self = [super init])) {
        _intentKind = kind;
        _identity = identity;
        _parentIntent = [parent retain];
    }
    return self;
}
- (void)dealloc
{
    [_parentIntent release];
    [_languageHint release];
    [_columnAlignments release];
    [super dealloc];
}
+ (NSPresentationIntent *)paragraphIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindParagraph identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)headerIntentWithIdentity:(NSInteger)identity level:(NSInteger)level nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindHeader identity:identity parent:parent] autorelease];
    intent->_headerLevel = level;
    return intent;
}
+ (NSPresentationIntent *)codeBlockIntentWithIdentity:(NSInteger)identity languageHint:(NSString *)languageHint nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindCodeBlock identity:identity parent:parent] autorelease];
    intent->_languageHint = [languageHint copy];
    return intent;
}
+ (NSPresentationIntent *)thematicBreakIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindThematicBreak identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)orderedListIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindOrderedList identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)unorderedListIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindUnorderedList identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)listItemIntentWithIdentity:(NSInteger)identity ordinal:(NSInteger)ordinal nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindListItem identity:identity parent:parent] autorelease];
    intent->_ordinal = ordinal;
    return intent;
}
+ (NSPresentationIntent *)blockQuoteIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindBlockQuote identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)tableIntentWithIdentity:(NSInteger)identity columnCount:(NSInteger)columnCount alignments:(NSArray *)alignments nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindTable identity:identity parent:parent] autorelease];
    intent->_columnCount = columnCount;
    intent->_columnAlignments = [alignments copy];
    return intent;
}
+ (NSPresentationIntent *)tableHeaderRowIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindTableHeaderRow identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)tableRowIntentWithIdentity:(NSInteger)identity row:(NSInteger)row nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindTableRow identity:identity parent:parent] autorelease];
    intent->_row = row;
    return intent;
}
+ (NSPresentationIntent *)tableCellIntentWithIdentity:(NSInteger)identity column:(NSInteger)column nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindTableCell identity:identity parent:parent] autorelease];
    intent->_column = column;
    return intent;
}
- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    return [self retain]; // Immutable.
}
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_intentKind forKey:@"intentKind"];
    [coder encodeInteger:_identity forKey:@"identity"];
    [coder encodeObject:_parentIntent forKey:@"parentIntent"];
    [coder encodeInteger:_headerLevel forKey:@"headerLevel"];
    [coder encodeInteger:_ordinal forKey:@"ordinal"];
    [coder encodeObject:_languageHint forKey:@"languageHint"];
    [coder encodeObject:_columnAlignments forKey:@"columnAlignments"];
    [coder encodeInteger:_columnCount forKey:@"columnCount"];
    [coder encodeInteger:_row forKey:@"row"];
    [coder encodeInteger:_column forKey:@"column"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _intentKind = [coder decodeIntegerForKey:@"intentKind"];
        _identity = [coder decodeIntegerForKey:@"identity"];
        _parentIntent = [[coder decodeObjectOfClass:[NSPresentationIntent class] forKey:@"parentIntent"] retain];
        _headerLevel = [coder decodeIntegerForKey:@"headerLevel"];
        _ordinal = [coder decodeIntegerForKey:@"ordinal"];
        _languageHint = [[coder decodeObjectOfClass:[NSString class] forKey:@"languageHint"] copy];
        _columnAlignments = [[coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSNumber class], nil] forKey:@"columnAlignments"] copy];
        _columnCount = [coder decodeIntegerForKey:@"columnCount"];
        _row = [coder decodeIntegerForKey:@"row"];
        _column = [coder decodeIntegerForKey:@"column"];
    }
    return self;
}
// requireIdentity distinguishes -isEqual: (identity counts, recursively) from
// -isEquivalentToPresentationIntent: ("the same as equality except that identity is not taken
// into account"); the parent chain is compared under the same rule as the receiver.
static BOOL wkPresentationIntentsEqual(NSPresentationIntent *a, NSPresentationIntent *b, BOOL requireIdentity)
{
    if (a == b)
        return YES;
    if (!a || !b)
        return NO;
    if (requireIdentity && a->_identity != b->_identity)
        return NO;
    return a->_intentKind == b->_intentKind
        && a->_headerLevel == b->_headerLevel
        && a->_ordinal == b->_ordinal
        && (a->_languageHint == b->_languageHint || [a->_languageHint isEqualToString:b->_languageHint])
        && (a->_columnAlignments == b->_columnAlignments || [a->_columnAlignments isEqualToArray:b->_columnAlignments])
        && a->_columnCount == b->_columnCount
        && a->_row == b->_row
        && a->_column == b->_column
        && wkPresentationIntentsEqual(a->_parentIntent, b->_parentIntent, requireIdentity);
}
- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSPresentationIntent class]])
        return NO;
    return wkPresentationIntentsEqual(self, other, YES);
}
- (BOOL)isEquivalentToPresentationIntent:(NSPresentationIntent *)other
{
    if (![other isKindOfClass:[NSPresentationIntent class]])
        return NO;
    return wkPresentationIntentsEqual(self, other, NO);
}
// "Each nested list increases the indentation level by one; all elements within the same list
// have the same indentation level. Text outside list intents has an indentation level of 0."
- (NSInteger)indentationLevel
{
    NSInteger level = 0;
    for (NSPresentationIntent *intent = self; intent; intent = intent->_parentIntent) {
        if (intent->_intentKind == WKPolyfillNSPresentationIntentKindOrderedList
            || intent->_intentKind == WKPolyfillNSPresentationIntentKindUnorderedList)
            level++;
    }
    return level;
}
- (NSUInteger)hash
{
    return (NSUInteger)_intentKind ^ ((NSUInteger)_identity << 4);
}
@end
WK_PRIV_ALIAS(NSPresentationIntent);

// The store these two take is a persistent one. 10.9 has neither an HSTS store nor an alternative-service
// store to persist into, so the initializer accepts the URL and keeps nothing: the object is a working
// store that is simply always empty, which is what "no HSTS state" and "no alternative services known"
// mean. Nothing is dropped silently -- there is no state to drop.
WK_PRIV_CLASS(_NSHSTSStorage) @interface _NSHSTSStorage : NSObject
- (instancetype)initPersistentStoreWithURL:(NSURL *)url;
@end
@implementation _NSHSTSStorage
- (instancetype)initPersistentStoreWithURL:(NSURL *)url { (void)url; return [self init]; }
@end
WK_PRIV_ALIAS(_NSHSTSStorage);
WK_PRIV_CLASS(_NSHTTPAlternativeServicesFilter) @interface _NSHTTPAlternativeServicesFilter : NSObject @end
@implementation _NSHTTPAlternativeServicesFilter @end
WK_PRIV_ALIAS(_NSHTTPAlternativeServicesFilter);
WK_PRIV_CLASS(_NSHTTPAlternativeServicesStorage) @interface _NSHTTPAlternativeServicesStorage : NSObject
- (instancetype)initPersistentStoreWithURL:(NSURL *)url;
- (void)setCanSuspendLocked:(BOOL)canSuspendLocked;
@end
@implementation _NSHTTPAlternativeServicesStorage
- (instancetype)initPersistentStoreWithURL:(NSURL *)url { (void)url; return [self init]; }
- (void)setCanSuspendLocked:(BOOL)canSuspendLocked { (void)canSuspendLocked; }
@end
WK_PRIV_ALIAS(_NSHTTPAlternativeServicesStorage);

// NSDateComponentsFormatter formats a quantity of time in words -- "2 minutes, 5 seconds". WebCore
// builds the media controls' accessibility description of a track's duration with it
// (RenderThemeCocoa::mediaControlsFormattedStringForDuration): units style Full, allowed units
// hour/minute/second, standalone formatting context, at most two units. VoiceOver reads the result
// out, so the spelled-out localized wording IS the string's purpose.
//
// The unit names, their plural forms and the separator between them are CLDR data, and 10.9's ICU
// (51.1, /usr/lib/libicucore.A.dylib) carries all of it. Each locale bundle's "units" and
// "unitsShort" tables hold "{0} hour" / "{0} hours" keyed by that locale's own plural categories --
// ru has one/few/many/other, ja has only other -- and ICU's MessageFormat picks the category for a
// value under the locale's plural rules and formats the number in the locale's digits. So the words
// in the output are the system's own, in the user's language; none of them are written here.
//
// MAVERICKS divergence, the separator: CLDR's "unit" list style, which is what joins the units on
// 10.10+, postdates ICU 51 -- the only list style in this data is "standard", whose two-item pattern
// is "{0} and {1}". The standard style's non-final ("middle") pattern is what the unit style uses in
// nearly every locale ("{0}, {1}" for en/es/he, "{0}، {1}" for ar, "{0}、{1}" for ja), so the units
// are joined with that and English reads "1 hour, 2 minutes".
//
// maximumUnitCount truncates rather than rounds, which is what 10.10+ documents: "1h 10m 30s,
// maximumUnitCount set to 2: '1h 10m'". A zero-valued unit is dropped, the zero-formatting default
// for a style other than positional; an interval that leaves nothing to show formats as zero of the
// smallest allowed unit ("0 seconds"). formattingContext is stored and does not reach the output,
// which is what the property does on 10.10+ too -- Apple's header marks it "Not yet supported".
typedef NS_ENUM(NSInteger, NSDateComponentsFormatterUnitsStyle) {
    NSDateComponentsFormatterUnitsStylePositional = 0,   // "1:10"
    NSDateComponentsFormatterUnitsStyleAbbreviated = 1,  // "1h 10m"
    NSDateComponentsFormatterUnitsStyleShort = 2,        // "1 hr, 10 min"
    NSDateComponentsFormatterUnitsStyleFull = 3,         // "1 hour, 10 minutes"
    NSDateComponentsFormatterUnitsStyleSpellOut = 4,     // "One hour, ten minutes"
    NSDateComponentsFormatterUnitsStyleBrief = 5,        // "1hr 10min"
};
typedef NSInteger NSFormattingContext;

// ICU's C resource-bundle and message-format entry points. libicucore is built with symbol renaming
// disabled, so these bare names are its real exports, and 10.9 ships no <unicode/*.h> for them --
// hence the declarations here. build-polyfill.sh links this dylib against libicucore.
typedef int32_t WKICUErrorCode;    // UErrorCode; > 0 is a failure, < 0 a warning
typedef uint16_t WKICUChar;        // UChar
typedef struct UResourceBundle UResourceBundle;
extern UResourceBundle *ures_open(const char *packageName, const char *locale, WKICUErrorCode *status);
extern UResourceBundle *ures_getByKeyWithFallback(const UResourceBundle *bundle, const char *keyPath, UResourceBundle *fillIn, WKICUErrorCode *status);
extern UResourceBundle *ures_getByIndex(const UResourceBundle *bundle, int32_t index, UResourceBundle *fillIn, WKICUErrorCode *status);
extern const WKICUChar *ures_getString(const UResourceBundle *bundle, int32_t *length, WKICUErrorCode *status);
extern int32_t ures_getSize(const UResourceBundle *bundle);
extern const char *ures_getKey(const UResourceBundle *bundle);
extern void ures_close(UResourceBundle *bundle);
extern int32_t u_formatMessage(const char *locale, const WKICUChar *pattern, int32_t patternLength, WKICUChar *result, int32_t resultLength, WKICUErrorCode *status, ...);

// The units a plain time interval decomposes into, largest first, each with the key CLDR stores it
// under. These are the fixed-length ones; a month and a year are as long as the calendar says, so a
// caller that allows them gets the units below that instead.
static const struct { NSUInteger calendarUnit; const char *dataKey; } wkDurationUnits[] = {
    { NSCalendarUnitDay,    "day"    },
    { NSCalendarUnitHour,   "hour"   },
    { NSCalendarUnitMinute, "minute" },
    { NSCalendarUnitSecond, "second" },
};
#define WK_DURATION_UNIT_COUNT ((NSInteger)(sizeof(wkDurationUnits) / sizeof(wkDurationUnits[0])))

static NSInteger wkDurationComponentValue(NSDateComponents *components, NSUInteger calendarUnit)
{
    switch (calendarUnit) {
    case NSCalendarUnitDay:    return components.day;
    case NSCalendarUnitHour:   return components.hour;
    case NSCalendarUnitMinute: return components.minute;
    default:                   return components.second;
    }
}

// A CLDR unit pattern ("{0} hours") as a MessageFormat plural submessage: the placeholder becomes the
// plural argument's own number placeholder, and each character MessageFormat reads as syntax is
// quoted so a locale's literal text arrives intact.
static void wkAppendPluralSubmessage(NSMutableString *out, NSString *pattern)
{
    NSUInteger length = pattern.length;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [pattern characterAtIndex:i];
        if (c == '{' && i + 2 < length && [pattern characterAtIndex:i + 1] == '0' && [pattern characterAtIndex:i + 2] == '}') {
            [out appendString:@"#"];
            i += 2;
        } else if (c == '\'')
            [out appendString:@"''"];
        else if (c == '{' || c == '}' || c == '#')
            [out appendFormat:@"'%C'", c];
        else
            [out appendFormat:@"%C", c];
    }
}

// "{0} hour" / "{0} hours" / ... for one unit, as the locale's plural rules apply them to value.
static NSString *wkSpelledOutUnit(const char *table, const char *unitKey, NSInteger value, const char *localeID)
{
    WKICUErrorCode status = 0;
    UResourceBundle *localeBundle = ures_open(NULL, localeID, &status);
    UResourceBundle *unitTable = NULL;
    NSString *result = nil;
    if (status <= 0 && localeBundle) {
        char keyPath[64];
        snprintf(keyPath, sizeof(keyPath), "%s/%s", table, unitKey);
        unitTable = ures_getByKeyWithFallback(localeBundle, keyPath, NULL, &status);
    }
    if (status <= 0 && unitTable) {
        NSMutableString *pattern = [NSMutableString stringWithString:@"{0,plural,"];
        int32_t categories = ures_getSize(unitTable);
        for (int32_t i = 0; i < categories; i++) {
            WKICUErrorCode itemStatus = 0;
            UResourceBundle *item = ures_getByIndex(unitTable, i, NULL, &itemStatus);
            int32_t textLength = 0;
            const WKICUChar *text = (item && itemStatus <= 0) ? ures_getString(item, &textLength, &itemStatus) : NULL;
            const char *category = item ? ures_getKey(item) : NULL;
            if (text && category && itemStatus <= 0) {
                [pattern appendFormat:@"%s{", category];
                wkAppendPluralSubmessage(pattern, [NSString stringWithCharacters:(const unichar *)text length:(NSUInteger)textLength]);
                [pattern appendString:@"}"];
            }
            ures_close(item);
        }
        [pattern appendString:@"}"];

        unichar patternBuffer[512];
        WKICUChar formatted[512];
        NSUInteger patternLength = pattern.length;
        if (patternLength && patternLength <= sizeof(patternBuffer) / sizeof(patternBuffer[0])) {
            [pattern getCharacters:patternBuffer range:NSMakeRange(0, patternLength)];
            WKICUErrorCode formatStatus = 0;
            int32_t formattedLength = u_formatMessage(localeID, (const WKICUChar *)patternBuffer, (int32_t)patternLength,
                formatted, (int32_t)(sizeof(formatted) / sizeof(formatted[0])), &formatStatus, (double)value);
            if (formatStatus <= 0 && formattedLength > 0 && formattedLength <= (int32_t)(sizeof(formatted) / sizeof(formatted[0])))
                result = [NSString stringWithCharacters:(const unichar *)formatted length:(NSUInteger)formattedLength];
        }
    }
    ures_close(unitTable);
    ures_close(localeBundle);
    return result;
}

// The locale's pattern for a list item that is not the last one -- "{0}, {1}" in English.
static NSString *wkDurationListPattern(const char *localeID)
{
    WKICUErrorCode status = 0;
    UResourceBundle *localeBundle = ures_open(NULL, localeID, &status);
    UResourceBundle *item = (status <= 0 && localeBundle) ? ures_getByKeyWithFallback(localeBundle, "listPattern/standard/middle", NULL, &status) : NULL;
    NSString *pattern = nil;
    if (status <= 0 && item) {
        int32_t textLength = 0;
        const WKICUChar *text = ures_getString(item, &textLength, &status);
        if (text && status <= 0)
            pattern = [NSString stringWithCharacters:(const unichar *)text length:(NSUInteger)textLength];
    }
    ures_close(item);
    ures_close(localeBundle);
    return pattern ?: @"{0}, {1}";
}

static NSString *wkApplyListPattern(NSString *pattern, NSString *first, NSString *second)
{
    NSMutableString *result = [NSMutableString string];
    NSUInteger length = pattern.length;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [pattern characterAtIndex:i];
        unichar placeholder = (c == '{' && i + 2 < length && [pattern characterAtIndex:i + 2] == '}') ? [pattern characterAtIndex:i + 1] : 0;
        if (placeholder == '0' || placeholder == '1') {
            [result appendString:placeholder == '0' ? first : second];
            i += 2;
        } else
            [result appendFormat:@"%C", c];
    }
    return result;
}

// The digit form, "1:02:05": the largest shown unit as it stands, each smaller one padded to two
// digits. It is what the positional style asks for, and what stands in should a locale's unit data
// be unreachable.
static NSString *wkPositionalDuration(const NSInteger *values, const NSInteger *shown, NSInteger shownCount)
{
    NSMutableString *result = [NSMutableString string];
    for (NSInteger i = 0; i < shownCount; i++)
        [result appendFormat:(i ? @":%02ld" : @"%ld"), (long)values[shown[i]]];
    return result;
}

WK_PRIV_CLASS(NSDateComponentsFormatter) @interface NSDateComponentsFormatter : NSFormatter
@property NSDateComponentsFormatterUnitsStyle unitsStyle;
@property NSUInteger allowedUnits;
@property NSInteger maximumUnitCount;
@property NSFormattingContext formattingContext;
- (NSString *)stringFromTimeInterval:(NSTimeInterval)interval;
@end
@implementation NSDateComponentsFormatter
- (NSString *)stringFromTimeInterval:(NSTimeInterval)interval
{
    if (!isfinite(interval))
        return nil;

    NSUInteger allowed = _allowedUnits ?: (NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond);
    NSInteger units[WK_DURATION_UNIT_COUNT];
    NSInteger unitCount = 0;
    NSUInteger mask = 0;
    for (NSInteger i = 0; i < WK_DURATION_UNIT_COUNT; i++) {
        if (allowed & wkDurationUnits[i].calendarUnit) {
            units[unitCount++] = i;
            mask |= wkDurationUnits[i].calendarUnit;
        }
    }
    if (!unitCount) {
        units[unitCount++] = WK_DURATION_UNIT_COUNT - 1;
        mask = NSCalendarUnitSecond;
    }

    // The calendar decomposes the interval: the largest requested unit absorbs everything above it,
    // and each unit truncates. A UTC Gregorian calendar keeps every unit in the table the length its
    // table entry says, whatever the current time zone does about daylight saving.
    NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *start = [NSDate dateWithTimeIntervalSinceReferenceDate:0];
    NSDate *end = [NSDate dateWithTimeIntervalSinceReferenceDate:fabs(interval)];
    NSDateComponents *components = [calendar components:mask fromDate:start toDate:end options:0];

    NSInteger values[WK_DURATION_UNIT_COUNT];
    for (NSInteger i = 0; i < unitCount; i++)
        values[i] = wkDurationComponentValue(components, wkDurationUnits[units[i]].calendarUnit);

    BOOL positional = _unitsStyle == NSDateComponentsFormatterUnitsStylePositional;
    NSInteger shown[WK_DURATION_UNIT_COUNT];
    NSInteger shownCount = 0;
    NSInteger largest = 0;
    while (largest + 1 < unitCount && !values[largest])
        largest++;
    for (NSInteger i = largest; i < unitCount; i++) {
        if (positional || values[i])
            shown[shownCount++] = i;
    }
    if (!shownCount)
        shown[shownCount++] = unitCount - 1;
    if (_maximumUnitCount > 0 && shownCount > _maximumUnitCount)
        shownCount = _maximumUnitCount;

    if (positional)
        return wkPositionalDuration(values, shown, shownCount);

    // Full and SpellOut read the whole unit names, the shorter styles the abbreviated ones. ICU 51
    // has the two tables; the narrow forms Abbreviated and Brief draw on from 10.12 arrived later,
    // so those styles read the abbreviated names as Short does.
    const char *table = (_unitsStyle == NSDateComponentsFormatterUnitsStyleFull || _unitsStyle == NSDateComponentsFormatterUnitsStyleSpellOut) ? "units" : "unitsShort";
    const char *localeID = [[NSLocale currentLocale] localeIdentifier].UTF8String;
    NSString *listPattern = wkDurationListPattern(localeID);
    NSString *result = nil;
    for (NSInteger i = 0; i < shownCount; i++) {
        NSInteger index = shown[i];
        NSString *piece = wkSpelledOutUnit(table, wkDurationUnits[units[index]].dataKey, values[index], localeID);
        if (!piece)
            return wkPositionalDuration(values, shown, shownCount);
        result = result ? wkApplyListPattern(listPattern, result, piece) : piece;
    }
    return result;
}
@end
WK_PRIV_ALIAS(NSDateComponentsFormatter);

// NSExtension (private Foundation, 10.10+): the app-extension registry. 10.9 predates app extensions
// entirely — Services on this OS come from service bundles reached through NSSharingService, which is
// present and which WebKit's ServicesController goes on using — so there is no extension registry here
// to look anything up in, and no extension set that can change.
//
// That makes every honest answer an empty one, and each is what the real API returns when nothing
// matches: +beginMatchingExtensionsWithAttributes:completion: hands back nil (no watcher token, because
// there is nothing to watch), and +extensionWithIdentifier:error: hands back nil (no such extension).
// ServicesController keeps its watcher in a RetainPtr and only releases it, so nil is handled; the
// consequence is simply that the services list is not refreshed when extensions change, which on an OS
// with no extensions is not a change that can occur.
//
// The instance methods exist so a caller that somehow obtains one gets the documented shape rather than
// an unrecognized selector; they cannot be reached, since no instance can be created.
WK_PRIV_CLASS(NSExtension) @interface NSExtension : NSObject
+ (id)beginMatchingExtensionsWithAttributes:(NSDictionary *)attributes completion:(void (^)(NSArray *, NSError *))completion;
+ (void)cancelMatchingExtensions:(id)token;
+ (NSExtension *)extensionWithIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)inputItems completion:(void (^)(id<NSCopying>, NSError *))handler;
- (void)cancelExtensionRequestWithIdentifier:(id<NSCopying>)requestIdentifier;
@end

@implementation NSExtension

+ (id)beginMatchingExtensionsWithAttributes:(NSDictionary *)attributes completion:(void (^)(NSArray *, NSError *))completion
{
    (void)attributes;
    // Report the empty match once, so a caller waiting on the completion is not left hanging, then
    // hand back no watcher token: nothing on this OS can change the (empty) extension set later.
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@[], nil);
        });
    }
    return nil;
}

+ (void)cancelMatchingExtensions:(id)token
{
    (void)token;
}

+ (NSExtension *)extensionWithIdentifier:(NSString *)bundleIdentifier error:(NSError **)error
{
    (void)bundleIdentifier;
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
    return nil;
}

- (void)beginExtensionRequestWithInputItems:(NSArray *)inputItems completion:(void (^)(id<NSCopying>, NSError *))handler
{
    (void)inputItems;
    if (handler)
        handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
}

- (void)cancelExtensionRequestWithIdentifier:(id<NSCopying>)requestIdentifier
{
    (void)requestIdentifier;
}

@end
WK_PRIV_ALIAS(NSExtension);
