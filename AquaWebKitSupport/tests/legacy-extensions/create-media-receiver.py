#!/usr/bin/env python3
"""Create and register an Apple-event receiver for target-application tests."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parent / 'build'
app = root / 'Media Handoff Receiver.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Resources').mkdir(exist_ok=True)
(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'org.aqua.webkit.media-handoff-receiver',
    'CFBundleName': 'Media Handoff Receiver',
    'CFBundleExecutable': 'receiver',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'LSUIElement': True,
    'CFBundleURLTypes': [{'CFBundleURLSchemes': ['http', 'https']}],
}))
executable = contents / 'MacOS/receiver'
with open('/tmp/wk_build.log', 'a') as log:
    subprocess.run(['/usr/bin/clang', '-fobjc-arc', '-mmacosx-version-min=10.9',
                    '-framework', 'AppKit', '-framework', 'Carbon',
                    str(Path(__file__).with_name('MediaHandoffReceiver.m')), '-o', str(executable)],
                   stdout=log, stderr=log, check=True)
subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(app)], check=True)
print(app)
