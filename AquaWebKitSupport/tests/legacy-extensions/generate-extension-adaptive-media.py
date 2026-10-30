#!/usr/bin/env python3
"""Generate HLS/DASH files for check-extension-adaptive-media.py.

Requires the vendored GStreamer tools and openssl. --render-base writes playlists
with the current installed extension base URI; HTTP templates use the server base.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
IDENTIFIER = 'org.webkit.extension-adaptive'


def boxes(data, start=0):
    while start < len(data):
        size = int.from_bytes(data[start:start + 4], 'big')
        kind = data[start + 4:start + 8]
        header = 8
        if size == 1:
            size = int.from_bytes(data[start + 8:start + 16], 'big')
            header = 16
        if not size:
            size = len(data) - start
        if size < header or start + size > len(data):
            raise ValueError('Invalid MP4 box')
        yield kind, data[start:start + size], data[start + header:start + size]
        start += size


def fragment_track(moof):
    tracks = []
    for kind, _, payload in boxes(moof):
        if kind == b'traf':
            for child, _, body in boxes(payload):
                if child == b'tfhd':
                    tracks.append(int.from_bytes(body[4:8], 'big'))
    if len(tracks) != 1:
        raise ValueError('Expected one track per mp4mux fragment')
    return tracks[0]


def split_fragments(data):
    init, current, track = b'', b'', None
    tracks = {1: [], 2: []}
    for kind, whole, payload in boxes(data):
        if kind == b'moof':
            if current:
                tracks[track].append(current)
            track = fragment_track(payload)
            current = whole
        elif current:
            if kind != b'mfra':
                current += whole
        else:
            init += whole
    if current:
        tracks[track].append(current)
    segments = tracks[1]
    if len(segments) != 9 or len(tracks[2]) not in (9, 10):
        raise ValueError('Expected nine video intervals and their AAC fragments')
    # AAC frame quantization can leave a short final fragment in the last interval.
    for index, audio in enumerate(tracks[2]):
        segments[min(index, len(segments) - 1)] += audio
    return init, segments


def render(output, base):
    if not base.endswith('/'):
        raise ValueError('--render-base must end in /')
    for template in output.rglob('*.template'):
        template.with_suffix('').write_text(template.read_text().replace('{{BASE}}', base))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--gst-prefix', type=Path, default=ROOT / 'AquaWebKitSupport/deps/build')
    parser.add_argument('--render-base')
    args = parser.parse_args()
    out = args.output.resolve()
    if args.render_base:
        render(out, args.render_base)
        return
    out.mkdir(parents=True, exist_ok=True)
    plist = out / 'Info.plist'
    if plist.exists() and plistlib.loads(plist.read_bytes()).get('CFBundleIdentifier') != IDENTIFIER:
        raise ValueError('Output belongs to another extension')
    gst = args.gst_prefix / 'bin/gst-launch-1.0'
    env = dict(os.environ, GST_REGISTRY_FORK='no',
               GST_PLUGIN_SYSTEM_PATH_1_0=str(args.gst_prefix / 'lib/gstreamer-1.0'))
    def run(name, pipeline):
        process = subprocess.run([str(gst), '-e', '-m'] + pipeline, env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (out / (name + '.log')).write_text(process.stdout)
        if process.returncode:
            raise RuntimeError(name + ': ' + process.stdout[-3000:])
        return process.stdout
    durations = {}
    for name, width, height, bitrate in [('low', 320, 180, 240), ('high', 640, 360, 1600)]:
        mp4 = out / (name + '.mp4')
        run(name, ['mp4mux', 'name=m', 'fragment-duration=2000', 'streamable=true', '!',
            'filesink', 'location=' + str(mp4), 'videotestsrc', 'num-buffers=540', 'pattern=snow', '!',
            'video/x-raw,format=I420,width=%d,height=%d,framerate=30/1' % (width, height), '!',
            'x264enc', 'speed-preset=ultrafast', 'tune=zerolatency', 'bitrate=' + str(bitrate),
            'key-int-max=60', 'bframes=0', '!', 'video/x-h264,profile=baseline', '!',
            'h264parse', '!', 'queue', '!', 'm.video_0', 'audiotestsrc', 'num-buffers=844',
            'samplesperbuffer=1024', 'freq=440', '!', 'audio/x-raw,rate=48000,channels=2', '!',
            'fdkaacenc', 'bitrate=64000', '!', 'aacparse', '!', 'queue', '!', 'm.audio_0'])
        ts = out / 'hls/ts' / name
        ts.mkdir(parents=True, exist_ok=True)
        log = run(name + '-ts', ['filesrc', 'location=' + str(mp4), '!', 'qtdemux', 'name=d',
            'splitmuxsink', 'name=s', 'muxer=mpegtsmux', 'max-size-time=2000000000',
            'location=' + str(ts / 'seg-%02d.ts'), 'd.video_0', '!', 'queue', '!', 'h264parse',
            '!', 's.video', 'd.audio_0', '!', 'queue', '!', 'aacparse', '!', 's.audio_0'])
        durations['ts-' + name] = [int(x) / 1e9 for x in re.findall(
            r'splitmuxsink-fragment-closed, .*fragment-duration=\(guint64\)(\d+)', log)]
        cmaf = out / 'hls/cmaf' / name
        cmaf.mkdir(parents=True, exist_ok=True)
        init, segments = split_fragments(mp4.read_bytes())
        (cmaf / 'init.mp4').write_bytes(init)
        for index, data in enumerate(segments):
            (cmaf / ('seg-%02d.m4s' % index)).write_bytes(data)
        if len(segments) != 9:
            raise ValueError('Expected nine two-second fragmented-MP4 segments')
        durations['cmaf-' + name] = [2.0] * len(segments)
    key = bytes.fromhex('00112233445566778899aabbccddeeff')
    (out / 'hls/aes').mkdir(parents=True, exist_ok=True)
    (out / 'hls/aes/key.bin').write_bytes(key)
    for name in ['low', 'high']:
        aes = out / 'hls/aes' / name
        aes.mkdir(parents=True, exist_ok=True)
        for index, source in enumerate(sorted((out / 'hls/ts' / name).glob('seg-*.ts'))):
            subprocess.run(['openssl', 'enc', '-aes-128-cbc', '-K', key.hex(), '-iv', '%032x' % index,
                            '-in', str(source), '-out', str(aes / source.name)], check=True)
        durations['aes-' + name] = durations['ts-' + name]
    for family in ['ts', 'cmaf', 'aes']:
        folder = out / 'hls' / family
        for name in ['low', 'high']:
            relative = 'hls/%s/%s/' % (family, name)
            entries = ['#EXTM3U', '#EXT-X-VERSION:7', '#EXT-X-PLAYLIST-TYPE:VOD',
                       '#EXT-X-TARGETDURATION:3', '#EXT-X-MEDIA-SEQUENCE:0']
            if family == 'cmaf':
                entries.append('#EXT-X-MAP:URI="{{BASE}}' + relative + 'init.mp4"')
            if family == 'aes':
                entries.append('#EXT-X-KEY:METHOD=AES-128,URI="{{BASE}}hls/aes/key.bin"')
            for index, duration in enumerate(durations[family + '-' + name]):
                file = 'seg-%02d.%s' % (index, 'm4s' if family == 'cmaf' else 'ts')
                entries.extend(['#EXTINF:%.6f,' % duration, '{{BASE}}' + relative + file if index % 2 else file])
            entries.append('#EXT-X-ENDLIST')
            (folder / name / 'index.m3u8.template').write_text('\n'.join(entries) + '\n')
        master = '#EXTM3U\n#EXT-X-VERSION:7\n'
        for name, bandwidth, resolution in [('low', 400000, '320x180'), ('high', 2100000, '640x360')]:
            master += '#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%s,CODECS="avc1.42c01e,mp4a.40.2"\n%s/index.m3u8\n' % (bandwidth, resolution, name)
        (folder / 'master.m3u8.template').write_text(master)
    # A separate subtitle master keeps text assertions independent of media loading.
    text = out / 'hls/ts/text'
    text.mkdir(exist_ok=True)
    entries = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:2', '#EXT-X-MEDIA-SEQUENCE:0']
    for i in range(9):
        (text / ('%02d.vtt' % i)).write_text('WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:324000000\n\n00:00:%02d.000 --> 00:00:%02d.900\nAdaptive cue %d\n' % (2*i, 2*i+1, i))
        entries += ['#EXTINF:2,', '%02d.vtt' % i]
    (text / 'index.m3u8.template').write_text('\n'.join(entries + ['#EXT-X-ENDLIST']) + '\n')
    master = (out / 'hls/ts/master.m3u8.template').read_text().replace('#EXT-X-VERSION:7\n', '#EXT-X-VERSION:7\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="text",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="text/index.m3u8"\n').replace('CODECS=', 'SUBTITLES="text",CODECS=')
    (out / 'hls/ts/subtitles.m3u8.template').write_text(master)
    segment_urls = ''.join('<SegmentURL media="hls/cmaf/high/seg-%02d.m4s"/>' % i for i in range(9))
    (out / 'stream.mpd').write_text('<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT18S" minBufferTime="PT2S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period><AdaptationSet mimeType="video/mp4"><Representation id="av" bandwidth="2100000" codecs="avc1.42c01e,mp4a.40.2" width="640" height="360"><SegmentList duration="2"><Initialization sourceURL="hls/cmaf/high/init.mp4"/>' + segment_urls + '</SegmentList></Representation></AdaptationSet></Period></MPD>\n')
    for name, source in [('clip.mp4', ROOT/'LayoutTests/media/content/test.mp4'),
                         ('clip.webm', ROOT/'LayoutTests/media/content/vp9-opus-good-3tracks.webm')]:
        shutil.copyfile(source, out/name)
    info = dict(Author='WebKit', CFBundleDisplayName='Extension Adaptive Media Test',
                CFBundleIdentifier=IDENTIFIER, CFBundleInfoDictionaryVersion='6.0',
                CFBundleVersion='1', CFBundleShortVersionString='1.0',
                DeveloperIdentifier='WDAOQFIKHZ', ExtensionInfoDictionaryVersion='1.0',
                Description='Local adaptive extension media regression fixture',
                Chrome={'Global Page':'global.html','Popovers':[{'Identifier':'adaptive-popover','Filename':'popover.html','Width':600.,'Height':450.}],
                        'Toolbar Items':[{'Identifier':'adaptive-button','Label':'Adaptive Media','Image':'button.png','Popover':'adaptive-popover'}]},
                Permissions={'Website Access':{'Level':'All','Include Secure Pages':True}})
    plist.write_bytes(plistlib.dumps(info))
    import struct
    import zlib
    def png_chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    pixels = b''.join(b'\x00' + bytes([40, 120, 220, 255]) * 16 for _ in range(16))
    png = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 16, 16, 8, 6, 0, 0, 0))
    png += png_chunk(b'IDAT', zlib.compress(pixels)) + png_chunk(b'IEND', b'')
    (out / 'button.png').write_bytes(png)
    for context in ['global','popover','tab']:
        (out/(context+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>Adaptive media '+context+'</title><pre id="log" style="max-height:80px;overflow:auto"></pre><script>window.testContext='+json.dumps(context)+';</script><script src="adaptive-media-driver.js"></script>')
    shutil.copyfile(HERE/'adaptive-media-driver.js', out/'adaptive-media-driver.js')
    (out/'fixture.json').write_text(json.dumps({'duration':18,'variants':['low','high'],'families':['ts','cmaf','aes'],'segmentDurations':durations},indent=2))
    for template in out.rglob('*.template'):
        template.with_suffix('').write_text(template.read_text())
    print(out)

if __name__ == '__main__':
    main()
