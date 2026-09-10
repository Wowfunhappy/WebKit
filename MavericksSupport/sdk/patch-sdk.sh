#!/bin/bash
# patch-sdk.sh — the two edits the build needs in the macOS SDK. Idempotent and reversible (each edited
# file keeps a *.pre-*-bak twin); re-run after re-extracting the SDK. bootstrap.sh runs it.
#
# 1. Re-home symbols: delete named symbols from the SDK's text-based stubs so the linker binds them
#    where the 10.9 runtime provides them — the URL-loading symbols leave CFNetwork.tbd (10.9 exports
#    them from Foundation), the LaunchServices classes leave CoreServices.tbd (the polyfill defines
#    them). Two-level namespace stays intact. Every .tbd copy under the framework dir is patched (the
#    SDK duplicates them across top-level / Versions/A / Versions/Current and nests sub-framework tbds).
# 2. Availability: mark the iOS-only AVFoundation classes WebKit soft-links (SOFT_LINK_CLASS_FOR_HEADER
#    emits an inline returning `<Class>*`) as declarable on macOS, by turning API_UNAVAILABLE(macos) into
#    API_AVAILABLE(macos(10.9)) on the attribute line preceding `@interface <Class>` — the class only,
#    never its members, so the deployment-target availability net stays active. Every physical copy of
#    the header is patched (AVFAudio is embedded in AVFoundation and duplicated under Versions/A).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # MavericksSupport/sdk
REPO="$(cd "$HERE/../.." && pwd)"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
[ -f "$SDK/SDKSettings.plist" ] || { echo "ERROR: no SDK at $SDK (place MacOSX26.1.sdk beside the checkout or set MAVERICKS_SDK)" >&2; exit 1; }
CLANG="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}/bin/clang"
PYTHON3="$REPO/MavericksSupport/toolchain/build/python3/bin/python3"   # 10.9 ships only python 2.7

# --- 1. re-home -------------------------------------------------------------------------------------
remove_syms() {  # $1 = symbol-list file; $2.. = tbd files
    local syms="$1"; shift
    [ -f "$syms" ] || { echo "ERROR: $syms not found" >&2; exit 1; }
    [ $# -gt 0 ] || { echo "ERROR: no .tbd files found for $(basename "$syms") under $SDK" >&2; exit 1; }
    for TBD in "$@"; do
        [ -f "$TBD" ] || { echo "ERROR: $TBD not found" >&2; exit 1; }
        if [ -f "$TBD.pre-rehome-bak" ]; then cp "$TBD.pre-rehome-bak" "$TBD"; else cp "$TBD" "$TBD.pre-rehome-bak"; fi
        "$PYTHON3" - "$TBD" "$syms" <<'PY'
import sys, re
tbd, symspath = sys.argv[1], sys.argv[2]
classes, consts = set(), set()
for line in open(symspath):
    s = line.strip()
    if not s: continue
    if s.startswith('_OBJC_CLASS_$_'):      classes.add(s[len('_OBJC_CLASS_$_'):])
    elif s.startswith('_OBJC_METACLASS_$_'): classes.add(s[len('_OBJC_METACLASS_$_'):])
    else: consts.add(s)
t = open(tbd).read(); removed = 0
for c in sorted(classes, key=len, reverse=True):
    t, n = re.subn(r'\b%s\b,?[ \t]*' % re.escape(c), '', t); removed += n
for c in sorted(consts, key=len, reverse=True):
    t, n = re.subn(r"'?%s'?,?[ \t]*" % re.escape(c), '', t); removed += n
open(tbd, 'w').write(t)
if removed:
    print("  %s: removed %d class + %d const (%d hits)" % (tbd.split('Frameworks/')[-1], len(classes), len(consts), removed))
PY
    done
}
echo "### CFNetwork URL-loading symbols -> Foundation"
remove_syms "$HERE/cfnetwork-rehome-symbols.txt" \
    $(find "$SDK/System/Library/Frameworks/CFNetwork.framework" -name '*.tbd' ! -name '*.pre-rehome-bak')
echo "### CoreServices/LaunchServices polyfill classes -> the polyfill"
remove_syms "$HERE/coreservices-rehome-symbols.txt" \
    $(find "$SDK/System/Library/Frameworks/CoreServices.framework" -name '*.tbd' ! -name '*.pre-rehome-bak')

# --- 2. availability ----------------------------------------------------------------------------------
patch_class() {  # $1 = class, $2 = header basename
    local cls="$1" base="$2" found=0 patched=0 hdr
    while IFS= read -r hdr; do
        grep -q "@interface $cls\b" "$hdr" 2>/dev/null || continue
        found=$((found+1))
        if [ -f "$hdr.pre-availability-bak" ]; then cp "$hdr.pre-availability-bak" "$hdr"; else cp "$hdr" "$hdr.pre-availability-bak"; fi
        CLS="$cls" perl -0777 -i -pe 's/API_UNAVAILABLE\(macos\)([^\n]*\n\@interface \Q$ENV{CLS}\E\s*:)/API_AVAILABLE(macos(10.9))$1/g' "$hdr"
        if CLS="$cls" perl -0777 -ne 'exit(/API_AVAILABLE\(macos\(10\.9\)\)[^\n]*\n\@interface \Q$ENV{CLS}\E\s*:/ ? 0 : 1)' "$hdr"; then
            patched=$((patched+1))
        else
            echo "ERROR: $cls @interface in $hdr not macOS-available after patch" >&2; exit 1
        fi
    done < <(find "$SDK" -name "$base" ! -name "*.bak" -type f 2>/dev/null)
    [ "$found" -gt 0 ] || { echo "ERROR: no files containing '@interface $cls' found for $base under $SDK" >&2; exit 1; }
    echo "  patched $cls in $patched/$found copy(ies) of $base"
}
echo "### iOS-only soft-linked AVFoundation classes -> declarable on macOS"
patch_class AVAudioSession AVAudioSession.h

echo "### self-test"
T="$(mktemp -d "${TMPDIR:-/tmp}/sdkpatch.XXXXXX")"; trap 'rm -rf "$T"' EXIT
FL="-x objective-c++ -fno-modules -fno-cxx-modules -isysroot $SDK -mmacosx-version-min=10.9 -fsyntax-only"
# The soft-link shape compiles through the umbrella include WebKit uses (which resolves to the embedded
# AVFAudio copy).
printf '#import <AVFoundation/AVFoundation.h>\n@class AVAudioSession;\nnamespace P{ inline AVAudioSession* a(Class c){return [c alloc];} }\n' > "$T/sl.mm"
"$CLANG" $FL "$T/sl.mm" 2>"$T/e1" || { echo "  FAIL: iOS-only soft-link type does not compile on macOS:"; cat "$T/e1"; exit 1; }
# Members keep API_UNAVAILABLE(macos): only the class line changed.
avhdr="$SDK/System/Library/Frameworks/AVFoundation.framework/Versions/Current/Frameworks/AVFAudio.framework/Headers/AVAudioSession.h"
[ "$(grep -c 'API_UNAVAILABLE(macos)' "$avhdr")" -gt 0 ] || { echo "  FAIL: AVAudioSession.h lost its member-level API_UNAVAILABLE(macos)"; exit 1; }
echo "### done"
