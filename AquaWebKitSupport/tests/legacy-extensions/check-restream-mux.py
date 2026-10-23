#!/usr/bin/env python3
"""Exercise the restream's dedicated MPEG-TS clock with both A/V start orders."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[3]
gst = root / 'AquaWebKitSupport/deps/build/bin/gst-launch-1.0'
out = Path(__file__).resolve().parent / 'build/restream-mux'
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, GST_REGISTRY_FORK='no')
previous_tables = None
for video_first in (True, False):
    name = 'video-first' if video_first else 'audio-first'
    destination = out / (name + '.ts')
    video_start = 10000000000 + (0 if video_first else 10000000)
    audio_start = 10000000000 + (10000000 if video_first else 0)
    pipeline = (
        f'mpegtsmux name=mux alignment=7 prog-map=program_map,PCR_1=(int)64 ! filesink location={destination} '
        f'audiotestsrc num-buffers=94 samplesperbuffer=1024 timestamp-offset={audio_start} '
        '! audio/x-raw,rate=48000,channels=2 ! fdkaacenc bitrate=128000 ! aacparse ! queue ! mux. '
        f'videotestsrc num-buffers=60 timestamp-offset={video_start} '
        '! video/x-raw,format=NV12,width=320,height=180,framerate=30/1 '
        '! vtenc_h264 allow-frame-reordering=false ! h264parse ! queue ! mux.')
    subprocess.run([str(gst), '-q', '-e'] + pipeline.split(), env=env, check=True)
    data = destination.read_bytes()
    assert data and len(data) % 188 == 0
    tables, counters, clocks, first_media = {}, {}, {}, None
    pmt_pid = None
    for offset in range(0, len(data), 188):
        packet = data[offset:offset + 188]
        assert packet[0] == 0x47 and not packet[1] & 0x80
        pid = ((packet[1] & 31) << 8) | packet[2]
        if pid == 8191:
            continue
        payload = bool(packet[3] & 16)
        counter = packet[3] & 15
        if pid in counters:
            assert counter == (counters[pid] + payload) % 16, (name, pid, offset)
        counters[pid] = counter
        begin = 4
        if packet[3] & 32:
            begin += 1 + packet[4]
            if packet[4] and packet[5] & 16:
                assert pid == 64 if not clocks or not payload else pid not in (0, pmt_pid), (name, 'PCR on wrong PID', pid, offset)
                p = packet[6:12]
                base = (p[0] << 25) | (p[1] << 17) | (p[2] << 9) | (p[3] << 1) | (p[4] >> 7)
                value = base * 300 + ((p[4] & 1) << 8) + p[5]
                clock = clocks.setdefault(pid, [])
                assert not clock or value >= clock[-1], (name, 'PCR moved backwards', pid)
                clock.append(value)
        if not payload:
            assert pid != 0, (name, 'adaptation-only packet on PAT PID')
            continue
        if pid == 0 or pid == pmt_pid:
            assert packet[1] & 64
            begin += 1 + packet[begin]
            length = 3 + ((packet[begin + 1] & 15) << 8) + packet[begin + 2]
            section = packet[begin:begin + length]
            assert len(section) == length
            assert pid not in tables or tables[pid] == section
            tables[pid] = section
            if pid == 0:
                pmt_pid = ((section[10] & 31) << 8) | section[11]
            else:
                assert ((section[8] & 31) << 8) | section[9] == 64
        else:
            assert 0 in tables and pmt_pid in tables, (name, 'media before program tables', offset)
            if first_media is None:
                first_media = pid
    assert first_media == (66 if video_first else 65), (name, first_media)
    assert len(clocks[64]) > 1 and clocks[64][-1] > clocks[64][0]
    assert previous_tables is None or tables == previous_tables, 'program tables depend on A/V start order'
    previous_tables = tables
    subprocess.run([str(gst), '-q', 'filesrc', f'location={destination}', '!', 'tsdemux', '!',
                    'h264parse', '!', 'avdec_h264', '!', 'fakesink'], env=env, check=True)
    print(f'{name}: program tables precede media; stable PCR PID, monotonic clock, continuity and decode passed', flush=True)
