#!/usr/bin/env python3
"""Index Matroska/WebM clusters for the range-fetching MSE fixture."""
import argparse
import json
from pathlib import Path


def index(path, duration):
    data = path.read_bytes()

    def vint(offset, identifier=False):
        size = 1
        while not data[offset] & (128 >> (size - 1)):
            size += 1
            if size > 8:
                raise ValueError('Invalid EBML integer')
        value = int.from_bytes(data[offset:offset + size], 'big')
        return (value if identifier else value & ((1 << (7 * size)) - 1)), size

    offset, scale, cluster = 0, 1000000, None
    fragments = []
    while offset < len(data):
        identifier, count = vint(offset, True)
        size, length = vint(offset + count)
        body = offset + count + length
        end = min(len(data), body + size)
        if identifier == 0x1F43B675:
            if cluster is not None:
                fragments[-1]['length'] = offset - fragments[-1]['offset']
            cluster = offset
            fragments.append(dict(offset=offset))
        if identifier == 0x2AD7B1:
            scale = int.from_bytes(data[body:end], 'big')
        if identifier == 0xE7 and cluster is not None:
            fragments[-1]['start'] = int.from_bytes(data[body:end], 'big') * scale / 1e9
        offset = body if identifier in (0x18538067, 0x1549A966, 0x1F43B675) else end
    for i, fragment in enumerate(fragments):
        fragment['end'] = fragments[i + 1]['start'] if i + 1 < len(fragments) else duration
    fragments[-1]['length'] = len(data) - fragments[-1]['offset']
    manifest = dict(source=path.name, init=fragments[0]['offset'], duration=duration, fragments=fragments)
    path.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(path.name, len(fragments), 'clusters')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--duration', required=True, type=float)
    parser.add_argument('files', type=Path, nargs='+')
    args = parser.parse_args()
    for path in args.files:
        index(path, args.duration)
