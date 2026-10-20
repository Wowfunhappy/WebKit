# QuickTime handoff rig

Generate the media and run the fixture server:

```sh
AquaWebKitSupport/toolchain/build/python3/bin/python3 AquaWebKitSupport/tests/legacy-extensions/generate-quicktime-media.py
AquaWebKitSupport/toolchain/build/python3/bin/python3 AquaWebKitSupport/tests/legacy-extensions/server.py
```

Load `MediaPlayerTest.safariextension` in Safari 7's Extension Builder. Open `http://127.0.0.1:8843/quicktime.html` and select a fixture. The test panel exercises `aqua.mediaPlayer.open(element, options)` with a configurable target application. Generated files live under ignored `build/quicktime-media/`. Check that ordinary page JavaScript reports `typeof aqua === "undefined"`.

For MP4 and native HLS, check that QuickTime opens the URL, browser playback pauses under the handoff placard, and closing the tab leaves QuickTime playing.

`element=audio` uses an audio element; `audio-only.mp4` is native AAC audio and `flac.webm` exercises audio-only MSE capture. Run `check-source-modes.py` with the test extension installed to check direct-only and capture-only requests, failed AirPlay probe restoration, accepted-session reuse, audio playback, seeking, and tab closure. Run `check-handoff-scope.py` to check callback failure, stale scope rejection, nested scopes, delayed opens after tab closure, detached unscoped calls, and the five-minute scope deadline.

For MSE, start playback before handoff. Test H.264/AAC, VP9/Opus, VP8/Vorbis, and FLAC audio. The browser continuously encodes its decoded output as H.264/AAC. Check that handoff produces no seeking, play, pause, or volumechange events, and preserves muted, volume, and playbackRate. Natural end-of-media still produces the usual pause event. A paused MSE source rejects with `not-playing`. Playback routed through Web Audio rejects with `unsupported-source`.

The output is an accumulating HLS event stream. Check rewinding to the beginning after several minutes, full seeking after ENDLIST, pausing the target for at least a minute, closing the Safari tab during playback, and closing the movie while leaving QuickTime running. While the receiver is paused, the source keeps playing and the recording keeps growing; receiver pause/resume emits no source pause/play events. All media and subtitle segments remain readable until the receiver closes. A deliberate seek in the source starts a discontinuity. Compare crash reports before and after testing.

`check-live-retention.py` checks accumulated media and subtitle history, source playback and event state during a 65-second receiver pause, playback after tab closure, completed-recording seeking and file cleanup. `--source noise.mp4` selects the high-bitrate fixture; `--seconds` controls the detached playback interval. Run `check-capture-stability.py` for standalone encoder cadence, sparse frames, track tails, fractional frame rates, multichannel audio, 4K noise, dense initial timing gaps, and a new stream following decoder EOS; `--main-stall 20`, `--cancel-after-stall` and `--consumer-delay 25` exercise delivery backpressure and cancellation.

`check-capture-transitions.py --cycles 30` repeats source seeks, rate changes and MediaSource replacements while checking advancing HLS sequences, discontinuities, receiver playback and continuation after tab closure.

`check-audio-endurance.py --seconds 3600` checks live audio-only capture, advancing receiver playback, a bounded playlist and endpoint cleanup after tab closure. `check-direct-redirects.py` checks relative and cross-port redirects for native HLS, MP4 video and audio-only media while retaining direct delivery and seeking.

For generic target selection, install `MediaPlayerTest.safariextension`. Its fixture controls call the same API. `create-media-receiver.py` generates and registers the local test app `org.aqua.webkit.media-handoff-receiver`. Received URLs appear in `build/media-receiver.jsonl`; keep the app running during HTTP and codec checks. A missing application must reject with `application-unavailable` and preserve source playback state.

`check-receiver-lifecycle.py` covers delayed window queries, delayed commands and file metadata, transient metadata loss, omission of an owned window from an application-wide query, source detachment, startup timeout recovery, application exit and reopening, and cancellation during a blocked query. A receiver query failure must preserve the direct source choice; only an explicit source rejection permits capture fallback. `check-route-discovery.py` checks normal routes, route-change listeners without availability listeners, and delayed site responses. `check-capture-startup.py` checks timeout and reopening after a source stalls before enough HLS media is available.

