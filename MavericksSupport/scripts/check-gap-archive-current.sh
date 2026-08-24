#!/bin/bash
# The gap archive (deps/build_deps.sh, GAP_SHARED) is force-loaded into every dylib and executable
# build_deps.sh links; build.sh relinks none of them, and reaches the same sources through
# libpolyfill.a instead.
#
# Currency comes from the manifest: a completed deps run republishes it together with the binaries
# it links, so re-hashing the sources answers "were these binaries built from this content".
# Coverage comes from the archive's symbols and its __cstring diagnostics, which answer "did the
# force_load reach this artifact" one artifact at a time.
#
# --sources-only stops after the currency half, which reads nothing but the manifest and the sources,
# so build.sh can run it in under a second before it compiles anything.
set -euo pipefail
export LC_ALL=C
trap 'echo "  gap-archive currency: FAILED -- the check itself exited at ${BASH_SOURCE[0]}:$LINENO"; exit 1' ERR

SOURCES_ONLY=""
for arg in "$@"; do
    case "$arg" in
        --sources-only) SOURCES_ONLY=1 ;;
        *) echo "usage: check-gap-archive-current.sh [--sources-only]" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SHARED="$REPO/MavericksSupport/polyfill/polyfills/shared"
DEPS="$REPO/MavericksSupport/deps/build"
BUILD_DEPS="$REPO/MavericksSupport/deps/build_deps.sh"
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"
. "$HERE/cctools.sh"
NM="$CCTOOLS/nm"
SHASUM=/usr/bin/shasum

REBUILD="Relink them:  bash MavericksSupport/deps/build_deps.sh"
RESTAGE="Rebuild them:  bash MavericksSupport/build.sh"
fail() {          # fail <headline> [line ...]
    echo "  gap-archive currency: FAILED -- $1"
    shift
    for line in "$@"; do echo "      $line"; done
    exit 1
}
fail_list() {     # fail_list <headline> <file of offenders> [remedy]
    local n
    n=$(wc -l < "$2" | tr -d ' ')
    echo "  gap-archive currency: FAILED -- $1"
    head -8 "$2" | sed 's/^/      /'
    [ "$n" -gt 8 ] && echo "      ... and $((n - 8)) more" || :
    echo "      ${3:-$REBUILD}"
    exit 1
}

for tool in "$NM" "$SHASUM" "$TC/bin/clang"; do
    [ -x "$tool" ] || fail "$tool is not executable, and the checks below need it"
done
[ -f "$BUILD_DEPS" ] || fail "no build_deps.sh at $BUILD_DEPS"
[ -d "$DEPS" ] || fail "no deps build at $DEPS" "$REBUILD"

MANIFEST="$DEPS/gap-sources.sha256"
SYMBOLS="$DEPS/gap-symbols.txt"
LITERALS="$DEPS/gap-literals.txt"
BUILDINFO="$DEPS/gap-buildinfo.txt"
UNLINKED="$DEPS/gap-unlinked.txt"
for f in "$MANIFEST" "$SYMBOLS" "$LITERALS" "$BUILDINFO"; do
    [ -r "$f" ] && [ -s "$f" ] || fail "no gap archive record at $f" "$REBUILD"
done
[ -r "$UNLINKED" ] || fail "no gap archive record at $UNLINKED" "$REBUILD"

scratch=$(mktemp -d -t gapgate)
trap 'rm -rf "$scratch"' EXIT

# --- the source set -------------------------------------------------------------------------------
# GAP_SHARED has one home, in build_deps.sh. The manifest's own .c entries are the other end of the
# same statement: a name added or dropped there without a deps build parts the two.
{ grep -o 'GAP_SHARED="[^"]*"' "$BUILD_DEPS" || true; } | sed 's/GAP_SHARED="//; s/"$//' \
    | tr ' ' '\n' | sed '/^$/d; s/$/.c/' | sort -u > "$scratch/declared"
[ -s "$scratch/declared" ] || fail "no GAP_SHARED assignment found in $BUILD_DEPS"
awk '{ print $2 }' "$MANIFEST" | { grep '^[^/]*\.c$' || true; } | sort -u > "$scratch/compiled"
comm -3 "$scratch/declared" "$scratch/compiled" | tr -d '\t' > "$scratch/list_diff"
[ -s "$scratch/list_diff" ] && fail_list \
    "GAP_SHARED in build_deps.sh and the sources the deps build compiled disagree:" "$scratch/list_diff" || :
while IFS= read -r s; do
    [ -f "$SHARED/$s" ] || fail "$SHARED/$s is named in GAP_SHARED and absent"
done < "$scratch/declared"

