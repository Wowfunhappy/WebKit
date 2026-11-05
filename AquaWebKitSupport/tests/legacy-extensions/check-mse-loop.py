#!/usr/bin/env python3
"""A looping Media Source video returns to its start and keeps playing, repeatedly."""
import json
import subprocess
import time


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=40, stderr=subprocess.STDOUT).decode().strip()


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of front window')


def wait(condition, seconds=30):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = condition()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError('Timeout')


osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=mse.mp4"}')
wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2)') == 'true')
js('window.seekings=0;window.seekeds=0;video.addEventListener("seeking",()=>seekings++);video.addEventListener("seeked",()=>seekeds++);video.loop=true;video.play();1')
for loop in range(3):
    # Each pass plays the last two seconds and has to wrap around.
    js('video.currentTime=video.duration-2;1')
    wait(lambda: js('!video.seeking&&video.currentTime<video.duration-2.5') == 'true', 15)
    position = float(js('video.currentTime'))
    wait(lambda: float(js('video.currentTime')) > position + .5, 10)
    assert js('!video.paused&&!video.ended&&video.readyState>=2') == 'true', js('JSON.stringify({p:video.paused,e:video.ended,r:video.readyState})')
    print('loop', loop, 'position', position, flush=True)
assert js('seekings===seekeds') == 'true', js('JSON.stringify([seekings,seekeds])')
osa('tell application "Safari" to close current tab of front window')

# Data appended after a wrap reopens the source, and the longer stream wraps as well.
osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=plain.mp4"}')
wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2)') == 'true')
js('''(async function () {
    window.state = 'loading';
    const source = new MediaSource();
    window.mediaSource = source;
    video.src = URL.createObjectURL(source);
    await new Promise(resolve => source.addEventListener('sourceopen', resolve, { once: true }));
    window.sourceBuffer = source.addSourceBuffer('video/mp4; codecs="avc1.42E01E,mp4a.40.2"');
    window.fixture = await (await fetch('/quicktime-media/av-short.mp4')).arrayBuffer();
    sourceBuffer.appendBuffer(fixture);
    await new Promise(resolve => sourceBuffer.addEventListener('updateend', resolve, { once: true }));
    source.endOfStream();
    video.loop = true;
    video.play();
    window.state = 'ready';
}()); 1''')
wait(lambda: js('window.state') == 'ready')
first_duration = float(js('video.duration'))
js('video.currentTime=video.duration-1;1')
wait(lambda: js('!video.seeking&&video.currentTime<video.duration-1.5') == 'true', 15)
js('''(async function () {
    sourceBuffer.timestampOffset = mediaSource.duration;
    sourceBuffer.appendBuffer(fixture);
    await new Promise(resolve => sourceBuffer.addEventListener('updateend', resolve, { once: true }));
    mediaSource.endOfStream();
    window.state = 'extended';
}()); 1''')
wait(lambda: js('window.state') == 'extended')
assert float(js('video.duration')) > first_duration * 1.5, js('video.duration')
js('video.currentTime=video.duration-1;1')
wait(lambda: js('!video.seeking&&video.currentTime<video.duration-1.5&&video.currentTime<3') == 'true', 15)
position = float(js('video.currentTime'))
wait(lambda: float(js('video.currentTime')) > position + .5, 10)
assert js('!video.error&&!video.paused') == 'true'
osa('tell application "Safari" to close current tab of front window')

# Data appended while the source's end of stream is still playing out continues the same playback.
osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=plain.mp4"}')
wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2)') == 'true')
js('''(async function () {
    window.state = 'loading';
    const source = new MediaSource();
    window.mediaSource = source;
    video.src = URL.createObjectURL(source);
    await new Promise(resolve => source.addEventListener('sourceopen', resolve, { once: true }));
    window.sourceBuffer = source.addSourceBuffer('video/mp4; codecs="avc1.42E01E,mp4a.40.2"');
    window.fixture = await (await fetch('/quicktime-media/av-short.mp4')).arrayBuffer();
    sourceBuffer.appendBuffer(fixture);
    await new Promise(resolve => sourceBuffer.addEventListener('updateend', resolve, { once: true }));
    source.endOfStream();
    video.loop = false;
    window.ends = 0;
    window.seekings = 0;
    video.addEventListener('ended', () => ends++);
    video.addEventListener('seeking', () => seekings++);
    video.play();
    window.state = 'ready';
}()); 1''')
wait(lambda: js('window.state') == 'ready')
first_duration = float(js('video.duration'))
wait(lambda: float(js('video.currentTime')) > 1, 10)
js('''(async function () {
    sourceBuffer.timestampOffset = mediaSource.duration;
    sourceBuffer.appendBuffer(fixture);
    await new Promise(resolve => sourceBuffer.addEventListener('updateend', resolve, { once: true }));
    mediaSource.endOfStream();
    window.state = 'extended';
}()); 1''')
wait(lambda: js('window.state') == 'extended')
position = float(js('video.currentTime'))
assert 1 < position < first_duration, position
assert float(js('video.duration')) > first_duration * 1.5, js('video.duration')
wait(lambda: float(js('video.currentTime')) > first_duration + 1, first_duration + 15)
assert js('!video.error&&!video.paused&&!video.ended&&ends===0&&seekings===0') == 'true', js('JSON.stringify({error:Boolean(video.error),paused:video.paused,ended:video.ended,ends,seekings})')
js('video.currentTime=video.duration-1;1')
wait(lambda: js('video.ended') == 'true', 15)
assert js('!video.error&&ends===1') == 'true', js('JSON.stringify({error:Boolean(video.error),ends})')
osa('tell application "Safari" to close current tab of front window')

