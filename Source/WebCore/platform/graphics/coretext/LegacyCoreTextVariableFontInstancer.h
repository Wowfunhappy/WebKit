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

// MAVERICKS_BACKPORT: macOS 10.9 CoreText/CoreGraphics cannot instance OpenType 1.8
// variable fonts loaded through the CGFont web-font path: kCTFontVariationAttribute is
// silently ignored, and CGFontCreateCopyWithVariations produces collapsed/empty glyph
// outlines for ANY non-default coordinate (single- and multi-axis alike). Fonts whose
// fvar default master is not Regular (e.g. Google's Raleway defaults to wght=100 Thin)
// therefore render every weight at that master — visibly wrong text.
//
// This file is a software instancer: it applies the font's own avar/gvar variation
// deltas to the glyf outlines and hmtx metrics at a requested set of pinned axis
// values, producing a static sfnt that legacy CoreText renders correctly.

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <cstdint>
#include <utility>
#include <vector>

namespace WebCore {

struct LegacyVariableFontAxis {
    uint32_t tag { 0 };
    float minimumValue { 0 };
    float defaultValue { 0 };
    float maximumValue { 0 };
};

// Parses the fvar table. Returns the axes when the buffer is an sfnt with TrueType
// outlines that the software instancer can handle (fvar + gvar + glyf); empty otherwise.
std::vector<LegacyVariableFontAxis> legacyVariableFontAxes(CFDataRef);

// Returns (retained) a static sfnt equivalent to the input variable font with each
// axis pinned to the given value: avar/gvar deltas are applied to the glyf outlines
// and hmtx advances, and the variation tables are dropped. Returns null on any parse
// anomaly (callers fall back to the default master).
CFDataRef createLegacyVariableFontInstance(CFDataRef, const std::vector<std::pair<uint32_t, float>>& pinnedAxisValues);

// Returns (retained) the input sfnt with the variation tables dropped, turning a
// variable font into its (static) default master. Returns the input (retained) when
// there is nothing to strip or the font cannot be safely rewritten.
CFDataRef createFontDataWithVariationTablesStripped(CFDataRef);

} // namespace WebCore
