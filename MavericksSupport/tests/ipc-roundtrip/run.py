#!/usr/bin/env python3
"""Exercise the installed WebKit2 IPC coders using the matching build's headers."""
import json
from pathlib import Path
import shlex
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
build = root / "WebKitBuild/Release"
out = build / "ipc-roundtrip"
out.mkdir(exist_ok=True)
entries = json.loads((build / "compile_commands.json").read_text())
entry = next(item for item in entries if item["file"].endswith("GeneratedSerializersSharedCocoa.mm"))
command = shlex.split(entry["command"])
args = []
i = 0
while i < len(command):
    arg = command[i]
    if arg == "-o":
        i += 2
    elif arg == "-Xclang" and command[i + 1] in ("-include", "-include-pch"):
        i += 4
    elif arg in ("-c", entry["file"]):
        i += 1
    else:
        args.append(arg)
        i += 1
obj = out / "main.o"

def run_logged(command, log, **kwargs):
    result = subprocess.run(command, stdout=log, stderr=log, **kwargs)
    if result.returncode:
        sys.exit("IPC harness build failed; see /tmp/wk_build.log")

with open("/tmp/wk_build.log", "a") as log:
    run_logged(args + ["-c", str(Path(__file__).with_name("main.mm")), "-o", str(obj)],
               log, cwd=entry["directory"])
    objects = [obj]
    for relative in ("IPC/Encoder.cpp", "IPC/Decoder.cpp", "Logging.cpp"):
        source = root / "Source/WebKit/Platform" / relative
        name = source.stem
        compiled = out / (name + ".o")
        run_logged(args + ["-x", "objective-c++", "-c", str(source), "-o", str(compiled)],
                   log, cwd=entry["directory"])
        objects.append(compiled)
    if "--compile-only" in sys.argv:
        sys.exit(0)
    sdk = root.parent / "MacOSX26.1.sdk"
    executable = out / "DumpRenderTree"
    run_logged([command[0], "--no-default-config", "-isysroot", str(sdk), "-mmacosx-version-min=10.9",
                    "-fuse-ld=lld", *map(str, objects), "-o", str(executable),
                    "/System/Library/PrivateFrameworks/WebKit2.framework/WebKit2",
                    "/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/WebCore",
                    "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
                    "-framework", "Foundation", "-framework", "AppKit",
                    "-nostdlib++",
                    "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++.1.dylib",
                    "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++abi.1.dylib"], log)
sys.exit(subprocess.call([str(executable)]))
