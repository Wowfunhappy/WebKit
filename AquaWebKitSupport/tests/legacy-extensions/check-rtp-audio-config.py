#!/usr/bin/env python3
"""Check AAC channel configuration and explicit sample rates in RTP caps."""
import os
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[3]
gst = root / 'AquaWebKitSupport/deps/build/bin/gst-launch-1.0'
for configuration, channels, explicit_rate in [(2, 2, False), (7, 8, False), (12, 8, False), (2, 2, True)]:
    bits = '00010' + ('1111' if explicit_rate else '0011')
    if explicit_rate:
        bits += format(48000, '024b')
    bits += format(configuration, '04b') + '000'
    bits += '0' * (-len(bits) % 8)
    config = int(bits, 2).to_bytes(len(bits) // 8, 'big').hex()
    caps = ('audio/mpeg,mpegversion=4,stream-format=raw,rate=48000,'
            f'channels={channels},codec_data=(buffer){config}')
    result = subprocess.run([
        str(gst), '-v', 'fakesrc', 'num-buffers=2', 'sizetype=fixed', 'sizemax=4',
        '!', caps, '!', 'rtpmp4gpay', '!', 'fakesink',
    ], env=dict(os.environ, GST_REGISTRY_FORK='no'), stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, timeout=15, check=True)
    assert f'encoding-params=(string){channels}' in result.stdout, result.stdout
    assert 'clock-rate=(int)48000' in result.stdout, result.stdout
    assert f'config=(string){config}' in result.stdout, result.stdout
print('PASS: stereo, both eight-channel configurations, explicit sample rate')
