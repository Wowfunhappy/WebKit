#!/usr/bin/env python3
"""Compile and exercise the bounded encoded-frame queue against the installed frameworks."""
import json
import pathlib
import resource
import shlex
import subprocess

root = pathlib.Path(__file__).resolve().parents[3]
out = pathlib.Path(__file__).resolve().parent / 'build' / 'frame-queue'
out.mkdir(parents=True, exist_ok=True)
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (min(4096, hard), hard))
entries = json.loads((root / 'WebKitBuild/Release/compile_commands.json').read_text())
entry = next(item for item in entries if item['file'].endswith('/MediaRestreamRTSP.cpp'))
command = shlex.split(entry['command'])
command[1:1] = ['-I' + str(root / 'AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/mse')]
while '-Xclang' in command:
    index = command.index('-Xclang')
    del command[index:index + 4]
command[command.index('-o') + 1] = str(out / 'test.o')
command[-1] = str(pathlib.Path(__file__).with_name('MediaRestreamFrameQueueTest.cpp'))
jsc = pathlib.Path('/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks')
with open('/tmp/wk_build.log', 'ab') as log:
    subprocess.run(command, cwd=entry['directory'], stdout=log, stderr=log, check=True)
    subprocess.run([
        str(root / 'AquaWebKitSupport/toolchain/build/clang/bin/clang++'),
        '-mmacosx-version-min=10.9', str(out / 'test.o'), '-o', str(out / 'test'),
        '-Wl,-client_name,WebKit', '-Wl,-rpath,' + str(jsc),
        '/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/WebCore',
        '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore',
        str(jsc / 'libc++.1.dylib'), str(jsc / 'libc++abi.1.dylib'), '-framework', 'CoreFoundation',
    ], stdout=log, stderr=log, check=True)
subprocess.run([str(out / 'test')], check=True)
