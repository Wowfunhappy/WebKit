#!/bin/bash
#
# check-backport-markers.sh
#
# Audits the WebKit Mavericks backport for source divergences from the upstream
# base commit that LACK a canonical `MAVERICKS_BACKPORT` marker comment.
#
# Project rule: EVERY hunk that differs from upstream MUST carry a
# `MAVERICKS_BACKPORT` marker, placed WITHIN or IMMEDIATELY ABOVE the divergent
# lines (per-hunk, not one umbrella comment per file).
#
# This script classifies each diverging hunk in Source/ into:
#   (a) UNMARKED              - no canonical and no legacy marker nearby  -> CI failure
#   (b) legacy-marker         - only a freeform legacy phrasing ("10.9 backport",
#                               "macOS 10.9 backport", "Mavericks backport"); needs
#                               normalization to MAVERICKS_BACKPORT
#   (c) deletion-without-marker - a pure-deletion hunk whose surrounding current-file
#                               context has no marker
# Canonically MARKED hunks are silent (they pass).
#
# Exit status:
#   0  - no truly-UNMARKED hunks (legacy / deletion-without-marker may still exist)
#   1  - at least one truly-UNMARKED hunk (gate failure)
#   2  - usage / environment error
#
# Base commit resolution (first match wins):
#   1. $1 (CLI argument)                      -- manual override
#   2. $MAVERICKS_UPSTREAM_BASE (env var)     -- manual override
#   3. AUTO-DISCOVER: git merge-base HEAD <upstream ref>   <-- normal path
#      (upstream ref is origin/main by default; override via $MAVERICKS_UPSTREAM_REF)
#   4. fallback default: 83b24ce              -- last-resort safety net only
#
# The base is the point where the mavericks-backport branch diverged from the
# upstream WebKit line. As upstream is merged in, that branch point (merge-base)
# moves forward, and step 3 discovers it automatically -- no config file, no edit.
# There is intentionally NO pinned base file: discovery is always live.
#
# BSD-tool safe: no `grep -P`, no GNU-only sed/awk extensions.

set -u

# --- canonical marker + legacy phrasings -----------------------------------
CANONICAL="MAVERICKS_BACKPORT"
# Legacy phrasings are matched case-insensitively. Extend this list if older
# divergences use further wording.
LEGACY_PATTERNS='10.9 backport|macos 10.9 backport|mavericks backport'

# Number of current-file context lines to scan ABOVE a hunk for a marker.
# Kept small on purpose: a wide window risks a marker for hunk A spuriously
# "covering" an unrelated hunk B just below it (false negative). Override via
# $MAVERICKS_CONTEXT_ABOVE if your local convention places markers further up.
# Known cost of the small window: when git splits ONE logical divergence (e.g. a
# multi-line #if) into two physical hunks, a marker on the first hunk may sit
# more than CONTEXT_ABOVE lines above the second hunk, so the second is reported
# as UNMARKED even though the marker plainly covers the block. Treat such a
# report line as covered if a marker is visible just above it in the file.
CONTEXT_ABOVE="${MAVERICKS_CONTEXT_ABOVE:-3}"

# --- locate repo root ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root $REPO_ROOT" >&2; exit 2; }

DEFAULT_BASE="83b24ce"
# Upstream refs to compute the merge-base against, in order of preference.
# The first that resolves is used. No config file is involved -- discovery is
# always live, so it tracks the branch point as upstream is merged in.
UPSTREAM_REF_CANDIDATES="${MAVERICKS_UPSTREAM_REF:-origin/main main}"

# --- resolve base commit (always auto-discover; no pin file) ----------------
# Sets BASE and BASE_SOURCE. Runs in the current shell (no subshell) so the
# discovered ref name is available for the human-readable source label.
BASE=""
BASE_SOURCE=""
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    BASE="$1"; BASE_SOURCE="CLI argument (manual override)"
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
BASE_FULL="$(git rev-parse --short "$BASE")"
echo "Upstream base: $BASE_FULL  (resolved from: $BASE_SOURCE)"
echo "Scope: Source/  (excluding vendored binaries, build/generated dirs, and MavericksSupport/)"
echo

