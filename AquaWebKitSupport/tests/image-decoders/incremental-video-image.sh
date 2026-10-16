#!/bin/bash
# Exercise the built Image API with complete, cumulative, repeated and truncated video-image data. The
# program builds against WebKitBuild/Release, records the finished build it was compiled against in
# <program>.build, and runs only against the copy of that build (test-products-snapshot.sh), which the
# other test runners share under the test-run lock. The run names the build it tests when it starts
# and in its last line.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/WebKitBuild/Release/incremental-video-image"
. "$ROOT/AquaWebKitSupport/scripts/products-lock.sh"
if [ "${1:-}" != --no-build ]; then
rm -f "$OUT.build"
TREE_BUILD=$(finished_tree_build) || { echo "WebKitBuild/Release holds no finished build -- run AquaWebKitSupport/build.sh" >&2; exit 1; }
python3 - "$ROOT" "$OUT" >> /tmp/wk_build.log 2>&1 <<'PY'
import json, pathlib, shlex, subprocess, sys
root, out = map(pathlib.Path, sys.argv[1:])
build = root / 'WebKitBuild/Release'
deps = root / 'AquaWebKitSupport/deps/build'
poly = root / 'AquaWebKitSupport/polyfill/build'
compiler = root / 'AquaWebKitSupport/toolchain/build/clang/bin/clang++'
commands = json.loads((build / 'compile_commands.json').read_text())
entry = next(e for e in commands if e['file'].endswith('/CocoaCurlTransfer.mm'))
args = shlex.split(entry['command'])[1:]
flags = []
it = iter(args)
for arg in it:
    if arg == '-o':
        next(it)
    elif arg not in ('-c', entry['file']):
        flags.append(arg)
subprocess.run([str(compiler), *flags, '-c', str(root / 'AquaWebKitSupport/tests/image-decoders/incremental-video-image.mm'), '-o', str(out) + '.o'], cwd=build, check=True)
subprocess.run([str(compiler), '-mmacosx-version-min=10.9', str(out) + '.o', '-o', str(out), '-F' + str(build / 'lib'), '-framework', 'WebCore', '-framework', 'JavaScriptCore', '-framework', 'Foundation', '-framework', 'AppKit', '-Wl,-client_name,TestWebCore', str(poly / 'libpolyfill.a'), '-L' + str(poly), '-lpolyfill_classes', '-Wl,-rpath,' + str(build / 'lib'), '-Wl,-rpath,' + str(deps / 'lib'), '-Wl,-rpath,' + str(poly)], check=True)
PY
[ "$(finished_tree_build)" = "$TREE_BUILD" ] || { echo "WebKitBuild/Release changed while $OUT was built" >&2; exit 1; }
echo "$TREE_BUILD" > "$OUT.build"
fi
. "$ROOT/AquaWebKitSupport/scripts/test-run-lock.sh"
. "$ROOT/AquaWebKitSupport/scripts/test-products-snapshot.sh"
trap 'release_products_lock; release_test_run_lock; tested_build_report' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_test_run_lock
snapshot_test_products || { echo "could not copy the build products" >&2; exit 1; }
tested_build_report
program_matches_copy "$OUT" "$OUT.build" || exit 1
bash "$ROOT/AquaWebKitSupport/scripts/make-build-binaries-runnable.sh" --products="$TEST_PRODUCTS" "$OUT" \
    || { echo "could not make $OUT loadable" >&2; exit 1; }
export DYLD_FRAMEWORK_PATH="$TEST_PRODUCTS/lib${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export __XPC_DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH"
result=0
"$OUT" "$ROOT/LayoutTests/http/tests/resources/test.mp4" video/mp4 || result=1
"$OUT" "$ROOT/LayoutTests/fast/images/resources/sticker.heics" image/heic-sequence || result=1
exit "$result"
