#!/bin/bash
#
# check-backport-markers.sh
#
# Audits the WebKit Mavericks backport for source divergences from the upstream
# base commit that violate the divergence rules:
#
#   1. Every hunk that differs from upstream carries a `MAVERICKS_BACKPORT`
#      marker comment, placed WITHIN or IMMEDIATELY ABOVE the divergent lines
#      (per-hunk, not one umbrella comment per file).
#   2. Upstream code is never deleted outright. Divergences that disable
#      upstream code comment it out instead — `//` for a line or two, `/* */`
#      for anything longer — so upstream merges see the original text in place.
#      A pure-deletion hunk is therefore always a violation, marker or not.
#   3. A file added by the backport carries at least one marker.
#   4. Whitespace-only differences are divergence too: restore upstream's exact
#      bytes. (In whitespace-semantic files — Python, Makefiles — they are also
#      real behavioral changes, which is why they are never silently skipped.)
#
# Report sections:
#   (a) UNMARKED    - modified hunk with no marker in it or just above it
#   (b) DELETED     - pure-deletion hunk (restore the lines, commented out)
#   (c) NEW FILE    - backport-added file without a marker
#   (d) WHITESPACE  - hunk identical to upstream except whitespace (revert it)
# Marked, rule-conforming hunks are silent.
#
# Exit status:
#   0  - no violations
#   1  - at least one violation
#   2  - usage / environment error
#
# Base commit resolution (first match wins):
#   1. $1 (CLI argument)                      -- manual override
#   2. $MAVERICKS_UPSTREAM_BASE (env var)     -- manual override
#   3. auto-discover: git merge-base HEAD <upstream ref>
#      (upstream ref is origin/main by default; override via $MAVERICKS_UPSTREAM_REF)
#   4. built-in fallback: 83b24ce             -- last-resort safety net only
#
# The base is the point where the mavericks-backport branch diverged from the
# upstream WebKit line; merge-base discovery tracks it as upstream is merged in.
#
# BSD-tool safe: no `grep -P`, no GNU-only sed/awk extensions.

set -u

MARKER="MAVERICKS_BACKPORT"

# Number of current-file context lines to scan ABOVE a hunk for a marker.
# Kept small on purpose: a wide window risks a marker for hunk A spuriously
# "covering" an unrelated hunk B just below it. When git splits one logical
# divergence into two physical hunks, the second can be reported UNMARKED even
# though the marker plainly covers the block — treat such a report line as
# covered if a marker is visible just above it in the file.
CONTEXT_ABOVE="${MAVERICKS_CONTEXT_ABOVE:-3}"

# --- locate repo root ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root $REPO_ROOT" >&2; exit 2; }

DEFAULT_BASE="83b24ce"
UPSTREAM_REF_CANDIDATES="${MAVERICKS_UPSTREAM_REF:-origin/main main}"

# --- resolve base commit ----------------------------------------------------
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
echo "Upstream base: $(git rev-parse --short "$BASE")  (resolved from: $BASE_SOURCE)"
echo "Scope: Source/  (excluding vendored binaries, .json, build/generated dirs, and MavericksSupport/)"
echo

