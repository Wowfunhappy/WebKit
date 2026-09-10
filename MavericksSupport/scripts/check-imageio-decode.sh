#!/bin/bash
# Report whether anything in this port can hand image bytes to 10.9's ImageIO. Run by hand
# after touching image decoding, encoding or the polyfill layer; it reads the staged tree and
# the source, and changes neither.
#
# The port decodes every image format in WebCore -- ScalableImageDecoder and the vendored libjpeg,
# libpng, libwebp, libavif, libtiff behind it -- so that a hostile image response is parsed by code
# that is still maintained rather than by a 2013 ImageIO. Reading the source is not proof of that:
# one CGImageSourceCreateWithData added later, anywhere, puts a page's bytes back inside ImageIO's
# codecs with nothing to say so.
#
# ImageIO is reachable two ways, and each needs its own measurement:
#
#   (a) DIRECTLY, through the C API. An image cannot be decoded without a CGImageSource, and one
#       cannot exist without a constructor below, so no shipped binary may reference any of them.
#       The destination side is measured with it: encoding is kept, because CGImageDestination is
#       the only image encoder this OS has and a page can always reach one (canvas toBlob), but an
#       encoder that takes a CGImage is handed finished pixels and a named colour space, while the
#       entry points that take a source, a metadata object or an auxiliary-data dictionary hand it
#       the container again and put a page's bytes back inside ImageIO's parsers. Only the
#       pixels-in spelling may be referenced. This is measured over the linked product, which is
#       the strongest form the question takes.
#
#   (c) THROUGH A NAME RESOLVED AT RUNTIME. A symbol reached by name -- the polyfill layer's
#       WK_SYSTEM_FN / WK_ORIGINAL / wk_polyfill_original, a WK_POLYFILL_REPLACES that DEFINES the
#       symbol so WebKit's own references bind inside libpolyfill.a, WTF's SOFT_LINK_FUNCTION_*, a
#       bare dlsym -- emits no undefined reference, so (a) is blind to it exactly as it is to (b).
#       The CoreText polyfill decoded a font's sbix colour bitmaps that way, and a downloadable font
#       makes those page-controlled bytes. Measured over the polyfill layer and over both trees of
#       first-party source.
#
#       What it looks for is a CGImageSource CONSTRUCTOR by name. The two entry points the polyfill
#       layer does define -- CGImageSourceCreateImageAtIndex and CGImageSourceCreateThumbnailAtIndex,
#       which enforce CGImageSourceSetAllowableTypes -- take a source rather than bytes and are not
#       constructors, so they are outside the pattern rather than exempted from it: no line is ever
#       dropped whole, and a line that names one of them AND a constructor still fails.
#
#       In Source/ a constructor named directly is (a)'s to catch, since a direct call that compiles
#       leaves an undefined reference; only a name RESOLVED there escapes (a), so that is what this
#       half reads. In the polyfill layer any mention at all fails: nothing there may name one.
#
#   (b) THROUGH APPKIT. -[NSImage initWithData:] and its NSImageRep siblings parse their argument
#       inside ImageIO and leave no _CGImageSource* reference at all, so (a) cannot see them. They
#       are measured in the source instead -- the honest limit of this half: it reads Source/ for
#       the constructors that decode, not the binaries. Every spelling that takes bytes, a file, a
#       URL or a pasteboard is named, because the one that gets added later is the one nobody
#       thought to list.
#
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # MavericksSupport/scripts
REPO="$(cd "$HERE/../.." && pwd)"                                # repo root
STAGED="${1:-$REPO/WebKitBuild/Release/staged}"
. "$HERE/cctools.sh"
NM="$CCTOOLS/nm"

fail() { echo "  ImageIO-decode check: FAILED -- $*"; exit 1; }

# A check that cannot run must FAIL, never pass quietly.
[ -d "$STAGED" ] || fail "no staged tree at $STAGED"
[ -d "$REPO/Source" ] || fail "no Source tree at $REPO/Source"
[ -x "$NM" ] || fail "nm not executable at $NM"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/imageiodecode.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

# --- (a) CGImageSource construction, over the linked product ---------------------------------
find "$STAGED" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 > "$WORK/inventory"
BINCOUNT=$(tr '\0' '\n' < "$WORK/inventory" | grep -c . || true)
[ "$BINCOUNT" -gt 0 ] || fail "no binaries under $STAGED"

# -arch all: the frameworks ship fat, and nm reads only the host slice otherwise. nm prints a
# "<path>:" (or "<path> (for architecture X):") header ahead of each file's symbols, which is what
# attributes a finding to an image and to a slice.
#
# The i386 slice is skipped, and it is the one exclusion here. This port builds x86_64 only; the
# 32-bit slice is Apple's own 10.9 binary, grafted back in byte for byte so that a 32-bit app with a
# WebView still loads something (MavericksSupport/scripts/stage-frameworks.sh). It decodes in
# ImageIO because all of stock WebKit does, and none of it is this project's code to change. What
# the check therefore establishes is the property for the WebKit this port builds and Safari runs.
xargs -0 "$NM" -arch all -m < "$WORK/inventory" 2> "$WORK/nmerr" | awk '
    /^[^ \t].*:$/ {
        image = $0
        architecture = "x86_64"
        if (match(image, / \(for architecture [^)]*\):$/)) {
            architecture = substr(image, RSTART + 19, RLENGTH - 21)
            sub(/ \(for architecture .*\):$/, "", image)
        } else
            sub(/:$/, "", image)
        next
    }
    architecture == "i386" { next }
    /\(undefined\)/ {
        symbol = $NF
        for (i = 1; i <= NF; i++)
            if ($i ~ /^_CGImage(Source|Destination)/) symbol = $i
        if (symbol ~ /^_CGImageSourceCreateWith/ || symbol ~ /^_CGImageSourceCreateIncremental$/ || symbol ~ /^_CGImageSourceUpdateData/ \
            || symbol ~ /^_CGImageDestinationAddImageFromSource$/ || symbol ~ /^_CGImageDestinationCopyImageSource$/ \
            || symbol ~ /^_CGImageDestinationAddImageAndMetadata$/ || symbol ~ /^_CGImageDestinationAddAuxiliaryDataInfo$/)
            print image "\t" architecture "\t" symbol
    }
