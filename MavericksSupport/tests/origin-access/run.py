#!/usr/bin/env python3
"""Exercise origin-access IPC authority in installed WebKit2."""
import http.server
import json
from pathlib import Path
import shlex
import subprocess
import sys
import threading

root = Path(__file__).resolve().parents[3]
build = root / "WebKitBuild/Release"
out = build / "origin-access"
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
    elif arg in ("-c", entry["file"], "-fobjc-arc"):
        i += 1
    else:
        args.append(arg)
        i += 1
here = Path(__file__).parent
sdk = root.parent / "MacOSX26.1.sdk"
base = [command[0], "--no-default-config", "-isysroot", str(sdk), "-mmacosx-version-min=10.9", "-fuse-ld=lld"]
executable = out / "OriginAccess"
bundle = out / "OriginAccess.bundle"
(bundle / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
(bundle / "Contents/Info.plist").write_text('''<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>OriginAccess</string><key>CFBundleIdentifier</key><string>org.webkit.mavericks.OriginAccess</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>''')
with open("/tmp/wk_build.log", "a") as log:
    def compile(arguments):
        result = subprocess.run(arguments, stdout=log, stderr=log, cwd=entry["directory"])
        if result.returncode:
            sys.exit("Origin-access harness build failed; see /tmp/wk_build.log")
    compile(args + ["-fno-objc-arc", "-c", str(here / "main.mm"), "-o", str(out / "main.o")])
    objects = []
    for source in [here / "bundle.cpp", root / "Source/WebKit/Platform/IPC/Encoder.cpp"]:
        obj = out / (source.stem + ".o")
        compile(args + ["-I", str(root / "MavericksSupport/polyfill/polyfills/c"), "-fvisibility=default", "-x", "objective-c++", "-c", str(source), "-o", str(obj)])
        objects.append(str(obj))
    compile(base + ["-c", str(root / "MavericksSupport/polyfill/polyfills/shared/wk_symbols.c"), "-o", str(out / "symbols.o")])
    compile(base + ["-bundle", *objects, str(out / "symbols.o"), "-o", str(bundle / "Contents/MacOS/OriginAccess"),
        "/System/Library/PrivateFrameworks/WebKit2.framework/WebKit2",
        "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
        "-framework", "Foundation", "-nostdlib++",
        "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++.1.dylib",
        "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++abi.1.dylib"])
    compile(base + [str(out / "main.o"), "-o", str(executable),
        "/System/Library/PrivateFrameworks/WebKit2.framework/WebKit2",
        "-framework", "Foundation", "-framework", "AppKit", "-nostdlib++",
        "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++.1.dylib",
        "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks/libc++abi.1.dylib"])
if "--compile-only" in sys.argv:
    sys.exit(0)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = b"CROSS_ORIGIN_OK" if self.path.startswith("/target") else b"<!doctype html><title>Origin access</title>"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain" if self.path.startswith("/target") else "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass

with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    modes = sys.argv[1:] or ["AddOriginAccessAllowListEntry", "RemoveOriginAccessAllowListEntry", "ResetOriginAccessAllowLists", "test", "bundle"]
    for mode in modes:
        result = subprocess.run([str(executable), str(server.server_port), str(bundle), mode], timeout=600)
        if result.returncode:
            sys.exit(f"FAIL {mode}: exit {result.returncode}")
    server.shutdown()
