#!/bin/bash
# Exercise the dependency builder's publication guard without building packages.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/MavericksSupport/deps/build_deps.sh"
WORK=$(mktemp -d /tmp/webkit-recipe-publication.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
START=$(awk '$0 == "RECIPES_KEY=$(recipes_key) || exit 1" { print }' "$SCRIPT")
PUBLISH=$(awk '/^CURRENT_RECIPES_KEY=/ { selected=1 }
    selected { print }
    selected && /^printf .*DEST\/\.recipes/ { exit }' "$SCRIPT")
[ -n "$START" ] && [ -n "$PUBLISH" ]

run_case() (
    DEST="$WORK/$1"
    mkdir "$DEST"
    CURRENT_INPUT=original
    recipes_key() {
        [ "$CURRENT_INPUT" != hash-error ] || return 1
        printf '%s\n' "$CURRENT_INPUT"
    }
    eval "$START"
    CURRENT_INPUT="$2"
    eval "$PUBLISH"
)

run_case unchanged original
[ "$(< "$WORK/unchanged/.recipes")" = original ]
if run_case changed modified > "$WORK/changed.log" 2>&1; then
    echo 'FAIL: changed inputs were published' >&2
    exit 1
fi
[ ! -e "$WORK/changed/.recipes" ]
if run_case hash-error hash-error > "$WORK/hash-error.log" 2>&1; then
    echo 'FAIL: failed input hashing was published' >&2
    exit 1
fi
[ ! -e "$WORK/hash-error/.recipes" ]
echo 'PASS: unchanged recipe published; changed inputs and hashing errors refused'
