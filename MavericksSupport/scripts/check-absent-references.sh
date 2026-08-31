#!/bin/bash
# Fail the build if a shipped binary references a symbol that, at RUNTIME, nothing it links provides.
# The mirror image of the shadow gate in polyfill/build-polyfill.sh: that one asks "does the layer
# define something 10.9 already has?"; this one asks "does WebKit reference something 10.9 does NOT
# have that the layer forgot to define?"
#
# The modern SDK marks post-10.9 API with availability, so clang WEAK-imports every such reference; dyld
# binds an absent weak symbol to 0, and both uses are fatal with nothing at the fault site naming the
# symbol. Four reference kinds are scored, per image (a symbol counts as provided for image B only if
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
#   LOAD   a STRONG two-level reference -- "(from libSystem)" -- whose named provider does not export it.
#          Fatal in whichever of two shapes the reference takes, measured on this host: a NON-LAZY one
#          (an address taken, an _OBJC_CLASS_$_) kills the process before main, "dyld: Symbol not found
#          ... Expected in: /usr/lib/libSystem.B.dylib"; a LAZY one (an ordinary call, which is most of
#          them) loads fine and dies at the first call, "dyld: lazy symbol binding failed" with the same
#          two lines under it. Third-party code hand-declaring a post-10.9 SPI produces exactly this,
#          because a declaration written without availability leaves clang nothing to weak-import.
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
# WEAK ObjC class references (_OBJC_CLASS_$_/_OBJC_METACLASS_$_) are excluded by construction: an absent
# class binds to 0 and a message to nil returns zero, so they cannot fault this way (a class 10.9 lacks
# whose instances WebKit needs is polyfills/classes/'s business). A STRONG one is scored like any other
# LOAD reference: a class reference is non-lazy, so it kills the process before main and no nil-messaging
# rule reaches it.
#
# Do NOT filter on nm's "(from X)" provider field: in the STAGED binaries the reexport shim makes ordinary
# AppKit and Foundation imports record their provider as libpolyfill_classes.
#
# ---------------------------------------------------------------------------------------------------
# SHAPE. Process creation on this host costs roughly a third of a second of system CPU whatever the
# program then does, so the number of execs IS the run time; reading the symbol tables is noise beside
# it. nm, otool and dyldinfo each accept many files in one invocation and print "<path>:" or
# "<path> (for architecture X):" ahead of that file's output, so the whole audit is a handful of bulk
# reads whose output a single awk splits back apart on those headers:
#
#   1. otool -L over every staged image -- each image's direct dependencies.
#   2. Those dependency paths resolved to files, in the shell.
#   3. nm -gU, dyldinfo -export and otool -l over the libraries they resolve to -- their exports and
#      the LC_REEXPORT_DYLIB graph. A re-export names libraries the first round has not seen, so the
#      three reads repeat over just the newly discovered ones until the graph closes.
#   4. nm -m over every staged image -- every undefined reference, tagged with its kind.
#   5. One awk walks the re-export graph to get each image's link closure and subtracts that closure's
#      exports from the image's undefined references. The closure is the least fixpoint over the
#      re-export edges, which is what dyld resolves against; ld refuses to link a re-export cycle
#      ("cycle in dylib re-exports"), so the fixpoint terminates on the graph's own shape.
#   6. otool -Iv over only the images left holding an unbindable weak reference -- CALL versus ADDR.
#
# -arch all on every read: the frameworks ship fat x86_64+i386 and these tools read only the HOST slice
# of a fat file unless told otherwise, which would leave every i386 slice unswept.
set -euo pipefail
export LC_ALL=C   # sort and comm below must agree on ordering, and every symbol name is ASCII

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # MavericksSupport/scripts
REPO="$(cd "$HERE/../.." && pwd)"                                # repo root
STAGED="${1:-$REPO/WebKitBuild/Release/staged}"
. "$HERE/cctools.sh"
NM="$CCTOOLS/nm"
DYLDINFO="$CCTOOLS/dyldinfo"
OTOOL="$CCTOOLS/otool"