# --- path exclusion --------------------------------------------------------
# Returns 0 if the path should be EXCLUDED from the audit.
is_excluded_path() {
    case "$1" in
        MavericksSupport/*|*/MavericksSupport/*) return 0 ;;
        WebKitBuild/*|*/WebKitBuild/*) return 0 ;;
        */DerivedSources/*|*/Derived/*) return 0 ;;
        # vendored prebuilt binary artifacts under Source/ThirdParty
        Source/ThirdParty/*/lib/*) return 0 ;;
    esac
    # Binary-ish extensions (vendored prebuilt blobs, images, fonts, archives).
    case "$1" in
        *.a|*.o|*.dylib|*.so|*.bin|*.dat|*.png|*.jpg|*.jpeg|*.gif|*.bmp|*.ico|*.icns\
        |*.ttf|*.otf|*.woff|*.woff2|*.pdf|*.zip|*.gz|*.tar|*.mov|*.mp4|*.webp|*.wasm)
            return 0 ;;
    esac
    return 1
}

# --- temp output buckets ---------------------------------------------------
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/backport-markers.XXXXXX")" || exit 2
OUT_UNMARKED="$TMPDIR_RUN/unmarked"
OUT_LEGACY="$TMPDIR_RUN/legacy"
OUT_DELETION="$TMPDIR_RUN/deletion"
OUT_NEWFILE="$TMPDIR_RUN/newfile"
: > "$OUT_UNMARKED"; : > "$OUT_LEGACY"; : > "$OUT_DELETION"; : > "$OUT_NEWFILE"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# counters
n_unmarked=0; n_legacy=0; n_deletion=0; n_marked=0; n_newfile_bad=0; n_ws=0

# --- detect generated (non-source) files committed under Source/ ------------
# Some build artifacts (e.g. CMake-emitted Makefiles) carry a "DO NOT EDIT"
# banner and were committed into the tree. They are NOT hand-edited source
# divergences and must not be audited for markers. Build a NUL-delimited skip
# list by sniffing the first few lines of every changed file.
GENERATED_LIST="$TMPDIR_RUN/generated"
: > "$GENERATED_LIST"
git diff --name-only -z "$BASE" -- Source/ 2>/dev/null | \
while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    if head -3 "$f" 2>/dev/null | grep -qiE 'generated file: do not edit|do not edit this file|auto-generated|automatically generated'; then
        printf '%s\0' "$f" >> "$GENERATED_LIST"
    fi
done
# plain-text (newline-delimited) copy for awk consumption
GENERATED_TXT="$TMPDIR_RUN/generated.txt"
tr '\0' '\n' < "$GENERATED_LIST" > "$GENERATED_TXT"

is_generated_file() {
    # exact membership test against the generated skip list
    target="$1"
    while IFS= read -r g; do
        [ "$g" = "$target" ] && return 0
    done < "$GENERATED_TXT"
    return 1
}

# --- new-file classification (single git call) -----------------------------
# Brand-new files added by the backport: require >=1 canonical marker in the
# whole file. Records "path" NUL-delimited.
NEWFILES_LIST="$TMPDIR_RUN/newfiles"
git diff --diff-filter=A --name-only -z "$BASE" -- Source/ > "$NEWFILES_LIST" 2>/dev/null

while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    is_excluded_path "$file" && continue
    is_generated_file "$file" && continue
    [ -f "$file" ] || continue   # deleted/renamed-away: nothing to scan
    if grep -q "$CANONICAL" "$file" 2>/dev/null; then
        continue  # new file carries the canonical marker -> ok
    fi
    legacy_note=""
    if grep -iqE "$LEGACY_PATTERNS" "$file" 2>/dev/null; then
        legacy_note="  [has only legacy phrasing -- needs normalization]"
    fi
    snippet="$(grep -vE '^[[:space:]]*$' "$file" 2>/dev/null | head -1 | cut -c1-120)"
    printf '%s:1: NEW FILE lacks %s marker%s\n    %s\n' \
        "$file" "$CANONICAL" "$legacy_note" "$snippet" >> "$OUT_NEWFILE"
    n_newfile_bad=$((n_newfile_bad + 1))
done < "$NEWFILES_LIST"

# --- per-hunk audit of modified files (single streaming diff) ---------------
# One `git diff -U0` over all of Source/ is parsed by awk into per-hunk records.
# For each modified hunk awk decides MARKED/legacy/deletion/whitespace using the
# hunk's own added/removed lines, and ALSO checks ~CONTEXT_ABOVE lines of the
# current working-tree file just above the hunk (read directly by awk via
# getline) so a marker placed immediately above the divergence still counts.
#
# Records emitted on stdout (TAB-separated), one per non-MARKED hunk:
#     <category>\t<file>\t<newline>\t<snippet>
# plus tally lines:  #TALLY <name> <count>
# New files (diff-filter=A) are excluded here -- handled above.

AWK_REPORT="$TMPDIR_RUN/awk_report"
git diff -U0 "$BASE" -- Source/ 2>/dev/null | awk \
    -v CAN="$CANONICAL" \
    -v LEGRE="$LEGACY_PATTERNS" \
    -v CTXN="$CONTEXT_ABOVE" \
    -v GENF="$GENERATED_TXT" '
BEGIN {
    # Load the generated-file skip set (one path per line).
    if (GENF != "") {
        while ((getline gl < GENF) > 0) { if (gl != "") gen[gl] = 1 }
        close(GENF)
    }
}
function lc(s){ return tolower(s) }
function has_can(s){ return index(s, CAN) > 0 }
# case-insensitive ERE match against the legacy alternation
function has_leg(s){ return lc(s) ~ ("(" LEGRE ")") }
function strip_ws(s){ gsub(/[ \t\r\n]/, "", s); return s }
function trim(s){ sub(/^[ \t]+/, "", s); return s }

# Read CTXN current-file lines ABOVE 1-based line "ln" of "f"; append to a string.
function ctx_above(f, ln,    s, i, start, end, k, line, out) {
    out = ""
    if (f == "" || ln <= 1) return ""
    start = ln - CTXN; if (start < 1) start = 1
    end = ln - 1; if (end < 1) return ""
    k = 0
    # naive: read file from top to end (files are small; only ambiguous hunks).
    while ((getline line < f) > 0) {
        k++
        if (k >= start && k <= end) out = out "\n" line
        if (k >= end) break
    }
    close(f)
    return out
}

function flush(   added_strip, removed_strip, combined, ctx, snip, cat) {
    if (!have) return
    added_strip = strip_ws(added)
    removed_strip = strip_ws(removed)

    # whitespace-only: added/removed identical ignoring whitespace
    if ((added_strip != "" || removed_strip != "") && added_strip == removed_strip) {
        ws++; return
    }

    # marker in added lines?
    if (has_can(added)) { marked++; return }

    # else check current-file context just above the hunk
    ctx = ctx_above(curfile, newstart)
    combined = added "\n" ctx
    if (has_can(combined)) { marked++; return }

    # snippet: first non-blank added, else context tail, else removed
    snip = first_nonblank(added)
    if (snip == "") snip = last_nonblank(ctx)
    if (snip == "") snip = first_nonblank(removed)
    snip = trim(snip)
    if (length(snip) > 120) snip = substr(snip, 1, 120)

    is_del = (added_strip == "" && removed_strip != "")

    if (has_leg(combined)) {
        cat = "LEGACY"; legacy++
    } else if (is_del) {
        cat = "DELETION"; deletion++
        snip = "-" snip
    } else {
        cat = "UNMARKED"; unmarked++
    }
    printf "%s\t%s\t%s\t%s\n", cat, curfile, newstart, snip
}

function first_nonblank(s,   a, n, i, t) {
    n = split(s, a, "\n")
    for (i = 1; i <= n; i++) { t = a[i]; if (t ~ /[^ \t\r]/) return t }
    return ""
}
function last_nonblank(s,   a, n, i, t, r) {
    n = split(s, a, "\n"); r = ""
    for (i = 1; i <= n; i++) { t = a[i]; if (t ~ /[^ \t\r]/) r = t }
    return r
}

# new diff file header: "diff --git a/PATH b/PATH"
/^diff --git / {
    flush()
    have = 0
    # take the b/ side (post-image path); robust to spaces is hard in awk, but
    # WebKit paths have none. Strip leading "b/".
    bpath = $NF; sub(/^b\//, "", bpath)
    curfile = bpath
    skip = (is_excluded(curfile) || (curfile in gen))
    next
}
/^--- / { next }
/^\+\+\+ / { next }
/^Binary files / { next }

# hunk header: @@ -a[,b] +c[,d] @@
/^@@ / {
    flush()
    if (skip) { have = 0; next }
    # field 3 is "+c,d" or "+c"
    plus = $3; sub(/^\+/, "", plus)
    np = plus
    sub(/,.*/, "", np)         # c
    cnt = plus
    if (index(plus, ",") > 0) sub(/^[^,]*,/, "", cnt); else cnt = ""
    newstart = np + 0
    # pure-deletion hunk "+c,0": anchor context just above the deletion site.
    if (cnt == "0") newstart = newstart + 1
    added = ""; removed = ""; have = 1
    next
}
{
    if (!have || skip) next
    c = substr($0, 1, 1)
    rest = substr($0, 2)
    if (c == "+") added = added "\n" rest
    else if (c == "-") removed = removed "\n" rest
}