# --- path exclusion (mirrored in the awk below) ------------------------------
is_excluded_path() {
    case "$1" in
        MavericksSupport/*|*/MavericksSupport/*) return 0 ;;
        WebKitBuild/*|*/WebKitBuild/*) return 0 ;;
        */DerivedSources/*|*/Derived/*) return 0 ;;
        Source/ThirdParty/*/lib/*) return 0 ;;
    esac
    case "$1" in
        *.a|*.o|*.dylib|*.so|*.bin|*.dat|*.png|*.jpg|*.jpeg|*.gif|*.bmp|*.ico|*.icns\
        |*.ttf|*.otf|*.woff|*.woff2|*.pdf|*.zip|*.gz|*.tar|*.mov|*.mp4|*.webp|*.wasm)
            return 0 ;;
    esac
    # JSON has no comment syntax, so a divergent line in a .json file cannot carry a
    # marker; the extension is excluded from the audit.
    case "$1" in
        *.json) return 0 ;;
    esac
    return 1
}

# --- temp output buckets ------------------------------------------------------
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/backport-markers.XXXXXX")" || exit 2
OUT_UNMARKED="$TMPDIR_RUN/unmarked"
OUT_DELETED="$TMPDIR_RUN/deleted"
OUT_NEWFILE="$TMPDIR_RUN/newfile"
OUT_WS="$TMPDIR_RUN/whitespace"
: > "$OUT_UNMARKED"; : > "$OUT_DELETED"; : > "$OUT_NEWFILE"; : > "$OUT_WS"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

n_unmarked=0; n_deleted=0; n_marked=0; n_newfile_bad=0; n_ws=0

# --- generated (non-source) files committed under Source/ ---------------------
# Build artifacts with a "do not edit" banner are not hand-edited divergences
# and are skipped.
GENERATED_TXT="$TMPDIR_RUN/generated.txt"
: > "$GENERATED_TXT"
git diff --name-only -z "$BASE" -- Source/ 2>/dev/null | \
while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    if head -3 "$f" 2>/dev/null | grep -qiE 'generated file: do not edit|do not edit this file|auto-generated|automatically generated'; then
        printf '%s\n' "$f" >> "$GENERATED_TXT"
    fi
done

is_generated_file() {
    grep -Fxq "$1" "$GENERATED_TXT" 2>/dev/null
}

# --- new files: require >=1 marker anywhere in the file -----------------------
git diff --diff-filter=A --name-only -z "$BASE" -- Source/ 2>/dev/null | \
while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    is_excluded_path "$file" && continue
    is_generated_file "$file" && continue
    [ -f "$file" ] || continue
    grep -q "$MARKER" "$file" 2>/dev/null && continue
    snippet="$(grep -vE '^[[:space:]]*$' "$file" 2>/dev/null | head -1 | cut -c1-120)"
    printf '%s:1: NEW FILE lacks a %s marker\n    %s\n' "$file" "$MARKER" "$snippet" >> "$OUT_NEWFILE"
done
# grep -c prints the count even when it is 0 (exiting 1), so no fallback needed.
n_newfile_bad="$(grep -c ': NEW FILE ' "$OUT_NEWFILE" 2>/dev/null)" || true

# --- per-hunk audit of modified files ------------------------------------------
# One `git diff -U0` over Source/ is parsed by awk into per-hunk records. Each
# hunk is classified from its own added/removed lines plus ~CONTEXT_ABOVE lines
# of the current working-tree file just above it (a marker immediately above the
# divergence counts). New files are handled above and excluded here.
#
# Emitted records (TAB-separated):  <category>\t<file>\t<line>\t<snippet>
# plus tally lines:                 #TALLY <name> <count>

AWK_REPORT="$TMPDIR_RUN/awk_report"
git diff -U0 "$BASE" -- Source/ 2>/dev/null | awk \
    -v MARKER="$MARKER" \
    -v CTXN="$CONTEXT_ABOVE" \
    -v GENF="$GENERATED_TXT" '
BEGIN {
    if (GENF != "") {
        while ((getline gl < GENF) > 0) { if (gl != "") gen[gl] = 1 }
        close(GENF)
    }
}
function has_marker(s){ return index(s, MARKER) > 0 }
function strip_ws(s){ gsub(/[ \t\r\n]/, "", s); return s }
function trim(s){ sub(/^[ \t]+/, "", s); return s }

# CTXN current-file lines just above 1-based line "ln" of "f".
function ctx_above(f, ln,    i, start, end, k, line, out) {
    out = ""
    if (f == "" || ln <= 1) return ""
    start = ln - CTXN; if (start < 1) start = 1
    end = ln - 1
    k = 0
    while ((getline line < f) > 0) {
        k++
        if (k >= start && k <= end) out = out "\n" line
        if (k >= end) break
    }
    close(f)
    return out
}

function first_nonblank(s,   a, n, i, t) {
    n = split(s, a, "\n")
    for (i = 1; i <= n; i++) { t = a[i]; if (t ~ /[^ \t\r]/) return t }
    return ""
}

function flush(   added_strip, removed_strip, ctx, snip) {
    if (!have) return
    added_strip = strip_ws(added)
    removed_strip = strip_ws(removed)

    # identical to upstream except whitespace: divergence with a trivial fix
    if ((added_strip != "" || removed_strip != "") && added_strip == removed_strip) {
        ws++
        snip = trim(first_nonblank(added))
        if (length(snip) > 120) snip = substr(snip, 1, 120)
        printf "WHITESPACE\t%s\t%s\t%s\n", curfile, newstart, snip
        return
    }

    # Pure deletion: always a violation — the divergence rules keep upstream
    # text in place, commented out, so a marker cannot excuse it.
    if (added_strip == "" && removed_strip != "") {
        deleted++
        snip = trim(first_nonblank(removed))
        if (length(snip) > 120) snip = substr(snip, 1, 120)
        printf "DELETED\t%s\t%s\t-%s\n", curfile, newstart, snip
        return
    }

    if (has_marker(added)) { marked++; return }
    ctx = ctx_above(curfile, newstart)
    if (has_marker(ctx)) { marked++; return }

    unmarked++
    snip = trim(first_nonblank(added))
    if (length(snip) > 120) snip = substr(snip, 1, 120)
    printf "UNMARKED\t%s\t%s\t%s\n", curfile, newstart, snip
}

/^diff --git / {
    flush()
    have = 0
    bpath = $NF; sub(/^b\//, "", bpath)   # WebKit paths contain no spaces
    curfile = bpath
    skip = (is_excluded(curfile) || (curfile in gen))
    next
}
/^--- / { next }
/^\+\+\+ / { next }
/^Binary files / { next }

/^@@ / {
    flush()
    if (skip) { have = 0; next }
    plus = $3; sub(/^\+/, "", plus)
    np = plus; sub(/,.*/, "", np)
    cnt = plus
    if (index(plus, ",") > 0) sub(/^[^,]*,/, "", cnt); else cnt = ""
    newstart = np + 0
    # pure-deletion hunks report the line BEFORE the deletion; anchor below it
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