fail() { echo "  absent-reference check: FAILED -- $*"; exit 1; }

# A check that cannot run must FAIL, never pass quietly. Without these guards a broken $NM or a missing
# staged tree reaches the "clean -- N staged binaries" line without a single binary having been read,
# which is an invented success about whether the audit happened at all.
[ -d "$STAGED" ] || fail "no staged tree at $STAGED"
[ -x "$NM" ] || fail "nm not executable at $NM"
[ -x "$DYLDINFO" ] || fail "dyldinfo not executable at $DYLDINFO"
[ -x "$OTOOL" ] || fail "otool not executable at $OTOOL"

WORK="$(mktemp -d -t absentrefs)"; trap 'rm -rf "$WORK"' EXIT

# Given ONE file these tools print no header line at all, which would leave that invocation's output
# with nothing to attribute it to. The anchor rides at the head of every batch as xargs's fixed
# argument list, so no batch is ever a lone file. Each parser attributes only to files on the list it
# was invoked over, so the anchor's own output goes nowhere.
ANCHOR=/usr/lib/libSystem.B.dylib
[ -f "$ANCHOR" ] || fail "no $ANCHOR to anchor the bulk reads"

# One invocation per tool per list rather than one per file. xargs splits at the kernel's real argument
# limit and repeats the fixed arguments at the head of each batch, so nothing here has to guess at
# ARG_MAX. The status and stderr are kept: stdout into the parser is block-buffered, so a tool that
# dies mid-batch loses a whole block of output including files it had already read, and the sweep must
# fail rather than score what survived.
bulk() {
    local list="$1" rc=0
    shift
    # Both files are emptied BEFORE the read. The status is written only once xargs has returned, so a
    # bulk that dies in between leaves an empty tool.rc, which bulk_ok reads as a failure rather than
    # as the previous read's success.
    : > "$WORK/tool.err"
    : > "$WORK/tool.rc"
    xargs -0 "$@" "$ANCHOR" < "$list" 2> "$WORK/tool.err" || rc=$?
    echo "$rc" > "$WORK/tool.rc"
}

bulk_ok() {
    local rc=1
    read -r rc < "$WORK/tool.rc" || true
    if [ "$rc" = 0 ]; then return 0; fi
    echo "  absent-reference check: FAILED -- $1 exited $rc reading $2"
    sed 's/^/      /' "$WORK/tool.err"
    exit 1
}

# xargs -0 wants a NUL-separated list; every list in this script is one path per line.
nul_list() { tr '\n' '\0' < "$1" > "$1.nul"; }

# Every awk below identifies a file boundary the same way: a line that starts at the root and ends in a
# colon. Symbol, dependency and load-command lines all begin with an address, a tab or blank space, so
# none of them can be mistaken for one.
HDRFN='function hdrpath(s) { sub(/:$/, "", s); sub(/ \((for )?architecture [^)]*\)$/, "", s); return s }'

