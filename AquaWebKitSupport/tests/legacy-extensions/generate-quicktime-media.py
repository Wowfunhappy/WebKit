#!/usr/bin/env python3
"""Generate the local handoff fixtures with the vendored GStreamer runtime."""
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[3]
gst = root / 'AquaWebKitSupport/deps/build/bin/gst-launch-1.0'
out = Path(__file__).resolve().parent / 'build/quicktime-media'
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, GST_REGISTRY_FORK='no')

def run(pipeline, output=None):
    if output is None:
        subprocess.run([str(gst), '-e'] + pipeline.split(), env=env, check=True)
        return
    with subprocess.Popen([str(gst), '-q', '-e'] + pipeline.split(), env=env, stdout=subprocess.PIPE) as process:
        with output.open('wb') as destination:
            __import__('shutil').copyfileobj(process.stdout, destination)
        if process.wait():
            raise RuntimeError('Fixture pipeline failed')

for filename, mux in [('plain.mp4', 'mp4mux'), ('mse.mp4', 'mp4mux fragment-duration=2000 streamable=true')]:
    run(f'{mux} name=mux ! filesink location={out / filename} '
        'videotestsrc num-buffers=1800 pattern=ball ! video/x-raw,format=NV12,width=320,height=180,framerate=30/1 '
        '! vtenc_h264 max-keyframe-interval=60 ! h264parse ! queue ! mux.video_0 '
        'audiotestsrc num-buffers=2813 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
        '! fdkaacenc bitrate=128000 ! aacparse ! queue ! mux.audio_0')
run(f'mp4mux name=mux fragment-duration=2000 streamable=true ! filesink location={out}/noise.mp4 '
    'videotestsrc num-buffers=300 pattern=snow ! video/x-raw,format=I420,width=640,height=360,framerate=30/1 '
    '! x264enc speed-preset=ultrafast pass=qual quantizer=10 bitrate=240000 vbv-buf-capacity=1000 key-int-max=60 ! video/x-h264,profile=baseline ! h264parse ! queue ! mux.video_0 '
    'audiotestsrc num-buffers=469 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
    '! audioconvert ! fdkaacenc bitrate=128000 ! aacparse ! queue ! mux.audio_0')
subprocess.run([__import__('sys').executable, str(Path(__file__).with_name('index-quicktime-fragments.py')), str(out / 'noise.mp4')], check=True)
run(f'mp4mux name=mux ! filesink location={out}/audio-languages.mp4 '
    'videotestsrc num-buffers=900 pattern=ball ! video/x-raw,format=NV12,width=320,height=180,framerate=30/1 '
    '! vtenc_h264 realtime=true allow-frame-reordering=false ! h264parse ! queue ! mux.video_0 '
    'audiotestsrc num-buffers=1407 samplesperbuffer=1024 freq=440 ! audio/x-raw,rate=48000,channels=2 '
    '! audioconvert ! fdkaacenc ! aacparse ! taginject tags=language-code=en ! queue ! mux.audio_0 '
    'audiotestsrc num-buffers=1407 samplesperbuffer=1024 freq=880 ! audio/x-raw,rate=48000,channels=2 '
    '! audioconvert ! fdkaacenc ! aacparse ! taginject tags=language-code=de ! queue ! mux.audio_1')

run(f'mp4mux name=mux ! filesink location={out}/audio-languages-layout.mp4 '
    'videotestsrc num-buffers=900 pattern=ball ! video/x-raw,format=NV12,width=320,height=180,framerate=30/1 '
    '! vtenc_h264 realtime=true allow-frame-reordering=false ! h264parse ! queue ! mux.video_0 '
    'audiotestsrc num-buffers=1407 samplesperbuffer=1024 freq=440 ! audio/x-raw,rate=48000,channels=2 '
    '! audioconvert ! fdkaacenc bitrate=320000 ! aacparse ! taginject tags=language-code=en ! queue ! mux.audio_0 '
    'audiotestsrc num-buffers=1407 samplesperbuffer=1024 freq=880 ! audio/x-raw,rate=48000,channels=6 '
    '! audioconvert ! fdkaacenc bitrate=960000 ! aacparse ! taginject tags=language-code=de ! queue ! mux.audio_1')

run(f'audiotestsrc num-buffers=2813 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
    f'! audioconvert ! fdkaacenc bitrate=128000 ! aacparse ! mp4mux ! filesink location={out}/audio-only.mp4')

# MPEG-TS segments of at most 6 s, each starting at a keyframe, and their playlist. splitmuxsink reports
# each segment's duration as it closes it.
segmenter = subprocess.run([str(gst), '-m', '-e'] + (
    f'filesrc location={out / "plain.mp4"} ! qtdemux name=demux '
    f'splitmuxsink name=hls muxer=mpegtsmux location={out}/hls-%05d.ts max-size-time=6000000000 '
    'demux.video_0 ! queue ! h264parse ! hls.video '
    'demux.audio_0 ! queue ! aacparse ! hls.audio_0').split(), env=env, check=True, stdout=subprocess.PIPE,
    universal_newlines=True).stdout
segment_durations = [int(duration) / 1e9 for duration in
                     re.findall(r'splitmuxsink-fragment-closed, .*fragment-duration=\(guint64\)(\d+)', segmenter)]
