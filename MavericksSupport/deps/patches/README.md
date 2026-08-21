# Source patches

Patches `build_deps.sh` applies to the source trees it unpacks, on the run that unpacks them and before that module is configured (search it for `patches/`); every patch here is named explicitly and none is optional. Each patch fixes a bug or
over-strict behavior in GStreamer's **own** source — never a workaround that belongs in WebKit. Regenerate a patch against the pristine upstream tarball if its target version changes.

**If you find yourself wanting to add a new patch here, you are probably doing something wrong!** Consider:
- Is the thing you are trying to fix _really_ broken upstream for hundreds of thousands of users without anyone noticing? If not, it's probably a bug in our code, which we should fix in our code.
- Is it possible to upgrade to a newer version of the dependency instead of patching the old one? If so, it's probably better to upgrade.

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

vtdec's static sink template advertises VP9, AV1 and HEVC, and the template is what the registry serves to capability queries — WebKit's `GStreamerRegistryScanner` answers `MediaSource.isTypeSupported`, `canPlayType` and MediaCapabilities from factory templates, never from an instantiated element, and `PlatformMediaEngineConfigurationFactoryGStreamer` reports `powerEfficient` straight from the matched factory's `Hardware` klass.

10.9's VideoToolbox decodes none of the three on any hardware. The supplemental-decoder mechanism vtdec gates VP9 and AV1 on is macOS 11+; HEVC decode arrived in 10.13; and `VTIsHardwareDecodeSupported` is itself 10.13+ (the gap-archive definition probes a `RequireHardware` session, so it answers false on every 10.9 machine). Measured on this host, a VideoToolbox HEVC session fails outright — `VTDecompressionSessionCreate` returns **-12906** — while vtdec's own `getcaps` already strips VP9 and AV1 before negotiation.

With the template claiming what the machine then denies, the scanner reported decoders that can never instantiate and called their software fallback power-efficient: sites offered AV1 or HEVC on the strength of that answer streamed video that decodes in software (HEVC, via `avdec_h265`) or not at all (AV1 embeds played audio over black frames, the branch sitting undecodable behind a parser). Removing the three entries makes the registry agree with the machine, so those codecs are reported unsupported-by-VideoToolbox and `powerEfficient` is no longer asserted for a software decode path. H.264/MPEG-2/JPEG/ProRes stay: those go through the per-codec `RequireHardware` probe above or plain vtdec's software session, which 10.9's VideoToolbox does provide.

## gst-libav-register-libdav1d.patch

**Target:** `gst-libav-1.28.5`, `ext/libav/gstavviddec.c`
**Applied to:** libgstlibav

gst-libav's decoder registration skips every FFmpeg decoder whose name starts with `lib`, on the stated premise that "we have native gstreamer plugins for all of those libraries anyway". This runtime has no native AV1 decoder for that rule to point at: gst-plugins-bad 1.28 carries no dav1d wrapper (`dav1ddec` lives in gst-plugins-rs, which is not part of this build), its `ext/aom` needs a libaom this build does not vendor, and FFmpeg's native `av1` decoder is hardware-only (gst-libav skips it by name for exactly that reason). The FFmpeg built here links dav1d (`--enable-libdav1d`), so the wrapper codec is present and fully functional software decode. The patch admits `libdav1d` through the external-library skip, registering `avdec_libdav1d` (rank marginal, like the other avdec video decoders) — the runtime's AV1 decoder for `<video>`, MSE and WebCodecs. The required-artifacts gate asks the registry for the element by name so a regression fails the build rather than reverting AV1 to a parser with no decoder.

## ffmpeg-hevc-alpha-videotoolbox-vps.patch