# A removal reopens a source whose end of stream is still playing out, and a second end of stream follows.
osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=plain.mp4"}')
wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2)') == 'true')
js('''(async function () {
    window.state = 'loading';
    const source = new MediaSource();
    window.mediaSource = source;
    video.src = URL.createObjectURL(source);
    await new Promise(resolve => source.addEventListener('sourceopen', resolve, { once: true }));
    window.sourceBuffer = source.addSourceBuffer('video/mp4; codecs="avc1.42E01E,mp4a.40.2"');
    sourceBuffer.appendBuffer(await (await fetch('/quicktime-media/av-short.mp4')).arrayBuffer());
    await new Promise(resolve => sourceBuffer.addEventListener('updateend', resolve, { once: true }));
    source.endOfStream();
    window.ends = 0;
    video.addEventListener('ended', () => ends++);
    video.play();
    window.state = 'ready';
}()); 1''')
wait(lambda: js('window.state') == 'ready')
wait(lambda: float(js('video.currentTime')) > 1, 10)
js('''(async function () {
    sourceBuffer.remove(mediaSource.duration - 2, mediaSource.duration);
    await new Promise(resolve => sourceBuffer.addEventListener('updateend', resolve, { once: true }));
    mediaSource.endOfStream();
    window.state = 'removed';
}()); 1''')
wait(lambda: js('window.state') == 'removed')
wait(lambda: js('video.ended') == 'true', 20)
js('video.currentTime=0;video.play();1')
wait(lambda: js('!video.seeking&&!video.paused&&video.currentTime>.5') == 'true', 15)
wait(lambda: js('video.ended') == 'true', 20)
assert js('!video.error&&ends===2') == 'true', js('JSON.stringify({error:Boolean(video.error),ends})')
osa('tell application "Safari" to close current tab of front window')

# A worker's source does the same.
osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=plain.mp4"}')
wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2)') == 'true')
js('''(function () {
    window.state = 'loading';
    const code = `
        let source, buffer, fixture;
        self.onmessage = async event => {
            if (event.data === 'start') {
                source = new MediaSource();
                self.postMessage({ handle: source.handle }, [source.handle]);
                await new Promise(resolve => source.addEventListener('sourceopen', resolve, { once: true }));
                buffer = source.addSourceBuffer('video/mp4; codecs="avc1.42E01E,mp4a.40.2"');
                fixture = await (await fetch('${location.origin}/quicktime-media/av-short.mp4')).arrayBuffer();
                buffer.appendBuffer(fixture);
                await new Promise(resolve => buffer.addEventListener('updateend', resolve, { once: true }));
                source.endOfStream();
                self.postMessage({ state: 'ready' });
            } else {
                buffer.timestampOffset = source.duration;
                buffer.appendBuffer(fixture);
                await new Promise(resolve => buffer.addEventListener('updateend', resolve, { once: true }));
                source.endOfStream();
                self.postMessage({ state: 'extended' });
            }
        };`;
    window.worker = new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
    window.ends = 0;
    video.addEventListener('ended', () => ends++);
    worker.onmessage = event => {
        if (event.data.handle) {
            video.removeAttribute('src');
            video.srcObject = event.data.handle;
        } else {
            window.state = event.data.state;
            if (state === 'ready') video.play();
        }
    };
    worker.postMessage('start');
}()); 1''')
wait(lambda: js('window.state') == 'ready')
first_duration = float(js('video.duration'))
wait(lambda: float(js('video.currentTime')) > 1, 10)
js('worker.postMessage("extend");1')
wait(lambda: js('window.state') == 'extended')
wait(lambda: float(js('video.currentTime')) > first_duration + 1, first_duration + 15)
assert js('!video.error&&!video.paused&&ends===0') == 'true', js('JSON.stringify({error:Boolean(video.error),paused:video.paused,ends})')
osa('tell application "Safari" to close current tab of front window')
print('PASS looping Media Source video wraps and keeps playing, and data appended or removed after the end of stream plays on, also from a worker', flush=True)
