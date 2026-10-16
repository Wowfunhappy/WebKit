// Foundation: stubs of the Foundation classes 10.9 does not have.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <unicode/uameasureformat.h>
#include <unicode/udisplaycontext.h>
#include <unicode/ulistformatter.h>
#include <unicode/unum.h>
#include <unicode/ures.h>
#include <unicode/ustring.h>

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

// NSURLSessionTaskTransactionMetrics and NSURLSessionTaskMetrics (10.12+): the record of a task's
// request-response transactions -- one per request, so a redirected load has one per hop -- that NSURLSession
// hands its delegate in -URLSession:task:didFinishCollectingMetrics: just before the task completes, and that
// -[NSURLSessionTask _incompleteTaskMetrics] reports while it runs. 10.9's NSURLSession keeps no such record;
// polyfills/webkit/task_metrics.mm fills these in from the task's own events. The properties are readwrite
// here for that filler; the modern SDK WebKit compiles against declares them readonly. A value 10.9 cannot
// observe (DNS, connect and TLS times, header byte counts, the connection's addresses) stays nil or zero,
// which is how the metrics report a value that was not collected.
WK_PRIV_CLASS(NSURLSessionTaskTransactionMetrics) @interface NSURLSessionTaskTransactionMetrics : NSObject
@property (copy) NSURLRequest *request;
@property (copy) NSURLResponse *response;
@property (copy) NSDate *fetchStartDate;
@property (copy) NSDate *domainLookupStartDate;
@property (copy) NSDate *domainLookupEndDate;
@property (copy) NSDate *connectStartDate;
@property (copy) NSDate *secureConnectionStartDate;
@property (copy) NSDate *secureConnectionEndDate;
@property (copy) NSDate *connectEndDate;
@property (copy) NSDate *requestStartDate;
@property (copy) NSDate *requestEndDate;
@property (copy) NSDate *responseStartDate;
@property (copy) NSDate *responseEndDate;
@property (copy) NSString *networkProtocolName;
@property (getter=isProxyConnection) BOOL proxyConnection;
@property (getter=isReusedConnection) BOOL reusedConnection;
@property NSInteger resourceFetchType;
@property int64_t countOfRequestHeaderBytesSent;
@property int64_t countOfRequestBodyBytesSent;
@property int64_t countOfRequestBodyBytesBeforeEncoding;
@property int64_t countOfResponseHeaderBytesReceived;
@property int64_t countOfResponseBodyBytesReceived;
@property int64_t countOfResponseBodyBytesAfterDecoding;
@property (copy) NSString *localAddress;
@property (copy) NSNumber *localPort;
@property (copy) NSString *remoteAddress;
@property (copy) NSNumber *remotePort;
@property (copy) NSNumber *negotiatedTLSProtocolVersion;
@property (copy) NSNumber *negotiatedTLSCipherSuite;
@property (getter=isCellular) BOOL cellular;
@property (getter=isExpensive) BOOL expensive;
@property (getter=isConstrained) BOOL constrained;
@property (getter=isMultipath) BOOL multipath;
@property NSInteger domainResolutionProtocol;
@property (copy) NSUUID *_connectionIdentifier;
@property (copy) NSString *_remoteAddressAndPort;
@property int _privacyStance;
@property (retain) id _establishmentReport;
@property BOOL _isUnlistedTracker;
@end
@implementation NSURLSessionTaskTransactionMetrics
// On this system a connection is never relayed or proxied privately: iCloud Private Relay does not exist.
- (instancetype)init
{
    if ((self = [super init]))
        __privacyStance = 1; // nw_connection_privacy_stance_not_eligible
    return self;
}
- (void)dealloc
{
    [_request release];
    [_response release];
    [_fetchStartDate release];
    [_domainLookupStartDate release];
    [_domainLookupEndDate release];
    [_connectStartDate release];
    [_secureConnectionStartDate release];
    [_secureConnectionEndDate release];
    [_connectEndDate release];
    [_requestStartDate release];
    [_requestEndDate release];
    [_responseStartDate release];
    [_responseEndDate release];
    [_networkProtocolName release];
    [_localAddress release];
    [_localPort release];
    [_remoteAddress release];
    [_remotePort release];
    [_negotiatedTLSProtocolVersion release];
    [_negotiatedTLSCipherSuite release];
    [__connectionIdentifier release];
    [__remoteAddressAndPort release];
    [__establishmentReport release];
    [super dealloc];
}
@end
WK_PRIV_ALIAS(NSURLSessionTaskTransactionMetrics);

