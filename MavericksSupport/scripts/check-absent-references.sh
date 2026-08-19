#!/bin/bash
# Fail the build if a shipped binary references a symbol that, at RUNTIME, nothing it links provides.
# The mirror image of the shadow gate in polyfill/build-polyfill.sh: that one asks "does the layer
# define something 10.9 already has?"; this one asks "does WebKit reference something 10.9 does NOT
# have that the layer forgot to define?"
#
# The modern SDK marks post-10.9 API with availability, so clang WEAK-imports every such reference; dyld
# binds an absent weak symbol to 0, and both uses are fatal with nothing at the fault site naming the
# symbol. Three reference kinds are scored, per image (a symbol counts as provided for image B only if
# something in B's own load closure exports it -- WebKit2 weak-links Network/Metal/CryptoTokenKit, none
# of which exist on 10.9):
#
#   ADDR   a data constant: the generated code loads the GOT slot and dereferences it inline, so merely
#          EVALUATING the constant faults. Always fails the build; there is no guardable form.
#   CALL   a function: the branch goes to address 0. Every CALL finding is a DIRECT reference (soft-linking
#          resolves through dlsym and emits no link-time reference), so there is no probe a gap-fill could
#          flip. Fails whenever the referencing image links the polyfill archive.
#   DYN    a strong flat-namespace reference "-undefined dynamic_lookup" let through the link to a
#          definition that was never compiled (see its sweep below).
#
# The fix for a finding is a declaration in the polyfill layer: WK_POLYFILL_CONST for ADDR; WK_POLYFILL_ABSENT
# for CALL, implemented over a 10.9 primitive or returning the modern API's documented FAILURE shape (a stub
# that invents a SUCCESS value is not honest). There is no allow file: a prose claim that a path "never
# executes" is exactly what goes stale.
#
# Inventory only (printed, never dropped): a referencing image that does NOT carry __wk_pfmap, because no
# polyfill entry can satisfy it -- the bundled GStreamer plugins (libgstapplemedia references
# VTRegisterSupplementalVideoDecoderIfAvailable behind __builtin_available; libglib/libgstreamer reference
# __darwin_check_fd_set_overflow behind the SDK's own null guard).
#
# ObjC class references (_OBJC_CLASS_$_/_OBJC_METACLASS_$_) are excluded by construction: an absent class
# binds to 0 and a message to nil returns zero, so they cannot fault this way (a class 10.9 lacks whose
# instances WebKit needs is polyfills/classes/'s business).
#
# Do NOT filter on nm's "(from X)" provider field: in the STAGED binaries the reexport shim makes ordinary
# AppKit and Foundation imports record their provider as libpolyfill_classes.
set -euo pipefail
export LC_ALL=C   # sort and comm below must agree on ordering, and every symbol name is ASCII

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # MavericksSupport/scripts
REPO="$(cd "$HERE/../.." && pwd)"                                # repo root
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
STAGED="${1:-$REPO/WebKitBuild/Release/staged}"
NM=/Library/Developer/CommandLineTools/usr/bin/nm

# A check that cannot run must FAIL, never pass quietly. Without these guards a broken $NM or a missing
# staged tree reaches the "clean -- N staged binaries" line without a single binary having been read,
# which is an invented success about whether the audit happened at all.
[ -d "$STAGED" ] || { echo "  absent-reference check: FAILED -- no staged tree at $STAGED"; exit 1; }
[ -x "$NM" ] || { echo "  absent-reference check: FAILED -- nm not executable at $NM"; exit 1; }
command -v otool >/dev/null || { echo "  absent-reference check: FAILED -- otool not found"; exit 1; }

# The sweep runs one worker process per image (see the driver at the bottom), and they share this
# directory: the memoized export caches, the binary inventory, and each worker's findings file all
# live in it. A worker is handed it in WK_ABSENTREF_WORK and must not delete it.
if [ -n "${WK_ABSENTREF_WORK:-}" ]; then
    WORK="$WK_ABSENTREF_WORK"