# Collapse `file` output to a real path and the number of architectures the image declares. The
# per-architecture lines read
#   /path (for architecture x86_64):<TAB>Mach-O 64-bit ...
# so stripping only at the first colon manufactures the nonexistent path "/path (for architecture
# x86_64)" -- which silently drops the binary from the scan if the universal-summary line ever stops
# being emitted. Strip the architecture parenthetical FIRST, then the colon.
#
# The universal-summary line, "/path: Mach-O universal binary with 2 architectures", is the declared
# slice count that the coverage proof in step 4 measures nm against; a thin image has no such line and
# declares one.
machos() {
    # grep's status-1 means "this tree holds no Mach-O", which the count at the call site reports;
    # every other status here fails the check.
    xargs -0 file \
      | { grep "Mach-O" || [ "$?" -eq 1 ]; } \
      | awk '{
            s = $0
            slices = sub(/ \(for architecture [^)]*\)/, "", s)
            p = s; sub(/:.*/, "", p)
            if (!(p in seen)) { seen[p] = 1; n++; order[n] = p; narch[p] = 1 }
            if (slices) perarch[p]++
            if (s ~ /: *Mach-O universal binary with [0-9]+ architecture/) {
                t = s; sub(/.*universal binary with /, "", t); sub(/[^0-9].*/, "", t)
                narch[p] = t + 0
            }
        }
        END {
            # The summary line and the per-architecture lines are two independent statements of the
            # same count; take the larger so neither one going missing understates the sweep.
            for (i = 1; i <= n; i++) {
                p = order[i]
                print p "\t" (perarch[p] > narch[p] ? perarch[p] : narch[p])
            }
        }' \
      | sort -u
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
find "$STAGED" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 > "$WORK/inventory"
machos < "$WORK/inventory" > "$WORK/archcount"
awk -F'\t' '{ print $1 }' "$WORK/archcount" > "$WORK/binaries"

BINCOUNT=$(wc -l < "$WORK/binaries" | tr -d ' ')
[ "$BINCOUNT" -gt 0 ] || fail "no Mach-O binaries under $STAGED"
nul_list "$WORK/binaries"

# basename -> shipped path, for @rpath resolution. bash 3.2 has no associative arrays and a per-lookup
# `grep` would put the exec cost straight back, so the map lives in shell variables named after the
# basename with every character outside [A-Za-z0-9_] folded to "_". Two basenames can fold onto one
# variable name, so each variable holds a chain of "basename>path|" entries that the lookup compares
# exactly; the first entry wins, which is the shipped copy that sorts first.
while IFS= read -r b; do
    leaf="${b##*/}"; v="_wkbn_${leaf//[^A-Za-z0-9_]/_}"
    eval "chain=\${$v:-}"
    eval "$v=\"\$chain\$leaf>\$b|\""
done < "$WORK/binaries"

# Set membership over arbitrary strings, same storage trick, with the key kept in the value so a folded
# name collision cannot answer for the wrong key. Returns 0 if the key was ALREADY in the set.
seen_lib() {
    local v chain
    v="_wklib_${1//[^A-Za-z0-9_]/_}"
    eval "chain=\${$v:-}"
    case "$chain" in *"|$1|"*) return 0 ;; esac
    eval "$v=\"\$chain|\$1|\""
    return 1
}

# An install path as recorded in a load command -> a file to read. The staged tree's copy WINS: the
# WebKit frameworks record absolute /System/... paths (stage-frameworks.sh rewrites @rpath away for
# them), so without this mapping the gate reads the frameworks currently installed on the system
# rather than the ones just built. The bundled GStreamer libraries keep @rpath/@loader_path deps, which
# must be resolved too: unresolved, their libc++abi dependency disappears and every `operator new`/
# `operator delete` they import is reported as missing.
# Results come back in RESOLVED rather than on stdout, for the same reason the sweep is bulk: a command
# substitution forks. Callers read RESOLVED immediately, before the next call overwrites it.
resolve_dep() {
    local rel leaf v chain ent
    RESOLVED=""
    case "$1" in
      @loader_path/*|@executable_path/*)
          rel="${1#@*path/}"
          if [ -n "${2:-}" ] && [ -e "$2/$rel" ]; then RESOLVED="$2/$rel"; return; fi
          ;;
      @rpath/*)
          # LC_RPATH search paths are themselves @loader_path-relative here, so resolve by basename
          # against everything the bundle ships -- an in-bundle library is what @rpath means. The
          # compare is an exact string compare, NOT a pattern: these basenames contain regex
          # metacharacters ("libc++abi.1.dylib"), and a pattern-based lookup silently misses them --
          # which loses libc++'s libc++abi dependency and reports every operator new/delete it imports
          # as missing.
          leaf="${1##*/}"; v="_wkbn_${leaf//[^A-Za-z0-9_]/_}"
          eval "chain=\${$v:-}"
          while [ -n "$chain" ]; do
              ent="${chain%%|*}"; chain="${chain#*|}"
              if [ "${ent%%>*}" = "$leaf" ]; then RESOLVED="${ent#*>}"; return; fi
          done
          ;;
    esac
    if [ -e "$STAGED$1" ]; then RESOLVED="$STAGED$1"; elif [ -e "$1" ]; then RESOLVED="$1"; fi
}