Run `check-media-restream.py <handoff-url>` to check HTTP methods, byte ranges, token rejection, transport continuity, and subtitle resources. It saves playlists and segments under `build/restream/`. Inspect the saved segments with the vendored GStreamer decoder. Run `check-restream-mux.py` to check program tables, the dedicated PCR PID, clocks, continuity, and both audio/video start orders.

The uneven-endings fixture has shorter audio than video. `short-audio.mp4` has two seconds of audio and twenty-four seconds of video; test handoff near audio EOS, and a source seek after audio ends. `mode=open` omits `endOfStream()`. `mode=window` fetches a moving buffer window during playback and after user seeks; `index-quicktime-fragments.py` supplies byte ranges. `worker=1` attaches a transferred MediaSourceHandle. Check that all continue naturally without capture-triggered fetches or seeks.

`mode=live` appends ahead of playback and evicts old data. Add `end=1` to finish after one cycle, or `liveHint=1` to declare a finite one-hour duration. Test both `mse.mp4` and `vp8-vorbis.webm`, including worker-owned MSE. The declared duration does not change the capture path. Check advancement after tab closure and an ENDLIST after actual EOS. Ordinary hidden muted video must retain normal browser suspension behavior.

`check-capture-startup-buffer.py` delays a selected subtitle track for eight seconds and checks that its load event preserves the minimum live startup buffer of three target durations. It uses the generic test receiver and an isolated HTTP fixture server.

`source=encrypted.mp4` exercises the public ClearKey fixture through the page's normal EME session and browser decoder. Start handoff immediately after playback starts: the fixture is about two seconds long. Verify video in the resulting short stream. Protected decoder buffers that cannot be read by the encoder reject with `unsupported-source`.

Add `subtitles=1` for a showing English TextTrack with overlapping cues. `subtitles=external` loads `quicktime-captions.vtt`; `subtitles=delayed` delays its response by three seconds. Inspect the master, `media.m3u8`, subtitle playlists, and timestamp-mapped WebVTT. Check full overlapping cue intervals, layout, cue edits/removals, regions, delayed tracks, and future cues. Published subtitle segments are immutable.

`mode=epochs&subtitles=1` appends two video resolutions. The encoder scales to the initial output geometry. Add `offset=0.5` to exercise a nonzero packet timeline. Check audio/video synchronization and matching subtitle presentation times. `source=inband.mp4` exercises embedded CEA-608 captions; enable its TextTrack before handoff. `check-continuous-handoff.py inband.mp4 --enable-inband --rate 0.25 --replace-source` verifies replacement-track identity and newly published caption text after replacing the decoder.

Replacing MSE and seeking before the new pipeline connects can deadlock GStreamer's playsink ([WebKit 272975](https://bugs.webkit.org/show_bug.cgi?id=272975)), independently reproduced without handoff. `build/continuous-qa/plain-replacement-position.log` and `plain-replacement-stall.sample.txt` record that reproduction; `caption-replacement-stall.sample.txt` records the same stack in the handoff fixture. That interrupted run is an upstream hang, not a passing replacement check.

`MediaLegibleProbe.m` observes platform timed caption output:

```sh
/usr/bin/clang -fobjc-arc -framework AVFoundation -framework Foundation -framework CoreMedia AquaWebKitSupport/tests/legacy-extensions/MediaLegibleProbe.m -o AquaWebKitSupport/tests/legacy-extensions/build/MediaLegibleProbe >> /tmp/wk_build.log 2>&1
AquaWebKitSupport/tests/legacy-extensions/build/MediaLegibleProbe <handoff-url> 15
```