else
    WORK="$(mktemp -d -t absentrefs)"; trap 'rm -rf "$WORK"' EXIT
    mkdir -p "$WORK/exp" "$WORK/found"
fi

# Collapse `file` output to real paths. The per-architecture lines read
#   /path (for architecture x86_64):<TAB>Mach-O 64-bit ...
# so stripping only at the first colon manufactures the nonexistent path "/path (for architecture
# x86_64)" -- which silently drops the binary from the scan if the universal-summary line ever stops
# being emitted. Strip the architecture parenthetical FIRST, then the colon.
machos() {
    # grep's status-1 means "this tree holds no Mach-O", which the count at the call site reports;
    # every other status here fails the check.
    xargs -0 file \
      | { grep "Mach-O" || [ "$?" -eq 1 ]; } \
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
# reexport shim. Memoized in the shared work directory, so the same handful of system frameworks is
# read once for the whole run however many workers want it: the cache is written to a per-process
# temporary and published by rename, which is atomic, so a concurrent reader sees either the complete
# export set or no file at all. The $seen chain breaks reexport cycles.
# ALL architectures, deliberately: -arch x86_64 would leave every i386 slice unchecked.
exports_of() {
    local path="$1" seen="$2" key cache
    key=$(echo "$path" | /usr/bin/openssl md5 | sed 's/.*= *//')
    cache="$WORK/exp/$key"
    [ -f "$cache" ] && { cat "$cache"; return; }
    case ":$seen:" in *":$key:"*) return ;; esac
    {
        "$NM" -gU "$path" 2>/dev/null | awk '$2 ~ /^[TDSBIRC]$/ { print $3 }'
        otool -l "$path" 2>/dev/null | awk '/LC_REEXPORT_DYLIB/ { r=1; next } r && /name /{ print $2; r=0 }' \
          | while IFS= read -r re; do
                rp=$(resolve_dep "$re" "$(dirname "$path")"); [ -n "$rp" ] && exports_of "$rp" "$seen:$key"
            done
    } | sort -u > "$cache.$$"
    mv -f "$cache.$$" "$cache"
    cat "$cache"
}

# One image's sweep. Both undefined-symbol kinds come out of a single `nm -m` read, and the link
# closure -- by far the most expensive thing here, since it reads every dependency's whole export
# table -- is built only for an image that actually carries a weak undefined reference. Findings go to
# a per-image file in the shared work directory, which is what lets the driver run these concurrently.
scan_one() {
    local bin="$1" tag
    tag=$(echo "$bin" | /usr/bin/openssl md5 | sed 's/.*= *//')
    # The findings file is published by rename, so it exists only for an image that was swept all the
    # way through. A worker killed mid-sweep (a signal, an out-of-memory kill) leaves none, and the
    # driver's count below turns that into a failed check rather than a short clean run.
    : > "$WORK/partial.$tag"
    scan_image "$bin" "$WORK/partial.$tag" || return
    mv -f "$WORK/partial.$tag" "$WORK/found/$tag"
}

