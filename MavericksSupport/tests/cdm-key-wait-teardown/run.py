#!/usr/bin/env python3
"""Compile the production CDM proxy with assertions and exercise instance teardown."""
import json
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
BUILD = ROOT / 'WebKitBuild/Release'
HERE = Path(__file__).resolve().parent
CLANG = ROOT / 'MavericksSupport/toolchain/build/clang/bin/clang++'
WEB_CORE = Path('/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A')
JSC = Path('/System/Library/Frameworks/JavaScriptCore.framework/Versions/A')


def compile_arguments():
    for entry in json.loads((BUILD / 'compile_commands.json').read_text()):
        source = Path(entry['file'])
        if 'UnifiedSource' not in source.name or source.suffix != '.cpp':
            continue
        if not source.is_file() or 'CDMProxy.cpp' not in source.read_text():
            continue
        args = iter(shlex.split(entry['command'])[1:])
        result = []
        for arg in args:
            if arg == '-o':
                next(args)
            elif arg not in ('-c', entry['file']):
                result.append(arg)
        return result
    raise RuntimeError('CDMProxy.cpp compile command not found; configure the main build first')


with tempfile.TemporaryDirectory(prefix='webkit-cdm-teardown-') as directory:
    work = Path(directory)
    flags = compile_arguments() + [
        '-UNDEBUG', '-include', str(ROOT / 'Source/WebCore/config.h'),
        '-I' + str(ROOT / 'Source/WebCore/platform/encryptedmedia'),
    ]
    sources = [ROOT / 'Source/WebCore/platform/encryptedmedia/CDMProxy.cpp', HERE / 'main.cpp']
    objects = [work / (source.name + '.o') for source in sources]
    with open('/tmp/wk_build.log', 'a') as log:
        for source, obj in zip(sources, objects):
            subprocess.run([str(CLANG)] + flags + ['-c', str(source), '-o', str(obj)],
                           cwd=BUILD, stdout=log, stderr=log, check=True)
        subprocess.run([
            str(CLANG), '--no-default-config', '-mmacosx-version-min=10.9',
            '-nostdlib++', '-Wl,-client_name,TestWebCore', *map(str, objects),
            str(WEB_CORE / 'WebCore'), str(JSC / 'JavaScriptCore'),
            str(JSC / 'Frameworks/libc++.1.dylib'), str(JSC / 'Frameworks/libc++abi.1.dylib'),
            '-Wl,-rpath,' + str(JSC / 'Frameworks'),
            '-Wl,-rpath,' + str(WEB_CORE / 'Frameworks'), '-framework', 'Foundation',
            '-o', str(work / 'check'),
        ], stdout=log, stderr=log, check=True)
    subprocess.run([str(work / 'check')], check=True)
