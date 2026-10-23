#!/usr/bin/env python3
"""Measure selected audio through Web Audio across seamless video loops."""
import json, subprocess, time

def osa(s):
    return subprocess.check_output(['osascript', '-e', s], timeout=35).decode().strip()

def wait(f, seconds=40):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        v = f()
        if v:
            return v
        time.sleep(0.3)
    raise AssertionError('Timed out')
osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=plain.mp4"}')
w = osa('tell application "Safari" to get id of front window')
print('WINDOW', w, flush=True)

def js(s):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(s) + ' in current tab of window id ' + w)
try:
    wait(lambda : js('Boolean(video.readyState>=2)') == 'true')
    js('video.src="/quicktime-media/audio-languages.mp4";video.loop=true;true')
    wait(lambda : js('video.readyState>=2&&video.audioTracks.length===2') == 'true')
    js('window.ctx=new AudioContext();window.analyser=ctx.createAnalyser();analyser.fftSize=8192;analyser.smoothingTimeConstant=0;window.node=ctx.createMediaElementSource(video);window.gain=ctx.createGain();gain.gain.value=0;node.connect(analyser);analyser.connect(gain);gain.connect(ctx.destination);Array.from(video.audioTracks).forEach(t=>t.enabled=t.language==="en");video.play();ctx.resume();true')
    wait(lambda : js('ctx.state==="running" && video.currentTime>1') == 'true')

    def frequency():
        return float(js('(()=>{let bins=new Float32Array(analyser.frequencyBinCount);analyser.getFloatFrequencyData(bins);let peak=bins.indexOf(Math.max(...bins));return peak*ctx.sampleRate/analyser.fftSize})()'))
    for i in range(10):
        language = 'de' if i % 2 == 0 else 'en'
        expected = 880 if language == 'de' else 440
        js('Array.from(video.audioTracks).forEach(t=>t.enabled=t.language===' + json.dumps(language) + ');true')
        try:
            wait(lambda : abs(frequency() - expected) < 8, 12)
        except Exception:
            print('FAILED', i, language, frequency(), js('JSON.stringify({time:video.currentTime,paused:video.paused,ended:video.ended,seeking:video.seeking,ready:video.readyState,error:video.error?.message,context:ctx.state,duration:video.duration,audio:Array.from(video.audioTracks).map(t=>({enabled:t.enabled,language:t.language}))})'), flush=True)
            raise
        print('SWITCH', i, language, frequency(), 'time', js('video.currentTime'), flush=True)
        time.sleep(7)
finally:
    osa('tell application "Safari" to close current tab of window id ' + w)
print('PASS plain browser audio selection across loops', flush=True)