WK_PRIV_CLASS(NSURLSessionTaskMetrics) @interface NSURLSessionTaskMetrics : NSObject
@property (copy) NSArray *transactionMetrics;
@property (retain) id taskInterval;
@property NSUInteger redirectCount;
@end
@implementation NSURLSessionTaskMetrics
- (void)dealloc
{
    [_transactionMetrics release];
    [_taskInterval release];
    [super dealloc];
}
@end
WK_PRIV_ALIAS(NSURLSessionTaskMetrics);

// NSDateComponentsFormatter formats a quantity of time in words -- "2 minutes, 5 seconds". WebCore
// builds the media controls' accessibility description of a track's duration with it
// (RenderThemeCocoa::mediaControlsFormattedStringForDuration): units style Full, allowed units
// hour/minute/second, standalone formatting context, at most two units. VoiceOver reads the result
// out, so the spelled-out localized wording IS the string's purpose.
//
// The formatting is Apple ICU's measure format (uameasfmt), the interface modern Foundation formats with,
// in WebKit's ICU: unit names under the locale's plural rules, joined by the locale's unit list pattern.
// None of the words are written here. Each style is one of its widths -- Full WIDE, Short SHORT,
// Abbreviated NARROW, Brief SHORTER, Positional NUMERIC ("1:10"; days and a lone unit fall back to the
// narrow form, "3d 4h"). SpellOut is WIDE with every number spelled out: the measure format spells out
// only the last unit's number, so each unit is formatted on its own with a spell-out number format in the
// unit's grammatical gender (the first capitalized for the start of a sentence) and the pieces are joined
// by the locale's unit list.
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

