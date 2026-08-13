# Source patches

Patches `build_deps.sh` applies to the source trees it unpacks, before each module is configured/built. Every patch here is applied explicitly and unconditionally by the build script (search it for `patches/`); none is optional. Almost all of them fix a bug or
over-strict behavior in a dependency's **own** source — never a workaround that belongs in WebKit. Regenerate a patch against the pristine upstream tarball if its target version changes.

**If you find yourself wanting to add a new patch here, you are probably doing something wrong!** Consider:
- Is the thing you are trying to fix _really_ broken upstream for hundreds of thousands of users without anyone noticing? If not, it's probably a bug in our code, which we should fix in our code.
- Is it possible to upgrade to a newer version of the dependency instead of patching the old one? If so, it's probably better to upgrade.

The one patch that is not a bug fix is `openwv-runtime-device-file.patch`, which changes where OpenWV reads its configuration from. It earns its place because the thing it changes is a deliberate upstream decision that does not hold here, and because no amount of WebKit-side code can substitute for it — see its section below.

## gst-plugins-bad-ice-credential-charset.patch

**Target:** `gst-plugins-bad-1.28.5`, `ext/webrtc/webrtcsdp.c`
**Applied to:** libgstwebrtc (webrtcbin)

webrtcbin 1.28's `_validate_ice_attr()` rejects a **remote** `ice-ufrag`/`ice-pwd` whose characters fall outside RFC 5245/8839's `ice-char` set (`ALPHA`/`DIGIT`/`+`/`/`). Real browsers (libwebrtc) emit base64/base64url ICE credentials containing `-`/`_`/`=` and do **not** validate the character set of the *remote* credential — you can't rewrite it anyway, it's the STUN username used for connectivity checks. webrtcbin 1.28's strict check makes `set-remote-description` fail for such peers (e.g. Google Meet: the answer is rejected and the call never starts, surfacing as `DisconnectedError EndCause = 19`).

The patch drops the character-set validation, keeping only the length bounds, matching libwebrtc behaviour. Fixed in GStreamer's own source because WebKit cannot legitimately alter the remote credential.

## gst-plugins-bad-vtenc-tag-source-colorimetry.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtenc.c`
**Applied to:** libgstapplemedia (vtenc_h264)

`gst_vtenc_set_colorimetry()` sets the compression session's destination color properties (`ColorPrimaries`/`TransferFunction`/`YCbCrMatrix`), which makes VideoToolbox color-match every source pixel buffer against them. On macOS the element builds those source buffers itself, with `CVPixelBufferCreateWithPlanarBytes()` around raw GstMemory, and never states what color the pixels are — the buffer reaches VideoToolbox with **no color attachments at all**. Modern macOS infers defaults for an untagged source; OS X 10.9's VideoToolbox cannot, and fails **every** frame with `kVTInsufficientSourceColorDataErr` (-12917) — the session creates fine, then zero frames come out. Net effect: WebRTC outbound H.264 (e.g. our camera on Google Meet) never sends a single packet. `gst-launch` isolates it: colorimetry that maps to no session color properties encodes clean; bt601/bt709 (properties set) fails every frame.

The colorimetry is already known from the negotiated caps, and vtenc already maps it onto the CoreVideo constants to build the session properties. The patch splits that mapping into `gst_vtenc_colorimetry_to_cv()` and tags the source buffer with it (`kCVImageBufferColorPrimariesKey` / `TransferFunctionKey` / `YCbCrMatrixKey`, all present since 10.4) at both sites that build a pixel buffer from raw memory. Color matching then has both ends it needs and succeeds on 10.9, with the destination properties left in place, so the encoded stream still carries correct color information.

## gst-plugins-bad-vtdec-hw-hardware-caps-probe.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtdec.c`
**Applied to:** libgstapplemedia (vtdec_hw)

`vtdec_hw` (rank primary+1, above `avdec_h264`) advertises every codec in its sink template whether or not the machine can hardware-decode it. On a machine with no hardware decoder for the codec (any VM; H.264-only-era Macs asked for HEVC), `VTDecompressionSessionCreate(RequireHardware)` fails with **-8973** (`kVTCouldNotFindVideoDecoderErr`) — but only in `set_format`, once caps flow on the streaming thread. `decodebin` recovers (its factory loop runs there and plugs the next factory); **`decodebin3` does not** — its candidate window closes after a caps-less READY→PAUSED, so the late error passes through and kills the pipeline. WebKit reaches decodebin3 through `playbin3` for every MSE, blob and mediastream player, so on such machines all MSE video dies with "GStreamer encountered a general resource error." while a working software decoder sits one rank below.