with (out / 'index.m3u8').open('w') as playlist:
    playlist.write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:0\n')
    playlist.write(f'#EXT-X-TARGETDURATION:{max(round(duration + 0.5) for duration in segment_durations)}\n\n')
    for index, duration in enumerate(segment_durations):
        playlist.write(f'#EXTINF:{duration:.3f},\nhls-{index:05d}.ts\n')
    playlist.write('#EXT-X-ENDLIST\n')
for video, audio in [('vp9', 'opus'), ('vp8', 'vorbis')]:
    run(f'webmmux name=mux streamable=true ! filesink location={out}/{video}-{audio}.webm '
        'videotestsrc num-buffers=1800 pattern=ball ! video/x-raw,width=320,height=180,framerate=30/1 '
        f'! {video}enc deadline=1 keyframe-max-dist=60 ! queue ! mux.video_0 '
        'audiotestsrc num-buffers=2813 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
        f'! {audio}enc ! queue ! mux.audio_0')

run(f'mp4mux name=mux fragment-duration=5000 streamable=true ! filesink location={out}/uneven.mp4 '
    'videotestsrc num-buffers=390 pattern=ball ! video/x-raw,format=NV12,width=320,height=180,framerate=30/1 '
    '! vtenc_h264 max-keyframe-interval=150 ! h264parse ! queue ! mux.video_0 '
    'audiotestsrc num-buffers=591 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
    '! fdkaacenc bitrate=128000 ! aacparse ! queue ! mux.audio_0')
subprocess.run([__import__('sys').executable, str(Path(__file__).with_name('index-quicktime-fragments.py')),
               str(out / 'mse.mp4'), str(out / 'uneven.mp4')], check=True)

run(f'mp4mux name=mux fragment-duration=2000 streamable=true ! filesink location={out}/short-audio.mp4 '
    'videotestsrc num-buffers=720 pattern=ball ! video/x-raw,format=NV12,width=320,height=180,framerate=30/1 '
    '! vtenc_h264 max-keyframe-interval=60 ! h264parse ! queue ! mux.video_0 '
    'audiotestsrc num-buffers=94 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
    '! fdkaacenc bitrate=128000 ! aacparse ! queue ! mux.audio_0')

run(f'mp4mux name=mux fragment-duration=1000 streamable=true ! filesink location={out}/loop-video.mp4 '
    'videotestsrc num-buffers=90 pattern=ball ! video/x-raw,format=NV12,width=320,height=180,framerate=30/1 '
    '! vtenc_h264 max-keyframe-interval=30 ! h264parse ! mux.video_0')


import shutil
shutil.copyfile(root / 'LayoutTests/media/content/encrypted/VideoClearKeyCenc.mp4', out / 'encrypted.mp4')

run(f'matroskamux name=mux streamable=true ! filesink location={out}/flac.webm '
    'audiotestsrc num-buffers=2813 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
    '! flacenc ! queue ! mux.audio_0')

subprocess.run([__import__('sys').executable, str(Path(__file__).with_name('index-quicktime-webm.py')),
                '--duration', '60', str(out / 'vp8-vorbis.webm')], check=True)
subprocess.run([__import__('sys').executable, str(Path(__file__).with_name('index-quicktime-webm.py')),
                '--duration', str((2813 * 1024 * 1000 // 48000) / 1000), str(out / 'flac.webm')], check=True)

run('mp4mux name=mux fragment-duration=2000 streamable=true ! fdsink fd=1 '
    'videotestsrc num-buffers=360 pattern=ball ! video/x-raw,format=NV12,width=320,height=180,framerate=30/1 '
    '! vtenc_h264 max-keyframe-interval=60 ! h264parse ! queue ! mux.video_0 '
    'audiotestsrc num-buffers=563 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
    '! avenc_eac3 ! ac3parse ! queue ! mux.audio_0', output=out / 'eac3.mp4')
subprocess.run([__import__('sys').executable, str(Path(__file__).with_name('index-quicktime-fragments.py')),
               str(out / 'eac3.mp4')], check=True)

for name, width, height in [('epoch-a', 320, 180), ('epoch-b', 160, 90)]:
    run(f'mp4mux name=mux fragment-duration=2000 streamable=true ! filesink location={out}/{name}.mp4 '
        f'videotestsrc num-buffers=360 pattern=ball ! video/x-raw,format=NV12,width={width},height={height},framerate=30/1 '
        '! vtenc_h264 max-keyframe-interval=60 ! h264parse ! queue ! mux.video_0 '
        'audiotestsrc num-buffers=563 samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 '
        '! fdkaacenc bitrate=128000 ! aacparse ! queue ! mux.audio_0')
    subprocess.run([__import__('sys').executable, str(Path(__file__).with_name('index-quicktime-fragments.py')),
                    str(out / (name + '.mp4'))], check=True)

run(f'filesrc location={root}/LayoutTests/media/content/test-inband-captions.mp4 ! qtdemux name=d '
    f'qtmux name=m fragment-duration=2000 streamable=true ! filesink location={out}/inband.mp4 '
    'd.video_0 ! queue max-size-time=0 max-size-bytes=0 max-size-buffers=0 ! h264parse ! m.video_0 '
    'd.audio_0 ! queue max-size-time=0 max-size-bytes=0 max-size-buffers=0 ! aacparse ! m.audio_0 '
    'd.subtitle_0 ! queue max-size-time=0 max-size-bytes=0 max-size-buffers=0 ! m.caption_0')
