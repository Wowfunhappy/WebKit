#!/usr/bin/env python3
"""Build GLibMainContextMavericks.cpp with WebCore's flags and run it on a CFRunLoop main thread."""
import json
from pathlib import Path
import shlex
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
build = root / "WebKitBuild/Release"
out = build / "glib-main-context"
out.mkdir(exist_ok=True)
entries = json.loads((build / "compile_commands.json").read_text())
entry = next(item for item in entries if item["file"].endswith("GLibMainContextMavericks.cpp"))
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

def run_logged(command, log, **kwargs):
    result = subprocess.run(command, stdout=log, stderr=log, **kwargs)
    if result.returncode:
        sys.exit("GLib main context test build failed; see /tmp/wk_build.log")

runtime = "/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/gstreamer/lib"
with open("/tmp/wk_build.log", "a") as log:
    objects = []
    for source, extra in ((Path(__file__).with_name("main.mm"), ["-x", "objective-c++", "-fobjc-arc"]), (Path(entry["file"]), [])):
        compiled = out / (source.stem + ".o")
        run_logged(args + extra + ["-c", str(source), "-o", str(compiled)], log, cwd=entry["directory"])
        objects.append(compiled)
    sdk = root.parent / "MacOSX26.1.sdk"
    executable = out / "glib-main-context"
    run_logged([command[0], "--no-default-config", "-isysroot", str(sdk), "-mmacosx-version-min=10.9",
                    "-fuse-ld=lld", *map(str, objects), "-o", str(executable),
                    "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
                    runtime + "/libglib-2.0.0.dylib",
                    "-framework", "Foundation", "-framework", "CoreFoundation",
                    "-nostdlib++",
                    "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++.1.dylib",
                    "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++abi.1.dylib"], log)
sys.exit(subprocess.call([str(executable)]))
