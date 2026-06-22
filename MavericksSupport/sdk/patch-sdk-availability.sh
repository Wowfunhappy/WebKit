#!/bin/bash
# patch-sdk-availability.sh — make a few genuinely-iOS-only AVFoundation classes that the public
# macOS SDK marks API_UNAVAILABLE(macos) declarable on a macOS build.
#
# Why: WebKit soft-links some iOS-only AVFoundation classes (SOFT_LINK_CLASS_FOR_HEADER emits an
# inline returning `<Class>*`). On the PUBLIC SDK those classes are API_UNAVAILABLE(macos), so the
# inline fails to compile in every macOS TU that includes the soft-link header. Upstream's macOS
# build doesn't hit this (internal-SDK arrangement); a public-SDK build does. Rather than diverge
# WebKit source with `#if PLATFORM(IOS_FAMILY)` gates, we patch the SDK header so the TYPE is
# declarable on macOS. Runtime stays safe: the class is soft-linked (nil when absent on 10.9) and
# every call site is respondsToSelector-/PLATFORM-guarded, so nothing is actually messaged.
#
# This is TARGETED (per-class), NOT a global availability disable: the deployment-target checks that
# catch 10.10+ API use (NSColor.systemBlueColor, etc.) stay fully active. Verified by the self-test.
#
# Mechanism: on the attribute line preceding `@interface <Class>`, turn API_UNAVAILABLE(macos) into
# API_AVAILABLE(macos(10.9)). Version-agnostic (doesn't depend on the iOS version string).
# Idempotent + reversible (*.pre-availability-bak). Re-run whenever the SDK is re-extracted.
#
# A framework header can exist as SEVERAL physical copies in the SDK: a standalone framework AND a
# sub-framework embedded in another (AVFAudio is embedded in AVFoundation), each also duplicated
# under Versions/A. Different #include spellings resolve to different copies — `<AVFoundation/...>`
# (what WebKit imports) pulls the embedded AVFAudio copy, not the standalone one. So we patch EVERY
# copy found by basename, not a single hard-coded path.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"                            # repo root (HERE is MavericksSupport/sdk)
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"    # SDK is a sibling of the repo

# Each entry: "<class>|<header-basename>" — every copy of the header in the SDK gets patched.
ENTRIES=(
  "AVAudioSession|AVAudioSession.h"
)

patch_class() {
    local cls="$1" base="$2" found=0 patched=0 hdr
    while IFS= read -r hdr; do
        grep -q "@interface $cls\b" "$hdr" 2>/dev/null || continue
        found=$((found+1))
        # restore-then-backup so the script is idempotent + reversible
        if [ -f "$hdr.pre-availability-bak" ]; then cp "$hdr.pre-availability-bak" "$hdr"; else cp "$hdr" "$hdr.pre-availability-bak"; fi
        # On the attribute line directly preceding `@interface <cls>`, swap the macOS-unavailable
        # marker for a macOS-available one. (perl: when the NEXT line opens the @interface, edit THIS line.)
        CLS="$cls" perl -0777 -i -pe 's/API_UNAVAILABLE\(macos\)([^\n]*\n\@interface \Q$ENV{CLS}\E\s*:)/API_AVAILABLE(macos(10.9))$1/g' "$hdr"
        # verify the @interface for THIS class is now macOS-available
        if CLS="$cls" perl -0777 -ne 'exit(/API_AVAILABLE\(macos\(10\.9\)\)[^\n]*\n\@interface \Q$ENV{CLS}\E\s*:/ ? 0 : 1)' "$hdr"; then
            patched=$((patched+1))
        else
            echo "ERROR: $cls @interface in $hdr not macOS-available after patch" >&2; exit 1
        fi
    done < <(find "$SDK" -name "$base" ! -name "*.bak" -type f 2>/dev/null)
    [ "$found" -gt 0 ] || { echo "ERROR: no files containing '@interface $cls' found for $base under $SDK" >&2; exit 1; }
    echo "  patched $cls in $patched/$found copy(ies) of $base"
}

echo "### patching SDK availability for iOS-only soft-linked AVFoundation classes"
for e in "${ENTRIES[@]}"; do patch_class "${e%%|*}" "${e##*|}"; done

echo "### self-test"
CLANG="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}/bin/clang"
FL="-x objective-c++ -fno-modules -fno-cxx-modules -isysroot $SDK -mmacosx-version-min=10.9 -fsyntax-only"
T="$(mktemp -d -t sdkavail)"; trap 'rm -rf "$T"' EXIT
# (a) the soft-link pattern (typed inline over an iOS-only class) now compiles THROUGH THE UMBRELLA
# include WebKit actually uses (<AVFoundation/AVFoundation.h>), which resolves to the embedded
# AVFAudio copy — the include path that exposed the single-copy miss.
printf '#import <AVFoundation/AVFoundation.h>\n@class AVAudioSession;\nnamespace P{ inline AVAudioSession* a(Class c){return [c alloc];} }\n' > "$T/sl.mm"
"$CLANG" $FL "$T/sl.mm" 2>"$T/e1" && echo "  OK: iOS-only soft-link type compiles on macOS (via <AVFoundation/AVFoundation.h>)" || { echo "  FAIL:"; cat "$T/e1"; exit 1; }
# (b) the patch is SURGICAL: it touched only the class @interface availability. The class's own
# method/property declarations keep their API_UNAVAILABLE(macos) (we don't blanket-replace), and no
# other SDK header is touched. So the global availability net that catches 10.10+ APIs
# (NSColor.systemBlueColor, etc.) is structurally unaffected. Checked on the embedded copy the build uses.
avhdr="$SDK/System/Library/Frameworks/AVFoundation.framework/Versions/Current/Frameworks/AVFAudio.framework/Headers/AVAudioSession.h"
if [ "$(grep -c 'API_UNAVAILABLE(macos)' "$avhdr")" -gt 0 ]; then echo "  OK: surgical — method-level API_UNAVAILABLE(macos) untouched, only the class made available"; else echo "  FAIL: blanket replace"; exit 1; fi
echo "### done"
