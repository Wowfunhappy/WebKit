# Extension adaptive media regression

These tests exercise native `<video src>` HLS through WebCore's resource loader.
They use a local HTTP controller, a developer Safari extension, and the vendored
GStreamer tools. Generated media and result files live in directories supplied by
the caller. The tools use `safari.*` and ordinary media APIs.

## Generate and install

Run from the repository root, with a new directory in the extension workspace:

```sh
python3 AquaWebKitSupport/tests/legacy-extensions/generate-extension-adaptive-media.py --output "$FIXTURE"
python3 AquaWebKitSupport/tests/legacy-extensions/check-extension-adaptive-media.py serve --fixture "$FIXTURE" --results "$RESULTS"
```

The controller listens on localhost:8862. Install the generated extension through
Safari's Extension Builder. The controller's `/events` endpoint reports `ready`
for the WK1 global page and popover, including the current `safari.extension.baseURI`.
The global page intentionally runs without a window. Open the extension's
`tab.html` in a separate browser window for WK2.

Safari gives installed extensions a token in their base URI. Render the playlists
in the installed **test extension's extracted cache directory** after installation,
and after a restart if the base URI changes:

```sh
python3 AquaWebKitSupport/tests/legacy-extensions/check-extension-adaptive-media.py render --installed "$INSTALLED_FIXTURE" --base "$BASE_URI"
```

On Safari 7 the bundle directory name is recorded in
`~/Library/Safari/Extensions/Extensions.plist`, and the extracted bundle is under
`~/Library/Caches/com.apple.Safari/Extensions/`. Only the generated test bundle
should be supplied. Rendering changes its playlist files from the included
`.template` files; it does not edit any application or library. This gives actual
absolute `safari-extension:` URLs without guessing or bypassing Safari's token.
The HTTP controller substitutes its own base into the same templates.

## Expectations

For each of `tab`, `global`, and a **visible** `popover`, run all three HLS families
(`ts`, `cmaf`, `aes`) with absolute and relative element sources:

```sh
python3 AquaWebKitSupport/tests/legacy-extensions/check-extension-adaptive-media.py run --context tab --id ts-absolute --path hls/ts/master.m3u8 --output "$RESULTS/ts-absolute.json"
python3 AquaWebKitSupport/tests/legacy-extensions/check-extension-adaptive-media.py run --context tab --id ts-relative --path hls/ts/master.m3u8 --relative --output "$RESULTS/ts-relative.json"
python3 AquaWebKitSupport/tests/legacy-extensions/check-extension-adaptive-media.py popover
```

Every positive case must load metadata, advance playback, seek to 60% and 90%, and
advance after each seek without a media error. A failed expectation exits nonzero
and retains the detailed result. The JSON includes source, dimensions, duration,
ready/network state, time, buffered ranges, rendered/dropped frame counts, wall-clock
timestamps, event sequence (including waiting), and seek targets.

Each master has 320x180 and 640x360 H.264/AAC variants. Media playlists alternate
relative and absolute segment URLs. `cmaf` is the fragmented-MP4 test directory:
its initialization map is absolute; no separate CMAF conformance claim is made.
`aes` contains AES-128-CBC MPEG-TS segments, a deterministic test key, implicit
media-sequence IVs, and PKCS#7 padding. The key URL is absolute. The generator
checks the expected fragmented-MP4 segment count; HTTP controls validate the same
assets independently of extension transport.

`--http` uses the local HTTP version. `--http --switch` throttles later high-variant
segments and observes playback until EOS or 90 seconds. It requires end-of-stream and a change in
video resolution; inspect `requests.jsonl` to confirm both variants were fetched.
Run it for TS and AES to exercise adaptation with and without decryption.

`--path hls/ts/subtitles.m3u8 --subtitles` enables the WebVTT track and requires
loaded cues. The subtitle master is separate so text failures are distinguishable
from basic transport failures.

For direct-media regressions, use `--path clip.mp4` and `--path clip.webm`, both
with and without `--http`. For blobs use `--path clip.mp4 --blob`, then repeat with
`--blob-type video/mp4`. Both must play and seek.

DASH is conditional. Record `ready.types['application/dash+xml']`; try
`--http --path stream.mpd` and the same with `--type application/dash+xml`. Only
use `--expect-failure` when checking that DASH is disabled on the current port.
The generated MPD references the fragmented MP4 files. If ordinary HTTP DASH is
unsupported, extension DASH is outside the enabled engine's capabilities.

## Clean up

Record the initial extension entries, Safari windows, environment, audio settings
and crash-report inventory before testing. Uninstall the test extension and remove
its Builder entry, close only its temporary browser window, stop the controller,
and restore changed settings. Remove temporary probe files. Keep Safari running.
Compare crash reports and extension entries with the initial snapshots.
