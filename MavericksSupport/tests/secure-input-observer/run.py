#!/usr/bin/env python3
import functools
import http.server
import pathlib
import subprocess
import threading

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "WebKitBuild/Release/secure-input-observer"
OUT.mkdir(parents=True, exist_ok=True)
with open("/tmp/wk_build.log", "a") as log:
    subprocess.run([
        "/bin/bash", "-c",
        '. "$1/MavericksSupport/polyfill/polyfill-env.sh"; '
        '"$CLANG" $MODERN "$2/main.m" -framework Cocoa -framework WebKit '
        '-framework Carbon -o "$3/probe"',
        "secure-input-observer", str(ROOT), str(HERE), str(OUT),
    ], stdout=log, stderr=subprocess.STDOUT, check=True)
server = http.server.ThreadingHTTPServer(
    ("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(HERE)))
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    subprocess.run([str(OUT / "probe"), str(server.server_port)], check=True, timeout=60)
finally:
    server.shutdown()
    server.server_close()