scan_image() {
    local bin="$1" out="$2" syms weak bindable missing stubs kind sym tag
    tag=$(echo "$bin" | /usr/bin/openssl md5 | sed 's/.*= *//')

    # ALL architectures: the frameworks ship fat x86_64+i386, and an -arch x86_64 sweep would never
    # look at an i386 slice. This one read serves both sweeps below, and its exit status is the
    # image's readability check.
    syms="$WORK/nm.$tag"
    "$NM" -m "$bin" > "$syms" 2>/dev/null || {
        echo "  absent-reference check: FAILED -- nm could not read $bin"; : > "$WORK/error"; return 1; }

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
    sed -n 's/.*(undefined) external \([^ ]*\) (dynamically looked up).*/\1/p' "$syms" | sort -u \
      | while read -r sym; do echo "DYN|$sym|${bin#$STAGED}"; done >> "$out"

    weak="$WORK/weak.$tag"
    sed -n 's/.*(undefined) weak external \([^ ]*\).*/\1/p' "$syms" \
      | awk '!/^_OBJC_(META)?CLASS_\$_/' | sort -u > "$weak"
    rm -f "$syms"
    [ -s "$weak" ] || { rm -f "$weak"; return; }

    # What this image can actually bind against: the union of its direct dependencies' exports
    # (each followed through its own reexports). Not the whole disk -- see the header. Reached only
    # by an image that carries a weak undefined reference, which is the one question it answers.
    bindable="$WORK/bindable.$tag"
    otool -L "$bin" | tail -n +2 | awk '{ print $1 }' \
      | while IFS= read -r dep; do
            dp=$(resolve_dep "$dep" "$(dirname "$bin")")
            if [ -n "$dp" ]; then exports_of "$dp" ""; fi
        done | sort -u > "$bindable"

    # What is left of $weak once the bindable names are subtracted is this image's findings. Both
    # sides are `sort -u` output under the LC_ALL=C exported at the top, which is the ordering comm
    # reads them in.
    missing="$WORK/missing.$tag"
    comm -23 "$weak" "$bindable" > "$missing"
    rm -f "$bindable"
    [ -s "$missing" ] || { rm -f "$weak" "$missing"; return; }

    stubs="$WORK/stubs.$tag"
    otool -Iv "$bin" \
      | awk '/^Indirect symbols for/ { inblk = /__TEXT,__stubs/; next } inblk && NF >= 3 { print $3 }' \
      | sort -u > "$stubs"
    while read -r sym; do
        if grep -qxF "$sym" "$stubs"; then kind=CALL; else kind=ADDR; fi
        echo "$kind|$sym|${bin#$STAGED}"
    done < "$missing" >> "$out"
    rm -f "$weak" "$missing" "$stubs"
}

# Worker mode: one image, dispatched by the driver below.
if [ -n "${WK_ABSENTREF_WORK:-}" ]; then
    scan_one "$2"
    exit 0
fi

# ---------------------------------------------------------------------------------------------------
# Every shipped Mach-O: frameworks, XPC services, daemons and the bundled dylibs. A crash in a
# WebContent service is a crash the user sees, so the services are in scope like the frameworks.
#
# The .dylib/.so patterns are NOT redundant with -perm -u+x. stage-frameworks.sh installs the in-bundle
# libraries mode 644, so an executables-only sweep misses libc++, libpolyfill_classes and every
# GStreamer plugin -- and then their EXPORTS are invisible too, which made libc++'s iostream vtables
# and the whole UTType* object-constant set look missing.
# ---------------------------------------------------------------------------------------------------
find "$STAGED" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 > "$WORK/inventory"
machos < "$WORK/inventory" > "$WORK/binaries"

BINCOUNT=$(wc -l < "$WORK/binaries" | tr -d ' ')
[ "$BINCOUNT" -gt 0 ] || { echo "  absent-reference check: FAILED -- no Mach-O binaries under $STAGED"; exit 1; }

# basename -> path, so an @rpath dependency can be resolved to the copy the bundle actually ships.
while IFS= read -r b; do printf '%s|%s\n' "$(basename "$b")" "$b"; done < "$WORK/binaries" > "$WORK/byname"

# One worker process per image, $JOBS at a time. The work is per-image and its only shared state is
# the export-cache directory, which is published by rename, so the images can be swept in any order
# and in any overlap. Each worker writes its own findings file; nothing is concatenated until they
# have all exited.
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
if ! tr '\n' '\0' < "$WORK/binaries" \
     | xargs -0 -n1 -P "$JOBS" env WK_ABSENTREF_WORK="$WORK" bash "$SELF" "$STAGED"; then
    echo "  absent-reference check: FAILED -- a worker exited nonzero (see above)"
    exit 1
fi
if [ -e "$WORK/error" ]; then exit 1; fi

SWEPT=$(ls "$WORK/found" | wc -l | tr -d ' ')
if [ "$SWEPT" != "$BINCOUNT" ]; then
    echo "  absent-reference check: FAILED -- $SWEPT of $BINCOUNT images were swept"
    exit 1
fi

cat "$WORK"/found/* > "$WORK/findings"
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
