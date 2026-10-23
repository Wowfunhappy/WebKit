#!/usr/bin/env python3
"""Verify stalled capture releases its request and can reopen."""
import json,pathlib,subprocess,time,sys
rig=pathlib.Path(__file__).resolve().parent
control=rig/'build/media-receiver-control.json'
def osa(s):return subprocess.check_output(['osascript','-e',s],timeout=40).decode().strip()
def js(s):return osa('tell application "Safari" to do JavaScript '+json.dumps(s)+' in current tab of front window')
def wait(f,seconds=60):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  value=f()
  if value:return value
  time.sleep(.25)
 raise AssertionError('Timeout')
def configure(value):control.write_text(json.dumps(value))
def result():return json.loads(wait(lambda:(lambda s:s if s.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
configure({})
osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=mse.mp4&sourceMode=capture&adapter=fixture"}')
wait(lambda:js('Boolean(document.querySelector("#video")?.readyState>=2&&document.querySelector("#open-media-player"))')=='true')
js('video.play()')
wait(lambda:float(js('video.currentTime'))>.5)
js('document.querySelector("#target-application").value="org.aqua.webkit.media-handoff-receiver";document.querySelector("#open-media-player").click();setTimeout(()=>video.pause(),1000)')
start=time.monotonic()
reply=result();print('STALLED',round(time.monotonic()-start,2),reply,flush=True)
assert reply.get('error')=='capture-timeout',reply
assert js('video.paused')=='true'
js('video.play()')
wait(lambda:js('!video.paused')=='true')
js('document.querySelector("#open-media-player").click()')
reply=result();print('REOPEN',reply,flush=True)
assert reply.get('method')=='restream',reply
osa('tell application "Safari" to close current tab of front window')
time.sleep(4)
configure({'closed':True})
time.sleep(3)
osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
configure({})
print('PASS stalled capture releases its opening state and reopens',flush=True)