# ---------------------------------------------------------------------------------------------------
# 1. Every image's direct dependencies. otool -L's first entry for a dylib is its own LC_ID_DYLIB,
#    which resolves back to the image itself -- that is how a dylib's own exports enter its closure.
# ---------------------------------------------------------------------------------------------------
: > "$WORK/hdr.deps"; : > "$WORK/deps.raw"
bulk "$WORK/binaries.nul" "$OTOOL" -L -arch all | awk -v bins="$WORK/binaries" -v hdrs="$WORK/hdr.deps" -v deps="$WORK/deps.raw" "
    $HDRFN"'
    BEGIN { while ((getline l < bins) > 0) isimg[l] = 1; close(bins) }
    /^\// && /:$/ { cur = hdrpath($0); keep = (cur in isimg); if (keep && !(cur in hs)) { hs[cur] = 1; print cur > hdrs } next }
    keep && /^\t/ { d = substr($0, 2); sub(/ .*/, "", d); if (!((cur, d) in seen)) { seen[cur, d] = 1; print cur "\t" d > deps } }
'
bulk_ok "otool -L" "the staged images"
sort -u "$WORK/hdr.deps" -o "$WORK/hdr.deps"
# Written to a file, not piped into `head`: past a pipe buffer's worth of unread images `head` exits
# first, `comm` takes SIGPIPE, and pipefail would kill the script before it printed why.
comm -23 "$WORK/binaries" "$WORK/hdr.deps" > "$WORK/unread.deps"
if [ -s "$WORK/unread.deps" ]; then
    echo "  absent-reference check: FAILED -- otool -L could not read:"
    awk 'NR <= 3 { print "      " $0 }' "$WORK/unread.deps"
    exit 1
fi

# ---------------------------------------------------------------------------------------------------
# 2. Resolve those dependencies to files, and collect the libraries whose exports the sweep needs.
# ---------------------------------------------------------------------------------------------------
: > "$WORK/libs.0"
while IFS=$'\t' read -r img dep; do
    resolve_dep "$dep" "${img%/*}"
    [ -n "$RESOLVED" ] || continue
    printf '%s\t%s\n' "$img" "$RESOLVED"
    seen_lib "$RESOLVED" || printf '%s\n' "$RESOLVED" >> "$WORK/libs.0"
done < "$WORK/deps.raw" > "$WORK/imgdeps"