// The units a plain time interval decomposes into, largest first, each with the key CLDR stores it
// under. These are the fixed-length ones; a month and a year are as long as the calendar says, so a
// caller that allows them gets the units below that instead.
static const struct { NSUInteger calendarUnit; UAMeasureUnit measureUnit; const char *dataKey; } wkDurationUnits[] = {
    { NSCalendarUnitDay,    UAMEASUNIT_DURATION_DAY,    "day"    },
    { NSCalendarUnitHour,   UAMEASUNIT_DURATION_HOUR,   "hour"   },
    { NSCalendarUnitMinute, UAMEASUNIT_DURATION_MINUTE, "minute" },
    { NSCalendarUnitSecond, UAMEASUNIT_DURATION_SECOND, "second" },
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

static NSString *wkStringFromUChars(const UChar *text, int32_t length, UErrorCode status)
{
    if (U_FAILURE(status) || status == U_STRING_NOT_TERMINATED_WARNING || length < 0)
        return nil;
    return [NSString stringWithCharacters:(const unichar *)text length:(NSUInteger)length];
}

// The measures in one of the measure format's widths, "1 hour, 10 minutes".
static NSString *wkFormattedMeasures(const UAMeasure *measures, NSInteger count, UAMeasureFormatWidth width, const char *localeID)
{
    UErrorCode status = U_ZERO_ERROR;
    UAMeasureFormat *format = uameasfmt_open(localeID, width, NULL, &status);
    UChar text[512];
    int32_t length = uameasfmt_formatMultiple(format, measures, (int32_t)count, text, (int32_t)(sizeof(text) / sizeof(text[0])), &status);
    uameasfmt_close(format);
    return wkStringFromUChars(text, length, status);
}

// ICU's resource lookup along a key path with locale fallback (uresimp.h), which libicucore exports.
extern UResourceBundle *ures_getByKeyWithFallback(const UResourceBundle *bundle, const char *keyPath, UResourceBundle *fillIn, UErrorCode *status);

// The spell-out rule set that agrees with a duration unit's grammatical gender in the locale: CLDR records
// the gender with the unit's names ("feminine" for French "heure"), and the locale's spell-out rules name
// a cardinal rule set for it ("%spellout-cardinal-feminine"; in Russian, whose rule sets are also split by
// case, that is the nominative one). Where the locale records no gender for the unit, or has no rule set
// for it, the number is spelled out with the locale's default.
static void wkSetSpellOutGender(UNumberFormat *spellOut, const char *unitKey, const char *localeID, UErrorCode *status)
{
    if (U_FAILURE(*status))
        return;
    char keyPath[64];
    snprintf(keyPath, sizeof(keyPath), "units/duration/%s/gender", unitKey);
    UErrorCode lookupStatus = U_ZERO_ERROR;
    UResourceBundle *units = ures_open(U_ICUDATA_NAME "-unit", localeID, &lookupStatus);
    UResourceBundle *gender = ures_getByKeyWithFallback(units, keyPath, NULL, &lookupStatus);
    int32_t genderLength = 0;
    const UChar *genderName = U_SUCCESS(lookupStatus) ? ures_getString(gender, &genderLength, &lookupStatus) : NULL;
    UChar ruleSet[96];
    int32_t ruleSetLength = 0;
    if (genderName && U_SUCCESS(lookupStatus)) {
        static const char prefix[] = "%spellout-cardinal-";
        ruleSetLength = (int32_t)strlen(prefix);
        if (ruleSetLength + genderLength < (int32_t)(sizeof(ruleSet) / sizeof(ruleSet[0]))) {
            u_charsToUChars(prefix, ruleSet, ruleSetLength);
            u_memcpy(ruleSet + ruleSetLength, genderName, genderLength);
            ruleSetLength += genderLength;
        } else
            ruleSetLength = 0;
    }
    ures_close(gender);
    ures_close(units);
    if (!ruleSetLength)
        return;

    UChar ruleSets[4096];
    UErrorCode ruleSetsStatus = U_ZERO_ERROR;
    int32_t ruleSetsLength = unum_getTextAttribute(spellOut, UNUM_PUBLIC_RULESETS, ruleSets, (int32_t)(sizeof(ruleSets) / sizeof(ruleSets[0])), &ruleSetsStatus);
    if (U_FAILURE(ruleSetsStatus) || ruleSetsStatus == U_STRING_NOT_TERMINATED_WARNING)
        return;
    for (int32_t start = 0; start < ruleSetsLength;) {
        int32_t end = start;
        while (end < ruleSetsLength && ruleSets[end] != ';')
            end++;
        if (end - start == ruleSetLength && !u_memcmp(ruleSets + start, ruleSet, ruleSetLength)) {
            unum_setTextAttribute(spellOut, UNUM_DEFAULT_RULESET, ruleSet, ruleSetLength, status);
            return;
        }
        start = end + 1;
    }
}

// The measures with every number spelled out, "One hour, ten minutes".
static NSString *wkSpelledOutMeasures(const UAMeasure *measures, const char *const *unitKeys, NSInteger count, const char *localeID)
{
    enum { maximumPieces = 8, pieceCapacity = 256 };
    UChar pieces[maximumPieces][pieceCapacity];
    const UChar *strings[maximumPieces];
    int32_t lengths[maximumPieces];
    if (count < 1 || count > maximumPieces)
        return nil;

    UErrorCode status = U_ZERO_ERROR;
    for (NSInteger i = 0; i < count && U_SUCCESS(status); i++) {
        UNumberFormat *spellOut = unum_open(UNUM_SPELLOUT, NULL, 0, localeID, NULL, &status);
        wkSetSpellOutGender(spellOut, unitKeys[i], localeID, &status);
        unum_setContext(spellOut, i ? UDISPCTX_CAPITALIZATION_FOR_MIDDLE_OF_SENTENCE : UDISPCTX_CAPITALIZATION_FOR_BEGINNING_OF_SENTENCE, &status);
        UAMeasureFormat *format = uameasfmt_open(localeID, UAMEASFMT_WIDTH_WIDE, spellOut, &status);
        lengths[i] = uameasfmt_format(format, measures[i].value, measures[i].unit, pieces[i], pieceCapacity, &status);
        strings[i] = pieces[i];
        uameasfmt_close(format);
        if (status == U_STRING_NOT_TERMINATED_WARNING)
            return nil;
    }
    UListFormatter *list = ulistfmt_openForType(localeID, ULISTFMT_TYPE_UNITS, ULISTFMT_WIDTH_WIDE, &status);
    UChar text[1024];
    int32_t length = ulistfmt_format(list, strings, lengths, (int32_t)count, text, (int32_t)(sizeof(text) / sizeof(text[0])), &status);
    ulistfmt_close(list);
    return wkStringFromUChars(text, length, status);
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

    UAMeasure measures[WK_DURATION_UNIT_COUNT];
    const char *unitKeys[WK_DURATION_UNIT_COUNT];
    for (NSInteger i = 0; i < shownCount; i++) {
        measures[i].value = values[shown[i]];
        measures[i].unit = wkDurationUnits[units[shown[i]]].measureUnit;
        unitKeys[i] = wkDurationUnits[units[shown[i]]].dataKey;
    }
    const char *localeID = [[NSLocale currentLocale] localeIdentifier].UTF8String;
    switch (_unitsStyle) {
    case NSDateComponentsFormatterUnitsStylePositional:
        return wkFormattedMeasures(measures, shownCount, UAMEASFMT_WIDTH_NUMERIC, localeID);
    case NSDateComponentsFormatterUnitsStyleAbbreviated:
        return wkFormattedMeasures(measures, shownCount, UAMEASFMT_WIDTH_NARROW, localeID);
    case NSDateComponentsFormatterUnitsStyleShort:
        return wkFormattedMeasures(measures, shownCount, UAMEASFMT_WIDTH_SHORT, localeID);
    case NSDateComponentsFormatterUnitsStyleSpellOut:
        return wkSpelledOutMeasures(measures, unitKeys, shownCount, localeID);
    case NSDateComponentsFormatterUnitsStyleBrief:
        return wkFormattedMeasures(measures, shownCount, UAMEASFMT_WIDTH_SHORTER, localeID);
    default:
        return wkFormattedMeasures(measures, shownCount, UAMEASFMT_WIDTH_WIDE, localeID);
    }
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

// NSItemProvider (10.10+): a typed item plus the promise of its data. WebKit's Mac use is the narrow
// deprecated one — wrap one already-materialised item under one UTI and hand it to
// NSSharingServicePicker, which both WebContextMenuProxyMac's service-controls menu and WebKitLegacy's
// WebContextMenuClient do. WebSharingServicePickerController reads the shared item back through
// -registeredTypeIdentifiers and -loadItemForTypeIdentifier:options:completionHandler:.
//
// 10.9's picker takes any NSPasteboardWriting, and its pasteboard types ARE UTIs, so writing the
// wrapped item under its own type identifier is what makes the picker offer the same services the
// modern one offers for the same item.
WK_PRIV_CLASS(NSItemProvider) @interface NSItemProvider : NSObject <NSPasteboardWriting> {
    id _item;
    NSString *_typeIdentifier;
}
- (instancetype)initWithItem:(id)item typeIdentifier:(NSString *)typeIdentifier;
- (NSArray *)registeredTypeIdentifiers;
- (void)loadItemForTypeIdentifier:(NSString *)typeIdentifier options:(NSDictionary *)options completionHandler:(void (^)(id, NSError *))completionHandler;
@end

@implementation NSItemProvider

- (instancetype)initWithItem:(id)item typeIdentifier:(NSString *)typeIdentifier
{
    if (!(self = [super init]))
        return nil;
    _item = [item retain];
    _typeIdentifier = [typeIdentifier copy];
    return self;
}

- (void)dealloc
{
    [_item release];
    [_typeIdentifier release];
    [super dealloc];
}

- (NSArray *)registeredTypeIdentifiers
{
    return _typeIdentifier ? [NSArray arrayWithObject:_typeIdentifier] : [NSArray array];
}

// The load runs on a private serial queue and the handler is called there, which is where the real
// class calls it: a caller is entitled to return from this method before the handler runs, and to hold
// a lock across the call.
- (void)loadItemForTypeIdentifier:(NSString *)typeIdentifier options:(NSDictionary *)options completionHandler:(void (^)(id, NSError *))completionHandler
{
    (void)options;
    if (!completionHandler)
        return;

    static dispatch_queue_t loadQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loadQueue = dispatch_queue_create("org.webkit.aquawebkit.NSItemProvider", DISPATCH_QUEUE_SERIAL);
    });

    // dispatch_async copies the block, which retains self and copies completionHandler for the
    // duration; requested is copied because the caller owns its string.
    NSString *requested = [typeIdentifier copy];
    dispatch_async(loadQueue, ^{
        @autoreleasepool {
            if (requested && _typeIdentifier && ![requested isEqualToString:_typeIdentifier])
                completionHandler(nil, [NSError errorWithDomain:@"NSItemProviderErrorDomain" code:-1000 userInfo:nil]);
            else
                completionHandler(_item, nil);
            [requested release];
        }
    });
}

- (NSArray *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    (void)pasteboard;
    return [self registeredTypeIdentifiers];
}

// Written under the type it was registered with, so the item's own NSPasteboardWriting answers wherever
// it has one — NSString, NSURL, NSImage and NSAttributedString all do. NSData carries no such
// conformance and is already a property list value.
- (id)pasteboardPropertyListForType:(NSString *)type
{
    if ([_item respondsToSelector:@selector(pasteboardPropertyListForType:)])
        return [_item pasteboardPropertyListForType:type];
    if ([_item isKindOfClass:[NSData class]])
        return _item;
    if ([_item respondsToSelector:@selector(TIFFRepresentation)])
        return [_item TIFFRepresentation];
    return nil;
}

@end
WK_PRIV_ALIAS(NSItemProvider);