# --- the source content ---------------------------------------------------------------------------
check=$( (cd "$SHARED" && "$SHASUM" -a 256 -c "$MANIFEST") 2>&1 ) && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$check" | sed -n 's/: FAILED.*$//p' > "$scratch/changed"
    fail_list "gap source content differs from what the deps build compiled:" "$scratch/changed"
fi
verified=$(printf '%s\n' "$check" | awk '/: OK$/ { n++ } END { print n + 0 }')
[ "$verified" -gt 0 ] || fail "the manifest verified no files at all" "$REBUILD"

# --- the rest of the compile ----------------------------------------------------------------------
gapcflags=$({ grep -o 'GAPCFLAGS="[^"]*"' "$BUILD_DEPS" || true; } | sed 's/GAPCFLAGS="//; s/"$//')
[ -n "$gapcflags" ] || fail "no GAPCFLAGS assignment found in $BUILD_DEPS"
{ printf 'cflags\t%s\n' "$gapcflags"
  printf 'clang\t%s\n' "$("$TC/bin/clang" --version | head -1)"; } > "$scratch/buildinfo"
if ! cmp -s "$scratch/buildinfo" "$BUILDINFO"; then
    { diff "$BUILDINFO" "$scratch/buildinfo" || true; } | sed -n 's/^[<>] /&/p' > "$scratch/cflag_diff"
    fail_list "the gap compile's inputs differ from the deps build's:" "$scratch/cflag_diff"
fi

if [ -n "$SOURCES_ONLY" ]; then
    echo "  gap-archive currency: clean -- $verified source files match the deps build"
    exit 0
fi

# --- the deployed artifacts -------------------------------------------------------------------------
for d in "$DEPS/lib" "$DEPS/bin"; do
    [ -d "$d" ] || fail "no $d to check" "$REBUILD"
done
find "$DEPS/lib" -type f -name '*.dylib' > "$scratch/artifacts"
find "$DEPS/bin" -type f -perm +111 >> "$scratch/artifacts"
sort -o "$scratch/artifacts" "$scratch/artifacts"
artifacts=$(wc -l < "$scratch/artifacts" | tr -d ' ')
[ "$artifacts" -gt 0 ] || fail "no dylibs or executables under $DEPS" "$REBUILD"
sed "s|^|$DEPS/lib/|" "$UNLINKED" | sort > "$scratch/unlinked"
comm -23 "$scratch/artifacts" "$scratch/unlinked" > "$scratch/linked"
linked=$(wc -l < "$scratch/linked" | tr -d ' ')
[ "$linked" -gt 0 ] || fail "every deployed artifact is named copied-not-linked in $UNLINKED"

# Literals, one batched grep: an artifact carrying none of them never force-loaded the archive, and
# the set that carries none must be the set build_deps.sh copies rather than links.
tr '\n' '\0' < "$scratch/artifacts" \
  | { xargs -0 grep -a -l -F -f "$LITERALS" || true; } > "$scratch/carriers" 2>"$scratch/greperr"
[ -s "$scratch/greperr" ] && fail "grep could not read the deployed binaries:" "$(cat "$scratch/greperr")" || :
sort -o "$scratch/carriers" "$scratch/carriers"
comm -23 "$scratch/artifacts" "$scratch/carriers" > "$scratch/literal_absent"
comm -3 "$scratch/literal_absent" "$scratch/unlinked" | tr -d '\t' > "$scratch/coverage_diff"
[ -s "$scratch/coverage_diff" ] && fail_list \
    "the artifacts without the archive's literals are not the ones build_deps.sh copies:" "$scratch/coverage_diff" || :

# Symbols. nm answers for every artifact whose build kept its local symbols; a partial answer is a
# link that predates part of the archive, and an undefined gap symbol is a reference that binds
# somewhere else -- the copied libc++ pair exports 28 of these names.
rc=0
tr '\n' '\0' < "$scratch/artifacts" \
  | xargs -0 "$NM" -A -arch x86_64 > "$scratch/nm" 2>"$scratch/nmerr" || rc=$?
