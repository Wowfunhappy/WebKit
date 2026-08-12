#!/bin/bash
# Fail the build if a shipped binary references a symbol that, at RUNTIME, nothing it links provides.
#
# This is the mirror image of polyfill/scripts/check-polyfill-shadows.sh. That gate asks "does the
# layer define something 10.9 already has?"; this one asks the question from the other side: "does
# WebKit reference something 10.9 does NOT have, and that the layer forgot to define?"
#
# It asks that question of two reference kinds. The first is a WEAK import of API 10.9 lacks (ADDR
# and CALL below); the second is a STRONG flat-namespace reference to a definition that was never
# compiled, which "-undefined dynamic_lookup" lets through the link (DYN, described at its sweep).
#
# The modern SDK marks post-10.9 API with availability, so clang WEAK-imports every such reference
# rather than failing the link. dyld then binds an absent weak symbol to address 0, and BOTH ways of
# using it are fatal:
#
#   ADDR   the generated code loads the GOT slot and dereferences it, so merely EVALUATING the
#          constant faults -- no call, no guard site, nothing at the crash address naming it.
#   CALL   the branch goes to address 0. Upstream soft-linking (`canLoad_X()` / `if (fn)`) exists for
#          exactly this, but a guard is something a call site has to actually DO; a __TEXT,__stubs
#          entry proves the symbol is CALLED, never that the call is protected.
#
# The ADDR half is not hypothetical. An undeclared AppKit appearance name reads like this in the
# generated code, and faults the moment its line runs:
#
#   AVOutputDeviceMenuControllerTargetPicker::showPlaybackTargetPicker+107   movq (%rax), %rdx
#                                                                           ^ %rax = 0, the GOT slot
#
# Nothing at the fault site names the symbol, and the line is an ARGUMENT expression -- not a call, not
# a guardable site. A gate is the only way to find this class before a user does: such a reference
# compiles clean, links clean, loads clean, and faults only when its line finally runs.
#
# PRESENCE IS PER-IMAGE, NOT GLOBAL. A symbol counts as provided for image B only if something in B's
# own load closure exports it. Scoring presence against the union of every Mach-O on the disk is wrong
# in the dangerous direction: WebKit2 weak-links Network, Metal and CryptoTokenKit and WebCore
# weak-links Metal -- none of which exist on 10.9 -- so a symbol whose name is exported by some
# framework B does NOT link would score present while dyld binds it to 0.
#
# Do NOT filter on nm's "(from X)" provider field as a presence test. In the STAGED binaries it is not
# the real owner: the system-framework reexport shim (scripts/reexport-shim.sh) makes ordinary AppKit
# and Foundation imports record their provider as libpolyfill_classes, so a filter that skips "our own"
# libraries by provider name silently drops real AppKit and Foundation findings.
#
# WHAT FAILS THE BUILD:
#
#   ADDR, always. Address-taken absent data has no guardable form -- there is no "check the constant
#   before reading it" idiom, the load is emitted inline at every use, and it faults every time.
#   Absent + address-taken is by itself a proof of a crash, so this half takes no judgement and has no
#   exemption mechanism.
#
#   CALL, whenever the referencing image links the polyfill archive -- regardless of whether the
#   owning dylib exists. Every CALL finding is by construction a DIRECT reference: soft-linking
#   (SoftLinking.h) resolves through dlsym and emits no link-time reference at all, so a soft-linked
#   symbol never appears as an undefined weak external. Proof in this tree: WebCore soft-links
#   VTRegisterSupplementalVideoDecoderIfAvailable and `nm -m` returns nine symbols for it, every one a
#   DEFINITION and none undefined. So there is no soft-link probe for a gap-fill to flip, and no
#   version of "but the call site might guard it" that survives contact with the symbol table.
#
# WHAT IS INVENTORY ONLY (printed every build, to be checked, never silently dropped): exactly one
# case -- a referencing image that does NOT carry __wk_pfmap, because no polyfill entry could ever
# satisfy it. The bundled GStreamer plugins are that case: libgstapplemedia references
# VTRegisterSupplementalVideoDecoderIfAvailable and guards it with __builtin_available, and libcrypto,
# libglib and libgstreamer reference __darwin_check_fd_set_overflow behind Apple's own SDK
# null-address guard.
#
# TWO TEMPTING SPLITS ARE WRONG, AND BOTH ARE EXEMPTION MECHANISMS IN MECHANICAL DISGUISE. "Owning
# dylib is present on 10.9" reads as a proxy for "a gap-fill could flip a soft-link probe", but it
# excuses Security functions WebTransport calls directly, with no probe anywhere. "Does the image
# contain the symbol name as a __TEXT,__cstring literal" is worse: SoftLinking.h stores its dlsym name
# in __TEXT,__dlsym_cstr, never __cstring, while WK_PF_ENTRY stores every polyfilled symbol's own name
# as a plain C literal -- so that test matches the layer's own registry, and its only other achievable
# "yes" is incidental text such as a RELEASE_LOG_ERROR format string naming the function.
#
# There is deliberately NO allow file. A prose claim that some path "provably never executes" is
# exactly the thing that goes stale.
# "WebTransport is preference-gated off" names a user-writable default (WebPreferencesCocoa.mm applies
# persisted WebKit-prefixed values from NSGlobalDomain), not a proof; "the WebAuthn platform
# authenticator is filtered out by LocalService::isAvailable()" is bypassed entirely by
# VirtualAuthenticatorManager::filterTransports(), which overrides it to do nothing and hands the REAL
# LocalAuthenticator a VirtualLocalConnection. A gate with a prose off-switch is not a gate. The fix
# for a finding is a declaration in the polyfill layer:
#
#   ADDR   WK_POLYFILL_CONST in polyfill/polyfills/constants.m.
#   CALL   WK_POLYFILL_ABSENT in the matching polyfills/*.c|m -- either implemented over a 10.9
#          primitive that satisfies the modern contract, or returning the modern API's documented
#          FAILURE shape so callers take their own error path. A failing stub for a capability the OS
#          does not have is honest; a stub that invents a SUCCESS value is not.
#
# Objective-C class references (_OBJC_CLASS_$_/_OBJC_METACLASS_$_) are EXCLUDED by construction: an
# absent class reference binds to 0 and `[AbsentClass message]` is a message to nil, which the runtime
# defines as returning zero. They cannot fault the way a data load or a call does. (A class 10.9 lacks
# whose *instances* WebKit needs is a different problem, and classes.m's business.)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # MavericksSupport/scripts
REPO="$(cd "$HERE/../.." && pwd)"                                # repo root
STAGED="${1:-$REPO/WebKitBuild/Release/staged}"
NM=/Library/Developer/CommandLineTools/usr/bin/nm

