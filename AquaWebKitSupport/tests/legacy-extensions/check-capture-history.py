#!/usr/bin/env python3
"""Check an extension-selected HLS history limit and completed retained window."""
import argparse
import json
import pathlib
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

rig = pathlib.Path(__file__).resolve().parent
control = rig / 'build/media-receiver-control.json'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--force-storage-pressure', action='store_true')
args = parser.parse_args()
maximum_duration = 9 if args.force_storage_pressure else 12


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=40).decode().strip()


def wait(check, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timed out')


def read(url):
    return urllib.request.urlopen(url, timeout=15).read()


def playlist(url):
    text = read(url).decode()
    durations = [float(value) for value in re.findall(r'^#EXTINF:([^,]+),', text, re.M)]
    sequence = int(re.search(r'^#EXT-X-MEDIA-SEQUENCE:(\d+)$', text, re.M).group(1))
    resources = [urllib.parse.urljoin(url, line) for line in text.splitlines() if line and not line.startswith('#')]
    assert durations and len(durations) == len(resources)
    assert sum(durations) <= maximum_duration + .000001, durations
    return text, sequence, durations, resources


def unavailable(url):
    try:
        read(url)
        return False
    except urllib.error.HTTPError as error:
        assert error.code == 404, error
        return True


def storage_files():
    result = subprocess.run(['/usr/sbin/lsof', '-n', '-P', '-a', '-c', 'com.apple.WebKi', '+L1', '-F', 'pDin'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
    assert result.returncode in (0, 1), result.returncode
    entries = set()
    process = device = inode = None
    for line in result.stdout.decode().splitlines():
        if line.startswith('p'):
            process, device, inode = line[1:], None, None
        elif line.startswith('D'):
            device, inode = line[1:], None
        elif line.startswith('i'):
            inode = line[1:]
        elif line.startswith('n') and 'media-player-stream-' in line:
            entries.add((process, device, inode))
    return entries


baseline_storage = storage_files()
read('http://127.0.0.1:8843/reset')
completion_report = '/report-capture-complete-' + str(time.time_ns())
control.write_text('{}')
capture_options = {'maxWidth': 3840, 'maxHeight': 2160, 'transport': 'hls', 'videoCodec': 'h264', 'maxHistoryDuration': 12}
if args.force_storage_pressure:
    capture_options['minimumFreeStorage'] = 2**53 - 1
capture = json.dumps(capture_options)
query = urllib.parse.urlencode({'source': 'mse.mp4', 'mode': 'live', 'end': '1', 'sourceMode': 'capture', 'adapter': 'fixture', 'capture': capture})
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps('http://127.0.0.1:8843/quicktime.html?' + query) + '}')
window = osa('tell application "Safari" to get id of front window')


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)


try:
    wait(lambda: js('Boolean(document.querySelector("#video")?.readyState>=2&&document.querySelector("#open-media-player"))') == 'true')
    js('window.addEventListener("pagehide",()=>navigator.sendBeacon(' + json.dumps(completion_report) + ',"closed"));true')
    js('document.querySelector("#target-application").value="org.aqua.webkit.media-handoff-receiver";document.querySelector("#open-media-player").click()')
    reply = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
    assert reply.get('method') == 'restream', reply
    master = read(reply['url']).decode()
    media_url = urllib.parse.urljoin(reply['url'], next(line for line in master.splitlines() if line and not line.startswith('#'))) if '#EXT-X-STREAM-INF:' in master else reply['url']
    initial = playlist(media_url)
    assert '#EXT-X-PLAYLIST-TYPE:' not in initial[0] and '#EXT-X-ENDLIST' not in initial[0]
    osa('tell application "Safari" to close window id ' + window)
    window = None
    time.sleep(1)
    assert not any(entry.get('path') == completion_report for entry in json.loads(read('http://127.0.0.1:8843/log')))
    old_url = initial[3][0]
    old_data = None if args.force_storage_pressure else read(old_url)
    advanced = wait(lambda: (lambda state: state if state[1] > initial[1] else None)(playlist(media_url)), 30)
    if args.force_storage_pressure:
        wait(lambda: unavailable(old_url), 10)
    else:
        assert read(old_url) == old_data, 'Removed segment lacked request grace'
        wait(lambda: unavailable(old_url), 20)
    final = wait(lambda: (lambda state: state if '#EXT-X-ENDLIST' in state[0] else None)(playlist(media_url)), 75)
    assert '#EXT-X-PLAYLIST-TYPE:' not in final[0]
    assert final[1] > advanced[1] and 6 <= sum(final[2]) <= maximum_duration + .000001
    wait(lambda: any(entry.get('path') == completion_report for entry in json.loads(read('http://127.0.0.1:8843/log'))), 20)
    closed = playlist(media_url)
    assert '#EXT-X-PLAYLIST-TYPE:' not in closed[0] and '#EXT-X-ENDLIST' in closed[0]
    assert all(read(resource) for resource in closed[3])
    retained_storage = storage_files() - baseline_storage
    assert 1 <= len(retained_storage) <= 24, len(retained_storage)
    print('PASS extension-selected history limit, sequence advancement, storage policy and bounded finalized playlist', args.force_storage_pressure, final[1], sum(final[2]), flush=True)
finally:
    control.write_text('{"closed":true}')
    if window:
        osa('tell application "Safari" to close window id ' + window)
    subprocess.run(['osascript', '-e', 'tell application id "org.aqua.webkit.media-handoff-receiver" to quit'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    control.write_text('{}')
    wait(lambda: storage_files() == baseline_storage, 20)
