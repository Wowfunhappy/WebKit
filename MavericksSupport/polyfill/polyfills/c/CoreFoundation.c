// CoreFoundation: entry points modern WebKit calls that 10.9's CoreFoundation does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#include "wk_clusters.h"

// ---------------------------------------------------------------------------------------------------
// CoreFoundation prefs daemon tuning — optimizations for sandboxed XPC services; no-ops on 10.9.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("CoreFoundation", void, _CFPrefsSetDirectModeEnabled, (int enabled))
{
    (void)enabled;
}

WK_POLYFILL_ABSENT("CoreFoundation", void, _CFPrefsSetReadOnly, (Boolean flag))
{
    (void)flag;
}

// The XPC bootstrap-dictionary channel is absent on 10.9 (see xpc_copy_bootstrap and
// xpc_connection_set_bootstrap in libSystem.m). This fills a bootstrap dictionary with the caller
// bundle's identity; with no bootstrap channel there is nothing to fill in, so the dictionary the
// caller passes is simply left as it was.
WK_POLYFILL_ABSENT("CoreFoundation", void, _CFBundleSetupXPCBootstrap, (xpc_object_t bootstrap))
{
    (void)bootstrap;
}

// ---------------------------------------------------------------------------------------------------
// CFStringGetRangeOfCharacterClusterAtIndex. 10.9 builds grapheme and composed-character clusters from
// combining-mark tables, so emoji ZWJ, modifier and tag sequences, flag pairs and Indic conjuncts come
// apart. Modern CoreFoundation segments them as UAX #29 extended grapheme clusters, which this port's ICU
// implements. A backward-deletion cluster further splits before every Armenian-through-Limbu code point
// other than a conjoining jamo, so Backspace removes an Arabic, Hebrew, Indic or Thai mark on its own.
// Cursor-movement clusters are 10.9's.
// ---------------------------------------------------------------------------------------------------

typedef CF_ENUM(CFIndex, CFStringCharacterClusterType) {
    kCFStringGraphemeCluster = 1,
    kCFStringComposedCharacterCluster = 2,
    kCFStringCursorMovementCluster = 3,
    kCFStringBackwardDeletionCluster = 4
};

enum { WKClusterTextChunkLength = 64 };

// A UText over a CFString with no UTF-16 buffer of its own, filled a chunk at a time into the buffer at p.
// A clone shares that buffer, so it is only valid during the call that made it.
static UText *wk_clusterTextClone(UText *destination, const UText *source, UBool deep, UErrorCode *status)
{
    if (U_FAILURE(*status))
        return destination;
    if (deep) {
        *status = U_UNSUPPORTED_ERROR;
        return destination;
    }
    destination = utext_setup(destination, 0, status);
    if (U_FAILURE(*status))
        return destination;
    void *extra = destination->pExtra;
    int32_t extraSize = destination->extraSize;
    int32_t flags = destination->flags;
    memcpy(destination, source, source->sizeOfStruct < destination->sizeOfStruct ? source->sizeOfStruct : destination->sizeOfStruct);
    destination->pExtra = extra;
    destination->extraSize = extraSize;
    destination->flags = flags;
    return destination;
}

static int64_t wk_clusterTextNativeLength(UText *text)
{
    return text->a;
}

static UBool wk_clusterTextAccess(UText *text, int64_t index, UBool forward)
{
    int64_t length = text->a;
    if (index < 0)
        index = 0;
    else if (index > length)
        index = length;
    if (forward ? (index >= text->chunkNativeStart && index < text->chunkNativeLimit)
                : (index > text->chunkNativeStart && index <= text->chunkNativeLimit)) {
        text->chunkOffset = (int32_t)(index - text->chunkNativeStart);
        return true;
    }
    int64_t start = forward ? index : index - WKClusterTextChunkLength;
    if (start > length - WKClusterTextChunkLength)
        start = length - WKClusterTextChunkLength;
    if (start < 0)
        start = 0;
    int64_t limit = start + WKClusterTextChunkLength < length ? start + WKClusterTextChunkLength : length;
    UniChar *chunk = (UniChar *)text->p;
    CFStringGetCharacters((CFStringRef)text->context, CFRangeMake((CFIndex)start, (CFIndex)(limit - start)), chunk);
    text->chunkContents = (const UChar *)chunk;
    text->chunkNativeStart = start;
    text->chunkNativeLimit = limit;
    text->chunkLength = (int32_t)(limit - start);
    text->nativeIndexingLimit = text->chunkLength;
    text->chunkOffset = (int32_t)(index - start);
    return forward ? index < limit : index > start;
}

static const UTextFuncs wk_clusterTextFuncs = {
    .tableSize = sizeof(UTextFuncs),
    .clone = wk_clusterTextClone,
    .nativeLength = wk_clusterTextNativeLength,
    .access = wk_clusterTextAccess,
};

// The thread's character iterator, and the immutable string whose text it holds (retained), so a caller
// stepping through one string keeps ICU's boundary cache from call to call.
typedef struct {
    UBreakIterator *iterator;
    CFStringRef string;
    const UniChar *characters;
    CFIndex length;
} wk_clusterIteratorState;

static pthread_key_t wk_clusterIteratorKey;
static pthread_once_t wk_clusterIteratorKeyOnce = PTHREAD_ONCE_INIT;

static void wk_clusterIteratorForgetText(wk_clusterIteratorState *state)
{
    if (state->string)
        CFRelease(state->string);
    state->string = NULL;
    state->characters = NULL;
    state->length = 0;
}

static void wk_clusterIteratorStateDestroy(void *state)
{
    wk_clusterIteratorForgetText((wk_clusterIteratorState *)state);
    ubrk_close(((wk_clusterIteratorState *)state)->iterator);
    free(state);
}