# A check that cannot run must FAIL, never pass quietly. Without these guards a broken $NM or a missing
# staged tree reaches the "clean -- N staged binaries" line without a single binary having been read,
# which is an invented success about whether the audit happened at all.
[ -d "$STAGED" ] || { echo "  absent-reference check: FAILED -- no staged tree at $STAGED"; exit 1; }
[ -x "$NM" ] || { echo "  absent-reference check: FAILED -- nm not executable at $NM"; exit 1; }
command -v otool >/dev/null || { echo "  absent-reference check: FAILED -- otool not found"; exit 1; }

WORK="$(mktemp -d -t absentrefs)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/exp"

# Collapse `file` output to real paths. The per-architecture lines read
#   /path (for architecture x86_64):<TAB>Mach-O 64-bit ...
# so stripping only at the first colon manufactures the nonexistent path "/path (for architecture
# x86_64)" -- which silently drops the binary from the scan if the universal-summary line ever stops
# being emitted. Strip the architecture parenthetical FIRST, then the colon.
machos() {
    xargs -0 file 2>/dev/null \
      | grep "Mach-O" \
      | sed -e 's/ (for architecture [^)]*)//' -e 's/:.*//' \
      | sort -u
}

# An install path as recorded in a load command -> a file to read. The staged tree's copy WINS: the
# WebKit frameworks record absolute /System/... paths (stage-frameworks.sh rewrites @rpath away for
# them), so without this mapping the gate reads the frameworks currently installed on the system
# rather than the ones just built. The bundled GStreamer libraries keep @rpath/@loader_path deps, which must be resolved
# too: unresolved, their libc++abi dependency disappears and every `operator new`/`operator delete`
# they import is reported as missing.
resolve_dep() {
    case "$1" in
      @loader_path/*|@executable_path/*)
          local rel="${1#@*path/}"
          [ -n "${2:-}" ] && [ -e "$2/$rel" ] && { echo "$2/$rel"; return; }
          ;;
      @rpath/*)
          # LC_RPATH search paths are themselves @loader_path-relative here, so resolve by basename
          # against everything the bundle ships -- an in-bundle library is what @rpath means.
          # awk with an exact string compare, NOT grep: these basenames contain regex metacharacters
          # ("libc++abi.1.dylib"), and a pattern-based lookup silently misses them -- which loses
          # libc++'s libc++abi dependency and reports every operator new/delete it imports as absent.
          local leaf; leaf=$(basename "$1")
          local hit; hit=$(awk -F'|' -v n="$leaf" '$1 == n { print $2; exit }' "$WORK/byname" 2>/dev/null)
          [ -n "$hit" ] && { echo "$hit"; return; }
          ;;
    esac
    if [ -e "$STAGED$1" ]; then echo "$STAGED$1"; elif [ -e "$1" ]; then echo "$1"; fi
}

# Everything a dylib vends, following LC_REEXPORT_DYLIB transitively -- that is how dyld satisfies a
# two-level reference recorded against an umbrella (ApplicationServices, CoreServices) or against the
# reexport shim. Memoized: the same handful of system frameworks appear in almost every closure.
# ALL architectures, deliberately: -arch x86_64 would leave every i386 slice unchecked.
exports_of() {
    local path="$1" seen="$2" key cache
    key=$(echo "$path" | /usr/bin/openssl md5 | sed 's/.*= *//')
    cache="$WORK/exp/$key"
    [ -f "$cache" ] && { cat "$cache"; return; }
    : > "$cache"                                  # publish early: breaks reexport cycles
    case ":$seen:" in *":$key:"*) return ;; esac
    {
        "$NM" -gU "$path" 2>/dev/null | awk '$2 ~ /^[TDSBIRC]$/ { print $3 }'
        otool -l "$path" 2>/dev/null | awk '/LC_REEXPORT_DYLIB/ { r=1; next } r && /name /{ print $2; r=0 }' \
          | while IFS= read -r re; do
                rp=$(resolve_dep "$re" "$(dirname "$path")"); [ -n "$rp" ] && exports_of "$rp" "$seen:$key"
            done
    } | sort -u > "$cache"
    cat "$cache"
}

