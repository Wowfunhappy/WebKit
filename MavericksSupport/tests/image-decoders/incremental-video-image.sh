#!/bin/bash
# Exercise the built Image API with complete, cumulative, repeated and truncated video-image data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/WebKitBuild/Release/incremental-video-image"
if [ "${1:-}" != --no-build ]; then
python3 - "$ROOT" "$OUT" >> /tmp/wk_build.log 2>&1 <<'PY'
import json, pathlib, shlex, subprocess, sys
root, out = map(pathlib.Path, sys.argv[1:])
build = root / 'WebKitBuild/Release'
deps = root / 'MavericksSupport/deps/build'
poly = root / 'MavericksSupport/polyfill/build'
compiler = root / 'MavericksSupport/toolchain/build/clang/bin/clang++'
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
subprocess.run([str(compiler), *flags, '-c', str(root / 'MavericksSupport/tests/image-decoders/incremental-video-image.mm'), '-o', str(out) + '.o'], cwd=build, check=True)
subprocess.run([str(compiler), '-mmacosx-version-min=10.9', str(out) + '.o', '-o', str(out), '-F' + str(build / 'lib'), '-framework', 'WebCore', '-framework', 'JavaScriptCore', '-framework', 'Foundation', '-framework', 'AppKit', '-Wl,-client_name,TestWebCore', str(poly / 'libpolyfill.a'), '-L' + str(poly), '-lpolyfill_classes', '-Wl,-rpath,' + str(build / 'lib'), '-Wl,-rpath,' + str(deps / 'lib'), '-Wl,-rpath,' + str(poly)], check=True)
PY
bash "$ROOT/MavericksSupport/scripts/make-build-binaries-runnable.sh" "$OUT" >> /tmp/wk_build.log 2>&1
fi
export DYLD_FRAMEWORK_PATH="$ROOT/WebKitBuild/Release/lib${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export __XPC_DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH"
result=0
"$OUT" "$ROOT/LayoutTests/http/tests/resources/test.mp4" video/mp4 || result=1
"$OUT" "$ROOT/LayoutTests/fast/images/resources/sticker.heics" image/heic-sequence || result=1
exit "$result"