# ---------------------------------------------------------------------------------------------------
# 3. Everything those libraries vend, and the LC_REEXPORT_DYLIB edges between them -- that is how dyld
#    satisfies a two-level reference recorded against an umbrella (ApplicationServices, CoreServices)
#    or against the reexport shim. A re-export names libraries no image depends on directly, so each
#    round reads only what the round before it discovered, until nothing new appears.
# ---------------------------------------------------------------------------------------------------
: > "$WORK/exports"; : > "$WORK/reedges"
round=0
while [ -s "$WORK/libs.$round" ]; do
    next=$(( round + 1 )); : > "$WORK/libs.$next"
    nul_list "$WORK/libs.$round"

    # Two shapes come out of nm -gU: "<addr> <type> <name>" for a defined symbol, and
    # "<type> <name> (indirect for <target>)" -- no address column -- for an indirect one. libc
    # reaches many exports the second way (_strncmp is "I _strncmp (indirect for __platform_strncmp)"),
    # so reading the name from a fixed column silently drops them.
    bulk "$WORK/libs.$round.nul" "$NM" -gU -arch all | awk -v libs="$WORK/libs.$round" "$HDRFN"'
        BEGIN { while ((getline l < libs) > 0) want[l] = 1; close(libs) }
        /^\// && /:$/ { cur = hdrpath($0); keep = (cur in want); next }
        !keep { next }
        $1 ~ /^[TDSBIRC]$/ { print cur "\t" $2; next }
        $2 ~ /^[TDSBIRC]$/ { print cur "\t" $3 }
    ' >> "$WORK/exports"
    bulk_ok "nm -gU" "the dependency libraries"

    # PER-SYMBOL re-exports, which live only in the export trie and have no symbol-table entry at all:
    # "[re-export] _av_freep (from libavutil)". dyld binds them, nm -gU cannot see them, and they are
    # not LC_REEXPORT_DYLIB either. FFmpeg forwards its whole libavutil surface this way -- libavcodec
    # defines 168 symbols and re-exports 596 -- so without this read every image that imports
    # av_malloc/av_freep through libavcodec reports them absent.
    bulk "$WORK/libs.$round.nul" "$DYLDINFO" -export | awk -v libs="$WORK/libs.$round" "$HDRFN"'
        BEGIN { while ((getline l < libs) > 0) want[l] = 1; close(libs) }
        /^\// && /:$/ { cur = hdrpath($0); keep = (cur in want); next }
        keep && $1 == "[re-export]" { print cur "\t" $2 }
    ' >> "$WORK/exports"
    bulk_ok "dyldinfo -export" "the dependency libraries"

    bulk "$WORK/libs.$round.nul" "$OTOOL" -l -arch all | awk -v libs="$WORK/libs.$round" "$HDRFN"'
        BEGIN { while ((getline l < libs) > 0) want[l] = 1; close(libs) }
        /^\// && /:$/ { cur = hdrpath($0); keep = (cur in want); r = 0; next }
        !keep { next }
        /LC_REEXPORT_DYLIB/ { r = 1; next }
        r && /name / { print cur "\t" $2; r = 0 }
    ' > "$WORK/re.$round"
    bulk_ok "otool -l" "the dependency libraries"

    while IFS=$'\t' read -r lib name; do
        resolve_dep "$name" "${lib%/*}"
        [ -n "$RESOLVED" ] || continue
        printf '%s\t%s\n' "$lib" "$RESOLVED"
        seen_lib "$RESOLVED" || printf '%s\n' "$RESOLVED" >> "$WORK/libs.$next"
    done < "$WORK/re.$round" >> "$WORK/reedges"

    round=$next
    [ "$round" -lt 64 ] || fail "the re-export graph did not close after $round rounds"
done