The patch extends `gst_vtdec_getcaps`'s existing honesty mechanism (VP9/AV1 are already gated on `VTIsHardwareDecodeSupported`): for the `require_hardware` subclass, each sink-template codec is kept only if a `RequireHardware` decompression session can actually be created for it, probed once per codec type with a bare `CMVideoFormatDescription` (measured: the bare-description software session succeeds while RequireHardware answers -8973, so the probe isolates hardware availability, not description validity). With the codec stripped, decodebin3's accept-caps check fails inside its candidate window and the next factory is tried. On machines whose VideoToolbox does hardware-decode the codec, the probe succeeds and `vtdec_hw` keeps its caps, rank and hardware path.

## gst-plugins-bad-vtdec-109-sink-template-codecs.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtdec.c`
**Applied to:** libgstapplemedia (vtdec, vtdec_hw)

vtdec's static sink template advertises VP9 and AV1, and the template is what the registry serves to capability queries — WebKit's `GStreamerRegistryScanner` answers `MediaSource.isTypeSupported`, `canPlayType` and MediaCapabilities from factory templates, never from an instantiated element. 10.9's VideoToolbox has no VP9 or AV1 decoder on any hardware: the supplemental-decoder mechanism vtdec gates them on is macOS 11+, and `VTIsHardwareDecodeSupported` (10.13+; the gap-archive definition probes a `RequireHardware` session) answers false for both on every 10.9 machine, so vtdec's own `getcaps` always strips both before negotiation. With the template claiming what getcaps then denies, the scanner reported decoders that can never instantiate — sites offered AV1 on the strength of that answer (YouTube embeds) streamed video whose branch sat undecodable behind a parser, playing audio over black frames. Removing the two entries makes the registry agree with getcaps. H.264/H.265/MPEG-2/JPEG/ProRes stay: those go through the per-codec `RequireHardware` probe above or plain vtdec's software session, which 10.9's VideoToolbox does provide.

## gst-libav-register-libdav1d.patch

**Target:** `gst-libav-1.28.5`, `ext/libav/gstavviddec.c`
**Applied to:** libgstlibav

gst-libav's decoder registration skips every FFmpeg decoder whose name starts with `lib`, on the stated premise that "we have native gstreamer plugins for all of those libraries anyway". This runtime has no native AV1 decoder for that rule to point at: gst-plugins-bad 1.28 carries no dav1d wrapper (`dav1ddec` lives in gst-plugins-rs, which is not part of this build), its `ext/aom` needs a libaom this build does not vendor, and FFmpeg's native `av1` decoder is hardware-only (gst-libav skips it by name for exactly that reason). The FFmpeg built here links dav1d (`--enable-libdav1d`), so the wrapper codec is present and fully functional software decode. The patch admits `libdav1d` through the external-library skip, registering `avdec_libdav1d` (rank marginal, like the other avdec video decoders) — the runtime's AV1 decoder for `<video>`, MSE and WebCodecs. The required-artifacts gate asks the registry for the element by name so a regression fails the build rather than reverting AV1 to a parser with no decoder.

## openwv-runtime-device-file.patch

**Target:** `openwv v1.1.4`, `src/config.rs` + `src/openwv.rs`
**Applied to:** `lib/libwidevinecdm.dylib`

OpenWV embeds the `.wvd` device identity in the binary at build time —
`include_bytes!("../embedded.wvd")` — because, as its README puts it, a CDM is heavily
sandboxed by the browser and so cannot read configuration from disk. That reasoning is
about Chrome and Firefox. Here the browser is ours: the module is deployed inside
WebCore.framework beside the GStreamer runtime, in a directory whose contents the
WebContent sandbox already reads, so it can open a file next to itself.

The patch makes it do that. `CONFIG.widevine_device` becomes `widevine_device_file`, a
name rather than bytes, and `InitializeCdmModule_4()` asks `dladdr()` where this library
was loaded from and reads the device from that directory. A missing file is logged and
left alone: `CreateCdmInstance()` already refuses without a device, which surfaces as an
unsupported key system.

Two things follow, and both are the point:
- The device identity is no longer compiled into a binary, so it can be supplied, replaced
  or removed by moving one file, with no rebuild of anything.
- `build_deps.sh` builds the module whether or not an operator supplied a `.wvd`.

This does **not** make the key any less exposed. The file has to be world-readable for the
sandboxed web process to read it, exactly as the module itself is, so anyone who could
extract the key from the binary can equally read the file.
