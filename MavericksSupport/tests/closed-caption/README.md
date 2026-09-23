Run `bash MavericksSupport/tests/closed-caption/run.sh` after building dependencies.
The native pipeline uses WebCore's CEA-608 conversion path (`ccconverter` and
`cea608tott`) and verifies exact WebVTT text, timestamp, and duration for a timed
pop-on caption. It loads the deployed dependency plugin, with no static substitute.

The layout tests `media/track/text-track-in-band-exposure.html` and
`media/track/track-inband-cea608-cue-endtime.html` additionally exercise video
demuxing, WebCore track exposure, playback, and cue lifetime after installation.
