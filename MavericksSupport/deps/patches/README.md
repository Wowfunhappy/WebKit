# GStreamer source patches

Patches applied to the vendored GStreamer source trees by `build_deps.sh` before each
module is configured/built. Every patch here is applied explicitly and unconditionally by
the build script (search it for `patches/`); none is optional. Each patch fixes a bug or
over-strict behavior in GStreamer's **own** source — never a workaround that belongs in
WebKit. Regenerate a patch against the pristine upstream tarball if its target version
changes.

## gst-plugins-bad-ice-credential-charset.patch

**Target:** `gst-plugins-bad-1.28.5`, `ext/webrtc/webrtcsdp.c`
**Applied to:** libgstwebrtc (webrtcbin)

webrtcbin 1.28's `_validate_ice_attr()` rejects a **remote** `ice-ufrag`/`ice-pwd` whose
characters fall outside RFC 5245/8839's `ice-char` set (`ALPHA`/`DIGIT`/`+`/`/`). Real
browsers (libwebrtc) emit base64/base64url ICE credentials containing `-`/`_`/`=` and do
**not** validate the character set of the *remote* credential — you can't rewrite it
anyway, it's the STUN username used for connectivity checks. webrtcbin 1.28's strict check
makes `set-remote-description` fail for such peers (e.g. Google Meet: the answer is
rejected and the call never starts, surfacing as `DisconnectedError EndCause = 19`).

The patch drops the character-set validation, keeping only the length bounds, matching
libwebrtc behaviour. Fixed in GStreamer's own source because WebKit cannot legitimately
alter the remote credential.

## gst-plugins-bad-vtenc-tag-source-colorimetry.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtenc.c`
**Applied to:** libgstapplemedia (vtenc_h264)

`gst_vtenc_set_colorimetry()` sets the compression session's destination color
properties (`ColorPrimaries`/`TransferFunction`/`YCbCrMatrix`), which makes VideoToolbox
color-match every source pixel buffer against them. On macOS the element builds those
source buffers itself, with `CVPixelBufferCreateWithPlanarBytes()` around raw GstMemory,
and never states what color the pixels are — the buffer reaches VideoToolbox with **no
color attachments at all**. Modern macOS infers defaults for an untagged source; OS X
10.9's VideoToolbox cannot, and fails **every** frame with
`kVTInsufficientSourceColorDataErr` (-12917) — the session creates fine, then zero frames
come out. Net effect: WebRTC outbound H.264 (e.g. our camera on Google Meet) never sends
a single packet. A/B-proven with `gst-launch`: colorimetry that maps to no session color
properties encodes clean; bt601/bt709 (properties set) fails every frame.

The colorimetry is already known from the negotiated caps, and vtenc already maps it onto
the CoreVideo constants to build the session properties. The patch splits that mapping
into `gst_vtenc_colorimetry_to_cv()` and tags the source buffer with it
(`kCVImageBufferColorPrimariesKey` / `TransferFunctionKey` / `YCbCrMatrixKey`, all present
since 10.4) at both sites that build a pixel buffer from raw memory. Color matching then
has both ends it needs and succeeds on 10.9, with the destination properties left in
place, so the encoded stream still carries correct color information.

## Retired / not applied

- **SCTP-transport GWeakRef guard** (webrtcsctptransport.c raw-pointer signal callbacks):
  webrtcbin's sctp-transport disconnects its `sctpenc`/`sctpdec` signal callbacks in
  finalize without waiting for an in-flight cross-thread emission, a genuine UAF. A GWeakRef
  patch was prototyped, but A/B testing on 1.28 (Meet 0/6 crashes with *and* without it;
  stress-test crash rate unchanged) showed 1.28's graceful `webrtcbin` `close()` reorders
  teardown so the race does not fire in practice. Per project policy (no dependency patch
  unless it demonstrably earns its place), it is **not** applied. If a teardown crash
  traced to that path reappears, the patch is recoverable from git history.