QuickTime 10.2i supports embedded CEA-608 closed captions, verified in the PBS reference stream. Separate non-forced HLS WebVTT tracks were not exposed in its subtitle menu or rendered automatically in tests. Verify visible rendering in the installed receiver in addition to checking playlist delivery. The API preserves forced-track metadata; selected full-caption tracks remain ordinary subtitle renditions. `MediaLegibleProbe` checks timed WebVTT delivery independently of the QuickTime menu. Mavericks AVFoundation ignores tested WebVTT CSS colors and may duplicate overlapping cues across segments or replace them early at format discontinuities.

`tracks=none`, `tracks=showing`, and `tracks=all` exercise explicit track selection. With `subtitles=1`, the first omits subtitles and the others retain cues. `tracks=duplicate`, `foreign`, `disabled`, `invalid`, `not-array`, `oversized`, and `throwing` reject with `unsupported-source`. `tracks=adopted` moves the video into a detached document from an array getter and rejects with `no-source`. Select an initially empty hidden track and add a cue after handoff to check future publication. Custom page caption overlays are not native TextTracks.

With the test extension and receiver installed, `check-continuous-handoff.py 'mse.mp4&subtitles=1'` opens a fixture, observes playback state/events, checks HTTP resources, closes the tab, and verifies continued production. `--position 20 --seek 40` checks nonzero capture and a deliberate source seek; `--rate 2` checks a faster source; `--change-rate 0.5` checks a rate transition; `pitch=false` in the fixture query tests pitch-changing playback; `--position 20 --rate 2 --inline-cues` checks inline subtitle timing on a subtitle fixture; `--replay` checks immutable completed history; `--caption-probe` checks generated captions with the prebuilt native probe; `--loop` checks automatic replay discontinuities; `--loop --stop-loop` checks finalization after disabling looping; `--replace-source` checks continued capture and a discontinuity after replacing the MediaSource; `--web-audio` checks shutdown when routing changes; `--paused` checks rejection without starting playback. The harness controls Safari and quits the test receiver after a successful capture check.


Website-provided remote sources and presentation
-----------------------------------------------

`check-external-handoff.py` drives the QuickTime scripting adapter and verifies
receiver seeking, the original MSE attachment, target closure, and inline return.
Run it with `mse.mp4&airplay=valid`, `--repeat`, and `--close-tab` for transfer
lifetime coverage. `plain.mp4` checks the original-URL timeline; add `--paused` to check paused playback intent. Use
`mse.mp4&airplay=unmatched --expect restream` and
`mse.mp4&airplay=denied --expect restream` to exercise fallback selection.
An invalid alternative can leave QuickTime 10.2 displaying a native error dialog;
`application-start-uncertain` preserves the paused source when receiver startup
and cleanup cannot be confirmed. Dismiss the dialog before resuming the source.
Screenshots in `build/external-handoff/` show the inline handoff placard and restored
video. The target owns URL playback; alternate timelines start at zero and return
to the preserved original position.

Use `mse.mp4&airplay=src-attribute` for a site that declares both `video.src`
and child alternatives. `mse.mp4&airplay=delayed-valid --close-pending`
closes the tab while an alternative is loading, then verifies receiver playback.
`mse.mp4&airplay=delayed-valid --cancel-pending` replaces the source during launch and
checks cancellation and receiver cleanup. Canvas frame reads and video patterns
are checked while the placard is visible. `plain.mp4&subtitles=external --expect restream`
checks that selected page captions retain the capture path.

Add `coalesce=1` to an external-handoff fixture to issue two simultaneous requests,
including a reordered adapter description. `--repeat` verifies the same result and
window are reused; `--reload-extension` checks reuse if the document survives, or clean receiver replacement when Extension Builder reloads the page;
`--closed-receiver` checks a click immediately after closing the movie; `--different-target` verifies that a configuration change leaves
the active receiver intact. `check-continuous-handoff.py 'short-audio.mp4' --rate 2 --replay`
checks finite audio gaps through EOS at a changed playback rate. `loop-video.mp4 --loop --stop-loop`
checks repeated natural MediaSource loops and subsequent finalization.

`check-audio-output.py` builds and runs the native output-suppression test using the configured build commands and installed frameworks. It checks nonzero upstream PCM, signed/unsigned/float silence, buffer lists, EOS/replay, recreated sinks, and restoring inline sound. Compilation appends to `/tmp/wk_build.log`.