' | sort -u > "$WORK/sources"

if [ -s "$WORK/sources" ]; then
    echo "  ImageIO-decode check: FAILED -- these images can hand encoded image bytes to ImageIO:"
    sed "s|^$STAGED/|    |" "$WORK/sources"
    echo "  Decode through WebCore::ImageDecoder::create, and encode a decoded frame with"
    echo "  CGImageDestinationAddImage."
    exit 1
fi

# --- (b) the AppKit constructors that decode, over the source --------------------------------
# NSImage/NSImageRep take their bytes to ImageIO. Commented-out lines are skipped: a divergence
# keeps the upstream text in place (MavericksSupport/scripts/check-backport-markers.sh), and that
# text is not code. Source/ThirdParty is not ours.
grep -rnE "NS(Image|BitmapImageRep|ImageRep)[^]]*\] *(initWith(Data|ContentsOf|Pasteboard)|initByReferencing(File|URL))|NS(Image|BitmapImageRep|ImageRep)[^]]*(imageWithData|imageWithContentsOf|imageRepWithData|imageRepsWithData|imageRepWithContentsOf|imageRepsWithContentsOf)" \
    "$REPO/Source" --include=*.mm --include=*.m --include=*.h 2>/dev/null \
    | grep -v "^$REPO/Source/ThirdParty" \
    | grep -vE ":[0-9]+: *//" > "$WORK/appkit" || true

if [ -s "$WORK/appkit" ]; then
    echo "  ImageIO-decode check: FAILED -- these decode image bytes inside AppKit, which decodes in ImageIO:"
    sed "s|^$REPO/||" "$WORK/appkit" | sed 's/^/    /'
    echo "  Decode through WebCore::ImageDecoder::create and wrap the frame (NSBitmapImageRep initWithCGImage:)."
    exit 1
fi

# --- (c) a CGImageSource constructor reached by name, over first-party source ---------------------
# Every line either pattern can match contains the literal CGImageSource, so narrowing to the files
# that hold it cannot drop a match, and it is what keeps this half off 24k files it can never match.
CONSTRUCTOR='CGImageSource(CreateWith[A-Za-z]*|CreateIncremental|UpdateData[A-Za-z]*)'
RESOLVED='SOFT_LINK|dlsym|wk_polyfill_original|WK_ORIGINAL|WK_SYSTEM_FN|WK_POLYFILL_'
POLYFILL_SCOPE="$REPO/MavericksSupport/polyfill/polyfills $REPO/MavericksSupport/polyfill/mechanism"
SOURCE_SCOPE="$REPO/Source $REPO/MavericksSupport/source"

: > "$WORK/dynamic"

# The polyfill layer: naming a constructor at all is the finding.
if grep -rlF "CGImageSource" $POLYFILL_SCOPE > "$WORK/polyfill-files" 2>/dev/null && [ -s "$WORK/polyfill-files" ]; then
    xargs -I{} grep -nE "$CONSTRUCTOR" {} /dev/null < "$WORK/polyfill-files" 2>/dev/null \
        | grep -vE ":[0-9]+: *(//|\*)" >> "$WORK/dynamic" || true
fi

# Source trees: a constructor RESOLVED by name. Source/ThirdParty is not ours. Commented-out lines
# are skipped, because a divergence keeps the upstream text in place and that text is not code.
if grep -rlF "CGImageSource" $SOURCE_SCOPE --include=*.cpp --include=*.mm --include=*.m --include=*.h 2>/dev/null \
        | grep -v "^$REPO/Source/ThirdParty" > "$WORK/source-files" && [ -s "$WORK/source-files" ]; then
    xargs -I{} grep -nE "$CONSTRUCTOR" {} /dev/null < "$WORK/source-files" 2>/dev/null \
        | grep -E "$RESOLVED" \
        | grep -vE ":[0-9]+: *(//|\*)" >> "$WORK/dynamic" || true
fi

if [ -s "$WORK/dynamic" ]; then
    echo "  ImageIO-decode check: FAILED -- these reach a CGImageSource constructor by name:"
    sed "s|^$REPO/||" "$WORK/dynamic" | sed 's/^/    /'
    echo "  A name resolved at runtime emits no undefined symbol, so the binary scan above cannot see it."
    exit 1
fi

echo "  ImageIO-decode check: clean -- $BINCOUNT staged binaries construct no CGImageSource and encode"
echo "                        only decoded frames, in the slices this port builds;"
echo "                        no NSImage/NSImageRep in Source/ decodes bytes;"
echo "                        no first-party source reaches a CGImageSource constructor by name"