[ "$rc" -eq 0 ] || fail "nm exited $rc over the deployed binaries:" "$(cat "$scratch/nmerr")"
[ -s "$scratch/nmerr" ] && fail "nm could not read the deployed binaries:" "$(cat "$scratch/nmerr")" || :
awk -v syms="$SYMBOLS" '
    BEGIN { while ((getline s < syms) > 0) { gap["_" s] = 1; total++ } }
    NF >= 3 {
        f = substr($1, 1, length($1) - 1)
        if (!(f in seen)) { seen[f] = 1; order[++n] = f }
        if ($NF in gap) { if ($(NF - 1) == "U") u[f]++; else d[f]++ }
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%d\t%d\t%d\n", order[i], d[order[i]] + 0, u[order[i]] + 0, total }
' "$scratch/nm" | sort > "$scratch/tally"
# nm passes over a file it does not recognise in silence; an artifact it produced no line for is one
# this gate never examined.
cut -f1 "$scratch/tally" | sort > "$scratch/tallied"
comm -23 "$scratch/artifacts" "$scratch/tallied" > "$scratch/unread"
[ -s "$scratch/unread" ] && fail_list "deployed binaries nm produced no symbols for:" "$scratch/unread" || :

join -t "$(printf '\t')" "$scratch/linked" "$scratch/tally" > "$scratch/linked_tally"
awk -F'\t' '$2 > 0 && $2 < $4 { print $1 " [" $2 " of " $4 "]" }' "$scratch/linked_tally" > "$scratch/partial"
[ -s "$scratch/partial" ] && fail_list "deployed binaries carrying only part of the archive:" "$scratch/partial" || :
awk -F'\t' '$3 > 0 { print $1 " [" $3 "]" }' "$scratch/linked_tally" > "$scratch/bound"
[ -s "$scratch/bound" ] && fail_list "deployed binaries whose gap symbols bind outside the archive:" "$scratch/bound" || :
full=$(awk -F'\t' '$2 == $4 { n++ } END { print n + 0 }' "$scratch/linked_tally")
symbols=$(wc -l < "$SYMBOLS" | tr -d ' ')

# --- the staged WebKit images ---------------------------------------------------------------------
# They link the same copied libc++, whose export table holds a frozen generation of 28 of these
# names. Every one of them force-loads libpolyfill.a, so a gap symbol left undefined in a staged
# image is one that binds libc++'s copy instead.
STAGED="$REPO/WebKitBuild/Release/staged"
[ -d "$STAGED" ] || fail "no staged tree at $STAGED" "$RESTAGE"
find "$STAGED" -type f > "$scratch/staged_files"
[ -s "$scratch/staged_files" ] || fail "no files under $STAGED"
tr '\n' '\0' < "$scratch/staged_files" | xargs -0 file > "$scratch/file" 2>"$scratch/fileerr"
[ -s "$scratch/fileerr" ] && fail "file could not read the staged tree:" "$(cat "$scratch/fileerr")" || :
{ grep 'Mach-O' "$scratch/file" || true; } | sed 's/ (for architecture [^)]*)//' \
    | cut -d: -f1 | sort -u > "$scratch/staged_macho"
[ -s "$scratch/staged_macho" ] || fail "no Mach-O image under $STAGED"
sed 's|^|/|' "$UNLINKED" > "$scratch/unlinked_names"
{ grep -v -F -f "$scratch/unlinked_names" "$scratch/staged_macho" || true; } > "$scratch/staged_linked"
staged=$(wc -l < "$scratch/staged_linked" | tr -d ' ')
[ "$staged" -gt 0 ] || fail "every staged Mach-O image is one build_deps.sh copies"
rc=0
tr '\n' '\0' < "$scratch/staged_linked" \
  | xargs -0 "$NM" -A -arch x86_64 > "$scratch/staged_nm" 2>"$scratch/staged_nmerr" || rc=$?
[ "$rc" -eq 0 ] || fail "nm exited $rc over the staged images:" "$(cat "$scratch/staged_nmerr")"
[ -s "$scratch/staged_nmerr" ] && fail "nm could not read the staged images:" "$(cat "$scratch/staged_nmerr")" || :
awk -v syms="$SYMBOLS" -v seen_out="$scratch/staged_seen" '
    BEGIN { while ((getline s < syms) > 0) gap["_" s] = 1 }
    NF >= 3 {
        f = substr($1, 1, length($1) - 1)
        if (!(f in seen)) { seen[f] = 1; order[++n] = f }
        if ($(NF - 1) == "U" && $NF in gap) u[f] = u[f] " " $NF
    }
    END { for (i = 1; i <= n; i++) {
              print order[i] > seen_out
              if (order[i] in u) print order[i] "  " u[order[i]]
          } }
' "$scratch/staged_nm" > "$scratch/staged_bound"
sort -u "$scratch/staged_seen" > "$scratch/staged_read"
comm -23 "$scratch/staged_linked" "$scratch/staged_read" > "$scratch/staged_unread"
[ -s "$scratch/staged_unread" ] && fail_list "staged images nm produced no symbols for:" "$scratch/staged_unread" "$RESTAGE" || :
[ -s "$scratch/staged_bound" ] && fail_list \
    "staged WebKit images whose gap symbols bind outside the polyfill:" "$scratch/staged_bound" "$RESTAGE" || :

echo "  gap-archive currency: clean -- $verified source files match the deps build; $linked of $artifacts deployed binaries carry its literals, $full of them all $symbols symbols; $staged staged images bind none of them elsewhere"
