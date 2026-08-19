/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// Software instancer for OpenType 1.8 variable fonts, used by the CoreText polyfills in
// CoreText.c. 10.9's CoreText cannot instance a variable font: a descriptor carrying
// kCTFontVariationAttribute realizes to the fvar default master, and the one path CoreText does
// route variations through (CTFontCreateWithGraphicsFont with that attribute, which reaches
// CGFontCreateCopyWithVariations) collapses every outline to a zero-width, zero-area glyph. Both
// were measured on 10.9.5. Fonts whose fvar default master is not Regular (e.g. Google's Raleway,
// which defaults to wght=100 Thin) therefore render every weight at that master.
//
// The implementation applies the font's own avar/gvar variation deltas to the glyf outlines and
// hmtx metrics at a requested set of pinned axis values, producing a static sfnt that legacy
// CoreText renders correctly. It uses only CoreFoundation and the C++ standard library; the
// surface below is C so that CoreText.c can call it.

#ifndef WK_VARIABLE_FONT_INSTANCER_H
#define WK_VARIABLE_FONT_INSTANCER_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// True when the buffer is an sfnt with TrueType outlines the instancer can cut (fvar + gvar +
// glyf). Only such fonts need their descriptor to carry the source bytes.
bool wk_legacy_variable_font_is_instanceable(CFDataRef sfnt);

// Returns (retained) the input sfnt with the variation tables dropped, turning a variable font
// into its (static) default master. Returns the input (retained) when there is nothing to strip
// or the font cannot be safely rewritten; never returns null for a non-null input.
CFDataRef wk_legacy_variable_font_strip_variations(CFDataRef sfnt);

// Returns (retained) a static sfnt equivalent to `sfnt` with every axis pinned: the axes named in
// `ctVariationAttribute` (a kCTFontVariationAttribute dictionary, keyed by four-character tag the
// way CoreText writes it) take the given value clamped to the axis range, and every other axis
// stays at its fvar default. Returns null when the font is not instanceable, when the requested
// values are all the fvar defaults (nothing to do), or on any parse anomaly — callers then use
// the default master. Results are memoized, since font-variation-settings is animatable and CSS
// can mint a new pinned-value set per frame.
CFDataRef wk_legacy_variable_font_instance(CFDataRef sfnt, CFDictionaryRef ctVariationAttribute);

#ifdef __cplusplus
}
#endif

#endif // WK_VARIABLE_FONT_INSTANCER_H
