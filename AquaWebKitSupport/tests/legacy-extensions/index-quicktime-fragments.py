#!/usr/bin/env python3
"""Index fMP4 fragments for the seek-driven MSE fixture."""
import json
from pathlib import Path
import struct


def boxes(data, start=0, end=None):
    end = len(data) if end is None else end
    while start < end:
        size, kind = struct.unpack_from('>I4s', data, start)
        header = 8
        if size == 1:
            size = struct.unpack_from('>Q', data, start + 8)[0]
            header = 16
        if not size:
            size = end - start
        if size < header or start + size > end:
            raise ValueError('Invalid ISO box')
        yield kind, start, start + header, start + size
        start += size


def index(path):
    data = path.read_bytes()
    top = list(boxes(data))
    scales, defaults = {}, {}
    for kind, _, body, end in top:
        if kind != b'moov':
            continue
        for child, _, cb, ce in boxes(data, body, end):
            if child == b'trak':
                track, scale = None, None
                for atom, _, ab, ae in boxes(data, cb, ce):
                    if atom == b'tkhd':
                        track = struct.unpack_from('>I', data, ab + (20 if data[ab] else 12))[0]
                    elif atom == b'mdia':
                        for leaf, _, lb, le in boxes(data, ab, ae):
                            if leaf == b'mdhd':
                                scale = struct.unpack_from('>I', data, lb + (20 if data[lb] else 12))[0]
                scales[track] = scale
            elif child == b'mvex':
                for atom, _, ab, ae in boxes(data, cb, ce):
                    if atom == b'trex':
                        track, _, duration = struct.unpack_from('>III', data, ab + 4)
                        defaults[track] = duration
    fragments = []
    for i, (kind, start, body, end) in enumerate(top):
        if kind != b'moof':
            continue
        times = []
        for child, _, cb, ce in boxes(data, body, end):
            if child != b'traf':
                continue
            track, duration, timestamp = None, 0, None
            runs = []
            for atom, _, ab, ae in boxes(data, cb, ce):
                flags = int.from_bytes(data[ab + 1:ab + 4], 'big')
                if atom == b'tfhd':
                    track = struct.unpack_from('>I', data, ab + 4)[0]
                    offset = ab + 8 + (8 if flags & 1 else 0) + (4 if flags & 2 else 0)
                    duration = struct.unpack_from('>I', data, offset)[0] if flags & 8 else defaults.get(track, 0)
                elif atom == b'tfdt':
                    timestamp = struct.unpack_from('>Q' if data[ab] else '>I', data, ab + 4)[0]
                elif atom == b'trun':
                    runs.append((ab, flags))
            total = 0
            for ab, flags in runs:
                count = struct.unpack_from('>I', data, ab + 4)[0]
                offset = ab + 8 + (4 if flags & 1 else 0) + (4 if flags & 4 else 0)
                for _ in range(count):
                    total += struct.unpack_from('>I', data, offset)[0] if flags & 0x100 else duration
                    offset += 4 * sum(bool(flags & bit) for bit in (0x100, 0x200, 0x400, 0x800))
            if timestamp is None:
                raise ValueError('Missing fragment decode time')
            times.append((timestamp / scales[track], (timestamp + total) / scales[track]))
        stop = next((item[1] for item in top[i + 1:] if item[0] == b'moof'), len(data))
        fragments.append(dict(offset=start, length=stop-start, start=min(t[0] for t in times), end=max(t[1] for t in times)))
    manifest = dict(source=path.name, init=fragments[0]['offset'], duration=max(f['end'] for f in fragments), fragments=fragments)
    path.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(path.name, len(fragments), 'fragments', manifest['duration'], 'seconds')


if __name__ == '__main__':
    import sys
    for name in sys.argv[1:]:
        index(Path(name))
