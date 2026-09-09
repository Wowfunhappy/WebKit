#!/bin/bash
# Fail the build if anything in this port can hand image bytes to 10.9's ImageIO.
#
# The port decodes every image format in WebCore -- ScalableImageDecoder and the vendored libjpeg,
# libpng, libwebp, libavif, libtiff behind it -- so that a hostile image response is parsed by code
# that is still maintained rather than by a 2013 ImageIO. Reading the source is not proof of that:
# one CGImageSourceCreateWithData added later, anywhere, puts a page's bytes back inside ImageIO's
# codecs with nothing to say so.
#
# ImageIO is reachable two ways, and each needs its own measurement:
#
#   (a) DIRECTLY, through CGImageSource. An image cannot be decoded without one, and one cannot
#       exist without an entry point below, so no shipped binary may reference any of them. This is
#       measured over the linked product, which is the strongest form the question takes.
#
#   (b) THROUGH APPKIT. -[NSImage initWithData:] and its NSImageRep siblings parse their argument
#       inside ImageIO and leave no _CGImageSource* reference at all, so (a) cannot see them. They
#       are measured in the source instead -- the honest limit of this half: it reads Source/ for
#       the constructors that decode, not the binaries. Every spelling that takes bytes, a file, a
#       URL or a pasteboard is named, because the one that gets added later is the one nobody
#       thought to list.
#
# The two entry points the polyfill layer does define -- CGImageSourceCreateImageAtIndex and
# CGImageSourceCreateThumbnailAtIndex, which enforce CGImageSourceSetAllowableTypes -- are
# deliberately absent from (a). They take a source rather than bytes, they are reached through
# wk_polyfill_original's dynamic lookup rather than a link-time reference, and with no source
# constructible they have nothing to act on.
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

WORK="$(mktemp -d -t imageiodecode)"; trap 'rm -rf "$WORK"' EXIT

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
            if ($i ~ /^_CGImageSource/) symbol = $i
        if (symbol ~ /^_CGImageSourceCreateWith/ || symbol ~ /^_CGImageSourceCreateIncremental$/ || symbol ~ /^_CGImageSourceUpdateData/)
            print image "\t" architecture "\t" symbol
    }
' | sort -u > "$WORK/sources"

if [ -s "$WORK/sources" ]; then
    echo "  ImageIO-decode check: FAILED -- these images can construct a CGImageSource:"
    sed "s|^$STAGED/|    |" "$WORK/sources"
    echo "  Decode through WebCore::ImageDecoder::create instead."
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

echo "  ImageIO-decode check: clean -- $BINCOUNT staged binaries construct no CGImageSource in the"
echo "                        slices this port builds;"
echo "                        no NSImage/NSImageRep in Source/ decodes bytes"