# ---------------------------------------------------------------------------------------------------
# 4. Every undefined reference in every image, tagged with its kind.
#
#    Two things are proved here rather than assumed. nm exits 0 on a file it silently skips and on a
#    fat file whose i386 slice it cannot read, so coverage is measured, not inferred: the header count
#    per image must equal the slice count `file` declared for it, which is what makes the "all slices"
#    claim at the end true. The SEEN record then carries each image nm read all the way through into
#    the classifier, so the count there proves the sweep reached every image on the inventory.
# ---------------------------------------------------------------------------------------------------
: > "$WORK/slices"
bulk "$WORK/binaries.nul" "$NM" -m -arch all | awk -v bins="$WORK/binaries" -v archf="$WORK/archcount" \
                                                   -v slicef="$WORK/slices" "$HDRFN"'
    BEGIN {
        while ((getline l < bins) > 0) isimg[l] = 1; close(bins)
        while ((getline l < archf) > 0) { i = index(l, "\t"); want[substr(l, 1, i - 1)] = substr(l, i + 1) + 0 }
        close(archf)
    }
    /^\// && /:$/ {
        cur = hdrpath($0); keep = (cur in isimg)
        if (keep) { nhdr[cur]++; if (!(cur in hs)) { hs[cur] = 1; print cur "\tSEEN\t" } }
        next
    }
    !keep { next }
    {
        if ((p = index($0, "(undefined) weak external ")) > 0) {
            n = substr($0, p + 26); sub(/ .*/, "", n)
            if (n !~ /^_OBJC_(META)?CLASS_\$_/) print cur "\tWEAK\t" n
        } else if ((p = index($0, "(undefined) external ")) > 0) {
            rest = substr($0, p + 21); n = rest; sub(/ .*/, "", n)
            if (rest ~ /^[^ ]+ \(dynamically looked up\)/) print cur "\tDYN\t" n
            else if (rest ~ /^[^ ]+ \(from /) print cur "\tSTRONG\t" n
        }
    }
    END { for (q in isimg) if (nhdr[q] + 0 != want[q]) print q "\t" (nhdr[q] + 0) "\t" want[q] > slicef }
' | sort -u > "$WORK/undefs"
bulk_ok "nm -m" "the staged images"
if [ -s "$WORK/slices" ]; then
    echo "  absent-reference check: FAILED -- nm did not read every architecture of every image:"
    awk -F'\t' 'NR <= 3 { printf "      %s: %s of %s slice(s) read\n", $1, $2, $3 }' "$WORK/slices"
    exit 1
fi

# ---------------------------------------------------------------------------------------------------
# 5. Score each reference against the image's OWN link closure -- its direct dependencies plus what
#    those re-export, transitively. Not the whole disk, and not the union of what the bundle exports:
#    see the header.
#
#    DYN, the other half of "references something nothing provides": a STRONG flat-namespace reference.
#    WebCore links with "-undefined dynamic_lookup" (Source/WebCore/CMakeLists.txt), so a call to a
#    definition that never got compiled -- an upstream TU a source-list seam withholds, or one upstream
#    builds only from its Xcode project -- survives the link as an undefined flat symbol instead of
#    failing it. Nothing reports it until a client binds the image eagerly, and then dyld refuses to
#    load that client outright: an iWork QuickLook generator, hard-bound against WebKit, dies with
#    "Symbol not found ... Expected in: flat namespace" and its previews stop working.
#
#    These carry no presence test, because there is nothing to score them against: flat lookup searches
#    the images loaded in the CLIENT process at bind time, which is neither this image's link closure
#    nor the bundle. Scoring them against the union of what the bundle exports is the global-presence
#    mistake the header rejects, one slice and one lazily-dlopened plugin wide -- a name some unrelated
#    staged image happens to export would pass while dyld aborts the client.
#
#    LOAD: a STRONG reference carrying a two-level provider, "(from libSystem)". It is scored against
#    the same link closure the weak references are, because it binds the same way -- dyld searches the
#    named dylib and what that dylib re-exports, and nothing else. What differs is when it kills the
#    process: at load for a non-lazy reference, at the first call for a lazy one.
#
#    Only the symbols some image actually references are kept out of the export tables, and closures
#    that come out identical share one memo, so the subtraction stays a hash lookup per reference.
# ---------------------------------------------------------------------------------------------------
: > "$WORK/findings.raw"; : > "$WORK/missing"
awk -v undefs="$WORK/undefs" -v expf="$WORK/exports" -v redgef="$WORK/reedges" -v depf="$WORK/imgdeps" \
    -v out="$WORK/findings.raw" -v missf="$WORK/missing" -v sweptf="$WORK/swept" -v staged="$STAGED" '
    function closure(img,   i, k, lib, r2) {
        gen++; nclos = 0
        for (i = 1; i <= nd[img]; i++) {
            lib = dp[img, i]
            if (mark[lib] != gen) { mark[lib] = gen; nclos++; clos[nclos] = lib }
        }
        # Growing the list while walking it is the breadth-first pass over the re-export edges; the
        # generation mark de-duplicates.
        for (i = 1; i <= nclos; i++) {
            lib = clos[i]
            for (k = 1; k <= nre[lib]; k++) {
                r2 = re[lib, k]
                if (mark[r2] != gen) { mark[r2] = gen; nclos++; clos[nclos] = r2 }
            }
        }
        sig = ""
        for (i = 1; i <= nclos; i++) sig = sig "\001" clos[i]
        if (!(sig in sigid)) { nsig++; sigid[sig] = nsig }
        sid = sigid[sig]
    }
    function bindable(sym,   i, key, b) {
        key = sid "\002" sym
        if (key in memo) return memo[key]
        b = 0
        for (i = 1; i <= nclos; i++) if ((clos[i], sym) in own) { b = 1; break }
        memo[key] = b
        return b
    }
    BEGIN {
        slen = length(staged)
        while ((getline l < undefs) > 0) { i = index(l, "\t"); r = substr(l, i + 1); j = index(r, "\t"); U[substr(r, j + 1)] = 1 }
        close(undefs)
        while ((getline l < expf) > 0) { i = index(l, "\t"); s = substr(l, i + 1); if (s in U) own[substr(l, 1, i - 1), s] = 1 }
        close(expf)
        while ((getline l < redgef) > 0) { i = index(l, "\t"); a = substr(l, 1, i - 1); b = substr(l, i + 1); nre[a]++; re[a, nre[a]] = b }
        close(redgef)
        while ((getline l < depf) > 0) { i = index(l, "\t"); a = substr(l, 1, i - 1); b = substr(l, i + 1); nd[a]++; dp[a, nd[a]] = b }
        close(depf)
    }
    {
        i = index($0, "\t"); img = substr($0, 1, i - 1); r = substr($0, i + 1)
        j = index(r, "\t"); kind = substr(r, 1, j - 1); sym = substr(r, j + 1)
        if (img != curimg) { curimg = img; rel = substr(img, slen + 1); closure(img) }
        if (kind == "SEEN") { nswept++; next }
        if (kind == "DYN") { print "DYN|" sym "|" rel > out; next }
        if (bindable(sym)) next
        # An _OBJC_CLASS_$ weak reference never reaches here: a nil class is what missing-class
        # messaging already answers, and which Objective-C classes WebKit needs is the business of
        # polyfills/classes/.
        if (kind == "STRONG") print "LOAD|" sym "|" rel > out
        else print img "\t" sym > missf
    }
    END { print nswept + 0 > sweptf }
' "$WORK/undefs"

SWEPT=""; read -r SWEPT < "$WORK/swept" || true
[ "$SWEPT" = "$BINCOUNT" ] || fail "${SWEPT:-0} of $BINCOUNT images were classified"

# ---------------------------------------------------------------------------------------------------
# 6. A weak reference nothing provides is a call through a stub (CALL) or a bare address load (ADDR).
#    Only the images that have one pay for this read.
# ---------------------------------------------------------------------------------------------------
if [ -s "$WORK/missing" ]; then
    : > "$WORK/ivimages"
    prev=""
    while IFS=$'\t' read -r img sym; do
        [ "$img" = "$prev" ] || { printf '%s\n' "$img" >> "$WORK/ivimages"; prev="$img"; }
    done < "$WORK/missing"
    nul_list "$WORK/ivimages"
    : > "$WORK/iv.unread"
    bulk "$WORK/ivimages.nul" "$OTOOL" -Iv -arch all | awk -v missf="$WORK/missing" -v out="$WORK/findings.raw" \
                                                        -v staged="$STAGED" -v unread="$WORK/iv.unread" "$HDRFN"'
        BEGIN {
            slen = length(staged)
            while ((getline l < missf) > 0) {
                i = index(l, "\t"); img = substr(l, 1, i - 1)
                if (!(img in cnt)) { nimg++; imgs[nimg] = img }
                cnt[img]++; ms[img, cnt[img]] = substr(l, i + 1)
            }
            close(missf)
        }
        /^\// && /:$/ { cur = hdrpath($0); keep = (cur in cnt); if (keep) sawhdr[cur] = 1; inblk = 0; next }
        !keep { next }
        /^Indirect symbols for/ { inblk = /__TEXT,__stubs|__TEXT,__symbol_stub/; next }
        inblk && NF >= 3 { stub[cur, $3] = 1 }
        END {
            for (k = 1; k <= nimg; k++) {
                img = imgs[k]; rel = substr(img, slen + 1)
                # An image otool could not read has an empty stub set, which would silently downgrade
                # every one of its findings to ADDR, so it fails the check instead.
                if (!(img in sawhdr)) { print img > unread; continue }
                for (j = 1; j <= cnt[img]; j++) {
                    s = ms[img, j]
                    kind = ((img, s) in stub) ? "CALL|" : "ADDR|"
                    print kind s "|" rel >> out
                }
            }
        }
    '
    bulk_ok "otool -Iv" "the images holding an unbindable weak reference"
    if [ -s "$WORK/iv.unread" ]; then
        echo "  absent-reference check: FAILED -- otool -Iv could not read:"
        awk 'NR <= 3 { print "      " $0 }' "$WORK/iv.unread"
        exit 1
    fi
fi

sort -u "$WORK/findings.raw" > "$WORK/findings"

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

# A findings line that does not split into a (kind, symbol, image) triple is fatal like any other: the
# gate has no path that discards its own output.
: > "$WORK/fatal"; : > "$WORK/pinnedhit"
awk -v pin="$WORK/pinned" -v fatal="$WORK/fatal" -v hit="$WORK/pinnedhit" '
    BEGIN { while ((getline l < pin) > 0) if (split(l, a, " ") == 3) p[a[1], a[2], a[3]] = 1; close(pin) }
    {
        n = index($0, "|"); rest = substr($0, n + 1); m = index(rest, "|")
        if (n == 0 || m == 0) { print $0 >> fatal; next }
        b = substr(rest, m + 1); sub(/.*\//, "", b)
        if ((substr($0, 1, n - 1), substr(rest, 1, m - 1), b) in p) print $0 >> hit
        else print $0 >> fatal
    }
' "$WORK/findings"

show() { awk -F'|' '{ printf "      %-52s %s\n", $2, $3 }' "$1" | sort -u; }

{ grep -v -e '^DYN|' -e '^LOAD|' "$WORK/fatal" > "$WORK/fatalweak"; } || true
{ grep '^DYN|' "$WORK/fatal" > "$WORK/fataldyn"; } || true
{ grep '^LOAD|' "$WORK/fatal" > "$WORK/fatalload"; } || true

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

if [ -s "$WORK/fatalload" ]; then
    echo "  absent-reference check: FAILED"
    echo "    A shipped binary carries a strong two-level reference the dylib it names does not export."
    echo "    A non-lazy one (an address taken, an _OBJC_CLASS_\$_) kills every process that links the"
    echo "    image before main; a lazy one -- an ordinary call -- dies at the first call with \"dyld:"
    echo "    lazy symbol binding failed\". Define the symbol in the polyfill layer, honestly: force_load"
    echo "    resolves the reference at link time, so no undefined record is emitted at all. A vendored"
    echo "    image that force-loads no polyfill takes the gap archive in deps/build_deps.sh instead."
    echo "    Only where no linkable boundary exists, key the caller off a capability macro that picks"
    echo "    the 10.9 path so the reference is never emitted."
    echo
    show "$WORK/fatalload"
fi

if [ -s "$WORK/fatal" ]; then exit 1; fi

echo "  absent-reference check: clean -- $BINCOUNT staged binaries, per-image link closures, all slices"
echo "    ($(grep -c '^DYN|' "$WORK/pinnedhit" || true) pinned flat-namespace reference(s), $(grep -c '^LOAD|' "$WORK/pinnedhit" || true) pinned two-level reference(s), $(grep -vc -e '^DYN|' -e '^LOAD|' "$WORK/pinnedhit" || true) pinned third-party weak reference(s))"