Use `check-external-handoff.py mse.mp4 --expect restream --without-controls` to verify the placard on a controls-less video whose page CSS hides the native-controls wrapper, including a newly added showing caption track. Inspect both screenshots for the handoff message and caption restoration.

`check-route-handoff.py` exercises a site that supplies its external URL in response
to the wireless presentation event. It checks original URL delivery despite a supplied title, initial position/rate,
rapid play/pause, overlapping seeks, receiver
clock feedback, same-source reload, source detachment and playback after tab closure.
Use `--paused` for initial pause intent, `--route route-timeout` for an unhandled
route request. Timeout fallback should restore local capture; paused capture
should reject without starting local playback. `--route route-rejected` checks
QuickTime’s unacknowledged 404 launch: it must report `application-start-uncertain`
and leave the page paused. Use `--fallback-disconnect sync`, `async`, or
`none` to vary whether the site replaces its decoder on disconnect, and
`--source flac.webm` to exercise an audio-only decoder.

Inspect the private placard during the initial capture interval: it should hide
inline video and captions, show an animated spinner and the extension's complete opening message, then change to the external playback message when the receiver accepts.
Use a real site with remote playback support to verify URL negotiation and receiver seeking. Use a capture-only source to verify selected audio and repeated decoder replacements; its receiver window must remain open through replacements.

`check-route-handoff.py --return-inline sync`, `async`, `none`, and `controlled` check receiver closure after a same-URL decoder rebuild. They cover immediate or delayed site restoration, absent disconnect handling, and controls issued while the browser waits for the local source.

Live capture uses hardware-only VideoToolbox H.264 Baseline with a 100 Mbps target when available. Software encoding uses x264 ultrafast with normal frame threading, CRF 10, `aq-mode=1`, a 240 Mbps VBV ceiling and a 240 Mbit buffer, constrained to Level 5.2. Extreme scenes can lower quality to respect the ceiling. Audio uses AAC-LC at 160 kbps per channel and preserves the selected decoded channel layout. Actual video bitrate depends on the picture. Capture retains source frame rates of at least 1 fps and repeats slower frames at 1 fps for HLS fragment boundaries. Optional capture dimensions bound the initial resolution while preserving aspect ratio and avoiding upscaling.

Live capture bounds both video input and encoder queues. When encoding falls behind, stale video frames are dropped while audio and media timestamps remain continuous; picture cadence can decrease under load. Long playback checks should verify advancing fragments and audio/video timing as well as receiver lifetime.

The test extension accepts `openingMessage=` for an empty label and `omitOpeningMessage=1` to omit it. Use a custom message containing `<b>`, `&`, quotes and an ellipsis to check literal rendering. Both empty cases must retain the spinner during startup and switch to the active placard after acceptance.

Direct media preserves the original URL and the receiver’s native audio choices. Verify standard HLS audio groups and multi-audio files in QuickTime’s language menu. The adapter does not transfer the browser’s selected language to QuickTime. For sources that require capture, run `check-audio-handoff.py en`, `de`, and `disabled` to check decoded 440/880 Hz selection and omission of disabled audio using fixtures with selected external captions that require capture, including continued playback after tab closure. Enabling initially omitted audio requires a new capture session.

With QuickTime quit, run `check-player-startup.py` to suspend the newly launched receiver for two seconds and verify one movie opens and continues after tab closure. Run it again with QuickTime quit and `--cancel` to hold the receiver while changing the source; no movie should appear after it resumes. Startup queries share the handoff deadline; ordinary receiver monitoring keeps its short timeout.

`check-source-resolver.py` exercises the generic extension source resolver: unchanged direct URLs, a supplied master playlist with remote children, full seeking, playback after tab closure, endpoint cleanup, malformed/rejected/oversized output, timeout, and source replacement during an asynchronous resolution. The test extension's `resolve=` query controls these cases.

`check-handoff-dispatch.py` checks host-prepared tickets, delivery after closing a busy tab, single-use claims, cancellation, expiry, and tab/document isolation using the generic receiver fixture.
