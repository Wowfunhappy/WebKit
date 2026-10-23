#!/usr/bin/env python3
"""Check full/limited YUV range conversion used by decoded media capture."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[3]
gst = root / 'AquaWebKitSupport/deps/build/bin/gst-launch-1.0'
out = pathlib.Path(__file__).resolve().parent / 'build' / 'color-range'
out.mkdir(parents=True, exist_ok=True)
for source_range, target_range, source_levels, target_levels in [
    ('bt601', '1:4:16:4', (16, 235), (0, 255)),
    ('1:4:16:4', 'bt601', (0, 255), (16, 235)),
    ('bt601', 'bt601', (16, 235), (16, 235)),
]:
    for source, expected in zip(source_levels, target_levels):
        for output_format in ('I420', 'NV12'):
            (out / 'input.yuv').write_bytes(bytes([source]) * 256 + bytes([128]) * 128)
            subprocess.run([
                str(gst), '-q', 'filesrc', 'location=' + str(out / 'input.yuv'), '!',
                'rawvideoparse', 'format=i420', 'width=16', 'height=16', 'framerate=1/1',
                'colorimetry=' + source_range, '!', 'videoconvert', '!',
                'video/x-raw,format=' + output_format + ',colorimetry=' + target_range,
                '!', 'filesink', 'location=' + str(out / 'output.yuv'),
            ], check=True)
            data = (out / 'output.yuv').read_bytes()
            assert len(data) == 384, len(data)
            # The converter's 8-bit fixed-point matrix truncates the coefficient
            # and offset separately. Allow its two-code-value rounding bound.
            assert all(abs(value - expected) <= 2 for value in data[:256]), (source_range, target_range, output_format, source, expected, data[0])
            assert all(abs(value - 128) <= 1 for value in data[256:]), (output_format, min(data[256:]), max(data[256:]))
print('PASS: limited/full black and white, planar/interleaved chroma, same-range copy')
