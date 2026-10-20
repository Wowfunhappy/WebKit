#!/usr/bin/env python3
"""Exercise HLS capture cadence, bounded queues, track tails and multichannel audio."""
import argparse
import json
import math
import os
import pathlib
import resource
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--case', choices=['all', 'video', 'sparse', 'low-rate', 'video-tail', 'audio-tail', 'surround', 'fractional', 'hd', '4k', 'initial-gaps', 'post-eos'], default='all')
parser.add_argument('--seconds', type=int, default=20)
parser.add_argument('--skip-build', action='store_true')
parser.add_argument('--main-stall', type=int, default=0, help='Block main-thread delivery after five seconds')
parser.add_argument('--cancel-after-stall', action='store_true', help='Cancel capture before draining the blocked delivery queue')
parser.add_argument('--consumer-delay', type=int, default=0, help='Retain each fragment for this many seconds before acknowledging it')
args = parser.parse_args()
if args.seconds < 8:
    parser.error('--seconds must be at least 8')
if args.cancel_after_stall and not args.main_stall:
    parser.error('--cancel-after-stall requires --main-stall')
root = pathlib.Path(__file__).resolve().parents[3]
source = root / 'AquaWebKitSupport/source/WebCore/platform/graphics/gstreamer/mse'
out = pathlib.Path(__file__).resolve().parent / 'build/capture-stability'
out.mkdir(parents=True, exist_ok=True)
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (min(4096, hard) if hard != -1 else 4096, hard))
gst = pathlib.Path('/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/gstreamer/lib')
jsc = pathlib.Path('/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Frameworks')
if not args.skip_build:
    entries = json.loads((root / 'WebKitBuild/Release/compile_commands.json').read_text())
    entry = next(row for row in entries if row['file'].endswith('/MediaRestreamCapture.cpp'))
    base = shlex.split(entry['command'])
    base[1:1] = ['-DMediaRestreamCapture=TestMediaRestreamCapture', '-I' + str(source)]
    for option in ('-include-pch', '-include'):
        matches = [i for i in range(len(base) - 3) if base[i:i+3] == ['-Xclang', option, '-Xclang'] and pathlib.Path(base[i+3]).name in ('cmake_pch.hxx', 'cmake_pch.hxx.pch')]
        for i in reversed(matches):
            del base[i:i+4]
    objects = []
    with open('/tmp/wk_build.log', 'ab') as log:
        for filename in [pathlib.Path(__file__).with_name('MediaRestreamCaptureTest.cpp'), source / 'MediaRestreamCapture.cpp']:
            obj = out / (filename.stem + '.o')
            objects.append(str(obj))
            command = base.copy()
            command[command.index('-o') + 1] = str(obj)
            command[-1] = str(filename)
            subprocess.run(command, cwd=entry['directory'], stdout=log, stderr=log, check=True)
        command = [str(root / 'AquaWebKitSupport/toolchain/build/clang/bin/clang++'), '-mmacosx-version-min=10.9', *objects, '-o', str(out / 'test'), '-Wl,-client_name,WebKit', '-Wl,-rpath,' + str(jsc), '/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/WebCore', '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore', '-framework', 'CoreFoundation']
        for name in ('gstapp-1.0.0', 'gstaudio-1.0.0', 'gstvideo-1.0.0', 'gstreamer-1.0.0', 'gobject-2.0.0', 'glib-2.0.0', 'c++.1', 'c++abi.1'):
            command.append(str((gst if name.startswith('gst') else jsc) / ('lib' + name + '.dylib')))
        subprocess.run(command, stdout=log, stderr=log, check=True)
# Load the installed core libraries with the current dependency plugins.
# They share an ABI, and plugin changes can be tested before framework installation.
libs = out / 'libraries'
libs.mkdir(exist_ok=True)
for directory in (gst, jsc):
    for library in directory.glob('*.dylib'):
        if library.name.startswith(('libc++', 'libobjc')):
            continue
        link = libs / library.name
        if not link.exists():
            link.symlink_to(library)
env = dict(os.environ, CAPTURE_MAIN_STALL=str(args.main_stall), CAPTURE_CONSUMER_DELAY=str(args.consumer_delay), DYLD_LIBRARY_PATH=str(libs), GST_REGISTRY_FORK='no', GST_PLUGIN_SYSTEM_PATH_1_0=str(root / 'AquaWebKitSupport/deps/build/lib/gstreamer-1.0'))
if args.cancel_after_stall:
    env['CAPTURE_CANCEL_AFTER_STALL'] = '1'
cases = ['video', 'sparse', 'low-rate', 'video-tail', 'audio-tail', 'surround', 'fractional', 'hd', '4k', 'initial-gaps', 'post-eos'] if args.case == 'all' else [args.case]
for case in cases:
    video_seconds = 4 if case == 'audio-tail' else args.seconds
    audio_seconds = 4 if case == 'video-tail' else args.seconds
    rate_n, rate_d = (1, 4) if case == 'low-rate' else (30000, 1001) if case == 'fractional' else (30, 1)
    width, height = (3840, 2160) if case == '4k' else (1920, 1080) if case == 'hd' else (640, 360)
    channels = 6 if case == 'surround' else 2
    pipeline = 'playsink name=ps video-sink="fakesink sync=true" audio-sink="fakesink sync=true" '
    if case != 'surround':
        pipeline += f'videotestsrc pattern=snow num-buffers={math.ceil(video_seconds * rate_n / rate_d)} ! video/x-raw,format=I420,width={width},height={height},framerate={rate_n}/{rate_d} ! '
        if case == 'sparse':
            pipeline += 'identity drop-probability=0.98 ! '
        if case == 'initial-gaps':
            pipeline += 'identity name=startupDelay sleep-time=1000000 ! '
        pipeline += 'ps.video_sink '
    pipeline += f'audiotestsrc timestamp-offset={600000000 if case == "initial-gaps" else 0} num-buffers={math.ceil(audio_seconds * 48000 / 1024)} ! audio/x-raw,format=F32LE,rate=48000,channels={channels} ! ps.audio_sink'
    limit = max(120, args.seconds * 8)
    print('RUN', case, args.seconds, 'seconds', flush=True)
    case_env = dict(env)
    if case == 'initial-gaps':
        case_env['CAPTURE_INITIAL_GAPS'] = '1'
    if case == 'post-eos':
        case_env['CAPTURE_POST_EOS_STREAM_START'] = '1'
    if case == 'surround':
        case_env['CAPTURE_EXPECT_CHANNELS'] = '6'
    subprocess.run([str(out / 'test'), pipeline, str(limit)], env=case_env, timeout=limit + 30, check=True)