# ---------------------------------------------------------------------------------------------------
# Every shipped Mach-O: frameworks, XPC services, daemons and the bundled dylibs. A crash in a
# WebContent service is a crash the user sees, so the services are in scope like the frameworks.
#
# The .dylib/.so patterns are NOT redundant with -perm -u+x. stage-frameworks.sh installs the in-bundle
# libraries mode 644, so an executables-only sweep misses libc++, libpolyfill_classes and every
# GStreamer plugin -- and then their EXPORTS are invisible too, which made libc++'s iostream vtables
# and the whole UTType* object-constant set look missing.
# ---------------------------------------------------------------------------------------------------
{ find "$STAGED" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null \
  | machos > "$WORK/binaries"; } || true

BINCOUNT=$(wc -l < "$WORK/binaries" | tr -d ' ')
[ "$BINCOUNT" -gt 0 ] || { echo "  absent-reference check: FAILED -- no Mach-O binaries under $STAGED"; exit 1; }

# basename -> path, so an @rpath dependency can be resolved to the copy the bundle actually ships.
while IFS= read -r b; do printf '%s|%s\n' "$(basename "$b")" "$b"; done < "$WORK/binaries" > "$WORK/byname"

: > "$WORK/findings"
while IFS= read -r bin; do
    # What this image can actually bind against: the union of its direct dependencies' exports
    # (each followed through its own reexports). Not the whole disk -- see the header.
    { otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{ print $1 }' \
        | while IFS= read -r dep; do
              dp=$(resolve_dep "$dep" "$(dirname "$bin")"); [ -n "$dp" ] && exports_of "$dp" ""
          done | sort -u > "$WORK/bindable"; } || true

    { otool -Iv "$bin" 2>/dev/null \
      | awk '/^Indirect symbols for/ { inblk = /__TEXT,__stubs/; next } inblk && NF >= 3 { print $3 }' \
      | sort -u > "$WORK/stubs"; } || true

    # ALL architectures: the frameworks ship fat x86_64+i386, and an -arch x86_64 sweep would never
    # look at an i386 slice.
    "$NM" -m "$bin" >/dev/null 2>&1 || { echo "  absent-reference check: FAILED -- nm could not read $bin"; exit 1; }
    { "$NM" -m "$bin" 2>/dev/null \
      | sed -n 's/.*(undefined) weak external \([^ ]*\).*/\1/p' \
      | sort -u \
      | while read -r sym; do
            case "$sym" in _OBJC_CLASS_\$_*|_OBJC_METACLASS_\$_*) continue ;; esac
            if grep -qxF "$sym" "$WORK/bindable"; then continue; fi
            if grep -qxF "$sym" "$WORK/stubs"; then kind=CALL; else kind=ADDR; fi
            echo "$kind|$sym|${bin#$STAGED}"
        done >> "$WORK/findings"; } || true

    # DYN, the other half of "references something nothing provides": a STRONG flat-namespace
    # reference. WebCore links with "-undefined dynamic_lookup" (Source/WebCore/CMakeLists.txt), so a
    # call to a definition that never got compiled -- an upstream TU a source-list seam withholds, or
    # one upstream builds only from its Xcode project -- survives the link as an undefined flat symbol
    # instead of failing it. Nothing reports it until a client binds the image eagerly, and then dyld
    # refuses to load that client outright: an iWork QuickLook generator, hard-bound against WebKit,
    # dies with "Symbol not found ... Expected in: flat namespace" and its previews stop working.
    #
    # These carry no presence test, because there is nothing to score them against: flat lookup
    # searches the images loaded in the CLIENT process at bind time, which is neither this image's
    # link closure nor the bundle. Scoring them against the union of what the bundle exports is the
    # global-presence mistake the header rejects, one slice and one lazily-dlopened plugin wide -- a
    # name some unrelated staged image happens to export would pass while dyld aborts the client.
    { "$NM" -m "$bin" 2>/dev/null \
      | sed -n 's/.*(undefined) external \([^ ]*\) (dynamically looked up).*/\1/p' \
      | sort -u \
      | while read -r sym; do echo "DYN|$sym|${bin#$STAGED}"; done >> "$WORK/findings"; } || true
