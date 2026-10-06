// Grapheme cluster segmentation shared by the CoreFoundation and CoreText polyfills.
#pragma once

#include <CoreFoundation/CoreFoundation.h>

// The port's ICU 74 exports its C API under unversioned names.
#define U_DISABLE_RENAMING 1
#include <unicode/ubrk.h>
#include <unicode/utext.h>
#include <unicode/utf16.h>

// The calling thread's UBRK_CHARACTER iterator, for a caller that sets its text.
UBreakIterator *wk_characterClusterIterator(void);

// 10.9's own composed-character cluster containing index.
CFRange wk_systemComposedCharacterClusterAtIndex(CFStringRef string, CFIndex index);
