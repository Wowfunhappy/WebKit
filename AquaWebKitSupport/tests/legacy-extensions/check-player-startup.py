#!/usr/bin/env python3
"""Check delayed receiver startup and cancellation. Quit QuickTime before running."""
import argparse
import json
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cancel', action='store_true')
parser.add_argument('--reload', action='store_true')
args = parser.parse_args()


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=35).decode().strip()


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of front window')


def wait(check, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError('Timed out')


assert subprocess.run(['pgrep', '-x', 'QuickTime Player'], stdout=subprocess.DEVNULL).returncode, 'Quit QuickTime before running'
stopped = threading.Event()
finished = threading.Event()
release = threading.Event()
resumed = threading.Event()
worker_errors = []


def delay_launch():
    try:
        while not finished.is_set():
            result = subprocess.run(['pgrep', '-x', 'QuickTime Player'], stdout=subprocess.PIPE)
            if not result.returncode:
                pid = int(result.stdout.strip())
                subprocess.run(['kill', '-STOP', str(pid)], check=True)
                try:
                    stopped.set()
                    print('Suspend receiver startup', pid, flush=True)
                    if args.cancel:
                        assert release.wait(10), 'Cancellation did not release receiver'
                    else:
                        time.sleep(2)
                finally:
                    subprocess.run(['kill', '-CONT', str(pid)], check=True)
                    resumed.set()
                return
            time.sleep(.01)
    except BaseException as error:
        worker_errors.append(error)


source = 'mse.mp4&airplay=valid' if args.cancel else 'plain.mp4' if args.reload else 'mse.mp4'
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps('http://127.0.0.1:8843/quicktime.html?source=' + source) + '}')
wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2 && document.querySelector("#open-media-player"))') == 'true')
js('video.play()')
wait(lambda: js('!video.paused && video.currentTime>0') == 'true')
thread = threading.Thread(target=delay_launch)
thread.start()
try:
    js('document.querySelector("#open-media-player").click()')
    assert stopped.wait(30), 'Receiver did not launch'
    if args.cancel:
        js('video.src="/quicktime-media/plain.mp4?cancelled=1";video.load()')
        assert not resumed.is_set(), "Cancellation completed after receiver resumed"
        release.set()
    elif args.reload:
        js('video.load();video.play()')
    result = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
    print('handoff', result, flush=True)
finally:
    finished.set()
    release.set()
    thread.join()
    if worker_errors:
        raise worker_errors[0]

if args.cancel:
    assert result.get('error') == 'no-source', result
    time.sleep(3)
    assert osa('tell application "QuickTime Player" to get count of documents') == '0', 'Cancelled handoff opened a late document'
    osa('tell application "Safari" to close current tab of front window')
    print('PASS cancellation during delayed startup; no late document', flush=True)
else:
    assert result.get('method') == ('url' if args.reload else 'restream'), result
    windows = osa('tell application "QuickTime Player" to get id of every window').split(',')
    assert len(windows) == 1 and windows[0].strip(), windows
    movie = 'document of window id ' + str(int(windows[0]))
    def position():
        return float(osa('tell application "QuickTime Player" to get current time of ' + movie))
    wait(lambda: position() > 1)
    if args.reload:
        osa('tell application "QuickTime Player" to close ' + movie + ' saving no')
        wait(lambda: js('video.readyState>=2 && !video.paused') == 'true', 30)
        before = float(js('video.currentTime'))
        wait(lambda: float(js('video.currentTime')) > before + 1, 15)
        osa('tell application "Safari" to close current tab of front window')
        print('PASS same-URL reload during delayed direct startup and inline return', flush=True)
        raise SystemExit(0)
    before = position()
    osa('tell application "Safari" to close current tab of front window')
    wait(lambda: position() > before + 5)
    osa('tell application "QuickTime Player" to close ' + movie + ' saving no')
    print('PASS delayed startup opens one movie and survives tab closure', flush=True)
