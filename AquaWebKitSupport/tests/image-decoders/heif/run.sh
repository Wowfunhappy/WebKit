#!/bin/bash
# Run the HEIF decode harness build.sh built.
#
#   run.sh probe [--ubsan] <files...>
#       Decode each file as HEIFImageDecoder does and print its size, alpha, bit depth, colour
#       profile, grid and transform properties, the coded item types and a checksum of the pixels.
#
#   run.sh fuzz [--ubsan] <rounds> <iterations> <seed-dir>
#       Each round mutates the files in <seed-dir> <iterations> times in one process under libgmalloc
#       (every allocation ends at a guard page) and decodes every mutant. A fault, a UBSan trap
#       (SIGILL) or a 20-second stall writes the input responsible to crash-*.heic / hang-*.heic in
#       WebKitBuild/Release/heif-tests/fuzz/, and summary.txt there has a line per round.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
OUT="$ROOT/WebKitBuild/Release/heif-tests"

COMMAND=${1:-}; shift || true
MODE=release
if [ "${1:-}" = "--ubsan" ]; then MODE=ubsan; shift; fi
HARNESS="$OUT/heif-harness-$MODE"
[ -x "$HARNESS" ] || { echo "run build.sh${MODE/release/}${MODE/ubsan/ --ubsan} first" >&2; exit 2; }

case "$COMMAND" in
probe)
    exec "$HARNESS" probe "$@"
    ;;
fuzz)
    ROUNDS=$1 ITERATIONS=$2 SEEDS=$(cd "$3" && pwd)
    mkdir -p "$OUT/fuzz"
    cd "$OUT/fuzz"
    for ((round = 0; round < ROUNDS; round++)); do
        seed=$RANDOM$RANDOM
        DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib "$HARNESS" fuzz "$ITERATIONS" "$seed" "$SEEDS"/* \
            > "round-$seed.out" 2> "round-$seed.err"
        rc=$?
        echo "$MODE seed=$seed rc=$rc $(tail -1 "round-$seed.out") $(grep -o '\(crash\|hang\)-[0-9]*-[0-9]*\.heic' "round-$seed.err" | tr '\n' ' ')" >> summary.txt
        rm -f "round-$seed.out"
        [ $rc -eq 0 ] && rm -f "round-$seed.err"
    done
    grep -c 'rc=0 ' summary.txt | sed 's/^/clean rounds: /'
    ;;
*)
    sed -n '2,13p' "$0" >&2
    exit 2
    ;;
esac