static void wk_clusterIteratorKeyCreate(void)
{
    if (pthread_key_create(&wk_clusterIteratorKey, wk_clusterIteratorStateDestroy))
        abort();
}

static wk_clusterIteratorState *wk_clusterIteratorStateForThread(void)
{
    pthread_once(&wk_clusterIteratorKeyOnce, wk_clusterIteratorKeyCreate);
    wk_clusterIteratorState *state = (wk_clusterIteratorState *)pthread_getspecific(wk_clusterIteratorKey);
    if (state)
        return state;
    state = (wk_clusterIteratorState *)calloc(1, sizeof(*state));
    if (!state)
        abort();
    UErrorCode status = U_ZERO_ERROR;
    state->iterator = ubrk_open(UBRK_CHARACTER, "", NULL, 0, &status);
    if (U_FAILURE(status))
        abort();
    pthread_setspecific(wk_clusterIteratorKey, state);
    return state;
}

UBreakIterator *wk_characterClusterIterator(void)
{
    wk_clusterIteratorState *state = wk_clusterIteratorStateForThread();
    wk_clusterIteratorForgetText(state);
    return state->iterator;
}

extern Boolean __CFStringIsMutable(CFStringRef);

// A CoreFoundation string object (not a subclass or constant) that is not mutable.
static bool wk_isImmutableCFString(CFStringRef string)
{
    static Class cfStringClass;
    if (!cfStringClass)
        cfStringClass = objc_getClass("__NSCFString");
    return object_getClass((id)string) == cfStringClass && !__CFStringIsMutable(string);
}

static bool wk_startsBackwardDeletionCluster(UChar32 character)
{
    return character >= 0x0530 && character < 0x1950 && (character < 0x1100 || character > 0x11FF);
}

WK_POLYFILL_REPLACES("CoreFoundation", CFRange, CFStringGetRangeOfCharacterClusterAtIndex,
    (CFStringRef string, CFIndex charIndex, CFStringCharacterClusterType type))
{
    if (type != kCFStringGraphemeCluster && type != kCFStringComposedCharacterCluster && type != kCFStringBackwardDeletionCluster)
        return WK_ORIGINAL(CFStringGetRangeOfCharacterClusterAtIndex)(string, charIndex, type);

    CFIndex length = CFStringGetLength(string);
    if (charIndex < 0 || charIndex >= length)
        return CFRangeMake(kCFNotFound, 0);

    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(string, &buffer, CFRangeMake(0, length));
    CFIndex index = charIndex;
    UniChar character = CFStringGetCharacterFromInlineBuffer(&buffer, index);
    if (U16_IS_TRAIL(character) && index && U16_IS_LEAD(CFStringGetCharacterFromInlineBuffer(&buffer, index - 1)))
        character = CFStringGetCharacterFromInlineBuffer(&buffer, --index);

    // No character below U+0300 extends, prepends or joins, so one whose neighbours are also below U+0300
    // is a cluster by itself unless it is half of CR LF.
    if (character < 0x0300 && character != '\r' && character != '\n'
        && (!index || CFStringGetCharacterFromInlineBuffer(&buffer, index - 1) < 0x0300)
        && (index + 1 == length || CFStringGetCharacterFromInlineBuffer(&buffer, index + 1) < 0x0300))
        return CFRangeMake(index, 1);

    wk_clusterIteratorState *state = wk_clusterIteratorStateForThread();
    const UniChar *characters = CFStringGetCharactersPtr(string);
    if (!characters || state->string != string || state->characters != characters || state->length != length) {
        wk_clusterIteratorForgetText(state);
        UniChar chunk[WKClusterTextChunkLength];
        UText text = UTEXT_INITIALIZER;
        UErrorCode status = U_ZERO_ERROR;
        if (characters)
            utext_openUChars(&text, (const UChar *)characters, length, &status);
        else {
            utext_setup(&text, 0, &status);
            text.pFuncs = &wk_clusterTextFuncs;
            text.context = string;
            text.p = chunk;
            text.a = length;
        }
        ubrk_setUText(state->iterator, &text, &status);
        if (U_FAILURE(status))
            abort();
        if (characters && wk_isImmutableCFString(string)) {
            state->string = (CFStringRef)CFRetain(string);
            state->characters = characters;
            state->length = length;
        }
    }
    UBreakIterator *iterator = state->iterator;

    CFIndex end = ubrk_following(iterator, (int32_t)index);
    CFIndex start = ubrk_previous(iterator);

    if (type == kCFStringBackwardDeletionCluster) {
        CFIndex clusterStart = start;
        for (CFIndex position = clusterStart; position < end; ) {
            UniChar unit = CFStringGetCharacterFromInlineBuffer(&buffer, position);
            UChar32 codePoint = unit;
            CFIndex size = 1;
            if (U16_IS_LEAD(unit) && position + 1 < end) {
                UniChar trail = CFStringGetCharacterFromInlineBuffer(&buffer, position + 1);
                if (U16_IS_TRAIL(trail)) {
                    codePoint = U16_GET_SUPPLEMENTARY(unit, trail);
                    size = 2;
                }
            }
            if (position != clusterStart && wk_startsBackwardDeletionCluster(codePoint)) {
                if (position > index) {
                    end = position;
                    break;
                }
                start = position;
            }
            position += size;
        }
    }
    return CFRangeMake(start, end - start);
}

CFRange wk_systemComposedCharacterClusterAtIndex(CFStringRef string, CFIndex index)
{
    return WK_ORIGINAL(CFStringGetRangeOfCharacterClusterAtIndex)(string, index, kCFStringComposedCharacterCluster);
}