done < "$WORK/binaries"

sort -u "$WORK/findings" -o "$WORK/findings"

# Everything is fatal unless the exact (kind, symbol, image basename) triple is PINNED below. The pin
# is a closed set, not an allow list: it carries no reason field and makes no claim about whether
# anything executes, so it cannot absorb a new finding the way prose can. Anything not on it fails the
# build.
#
# KIND is part of the key because a pin justified for one reference kind does not license another. The
# entries below rest on a guard around a WEAK call; the same symbol referenced strongly from the flat
# namespace is a hard dyld load failure that no call-site guard can survive, so it must not inherit
# their pin.
#
# Note what the pin deliberately does NOT key on. "The image does not carry __wk_pfmap" reads as a
# proxy for "no polyfill could reach it", but it also covers this project's OWN binaries that happen
# not to force-load the archive -- webpushd, a user-facing daemon built against the 26.1 SDK, and
# libpolyfill_classes.dylib -- so an absent call from either would print and pass.
#
# The pinned entries are all vendored third-party images that cannot link the polyfill archive, and
# each is guarded at its own call site, verified by disassembly: libgstapplemedia guards
# VTRegisterSupplementalVideoDecoderIfAvailable with __builtin_available, and libcrypto/libglib/
# libgstreamer reach __darwin_check_fd_set_overflow through Apple's own SDK null-address test inside
# FD_SET. Verify the same before ever adding a line here.
cat > "$WORK/pinned" <<'PINNED'
CALL _VTRegisterSupplementalVideoDecoderIfAvailable libgstapplemedia.dylib
CALL ___darwin_check_fd_set_overflow libcrypto.3.dylib
CALL ___darwin_check_fd_set_overflow libglib-2.0.0.dylib
CALL ___darwin_check_fd_set_overflow libgstreamer-1.0.0.dylib
PINNED

