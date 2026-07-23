#!/bin/bash
#
# divergence-stats.sh
#
# Reports how far the Mavericks backport has diverged from its upstream base:
# hunk, file, and line counts, size distributions, per-project and per-file-type
# breakdowns, and what the added lines actually consist of.
#
# This is a REPORT, not a gate -- it always exits 0. The gate is its sibling
# check-backport-markers.sh, whose scope and exclusion rules this script mirrors
# exactly so the two agree on what counts as a divergence. In particular the
# hunk total printed here matches that script's
#   marked + unmarked + deleted + whitespace
# total, so the two can be read side by side.
#
# Scope: Source/ only, excluding MavericksSupport/, build and generated dirs,
# vendored ThirdParty libs, binaries, and .json (no comment syntax, so the
# marker gate skips it and so does this).
#
# MavericksSupport/ is excluded from the divergence figures on purpose -- it is
# out-of-tree by design, the whole point being to keep the in-tree diff small.
# It gets its own section at the end so the trade can be seen.
#
# Usage:
#   divergence-stats.sh [base-commit] [--full] [--top N]
#
#   base-commit  upstream base to diff against (see resolution order below)
#   --full       also count every line in Source/ to express the divergence as
#                a fraction of the tree. Adds roughly a minute.
#   --top N      how many files to list in the "most diverged" tables (default 15)
#
# Base commit resolution (first match wins), identical to the marker gate:
#   1. positional argument
#   2. $MAVERICKS_UPSTREAM_BASE
#   3. git merge-base HEAD <upstream ref>   ($MAVERICKS_UPSTREAM_REF, else origin/main main)
#   4. built-in fallback: 83b24ce
#
# Runtime is dominated by the single full-tree diff, which takes a couple of
# minutes cold and is much faster once git's caches are warm.
#
# BSD-tool safe: no `grep -P`, no GNU-only sed/awk extensions.

set -u

# --- locate repo root ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root $REPO_ROOT" >&2; exit 2; }

DEFAULT_BASE="83b24ce"
UPSTREAM_REF_CANDIDATES="${MAVERICKS_UPSTREAM_REF:-origin/main main}"

# --- arguments ----------------------------------------------------------------
BASE_ARG=""
FULL=0
TOPN=15
while [ "$#" -gt 0 ]; do
    case "$1" in
        --full) FULL=1 ;;
        --top)
            shift
            [ "$#" -ge 1 ] || { echo "ERROR: --top needs a number" >&2; exit 2; }
            TOPN="$1" ;;
        --help|-h)
            sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
        *)  BASE_ARG="$1" ;;
    esac
    shift
done

case "$TOPN" in
    ''|*[!0-9]*) echo "ERROR: --top expects a number, got '$TOPN'" >&2; exit 2 ;;
esac

# --- resolve base commit ------------------------------------------------------
BASE=""
BASE_SOURCE=""
if [ -n "$BASE_ARG" ]; then
    BASE="$BASE_ARG"; BASE_SOURCE="CLI argument (manual override)"
elif [ -n "${MAVERICKS_UPSTREAM_BASE:-}" ]; then
    BASE="$MAVERICKS_UPSTREAM_BASE"; BASE_SOURCE="\$MAVERICKS_UPSTREAM_BASE (manual override)"
else
    for ref in $UPSTREAM_REF_CANDIDATES; do
        git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 || continue
        mb="$(git merge-base HEAD "$ref" 2>/dev/null)"
        if [ -n "$mb" ]; then
            BASE="$mb"
            BASE_SOURCE="auto-discovered: git merge-base HEAD $ref"
            break
        fi
    done
    if [ -z "$BASE" ]; then
        BASE="$DEFAULT_BASE"
        BASE_SOURCE="built-in fallback (could not auto-discover; fetch the upstream ref, e.g. origin/main)"
    fi
fi

