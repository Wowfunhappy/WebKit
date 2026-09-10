#!/bin/bash
# Builds every font fixture the two test pages reference, so both run from a clean checkout.
#
# Sources: fonts in LayoutTests, the committed CBDT subset in fonts/, and this machine's Apple Color
# Emoji (an Apple font, so it is cut here rather than checked in). Each table under test gets a pair
# -- one font sanitized with the table passed through, one with it dropped -- so that a font which
# fails to load falls back identically on both sides and the comparison reads "no difference" instead
# of inventing one.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DEPS="$ROOT/MavericksSupport/deps/build"
TC="${MAVERICKS_CLANG:-$ROOT/MavericksSupport/toolchain/build/clang}"
SDK="${MAVERICKS_SDK:-$(dirname "$ROOT")/MacOSX26.1.sdk}"
LT="$ROOT/LayoutTests"
OUT="$HERE/fonts"
BIN="$HERE/tools/sanitize-font"
KEEP="sbix,morx,mort,kerx,feat,ankr"   # the polyfill's passthrough set

mkdir -p "$OUT"

echo "### building sanitize-font"
SDKROOT="$SDK" "$TC/bin/clang++" -std=c++11 -O1 -mmacosx-version-min=10.9 \
    -I"$DEPS/include" "$HERE/tools/sanitize-font.cpp" \
    "$DEPS/lib/libots.a" "$DEPS/lib/libwoff2dec.a" \
    "$DEPS/lib/libbrotlidec.a" "$DEPS/lib/libbrotlicommon.a" -lz -o "$BIN"

# remap <in> <out> <codepoint>: point U+0041 at the glyph that codepoint maps to. The colour tests
# then run on Latin text, whose system fallback is monochrome -- with an emoji the fallback is Apple
# Color Emoji, which paints colour whether or not the font under test did.
remap() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
from fontTools.ttLib import TTFont
src, dst, cp = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
font = TTFont(src)
glyph = next((t.cmap[cp] for t in font['cmap'].tables if cp in t.cmap), None)
if not glyph:
    sys.exit("no glyph for U+%04X in %s" % (cp, src))
for table in font['cmap'].tables:
    table.cmap[0x0041] = glyph
font.save(dst)
PY
}

echo "### unknown-table fixture"
python3 - "$LT/animations/font-variations/resources/Boxis-VF.ttf" "$OUT/junk-table.ttf" <<'PY'
import os, sys
from fontTools.ttLib import TTFont, newTable
font = TTFont(sys.argv[1])
table = newTable('JUNK'); table.data = os.urandom(4096)
font['JUNK'] = table
font.save(sys.argv[2])
PY

echo "### table pairs"
"$BIN" "$LT/fast/text/resources/Ahem-trak.ttf"                     "$OUT/trak-pass.ttf" trak
"$BIN" "$LT/fast/text/resources/Ahem-trak.ttf"                     "$OUT/trak-drop.ttf"
"$BIN" "$LT/fast/writing-mode/resources/DroidSansFallback-reduced.ttf" "$OUT/prop-pass.ttf" prop
"$BIN" "$LT/fast/writing-mode/resources/DroidSansFallback-reduced.ttf" "$OUT/prop-drop.ttf"
"$BIN" "$LT/imported/w3c/web-platform-tests/css/css-fonts/support/fonts/Exo-DemiBold.otf" "$OUT/morx-pass.otf" morx
"$BIN" "$LT/imported/w3c/web-platform-tests/css/css-fonts/support/fonts/Exo-DemiBold.otf" "$OUT/morx-drop.otf"
"$BIN" "$LT/fast/text/resources/Ahem-SVG.ttf"                      "$OUT/svg-pass.ttf" "SVG "
"$BIN" "$LT/fast/text/resources/Ahem-COLR.ttf"                     "$OUT/colr.ttf"

echo "### colour pairs (remapped onto U+0041)"
remap "$OUT/cbdt-source.ttf" "$OUT/.cbdt-A.ttf" 1F600
# This pair keeps CBDT/CBLC deliberately, which $KEEP does not, because the question it answers is
# whether keeping them would buy anything. A CBDT font carries no glyf, so with the bitmaps dropped
# there is nothing left to draw and OTS refuses it; with them kept, this OS refuses the font anyway
# -- CGFontCreateWithDataProvider returns null for the source bytes. Either way no file appears, and
# the page reads a missing file as "did not load".
"$BIN" "$OUT/.cbdt-A.ttf" "$OUT/cbdtA-pass.ttf" "$KEEP,CBDT,CBLC" || rm -f "$OUT/cbdtA-pass.ttf"
"$BIN" "$OUT/.cbdt-A.ttf" "$OUT/cbdtA-drop.ttf" "$KEEP"          || rm -f "$OUT/cbdtA-drop.ttf"
rm -f "$OUT/.cbdt-A.ttf"

APPLE_EMOJI="/System/Library/Fonts/Apple Color Emoji.ttf"
if [ -f "$APPLE_EMOJI" ]; then
    python3 -m fontTools.subset "$APPLE_EMOJI" --unicodes="U+1F600,U+1F601,U+1F602,U+1F603,U+2764" \
        --output-file="$OUT/.sbix-sub.ttf" 2>/dev/null
    cp "$OUT/.sbix-sub.ttf" "$OUT/generated-sbix.ttf"
    remap "$OUT/.sbix-sub.ttf" "$OUT/.sbix-A.ttf" 1F600
    "$BIN" "$OUT/.sbix-A.ttf" "$OUT/sbixA-pass.ttf" "$KEEP"
    "$BIN" "$OUT/.sbix-A.ttf" "$OUT/sbixA-drop.ttf" || rm -f "$OUT/sbixA-drop.ttf"
    rm -f "$OUT/.sbix-sub.ttf" "$OUT/.sbix-A.ttf"
else
    echo "  no $APPLE_EMOJI; the sbix checks will report not-loaded" >&2
fi

echo "### done"
ls -la "$OUT"