: > "$WORK/fatal"; : > "$WORK/pinnedhit"
while IFS='|' read -r kind sym image; do
    [ -n "$kind" ] || continue
    line="$kind|$sym|$image"
    if awk -v k="$kind" -v s="$sym" -v b="$(basename "$image")" '$1 == k && $2 == s && $3 == b { found = 1 } END { exit !found }' "$WORK/pinned"; then
        echo "$line" >> "$WORK/pinnedhit"
    else
        echo "$line" >> "$WORK/fatal"
    fi
done < "$WORK/findings"

show() { awk -F'|' '{ printf "      %-52s %s\n", $2, $3 }' "$1" | sort -u; }

{ grep -v '^DYN|' "$WORK/fatal" > "$WORK/fatalweak"; } || true
{ grep '^DYN|' "$WORK/fatal" > "$WORK/fataldyn"; } || true

if [ -s "$WORK/fatalweak" ]; then
    echo "  absent-reference check: FAILED"
    echo "    Nothing this 10.9 host provides and nothing in the bundle exports these, yet a shipped"
    echo "    binary references them. dyld binds each to address 0: an ADDR reference faults when the"
    echo "    line is evaluated, a CALL reference branches to 0. Soft-linking emits no undefined symbol,"
    echo "    so every CALL here is a DIRECT reference. Declare each in the polyfill layer --"
    echo "    WK_POLYFILL_CONST for ADDR, WK_POLYFILL_ABSENT returning the modern API's documented"
    echo "    failure shape for CALL."
    echo
    show "$WORK/fatalweak"
fi

if [ -s "$WORK/fataldyn" ]; then
    echo "  absent-reference check: FAILED"
    echo "    A shipped binary carries a strong flat-namespace reference. Every client that binds the"
    echo "    image eagerly -- dlopen RTLD_NOW, or a hard-bound plug-in such as a QuickLook generator --"
    echo "    fails to load outright. Compile the defining translation unit (WebCore_SOURCES in"
    echo "    MavericksSupport/cmake/WebCorePlatformMavericks.cmake carries the ones upstream builds"
    echo "    only from WebCore.xcodeproj), or stop compiling the caller when the port selects a"
    echo "    different backend for it."
    echo
    show "$WORK/fataldyn"
fi

if [ -s "$WORK/fatal" ]; then exit 1; fi

echo "  absent-reference check: clean -- $BINCOUNT staged binaries, per-image link closures, all slices"
echo "    ($(grep -c '^DYN|' "$WORK/pinnedhit" || true) pinned flat-namespace reference(s), $(grep -vc '^DYN|' "$WORK/pinnedhit" || true) pinned third-party weak reference(s))"
