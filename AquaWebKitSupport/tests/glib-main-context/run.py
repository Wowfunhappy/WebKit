#!/usr/bin/env python3
"""Build the bridge, shared timer and WTF dispatch sources as a standalone CFRunLoop harness."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
build = root / "WebKitBuild/Release"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bridge-source", type=Path, help="compile a specified bridge source")
parser.add_argument("--output-dir", type=Path, default=build / "glib-main-context", help="object and executable directory")
options = parser.parse_args()
out = options.output_dir.resolve()
out.mkdir(parents=True, exist_ok=True)
entries = json.loads((build / "compile_commands.json").read_text())
entry = next(item for item in entries if item["file"].endswith("GLibMainContextAquaWebKit.cpp"))
bridge_source = options.bridge_source.resolve() if options.bridge_source else Path(entry["file"])
print(f"Bridge source: {bridge_source}", flush=True)
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
    log.write(shlex.join(command) + "\n")
    log.flush()
    result = subprocess.run(command, stdout=log, stderr=log, **kwargs)
    if result.returncode:
        sys.exit("GLib main context test build failed; see /tmp/wk_build.log")

runtime = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks"
with open("/tmp/wk_build.log", "a") as log:
    objects = []
    sources = [
        (Path(__file__).with_name("main.mm"), ["-x", "objective-c++", "-fobjc-arc"]),
        (bridge_source, []),
        (root / "Source/WebCore/platform/cf/MainThreadSharedTimerCF.cpp", []),
        (root / "Source/WebCore/platform/MainThreadSharedTimer.cpp", []),
        (root / "Source/WebCore/platform/mac/PowerObserverMac.cpp", []),
        (root / "Source/WTF/wtf/RunLoop.cpp", []),
        (root / "Source/WTF/wtf/cf/RunLoopCF.cpp", []),
        (root / "Source/WTF/wtf/MainThread.cpp", []),
        (root / "Source/WTF/wtf/WorkQueue.cpp", []),
        (root / "Source/WTF/wtf/cocoa/WorkQueueCocoa.cpp", []),
    ]
    for source, extra in sources:
        compiled = out / (source.stem + ".o")
        run_logged(args + extra + ["-c", str(source), "-o", str(compiled)], log, cwd=entry["directory"])
        objects.append(compiled)
    for member in ("os_unfair_lock.o", "libSystem.o", "wk_polyfill_runtime.o", "wk_symbols.o"):
        compiled = out / member
        with compiled.open("wb") as output:
            subprocess.run(["ar", "-p", str(root / "AquaWebKitSupport/polyfill/build/libpolyfill.a"), member],
                           stdout=output, stderr=log, check=True)
        objects.append(compiled)
    sdk = root.parent / "MacOSX26.1.sdk"
    executable = out / "glib-main-context"
    run_logged([command[0], "--no-default-config", "-isysroot", str(sdk), "-mmacosx-version-min=10.9",
                    "-fuse-ld=lld", "-Wl,-dead_strip", *map(str, objects), "-o", str(executable),
                    "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
                    runtime + "/libglib-2.0.0.dylib",
                    "-framework", "Foundation", "-framework", "CoreFoundation", "-framework", "IOKit", "-lsandbox",
                    "-nostdlib++",
                    "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++.1.dylib",
                    "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++abi.1.dylib"], log)
passed = failed = 0
with subprocess.Popen([str(executable)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1) as process:
    for line in process.stdout:
        print(line, end="", flush=True)
        passed += line.startswith("PASS: ") or line.rstrip() == "PASS"
        failed += line.startswith("FAIL: ") or line.rstrip() == "FAIL"
    result = process.wait()
print(f"{passed}/{passed + failed} results passed", flush=True)
sys.exit(result)