END {
    flush()
    printf "#TALLY marked %d\n", marked
    printf "#TALLY unmarked %d\n", unmarked
    printf "#TALLY deleted %d\n", deleted
    printf "#TALLY ws %d\n", ws
}

function is_excluded(p) {
    if (p ~ /(^|\/)MavericksSupport\//) return 1
    if (p ~ /(^|\/)WebKitBuild\//) return 1
    if (p ~ /\/DerivedSources\//) return 1
    if (p ~ /\/Derived\//) return 1
    if (p ~ /^Source\/ThirdParty\/[^\/]+\/lib\//) return 1
    if (p ~ /\.(a|o|dylib|so|bin|dat|png|jpg|jpeg|gif|bmp|ico|icns|ttf|otf|woff|woff2|pdf|zip|gz|tar|mov|mp4|webp|wasm)$/) return 1
    # JSON has no comment syntax to carry a marker.
    if (p ~ /\.json$/) return 1
    return 0
}
' > "$AWK_REPORT"

# --- demux awk report ---------------------------------------------------------
while IFS= read -r row; do
    case "$row" in
        '#TALLY '*)
            set -- $row
            case "$2" in
                marked)   n_marked="$3" ;;
                unmarked) n_unmarked="$3" ;;
                deleted)  n_deleted="$3" ;;
                ws)       n_ws="$3" ;;
            esac
            ;;
        *)
            cat="${row%%	*}"
            rest="${row#*	}"
            file="${rest%%	*}"
            rest2="${rest#*	}"
            line="${rest2%%	*}"
            snip="${rest2#*	}"
            case "$cat" in
                UNMARKED)
                    printf '%s:%s: UNMARKED hunk (no %s in or just above it)\n    %s\n' \
                        "$file" "$line" "$MARKER" "$snip" >> "$OUT_UNMARKED" ;;
                DELETED)
                    printf '%s:%s: DELETED hunk (restore the lines commented out — /* */ for blocks — with a %s marker)\n    %s\n' \
                        "$file" "$line" "$MARKER" "$snip" >> "$OUT_DELETED" ;;
                WHITESPACE)
                    printf '%s:%s: WHITESPACE-only divergence (restore upstream bytes)\n    %s\n' \
                        "$file" "$line" "$snip" >> "$OUT_WS" ;;
            esac
            ;;
    esac
done < "$AWK_REPORT"

# --- report ---------------------------------------------------------------------
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

print_section "(a) UNMARKED hunks" "$OUT_UNMARKED"
print_section "(b) DELETED hunks (comment out instead of deleting)" "$OUT_DELETED"
print_section "(c) NEW files lacking a $MARKER marker" "$OUT_NEWFILE"
print_section "(d) WHITESPACE-only divergences (restore upstream bytes)" "$OUT_WS"

echo "==================================================================="
echo "TOTALS"
echo "==================================================================="
echo "  conforming MARKED hunks (pass)  : $n_marked"
echo "  UNMARKED hunks                  : $n_unmarked"
echo "  DELETED hunks                   : $n_deleted"
echo "  NEW files missing marker        : $n_newfile_bad"
echo "  WHITESPACE-only hunks           : $n_ws"
echo

violations=$((n_unmarked + n_deleted + n_newfile_bad + n_ws))
if [ "$violations" -gt 0 ]; then
    echo "RESULT: FAIL - $violations violation(s) of the divergence rules."
    exit 1
fi
echo "RESULT: PASS - every divergence is marked, none deleted, none whitespace-only."
exit 0