if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
    echo "ERROR: base commit '$BASE' (from $BASE_SOURCE) is not a valid commit." >&2
    exit 2
fi

# --- shared awk helpers -------------------------------------------------------
# Path exclusion, kept byte-identical in intent to check-backport-markers.sh's
# is_excluded(). Prepended to every awk program below so there is one definition.
read -r -d '' AWK_LIB <<'AWKLIB'
function excl(p) {
    if (p ~ /(^|\/)MavericksSupport\//) return 1
    if (p ~ /(^|\/)WebKitBuild\//) return 1
    if (p ~ /\/DerivedSources\//) return 1
    if (p ~ /\/Derived\//) return 1
    if (p ~ /^Source\/ThirdParty\/[^\/]+\/lib\//) return 1
    if (p ~ /\.(a|o|dylib|so|bin|dat|png|jpg|jpeg|gif|bmp|ico|icns|ttf|otf|woff|woff2|pdf|zip|gz|tar|mov|mp4|webp|wasm)$/) return 1
    if (p ~ /\.json$/) return 1
    return 0
}
# A numstat path may arrive as `dir/{old => new}.cpp` for a rename; keep the new side.
function newpath(p) {
    if (index(p, " => ") > 0) { sub(/^.* => /, "", p); gsub(/[{}]/, "", p) }
    return p
}
# Build-system plumbing rather than program text.
function is_build(p) {
    return (p ~ /(CMakeLists\.txt|\.cmake|Sources[A-Za-z]*\.txt|\.pri|\.xcconfig)$/)
}
# Comment syntax varies by file type; # for the script/build family, C-style otherwise.
# `t` is the line with leading whitespace already stripped.
function is_comment(t, p) {
    if (p ~ /\.(cmake|py|sh|pl|pm|yaml|yml|in|order)$/ || p ~ /\.txt$/)
        return (t ~ /^#/)
    return (t ~ /^\/\// || t ~ /^\/\*/ || t ~ /^\*[ \t]/ || t ~ /^\*\/$/ || t == "*")
}
AWKLIB

# --- collect the diffs once ---------------------------------------------------
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/divergence-stats.XXXXXX")" || exit 2
trap 'rm -rf "$TMPDIR_RUN"' EXIT
NUMSTAT="$TMPDIR_RUN/numstat"
NAMESTATUS="$TMPDIR_RUN/namestatus"
DIFFU0="$TMPDIR_RUN/diffu0"

printf 'Collecting diff against %s (this takes a minute)...\n' "$(git rev-parse --short "$BASE")" >&2

# ONE -U0 diff, with the file list and per-file line counts derived from it.
#
# Deriving rather than calling `git diff --numstat` separately is deliberate, for
# two reasons. First, correctness: at the default three lines of context git's hunk
# compaction absorbs matching boundary lines as context, so plain `--numstat`
# disagrees with -U0 about the same file (WebEditorClient.mm: 7/10 vs 9/12). -U0 is
# what the marker gate audits, so every section here must be computed from that
# representation or the totals will not reconcile with the hunk counts. Second,
# git 1.9.5 (Apple Git-50.3, the system git on 10.9) emits numstat AND the full
# patch when -U0 accompanies --numstat, so `--numstat -U0` cannot be used anyway.
git diff -U0 "$BASE" -- Source/ > "$DIFFU0" 2>/dev/null

# `<added>\t<removed>\t<path>`, the format the sections below parse.
awk '
function emit() { if (cur != "") printf "%d\t%d\t%s\n", a, d, cur; a = 0; d = 0 }
/^diff --git / { emit(); p = $NF; sub(/^b\//, "", p); cur = p; next }
/^--- / { next }
/^\+\+\+ / { next }
/^@@ / { next }
/^index / { next }
{
    c = substr($0, 1, 1)
    if (c == "+") a++
    else if (c == "-") d++
}
END { emit() }' "$DIFFU0" > "$NUMSTAT"

# `<status>\t<path>`; A/D come from the file-mode lines, R from a rename pair.
awk '
function emit() { if (cur != "") printf "%s\t%s\n", st, cur }
/^diff --git / { emit(); p = $NF; sub(/^b\//, "", p); cur = p; st = "M"; next }
/^new file mode/ { st = "A"; next }
/^deleted file mode/ { st = "D"; next }
/^rename to / { st = "R"; next }
END { emit() }' "$DIFFU0" > "$NAMESTATUS"

# Generated files carry a "do not edit" banner and are not hand-written
# divergences; the marker gate skips them, so this must too.
GENERATED="$TMPDIR_RUN/generated"
: > "$GENERATED"
awk '{ print $2 }' "$NAMESTATUS" | while IFS= read -r f; do
    [ -f "$f" ] || continue
    if head -3 "$f" 2>/dev/null | grep -qiE 'generated file: do not edit|do not edit this file|auto-generated|automatically generated'; then
        printf '%s\n' "$f" >> "$GENERATED"
    fi
done

# --- report -------------------------------------------------------------------
echo "==================================================================="
echo "  MAVERICKS BACKPORT -- UPSTREAM DIVERGENCE STATISTICS"
echo "==================================================================="
printf '  upstream base : %s  (%s)\n' "$(git rev-parse --short "$BASE")" "$BASE_SOURCE"
printf '  HEAD          : %s  %s\n' "$(git rev-parse --short HEAD)" "$(git log -1 --format=%s | cut -c1-60)"
printf '  commits since : %s\n' "$(git rev-list --count "$BASE"..HEAD)"
printf '  scope         : Source/ (excluding MavericksSupport/, generated and\n'
printf '                  build dirs, vendored ThirdParty libs, binaries, .json)\n'
echo

echo "-------------------------------------------------------------------"
echo "TOTALS"
echo "-------------------------------------------------------------------"

awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
{
    p = $2
    if (excl(p) || (p in G)) next
    st = substr($1, 1, 1)
    kind[st]++
    total++
}
END {
    printf "  files touched            : %d\n", total
    printf "    modified               : %d\n", kind["M"] + 0
    printf "    added by the backport   : %d\n", kind["A"] + 0
    printf "    deleted                : %d\n", kind["D"] + 0
    if (kind["R"] + 0 > 0) printf "    renamed                : %d\n", kind["R"]
}' "$NAMESTATUS"

awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
NR == FNR { status[$2] = substr($1, 1, 1); next }
{
    p = newpath($3)
    if (excl(p) || (p in G)) next
    a += $1; d += $2
    s = status[p]
    if (s == "A")      { na += $1; nf++ }
    else if (s == "D") { dd += $2; df++ }
    else               { ma += $1; md += $2; mf++ }
}
END {
    printf "\n  lines added              : %d\n", a
    printf "  lines removed            : %d\n", d
    printf "  net                      : %+d\n", a - d
    printf "  total churn              : %d\n", a + d
    printf "\n  in modified files        : %d files, +%d / -%d\n", mf, ma, md
    printf "  in new backport files    : %d files, +%d\n", nf, na
    if (df) printf "  in deleted files         : %d files, -%d\n", df, dd
}' "$NAMESTATUS" "$NUMSTAT"
echo

# --- hunks --------------------------------------------------------------------
echo "-------------------------------------------------------------------"
echo "HUNKS"
echo "-------------------------------------------------------------------"

awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
# Close out the hunk in progress and bucket it by the number of +/- lines it carries.
function fin(   ) {
    if (sz <= 0) return
    hunks++
    perfile[cur] += 1
    if (sz <= 2) b1++
    else if (sz <= 5) b2++
    else if (sz <= 20) b3++
    else if (sz <= 50) b4++
    else b5++
    if (sz > maxsz) { maxsz = sz; maxfile = cur }
    lines += sz
    sz = 0
}
/^diff --git / {
    fin()
    p = $NF; sub(/^b\//, "", p)         # WebKit paths contain no spaces
    cur = p
    skip = (excl(p) || (p in G))
    whole = 0; inhunk = 0
    next
}
# A file added or removed wholesale is one divergence, not one per hunk of its body.
/^new file mode/ { if (!skip) { whole = 1; newfiles++ } next }
/^deleted file mode/ { if (!skip) { whole = 1; delfiles++ } next }
/^@@ / { fin(); inhunk = (skip || whole) ? 0 : 1; next }
{
    if (!inhunk) next
    c = substr($0, 1, 1)
    if (c == "+" || c == "-") sz++
}
END {
    fin()
    nf = 0; for (f in perfile) nf++
    total = hunks + newfiles + delfiles
    printf "  divergent hunks          : %d\n", total
    printf "    in modified files      : %d\n", hunks
    printf "    whole new files        : %d\n", newfiles + 0
    if (delfiles + 0 > 0) printf "    whole deleted files    : %d\n", delfiles
    printf "  (matches check-backport-markers.sh marked+unmarked+deleted+whitespace)\n"
    if (!hunks) { printf "\n  (no hunks in modified files)\n"; exit }
    printf "\n  files carrying hunks     : %d\n", nf
    printf "  mean hunks per file      : %.1f\n", hunks / nf
    printf "  mean lines per hunk      : %.1f\n", lines / hunks
    printf "  largest hunk             : %d lines in %s\n", maxsz, maxfile
    printf "\n  size distribution (modified files):\n"
    printf "    1-2 lines              : %5d  (%4.1f%%)\n", b1 + 0, 100 * b1 / hunks
    printf "    3-5 lines              : %5d  (%4.1f%%)\n", b2 + 0, 100 * b2 / hunks
    printf "    6-20 lines             : %5d  (%4.1f%%)\n", b3 + 0, 100 * b3 / hunks
    printf "    21-50 lines            : %5d  (%4.1f%%)\n", b4 + 0, 100 * b4 / hunks
    printf "    51+ lines              : %5d  (%4.1f%%)\n", b5 + 0, 100 * b5 / hunks
}' "$DIFFU0"
echo

# --- per-project --------------------------------------------------------------
echo "-------------------------------------------------------------------"
echo "BY PROJECT"
echo "-------------------------------------------------------------------"
printf '  %-24s %6s %6s %9s %9s\n' "project" "files" "new" "+lines" "-lines"
awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
NR == FNR { if (substr($1, 1, 1) == "A") added[$2] = 1; next }
{
    p = newpath($3)
    if (excl(p) || (p in G)) next
    n = split(p, seg, "/")
    k = (n >= 2) ? seg[1] "/" seg[2] : p
    f[k]++; a[k] += $1; d[k] += $2
    if (p in added) nnew[k]++
}
END { for (k in f) printf "  %-24s %6d %6d %9d %9d\n", k, f[k], nnew[k] + 0, a[k], d[k] }
' "$NAMESTATUS" "$NUMSTAT" | sort -k4 -rn
echo

# --- per-file-type ------------------------------------------------------------
echo "-------------------------------------------------------------------"
echo "BY FILE TYPE"
echo "-------------------------------------------------------------------"
printf '  %-14s %6s %9s %9s\n' "type" "files" "+lines" "-lines"
awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
{
    p = newpath($3)
    if (excl(p) || (p in G)) next
    if (p ~ /CMakeLists\.txt$/) e = "CMakeLists"
    else {
        n = split(p, part, ".")
        e = (n > 1) ? "." part[n] : "(no ext)"
    }
    f[e]++; a[e] += $1; d[e] += $2
}
END { for (k in f) printf "  %-14s %6d %9d %9d\n", k, f[k], a[k], d[k] }
' "$NUMSTAT" | sort -k3 -rn
echo

awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
{
    p = newpath($3)
    if (excl(p) || (p in G)) next
    if (is_build(p)) { bf++; ba += $1; bd += $2 } else { cf++; ca += $1; cd += $2 }
}
END {
    if (ba + ca)
        printf "  build plumbing           : %d files, +%d / -%d  (%.1f%% of added lines)\n", \
            bf + 0, ba + 0, bd + 0, 100 * ba / (ba + ca)
    printf "  program source           : %d files, +%d / -%d\n", cf + 0, ca + 0, cd + 0
}' "$NUMSTAT"
echo

# --- what the added lines are -------------------------------------------------
echo "-------------------------------------------------------------------"
echo "COMPOSITION OF ADDED LINES"
echo "-------------------------------------------------------------------"
awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
/^diff --git / { p = $NF; sub(/^b\//, "", p); cur = p; skip = (excl(p) || (p in G)); next }
/^--- / { next }
/^\+\+\+ / { next }
/^@@ / { next }
{
    if (skip) next
    if (substr($0, 1, 1) != "+") next
    L = substr($0, 2)
    total++
    t = L; sub(/^[ \t]+/, "", t)
    if (t == "") { blank++; next }
    if (index(L, "MAVERICKS_BACKPORT") > 0) { mark++; next }
    if (is_comment(t, cur)) {
        cmt++
        # Commented-out upstream code, as rule 2 requires, rather than prose.
        if (t ~ /[;{}()]/) disabled++
        next
    }
    code++
}
END {
    printf "  total added lines        : %d\n", total
    if (!total) exit
    printf "    code                   : %5d  (%4.1f%%)\n", code + 0,  100 * code / total
    printf "    comments               : %5d  (%4.1f%%)\n", cmt + 0,   100 * cmt / total
    printf "      of which look like disabled upstream code : %d\n", disabled + 0
    printf "    MAVERICKS_BACKPORT markers : %d  (%.1f%%)\n", mark + 0, 100 * mark / total
    printf "    blank                  : %5d  (%4.1f%%)\n", blank + 0, 100 * blank / total
}' "$DIFFU0"
echo

# --- markers in the working tree ----------------------------------------------
echo "-------------------------------------------------------------------"
echo "MARKERS IN THE WORKING TREE"
echo "-------------------------------------------------------------------"
git grep -c "MAVERICKS_BACKPORT" -- Source/ 2>/dev/null | awk -F: '
{ n += $2; f++ }
END {
    printf "  files carrying a marker  : %d\n", f + 0
    printf "  marker comments          : %d\n", n + 0
    printf "  (markers exceed hunks: git coalesces adjacent divergences into one hunk)\n"
}'
echo

# --- most diverged files ------------------------------------------------------
echo "-------------------------------------------------------------------"
echo "MOST DIVERGED FILES (by hunk count, top $TOPN)"
echo "-------------------------------------------------------------------"
awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
/^diff --git / { p = $NF; sub(/^b\//, "", p); cur = p; skip = (excl(p) || (p in G)); whole = 0; next }
/^new file mode/ { whole = 1; next }
/^deleted file mode/ { whole = 1; next }
/^@@ / { if (skip || whole) next; h[cur]++ }
END { for (f in h) printf "  %5d  %s\n", h[f], f }
' "$DIFFU0" | sort -rn | head -"$TOPN"
echo

echo "-------------------------------------------------------------------"
echo "MOST DIVERGED FILES (by churn, top $TOPN)"
echo "-------------------------------------------------------------------"
awk -v gen="$GENERATED" "$AWK_LIB"'
BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
{ p = newpath($3); if (excl(p) || (p in G)) next; printf "  %5d  +%-6d -%-5d  %s\n", $1 + $2, $1, $2, p }
' "$NUMSTAT" | sort -rn | head -"$TOPN"
echo

# --- out-of-tree support layer ------------------------------------------------
echo "-------------------------------------------------------------------"
echo "OUT-OF-TREE SUPPORT LAYER (MavericksSupport/, excluded above)"
echo "-------------------------------------------------------------------"
echo "  Hand-written code that exists to keep divergence OUT of the in-tree diff."
echo
printf '  %-16s %7s %9s\n' "directory" "files" "lines"
for d in polyfill scripts demangler sdk tests; do
    dir="$REPO_ROOT/MavericksSupport/$d"
    [ -d "$dir" ] || continue
    nf=$(find "$dir" -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.mm' -o -name '*.m' \
         -o -name '*.h' -o -name '*.sh' -o -name '*.py' -o -name '*.cmake' -o -name '*.tbd' \
         -o -name '*.defs' -o -name 'CMakeLists.txt' \) 2>/dev/null | wc -l | tr -d ' ')
    nl=$(find "$dir" -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.mm' -o -name '*.m' \
         -o -name '*.h' -o -name '*.sh' -o -name '*.py' -o -name '*.cmake' -o -name '*.tbd' \
         -o -name '*.defs' -o -name 'CMakeLists.txt' \) -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
    [ "$nf" -gt 0 ] || continue
    printf '  %-16s %7s %9s\n' "$d/" "$nf" "$nl"
done
echo
echo "  Omitted as not hand-written source:"
printf '    deps/, toolchain/  vendored third-party (%s files)\n' \
    "$(find "$REPO_ROOT/MavericksSupport/deps" "$REPO_ROOT/MavericksSupport/toolchain" -type f 2>/dev/null | wc -l | tr -d ' ')"
printf '    safari7-abi/       generated symbol dumps (%s lines of ABI reference data)\n' \
    "$(cat "$REPO_ROOT"/MavericksSupport/safari7-abi/*.txt 2>/dev/null | wc -l | tr -d ' ')"
echo

# --- optional whole-tree denominators -----------------------------------------
if [ "$FULL" -eq 1 ]; then
    echo "-------------------------------------------------------------------"
    echo "DIVERGENCE AS A FRACTION OF THE TREE"
    echo "-------------------------------------------------------------------"
    printf 'Counting every source line under Source/ (slow)...\n' >&2

    TREEFILES="$TMPDIR_RUN/treefiles"
    git ls-files -- Source/ | grep -E '\.(c|cc|cpp|m|mm|h|hpp)$' > "$TREEFILES"
    tree_files=$(wc -l < "$TREEFILES" | tr -d ' ')
    tree_lines=$(tr '\n' '\0' < "$TREEFILES" | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')

    touched=$(awk -v gen="$GENERATED" "$AWK_LIB"'
        BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
        { p = $2; if (excl(p) || (p in G)) next; if (p ~ /\.(c|cc|cpp|m|mm|h|hpp)$/) n++ }
        END { print n + 0 }' "$NAMESTATUS")
    churn=$(awk -v gen="$GENERATED" "$AWK_LIB"'
        BEGIN { while ((getline g < gen) > 0) if (g != "") G[g] = 1; close(gen) }
        { p = newpath($3); if (excl(p) || (p in G)) next; if (p !~ /\.(c|cc|cpp|m|mm|h|hpp)$/) next; c += $1 + $2 }
        END { print c + 0 }' "$NUMSTAT")

    awk -v tf="$tree_files" -v tl="$tree_lines" -v to="$touched" -v ch="$churn" 'BEGIN {
        printf "  C/C++/ObjC files in Source/ : %d\n", tf
        printf "  lines in those files        : %d\n", tl
        printf "\n  of which the backport touches:\n"
        printf "    files                     : %d  (%.2f%%)\n", to, 100 * to / tf
        printf "    lines of churn            : %d  (%.3f%% of the tree)\n", ch, 100 * ch / tl
    }'
    echo
fi

echo "Run check-backport-markers.sh for the conformance gate on these divergences."
exit 0