END { flush();
      printf "#TALLY marked %d\n", marked
      printf "#TALLY unmarked %d\n", unmarked
      printf "#TALLY legacy %d\n", legacy
      printf "#TALLY deletion %d\n", deletion
      printf "#TALLY ws %d\n", ws
}

# --- exclusion predicate mirrored in awk -----------------------------------
function is_excluded(p) {
    if (p ~ /(^|\/)MavericksSupport\//) return 1
    if (p ~ /(^|\/)WebKitBuild\//) return 1
    if (p ~ /\/DerivedSources\//) return 1
    if (p ~ /\/Derived\//) return 1
    if (p ~ /^Source\/ThirdParty\/[^\/]+\/lib\//) return 1
    if (p ~ /\.(a|o|dylib|so|bin|dat|png|jpg|jpeg|gif|bmp|ico|icns|ttf|otf|woff|woff2|pdf|zip|gz|tar|mov|mp4|webp|wasm)$/) return 1
    return 0
}
' > "$AWK_REPORT"

# --- demux awk report into category buckets + counters ----------------------
# Tally lines start with "#TALLY"; data lines are TAB-separated.
while IFS= read -r row; do
    case "$row" in
        '#TALLY '*)
            set -- $row   # #TALLY name count
            case "$2" in
                marked)   n_marked="$3" ;;
                unmarked) n_unmarked="$3" ;;
                legacy)   n_legacy="$3" ;;
                deletion) n_deletion="$3" ;;
                ws)       n_ws="$3" ;;
            esac
            ;;
        *)
            cat="${row%%	*}"               # up to first TAB
            rest="${row#*	}"
            file="${rest%%	*}"
            rest2="${rest#*	}"
            line="${rest2%%	*}"
            snip="${rest2#*	}"
            case "$cat" in
                UNMARKED)
                    printf '%s:%s: UNMARKED hunk (no %s nearby)\n    %s\n' \
                        "$file" "$line" "$CANONICAL" "$snip" >> "$OUT_UNMARKED" ;;
                LEGACY)
                    printf '%s:%s: legacy marker (needs normalization to %s)\n    %s\n' \
                        "$file" "$line" "$CANONICAL" "$snip" >> "$OUT_LEGACY" ;;
                DELETION)
                    printf '%s:%s: deletion-without-marker (no nearby %s)\n    %s\n' \
                        "$file" "$line" "$CANONICAL" "$snip" >> "$OUT_DELETION" ;;
            esac
            ;;
    esac