**Target:** `ffmpeg-8.1.2`, `libavcodec/hevc/ps.c`
**Applied to:** libavcodec (the `hevc` decoder, gst-libav's avdec_h265)

Upstream FFmpeg commit `eedf8f0165fe` (Zhao Zhili, 2026-03-05, "avcodec/hevc: workaround hevc-alpha videos generated by VideoToolbox", FFmpeg ticket #22384), carried verbatim: it postdates the 8.1 branch and is in no release tarball.

HEVC with an alpha channel is one `hvc1` track whose every sample holds a base-layer NAL (`nuh_layer_id` 0) followed by an alpha-layer NAL (`nuh_layer_id` 1), each layer with its own SPS/PPS, described by an Annex F `vps_extension` (Apple's "HEVC Video with Alpha Interoperability Profile"; apple.com's hero animations, Final Cut and AVFoundation exports). libavcodec 62's `decode_vps_ext()` parses that extension for the two-layer case and `ff_hevc_is_alpha_video()` drives decoding of the alpha layer into the frame's fourth plane. The VPS extension VideoToolbox writes does not follow the syntax after the output-layer-set loop: the bits where `vps_num_rep_formats_minus1` belongs read as a value the parser cannot take, and it returned `AVERROR_INVALIDDATA`, which discards the whole VPS — `VPS 0 does not exist`, then every SPS and PPS is refused, and the stream decodes **zero frames**. The commit returns `AVERROR_PATCHWELCOME` there instead, and on that path keeps the alpha-layer topology already parsed (two layers, the alpha `nuh_layer_id`, the auxiliary scalability type) rather than falling back to a single layer; for an alpha layer with no dependency on the base layer it also sets `poc_lsb_not_present`, because these encoders write IDR alpha slices without `pic_order_cnt_lsb`. Measured on apple.com's `hero/medium.mov` with the `ffmpeg` tool: all 150 frames decode as `yuva420p`, with per-frame alpha planes of roughly a third transparent, a third opaque and a third partial.

## gst-libav-avviddec-select-first-software-format.patch

**Target:** `gst-libav-1.28.5`, `ext/libav/gstavviddec.c`, `ext/libav/gstavcodecmap.c`
**Applied to:** libgstlibav (every avdec_* video decoder)

libavcodec hands the output pixel format choice to the caller through `AVCodecContext.get_format`, offering the formats it can produce for the stream: hardware-accelerated ones first, software ones last, and when a decoder can produce a richer software format it lists that ahead of the plain one — the hevc decoder offers `yuva420p` before `yuv420p` for a stream carrying an alpha layer and decodes that layer **only if the caller selects the alpha format**. avviddec installs no `get_format`, so the choice falls to `avcodec_default_get_format()`, which returns the *last* software format. The alpha layer is therefore never decoded and the stream comes out as opaque I420 with the background the base layer encodes, and because the element succeeded, a page's `<source>` fallback to a VP9-alpha WebM never engages.

The patch installs a `get_format` that selects the first software format — the policy of the `ffmpeg` tool itself (`fftools/ffmpeg_dec.c`, `get_format()`), skipping `AV_PIX_FMT_FLAG_HWACCEL` entries. For every codec that offers a single software format the selection is that format, so only decoders that offer an alpha variant change behavior. The hevc decoder's alpha variants are `yuva420p`, `yuva422p`, `yuva444p` and their 10/12-bit forms; gst-libav's pixel-format table maps the 4:2:0 and 10-bit ones and lacks `yuva422p`, `yuva444p` and the 12-bit 4:2:2/4:4:4 ones, which GStreamer names `A422`, `A444`, `A422_12LE/BE` and `A444_12LE/BE` (since 1.24), so the patch adds those six entries — a selected format the table cannot name would otherwise end the stream as `unknown_format`.

Decoding the alpha layer also exercises a second part of libavcodec's `get_buffer2` contract (`libavcodec/avcodec.h`): "buf[] must contain one or more pointers to AVBufferRef structures. Each of the frame's data and extended_data pointers must be contained in these. That is, one AVBufferRef for each allocated chunk of memory, not necessarily one AVBufferRef per data[] entry." The hevc decoder decodes the alpha layer into its own frame and then points that frame's luma plane at the base frame's alpha plane (`replace_alpha_plane()` in `libavcodec/hevc/refs.c`), locating both planes' buffers through `buf[]`. avviddec's direct-rendering `get_buffer2` sets a single zero-size placeholder `AVBufferRef` that contains no plane, so the lookup fails with `AVERROR_BUG` on every alpha-layer NAL ("Invalid input packet", `MEDIA_ERR_SRC_NOT_SUPPORTED` in the page) while the bare `ffmpeg` tool, on libavcodec's own allocator, decodes the same file. The patch gives the frame one `AVBufferRef` per plane — `data[c]` and the plane's stride × height — each holding the mapped GStreamer frame through a shared parent reference whose release unmaps and returns the buffer as before; the read-only flag that forces a `get_buffer2` per output frame is carried on every plane reference. That is the shape libavcodec's own `avcodec_default_get_buffer2()` produces, and replacing one plane's buffer leaves the others holding the frame.

The A420 frames then take the same path as VP9-with-alpha WebM: gst-libav maps `yuva420p` to `A420`, and playsink's converter produces BGRA for WebKit's sink.

## gst-plugins-base-urisourcebin-reset-parsebin-on-caps-change.patch

**Target:** `gst-plugins-base-1.28.5`, `gst/playback/gsturisourcebin.c`
**Applied to:** libgstplayback (urisourcebin)

A stream whose media type changes mid-play stops at the change. The case that reaches users is an MSE SourceBuffer handed a clear period and then an encrypted one — what server-side ad insertion produces, and what CBS and Netflix serve. The clear period leaves parsebin holding an `h264parse` chain; the encrypted period arrives as `application/x-cenc`, which that chain cannot take, so the caps event is refused and the next `gst_pad_push` answers **not-negotiated**. WebKit surfaces that as `MEDIA_ERR_DECODE` ("Failed to push buffer") and the video never resumes, while the audio branch — whose decryptor was plugged for the same reason — leaves the pipeline unable to preroll, so a seek across the boundary never completes either.

decodebin3 already answers this for the parsebin *it* owns: on a caps event its chain does not accept, `gst_decodebin_input_reset_parsebin()` sets that parsebin to `GST_STATE_NULL` and syncs it back, and it re-autoplugs from the new caps — here, plugging a CENC decryptor ahead of the parser. urisourcebin owns a parsebin too, and `uridecodebin3` sets `parse-streams=TRUE` on it unconditionally, so in a playbin3 pipeline (which WebKit uses for every MSE player) the parsing happens in urisourcebin and decodebin3's own input is the `identity` passthrough. Nothing resets urisourcebin's parsebin, so the reconfiguration decodebin3 assumes exists never runs.

The patch gives urisourcebin the same reset, driven from the pad feeding parsebin rather than from parsebin's own sink: the reset deactivates that sink pad, so a probe holding its stream lock would deadlock, which is also why decodebin3 performs the reset from its ghost sink. parsebin answers accept-caps from its current chain (`gst_parse_chain_accept_caps`), and with no chain built yet the query falls through to the pad template and accepts, so the first caps of a stream never trigger a reset.