done < "$AWK_REPORT"

# --- report ----------------------------------------------------------------
print_section() {
    title="$1"; file="$2"
    echo "==================================================================="
    echo "$title"
    echo "==================================================================="
    if [ -s "$file" ]; then
        cat "$file"
    else
        echo "(none)"
    fi
    echo
}

print_section "(a) UNMARKED hunks  [gate-failing]" "$OUT_UNMARKED"
print_section "(b) legacy-marker hunks  [needs normalization to $CANONICAL]" "$OUT_LEGACY"
print_section "(c) deletion-without-marker hunks" "$OUT_DELETION"
print_section "(d) NEW files lacking a $CANONICAL marker  [gate-failing]" "$OUT_NEWFILE"

echo "==================================================================="
echo "TOTALS"
echo "==================================================================="
echo "  canonically MARKED hunks (pass) : $n_marked"
echo "  UNMARKED hunks                  : $n_unmarked"
echo "  legacy-marker hunks             : $n_legacy"
echo "  deletion-without-marker hunks   : $n_deletion"
echo "  NEW files missing marker        : $n_newfile_bad"
echo "  whitespace-only hunks (ignored) : $n_ws"
echo

# Gate: fail on truly-unmarked hunks OR unmarked new files.
fail=0
[ "$n_unmarked" -gt 0 ] && fail=1
[ "$n_newfile_bad" -gt 0 ] && fail=1
if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL - $((n_unmarked + n_newfile_bad)) divergence(s) without a $CANONICAL marker."
    exit 1
fi
echo "RESULT: PASS - every diverging hunk carries a $CANONICAL marker (legacy/deletion items above are advisory)."
exit 0
