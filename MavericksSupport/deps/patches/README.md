# Source patches

Patches `build_deps.sh` applies to the source trees it unpacks, on the run that unpacks them and before that module is configured (search it for `patches/`); every patch here is named explicitly and none is optional. Each patch fixes a bug or
over-strict behavior in GStreamer's **own** source — never a workaround that belongs in WebKit. Regenerate a patch against the pristine upstream tarball if its target version changes.

**If you find yourself wanting to add a new patch here, you are probably doing something wrong!** Consider:
- Is the thing you are trying to fix _really_ broken upstream for hundreds of thousands of users without anyone noticing? If not, it's probably a bug in our code, which we should fix in our code.
- Is it possible to upgrade to a newer version of the dependency instead of patching the old one? If so, it's probably better to upgrade.

## gst-plugins-bad-vtenc-h264-profile-caps.patch

**Target:** gst-plugins-bad 1.28.5, `sys/applemedia/vtenc.c`

The H.264 source template lists Main, Baseline, constrained Baseline and High, matching vtenc's VideoToolbox profile mappings. The native compression session's supported-value list contains Baseline, Main and High families; constrained Baseline uses the Baseline mapping. High 10, High 4:2:2 and High 4:4:4 are distinct profiles, so prefix matching them to High overstates support. WebKit's registry scanner queries these templates before creating an encoder. Main is first in the list to preserve the unconstrained encoder default.

For constrained-Baseline requests, output caps preserve the native SPS constraint flags. The Baseline encoder emits these constraints; clearing them labels its output as plain Baseline and prevents negotiation with constrained-Baseline peers. Ordinary Baseline requests retain the broader Baseline caps.

`MavericksSupport/tests/video-encoder-profile-caps.sh` checks profile acceptance, rejection, the default, and four-frame encoding for all four advertised profiles against the published plugin.

## gst-plugins-bad-vtdec-h264-reorder-bound.patch

**Target:** gst-plugins-bad 1.28.5, `sys/applemedia/vtdec.c`

The VideoToolbox adapter's output queue uses the SPS reorder bound, as WebKit's
Apple `ComputeH264ReorderSizeFromSPS` does. Reference-frame storage and output
reordering are different: the ordinary WPT High-profile H.264 fixture declares
three reference frames, picture-order type 2 and zero reorder frames. VideoToolbox
returns its first decoded picture immediately, and the adapter must publish it
without requiring more input or an end-of-stream flush. VUI restrictions and
intra-profile constraints bound the queue; other streams retain the existing
conservative DPB bound. Submission completion ordering still precedes PTS sorting.

`MavericksSupport/tests/video-decoder-reordering.sh` checks single-frame delivery
without EOS and presentation ordering for the upstream B-frame fixture.

## gst-plugins-bad-vtdec-hw-hardware-caps-probe.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtdec.c`
**Applied to:** libgstapplemedia (vtdec_hw)

`vtdec_hw` (rank primary+1, above `avdec_h264`) inherits `vtdec`'s sink pad template, which advertises every codec whether or not the machine can hardware-decode it. On a machine with no hardware decoder for the codec (any VM; H.264-only-era Macs asked for HEVC), `VTDecompressionSessionCreate(RequireHardware)` fails with **-8973** (10.9's legacy spelling of `kVTCouldNotFindVideoDecoderErr`).

The template is what every caller that does not instantiate the element reads. WebKit's `GStreamerRegistryScanner` picks a decoder factory out of factory templates, preferring the `Hardware` klass — `vtdec_hw`. `ImageDecoderGStreamer` then creates that factory and `GStreamerElementHarness` links its own pad straight into the decoder's sink pad with no accept-caps fallback: the link answers `GST_PAD_LINK_NOFORMAT`, the first buffer push returns `GST_FLOW_NOT_LINKED`, and an mp4 loaded as an image (`fast/images/animated-image-mp4.html`) decodes no frames at all. Through `decodebin3` the same claim surfaces later and harder: its candidate window closes after a caps-less READY→PAUSED succeeds, so `vtdec_hw`'s `set_format` error passes through unfiltered and kills every MSE, blob and mediastream pipeline `playbin3` builds, while a working software decoder sits one rank below.

The patch gives `vtdec_hw` its own sink template carrying only the codecs a `RequireHardware` decompression session can actually be created for, probed once per codec type with a bare `CMVideoFormatDescription` (measured: the bare-description software session succeeds while RequireHardware answers -8973, so the probe isolates hardware availability, not description validity). A status naming the decoder missing is cached; one reporting it busy or malfunctioning describes this instant rather than the machine, so the codec keeps its caps and the next query asks again. With the codec gone from the template, template readers select the next factory and decodebin3's accept-caps check fails inside its candidate window. On machines whose VideoToolbox does hardware-decode the codec, the probe succeeds and `vtdec_hw` keeps its caps, rank and hardware path.

## gst-plugins-bad-vtdec-109-sink-template-codecs.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtdec.c`
**Applied to:** libgstapplemedia (vtdec, vtdec_hw)

vtdec's static sink template advertises VP9, AV1 and HEVC, and the template is what the registry serves to capability queries — WebKit's `GStreamerRegistryScanner` answers `MediaSource.isTypeSupported`, `canPlayType` and MediaCapabilities from factory templates, never from an instantiated element, and `PlatformMediaEngineConfigurationFactoryGStreamer` reports `powerEfficient` straight from the matched factory's `Hardware` klass.

10.9's VideoToolbox decodes none of the three on any hardware. The supplemental-decoder mechanism vtdec gates VP9 and AV1 on is macOS 11+; HEVC decode arrived in 10.13; and `VTIsHardwareDecodeSupported` is itself 10.13+ (the gap-archive definition probes a `RequireHardware` session, so it answers false on every 10.9 machine). Measured on this host, a VideoToolbox HEVC session fails outright — `VTDecompressionSessionCreate` returns **-12906** — while vtdec's own `getcaps` already strips VP9 and AV1 before negotiation.

With the template claiming what the machine then denies, the scanner reported decoders that can never instantiate and called their software fallback power-efficient: sites offered AV1 or HEVC on the strength of that answer streamed video that decodes in software (HEVC, via `avdec_h265`) or not at all (AV1 embeds played audio over black frames, the branch sitting undecodable behind a parser). Removing the three entries makes the registry agree with the machine, so those codecs are reported unsupported-by-VideoToolbox and `powerEfficient` is no longer asserted for a software decode path. H.264/MPEG-2/JPEG/ProRes stay: those go through the per-codec `RequireHardware` probe above or plain vtdec's software session, which 10.9's VideoToolbox does provide.

## gst-plugins-bad-vtenc-hardware-encoder-probe.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtenc.c`
**Applied to:** libgstapplemedia (every vtenc element)

`gst_vtenc_register()` registers an element per codec whether or not this machine's VideoToolbox has an encoder for it, and a registered factory is what capability queries are answered from — `GStreamerRegistryScanner` reads encoder support off factory templates, never off an instantiated element, and reports `powerEfficient` from the matched factory's `Hardware` klass. Two codecs the registry claims cannot be backed here:

- **HEVC, on any 10.9 machine.** HEVC encode arrived in 10.13; `VTCopyVideoEncoderList` on 10.9 lists ProRes, H.263, H.264, JPEG and raw only, and `VTCompressionSessionCreate` answers **-12908** (`kVTCouldNotFindVideoEncoderErr`) for `hvc1` and `muxa`. With `vtenc_h265`, `vtenc_h265a` and their `_hw` variants registered, `RTCRtpSender.getCapabilities("video")` offered `video/H265`, so a peer that accepted it got a sender whose encoder cannot be created.
- **Hardware H.264, per machine.** `vtenc_h264_hw` is rank primary with klass `Hardware`, and `hasElementForCaps` stops at the first `Hardware`-klass candidate — so on a machine whose `RequireHardware` `avc1` session answers -12908, `MediaCapabilities.encodingInfo()` reported `powerEfficient` for an H.264 encode with no hardware behind it.

Both are the one defect — the registry advertising an encoder VideoToolbox cannot back — and one half is per-machine, since Macs with QuickSync do hardware-encode H.264 under 10.9. So the answer is measured: `gst_vtenc_register()` creates a compression session for the element's codec type carrying the element's own hardware-only requirement, and registers the element only if that succeeds. The result is cached per codec type per hardware-only setting, so the seven registrations cost one session creation each on registry rebuild (measured 6.7 ms for the first, which pays the framework warm-up the first real session would pay anyway, then 0.01–0.04 ms). This is the shape `vtdec` already uses to gate VP9/AV1 on `VTIsHardwareDecodeSupported`, and the shape this file already uses to ask the runtime with `__builtin_available`. On a machine whose VideoToolbox does back the codec the probe succeeds and the element keeps its rank, klass and path.

H.265 still decodes through `avdec_h265`; `h265parse` and `rtph265pay/depay` are unaffected.

## gst-plugins-bad-vtenc-source-colorimetry.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtenc.c`, `sys/applemedia/vtenc.h`
**Applied to:** libgstapplemedia (every vtenc element)

`gst_vtenc_set_colorimetry()` tells the compression session what color its frames are in, mapping the negotiated caps onto `kVTCompressionPropertyKey_ColorPrimaries`, `_TransferFunction` and `_YCbCrMatrix`. A session that has been told a color needs the source frame's color too, to know whether a conversion stands between the two — and 10.9's VideoToolbox reads that from the source `CVPixelBuffer`'s own `kCVImageBufferColorPrimariesKey` / `_TransferFunctionKey` / `_YCbCrMatrixKey` attachments. For a property the session declares and the buffer leaves unstated it answers **-12917** (`kVTInsufficientSourceColorDataErr`), in the output callback, for every frame. vtenc tags no source buffer anywhere — `sys/applemedia` calls `CVBufferSetAttachment` in neither the encoder nor its helpers — and encodes on the systems it ships for, so the requirement is 10.9's.

`gst_vtenc_encode_frame()` builds its source buffer with `CVPixelBufferCreateWithPlanarBytes()` over the `GstBuffer`'s own memory, passing NULL for the pixel buffer attributes and setting no attachments. So on 10.9 every `vtenc_h264` frame failed and the element emitted nothing — at every frame size, in NV12, I420 and UYVY alike, with or without a bitrate, realtime on or off. A buffer that arrives already CoreVideo-backed carries its own color attachments and takes the other branch of `gst_vtenc_encode_frame`, which is what WebKit hands the encoder for a canvas or `ArrayBuffer` `VideoFrame`; so WebCodecs H.264 looked healthy while a frame decoded into system memory could not be encoded at all. Measured on the pre-patch build, a WebCodecs VP8-to-H.264 transcode — `vp8dec` output straight into a `VideoEncoder` configured `avc1.42001E`, `vtenc_h264` being this port's only H.264 encoder — accepted all ten frames, emitted no chunk, fired no error and never settled its `flush()`.

Measured with a bare `VTCompressionSession` over `CVPixelBufferCreateWithPlanarBytes`: with no color property on the session every frame encodes; with any one of the three set and no attachment on the buffer every frame answers -12917; and with the buffer carrying an attachment for each property the session was told, every frame encodes. The requirement is per property, so the patch attaches exactly the set `gst_vtenc_set_colorimetry()` declared — nothing is invented for a component the caps leave unknown — and the values are the ones the session already holds, which makes source and target color identical and the conversion an identity. Where the session holds no color property at all — 10.9 refuses the BT.2020 values outright, -12902 — the attachments change nothing: the emitted SPS is byte-identical with the source buffer untagged, tagged BT.601 or tagged BT.2020.

The single-macroblock limit is separate and belongs to the encoder itself: a frame no wider than 16 and no taller than 16 (14x14, 16x16) answers **-12348** from a bare `VTCompressionSession` as well as through vtenc, while 16x17, 17x16 and everything larger encode.

## gst-plugins-bad-vtenc-drain-queued-frames.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtenc.c`, `sys/applemedia/vtenc.h`
**Applied to:** libgstapplemedia (every vtenc element)

`gst_vtenc_drain_encoder()` runs `VTCompressionSessionCompleteFrames()`, whose output callbacks queue the remaining frames for the output loop, and then calls `gst_vtenc_pause_output_loop()` under the comment "This will only pause after all frames are out". `gst_pad_pause_task()` stops the `GstTask` before its next iteration, so a frame queued after the loop's last pass stays in `output_queue`: a drain (EOS, caps change) loses it, and a flush leaves it to be pushed after `FLUSH_STOP`, ahead of the next segment. 10.9's H.264 encoder refuses `kVTCompressionPropertyKey_RealTime` and holds about nine frames, all of which `CompleteFrames` delivers just before the pause.

The drain now waits on `queue_cond` until `output_queue` is empty, a pause is requested, or the loop has stopped. A loop that meets a downstream error pauses its own task and only then, under `queue_mutex`, sets `output_stopped` and broadcasts, so a frame the output callback queues after the loop's last pass never leaves the drain waiting on a loop that will not run. A flush drain that finds the error — `downstream_ret`, written under the stream lock the drain holds — first waits for `output_stopped`, then clears it under `queue_mutex` before resuming the task, so the stopping loop's own pause cannot land after that resume. The loop's per-pop wake and `gst_vtenc_pause_output_loop()`'s wake are broadcasts, because the enqueue callback waits on the same condition.

Measured deterministically with a throwaway build whose loop sleeps at two points: between the end of one pass and the next (`VTENC_DIAG_LOOP_SLEEP_US`), and between the error branch's stream unlock and `gst_pad_pause_task()` (`VTENC_DIAG_ERR_SLEEP_US`), through a `GStreamerElementHarness`-shaped pipeline. With a 300 ms pass gap and 12 frames then EOS, the unpatched element drained 7, 7 and 6 frames and the patched one 12, 12 and 12. With the harness sink failing on the first frame of the EOS drain and a 1 s gap before the loop pauses itself, a drain that waits on the task state instead of `output_stopped` never returned in 3 of 3 runs, and this one returned in 3 of 3.

## gst-libav-register-libdav1d.patch

**Target:** `gst-libav-1.28.5`, `ext/libav/gstavviddec.c`
**Applied to:** libgstlibav

gst-libav's decoder registration skips every FFmpeg decoder whose name starts with `lib`, on the stated premise that "we have native gstreamer plugins for all of those libraries anyway". This runtime has no native AV1 decoder for that rule to point at: gst-plugins-bad 1.28 carries no dav1d wrapper (`dav1ddec` lives in gst-plugins-rs, which is not part of this build), its `ext/aom` needs a libaom this build does not vendor, and FFmpeg's native `av1` decoder is hardware-only (gst-libav skips it by name for exactly that reason). The FFmpeg built here links dav1d (`--enable-libdav1d`), so the wrapper codec is present and fully functional software decode. The patch admits `libdav1d` through the external-library skip, registering `avdec_libdav1d` (rank marginal, like the other avdec video decoders) — the runtime's AV1 decoder for `<video>`, MSE and WebCodecs. The required-artifacts gate asks the registry for the element by name so a regression fails the build rather than reverting AV1 to a parser with no decoder.

## gst-libav-avviddec-clear-decode-only-on-copied-output.patch

**Target:** `gst-libav-1.28.5`, `ext/libav/gstavviddec.c`
**Applied to:** libgstlibav (`avdec_libdav1d`, and any other decoder that allocates its own frames)

`gst_ffmpegviddec_handle_frame()` flags every incoming `GstVideoCodecFrame` `GST_VIDEO_CODEC_FRAME_FLAG_DECODE_ONLY` — "treat frame as void until a buffer is requested for it" — and `gst_ffmpegviddec_get_buffer2()` is the only place that clears it. libavcodec calls `AVCodecContext.get_buffer2` only for decoders that allocate through `ff_get_buffer()`; `ff_libdav1d_decoder` declares no `AV_CODEC_CAP_DR1` and serves dav1d's picture allocator from its own `av_buffer_pool` (`libdav1d_picture_allocator()` in `libavcodec/libdav1d.c`), so for `avdec_libdav1d` the callback never runs. `gst_ffmpegviddec_video_frame()` finds the frame has no direct-rendered buffer and takes its own fallback — `get_output_buffer()` allocates from the decoder's pool and copies the picture in — but the frame still carries the flag, and `gst_video_decoder_finish_frame()` drops it on `!frame->output_buffer || GST_VIDEO_CODEC_FRAME_IS_DECODE_ONLY (frame)`. Every frame is discarded, so the element emits nothing, never prerolls, and errors "No valid frames decoded before end of stream" at EOS. In a page that is a `<video>` spinning forever at `readyState 0` with `networkState 2` and no `error` — every AV1 stream, whatever the container.

The patch clears the flag once that fallback has produced the buffer. This is the transition `get_buffer2()` already performs, unconditionally, for every DR1 decoder, so it gives decoders that allocate their own frames the same behavior rather than a new one; on the direct-rendering path the clear is idempotent. `GST_FFMPEG_VIDEO_CODEC_FRAME_FLAG_ALLOCATED`, which `get_buffer2()` sets alongside, is deliberately not mirrored: its readers are the ghost-frame sweep further down (which tests `DECODE_ONLY`) and the input-frame unset after it, neither of which consults it on this path.

Upstream master is byte-identical here. The path is unreachable upstream because the `lib*` skip that `gst-libav-register-libdav1d.patch` opens never registers a non-DR1 wrapper decoder in the first place.

## libheif-ffmpeg-decoder-input-padding.patch

**Target:** `libheif-1.23.4`, `libheif/plugins/decoder_ffmpeg.cc`
**Applied to:** libheif.a (HEIFImageDecoder's FFmpeg backend)

libavcodec requires the buffers it parses to be followed by `AV_INPUT_BUFFER_PADDING_SIZE` (64) readable, zeroed bytes: `av_parser_parse2()` documents `buf_size` as the size "without the padding. I.e. the full buffer size is assumed to be buf_size + AV_INPUT_BUFFER_PADDING_SIZE". The HEVC parser relies on it. `parse_nal_units()` splits with `H2645_FLAG_SMALL_PADDING`, and for a NAL unit with no emulation-prevention bytes `ff_h2645_extract_rbsp()` points the NAL straight at the caller's buffer instead of copying it, so the bit reader that parses the parameter sets and slice headers reads past the end of the payload into that padding.

libheif's FFmpeg backend queues each coded item as a `std::vector` holding exactly its Annex-B payload and passes `data()` and `size()` to `av_parser_parse2()` with nothing after it. The parser therefore reads beyond the heap allocation. Measured with the decode harness in `tests/image-decoders/heif`: 63 mutated HEIC files fault inside libavcodec under libgmalloc, and every one decodes, or fails cleanly, once reads past the end of an allocation are allowed (`MALLOC_ALLOW_READS`). Without guard pages the parser reads whatever memory follows the vector.

The patch keeps the payload length in the packet and appends the 64 zero bytes to its storage. The same function also shrank the packet *queue* by the number of bytes a partial parse consumed (`input_data.resize(input_data.size() - n_bytes_consumed)`) where it meant to shrink the packet. The patch drops the consumed prefix from the packet instead.

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

## gst-plugins-base-decodebin2-prefill-pending-group.patch

**Target:** `gst-plugins-base-1.28.5`, `gst/playback/gstdecodebin2.c`
**Applied to:** libgstplayback (decodebin)

An adaptive demuxer switches variants by exposing a new set of pads, and decodebin builds them a new group that waits in `next_groups` until the active group drains. Everything the pending group will play sits behind its multiqueue until the switch, but `decodebin_set_queue_size_full` sizes a queue that is not posting buffering messages with the play-time limits - five buffers - so the pending queue holds a handful of buffers when the switch completes and the buffering reset that runs then starts it in buffering mode near zero: a burst of low-percentage buffering messages follows every variant switch, and an application that follows the buffering contract pauses playback on them.

The patch gives a group that is not its chain's `active_group` - a pending group of a buffering pipeline - the buffering-mode limits when `no_more_pads_cb` or `multi_queue_overrun_cb` moves its queue to playing mode, so it takes the same limits as the posting queue: the application's `max-size-*` properties, with the 2 MB / 5 s defaults where those are unset. A pending queue then fills across the drain interval, its first buffering report after the switch is at or above the high watermark, and playback continues; a genuinely starved pipeline still reports low percentages and still pauses. Measured on a paced down-switch of an 8 s-fragment fMP4 HLS stream: one burst of 45 sub-100 reports at the switch, against 60 at the switch and a second burst of 53 when the new group's queue starts buffering without it.

The active group's non-posting queues keep upstream's play-time arm, which in a buffering pipeline places no time or byte limit on them. Those queues sit behind a demuxer that emits a whole segment of one track before the next, and the buffering limits there stop the demuxer's thread at 5 s of the first track before the second track has a buffer: an fMP4 HLS stream with 8 s whole-track runs never prerolls.

## gst-plugins-base-video-format-2bit-alpha.patch

**Target:** gst-plugins-base 1.28.5, `gst-libs/gst/video/video-format.c`
**Applied to:** libgstvideo (every converter and unpacker)

`unpack_Y410`, `unpack_bgr10a2_le` and `unpack_rgb10a2_le` widen their 2-bit alpha to the 16-bit unpack range with `A = a2 << 14; A |= A >> 10`, the bit replication those functions use for their 10-bit channels. For two bits it fills only the top bits: fully opaque (3) unpacks as 0xC030, which every 8-bit output keeps as 192, so a Y410 frame converted to BGRA composites at 0.75 alpha. The patch scales the two bits across the full range (`a2 * 0x5555`: 0, 0x5555, 0xAAAA, 0xFFFF), as the 10-bit and 12-bit alpha unpacks already do for their maxima. Packing back keeps the top two bits, so a round trip is unchanged.

## gst-plugins-good-qtdemux-heif-image-sequence.patch

**Target:** `gst-plugins-good-1.28.5`, `gst/isomp4/qtdemux.c`, `gst/isomp4/fourcc.h`
**Applied to:** libgstisomp4 (qtdemux)

An ISO/IEC 23008-12 image sequence - the `.heics` an animated HEIC is - is an ISO-BMFF file with an ordinary `moov`/`trak`/`stbl`, a `VideoMediaHeaderBox` in its `minf` and an `hvc1` VisualSampleEntry in its `stsd`. The one thing that is not a video track's is the media handler in `hdlr`, which clause 7 of that standard sets to `pict`. `qtdemux_parse_trak` reads the handler into `stream->subtype`, and every branch that builds a pad, reads the sample table and produces caps tests it against `vide`, so both of WebKit's test sequences (`LayoutTests/fast/images/resources/sticker.heics`, `sea_animation.heics`) end at `gst_qtdemux_post_no_playable_stream_error`: "This file contains no playable streams". Nothing else about the file is unusual - rewriting the four handler bytes to `vide` and leaving the rest untouched decodes all 96 and all 120 frames through `qtdemux ! h265parse ! avdec_h265`.

The patch reads the handler as `vide` when it is `pict` and the file declares the `msf1` brand (major or compatible), which is what says the file is an image sequence rather than a QuickTime file with a still-picture track. Files without that brand keep the handler they have.

## gst-plugins-good-qtdemux-upstream-stream-tags.patch

**Target:** `gst-plugins-good-1.28.5`, `gst/isomp4/qtdemux.c`, `gst/isomp4/qtdemux.h`
**Applied to:** libgstisomp4 (qtdemux)

qtdemux hands an upstream TAG event to `gst_pad_event_default`, which forwards it to the source pads the element has so far. A demuxer behind an adaptive demuxer receives its stream's tags together with the first fragment, before the `moov` is parsed and any pad exists, so the tags go nowhere: an fMP4 HLS rendition's audio track loses the title and language its `EXT-X-MEDIA` declares.

The patch keeps stream-scoped upstream tags and merges them under each stream's own tags when those are pushed - the merge `GstBaseParse` and `GstAudioDecoder` apply to upstream stream tags - re-sends already pushed tags merged when new upstream tags arrive, and clears them on a new stream-start, as those elements do.

An HLS variant stream in fMP4 can also carry a rendition declared without a URI. hlsdemux sends that rendition's tags in a sticky `hls-rendition-tags` event holding one tag list per stream type (`audio`, `video`, `text`); qtdemux keeps it and merges each list into the tags of its streams of that type (`soun`; `vide`; `text`, `sbtl`, `subp`, `wvtt`), replacing the container's values, and clears it with the upstream tags. hlsdemux sends that event for a rendition with its own fragments as well, so the manifest's title and language win over the container's for every rendition. When the upstream stream-start carries a GstStream, qtdemux puts one on its own stream-start too: this stream's type, caps and flags, its tags under the upstream stream's, and the rendition tags of its type over both.

A `<type>-default` field in that event marks a `DEFAULT` rendition carried inside the container, and this container's stream of that type is announced with `GST_STREAM_FLAG_SELECT`.

## gst-plugins-good-qtdemux-push-mode-decode-time-interleave.patch

**Target:** `gst-plugins-good-1.28.5`, `gst/isomp4/qtdemux.c`, `gst/isomp4/qtdemux.h`, applied after `gst-plugins-good-qtdemux-upstream-stream-tags.patch`
**Applied to:** libgstisomp4 (qtdemux)

In pull mode `gst_qtdemux_loop_state_movie` sends the stream whose next sample decodes earliest, so qtdemux's output is interleaved by time whatever the file's storage order. In push mode `gst_qtdemux_process_adapter` sends each sample as its bytes arrive. A fragment may store each stream's samples as one run: legacy `hlsdemux` delivers fMP4 HLS segments that carry all of a segment's video before its audio, in one `moof` with a `traf` per track or in a `moof` per track. decodebin gives the queue behind the demuxer its buffering limits (2 MB / 5 s), so the demuxer's thread stops 5 s into an 8 s video run and the audio sink starves until playback drains the video. Measured with legacy `playbin`, a byte-seekable http push source and 8 s fragments: 5 audio gaps of 2.65 s in 48 s, in both layouts. Multiqueue `use-interleave`, which decodebin3 enables, cannot absorb this on decodebin2: while a queue has received no buffer the interleave grows only to 5 s (`calculate_interleave`), the leading queue fills to it before the other track's first sample, and the pipeline never prerolls (0 audio buffers in every case measured).

With an upstream delivering timed fragments (TIME segments, as adaptive demuxers push) and more than one non-sparse stream with a pad, push-mode fragmented qtdemux holds the samples it takes and sends them in decode-time order. A held sample goes out once no other non-sparse stream can still provide an earlier one in the fragment it was taken from. A track's samples come in decode order and each run continues where the previous one ended, so that is decided by facts the parsed `trun`s state: the other stream's next parsed sample, or the end of the samples parsed for it, is not before the held sample. A `moof` that replaces a stream's sample table leaves `sample_index` at -1 until the stream's first sample is read, which counts as index 0. Upstream's next timed fragment - `first_fragment_buffer` carries the fragment timestamp, which qtdemux records as a new `fragment_start` - completes the previous fragment: a stream whose data in it did not reach a held sample has a gap there, and the sample is sent. Sparse streams (subtitles, captions, timed metadata, as the `moov` marks them) hold nothing back. A demuxed rendition, one track per qtdemux, holds nothing.

Everything held is sent at upstream EOS (before the EOS goes out), before a new TIME segment, at stream-start, at a real discont and before a second `moov`, and dropped by `gst_qtdemux_reset`; `gst_qtdemux_sync_streams` sends no EOS to a stream with held samples. Each released sample's flow is combined as it is pushed. What is held is at most the fragment being demuxed. Measured on the same fixtures: 0 audio gaps in all four unpaced cases (8 s and 12 s, both layouts) and in the paced live playlist.

## gst-plugins-bad-hlsdemux-subtitle-renditions.patch

**Target:** `gst-plugins-bad-1.28.5`, `ext/hls/gsthlsdemux.c`, `ext/hls/gsthlsdemux.h`
**Applied to:** libgsthls (hlsdemux)

`gst_hls_demux_setup_streams` decides which renditions of the selected variant become output streams and answers `VIDEO || AUDIO`; `create_stream_for_playlist` returns immediately for anything else. A master playlist carrying its subtitles in an `EXT-X-MEDIA:TYPE=SUBTITLES` rendition - the ordinary HLS shape - therefore produces no text stream, and a player sees no text track for a stream that has one.

Selecting the rendition is half of it. A WebVTT fragment carries cue times on its own timeline and ties that timeline to the presentation through an `X-TIMESTAMP-MAP` header, so the times mean nothing to a player until they are converted. The successor element does this in `ext/adaptivedemux2/hls/gsthlsdemux-util.c` against a map from internal (MPEG-TS) time to stream time; the patch carries that conversion over and builds the map from the primary stream's first PCR together with the stream time of the fragment it came from, both of which this element already computes. The successor's fallbacks are kept verbatim: a fragment without an `X-TIMESTAMP-MAP` is read as carrying MPEG-TS values, a cue that cannot be converted because no primary fragment has produced a PCR yet keeps its original value, and a cue converting to a negative stream time is clamped to zero.

A rendition's `NAME` and `LANGUAGE` become its stream's title and language tags, and its `DEFAULT` and `TYPE=SUBTITLES` become the select and sparse stream flags. The tags are kept on the adaptive stream and merged into every tag event it sends: the element sends other stream tags on the same pad - the ID3 tags of a packed-audio fragment, the nominal bitrate after a variant switch - and each new stream tag event replaces the previous one downstream, so tags set once are gone by the first fragment.

A rendition's `CHARACTERISTICS` (media characteristic UTIs such as `public.accessibility.describes-video`) go into the same tag lists as the string tag `hls-characteristics`, which the element registers. The rendition's stream announces its tags, type and flags in a GstStream on its stream-start event, so a player reads them when it first sees the stream rather than whenever a tag event arrives. A URI rendition's tags also travel in the typed `hls-rendition-tags` event described next, so a demuxer splitting its fragments applies them over the container's own values - the precedence hlsdemux2 gives a rendition's `LANGUAGE` with `GST_TAG_MERGE_REPLACE`.

A rendition without a URI - the variant's own stream carries it, the usual shape for the default audio of a muxed variant - is dropped by the playlist parser (`gst_m3u8_parse_media` answers NULL for it), although `setup_streams` and the playlist update already skip such a rendition as "a placeholder for a stream contained in another mux". The patch keeps it, with the successor parser's validation (TYPE, GROUP-ID and NAME required). Its tags go out on the variant's stream in a sticky `hls-rendition-tags` event holding one tag list per stream type, because a tag event has no type and the demuxer splitting the variant's stream would otherwise spread a stream tag list over every elementary stream; the tsdemux and qtdemux patches apply each list to their streams of that type, as the successor attaches such a rendition to the variant's track of the matching type.

A whole fragment is converted at once, so a WebVTT stream accumulates its fragment until the end rather than pushing partial buffers. Otherwise a subtitle rendition travels the path the audio renditions already take, and `is_primary_playlist` stays false for it, so bitrate switching keeps following the main playlist.

A rendition without a URI that the playlist marks `DEFAULT=YES` sets `<type>-default` in the `hls-rendition-tags` event, so the demuxer splitting the variant's stream selects its stream of that type. A subtitle rendition with `FORCED=YES` carries the characteristic `public.subtitles.forced-only`, the value of AVFoundation's `AVMediaCharacteristicContainsOnlyForcedSubtitles`. When `setup_streams` reuses the previous variant's streams it skips a rendition without a URI, as stream creation and the playlist update do.

## gst-plugins-bad-mpegtsdemux-rendition-tags.patch

**Target:** `gst-plugins-bad-1.28.5`, `gst/mpegtsdemux/tsdemux.c`, `gst/mpegtsdemux/tsdemux.h`
**Applied to:** libgstmpegtsdemux (tsdemux)

An HLS variant stream can carry a rendition its master playlist declares without a URI: the variant's audio is then that `EXT-X-MEDIA` rendition, with its `NAME` and `LANGUAGE`. hlsdemux sends those in a sticky `hls-rendition-tags` event holding one tag list per stream type, because tsdemux turns an upstream stream tag list into global tags for every elementary stream of the program.

The patch keeps the event and merges the list for each elementary stream's type - audio, video, and subpicture as `text` - into the tags of the streams it creates from then on, replacing the transport stream's own values. The event is cleared with the demuxer's global tags on reset.

Each elementary stream's stream-start also takes `GST_STREAM_FLAG_SELECT` and `GST_STREAM_FLAG_UNSELECT` from the upstream stream-start - qtdemux takes the upstream flags the same way - so the selection made for the stream the transport stream arrives on reaches its streams; a `<type>-default` field in the rendition-tags event selects the elementary stream of that type. The flags go on the event and on the stream's GstStream.

## gst-plugins-bad-hlsdemux-date-ranges.patch

**Target:** `gst-plugins-bad-1.28.5`, `ext/hls/m3u8.c`, `ext/hls/m3u8.h`, `ext/hls/gsthlsdemux.c`
**Applied to:** libgsthls (hlsdemux)

hlsdemux ignores `EXT-X-DATERANGE`, so a player sees none of the timed metadata a media playlist declares with it; hlsdemux2 1.28.5 parses only `CAN-SKIP-DATERANGES` and `RECENTLY-REMOVED-DATERANGES`. The patch parses the tag (RFC 8216bis 4.4.5.1): `ID`, `CLASS`, `START-DATE`, `END-DATE`, `DURATION`, `PLANNED-DURATION`, `END-ON-NEXT` and the `X-` client attributes. `ID` and `START-DATE` are required, and a later tag with the same `ID` replaces the range.

A range's duration is its `DURATION`; otherwise `END-DATE` minus `START-DATE`; otherwise, with `END-ON-NEXT=YES`, the distance to the next range of the same `CLASS`. `PLANNED-DURATION` alone leaves the end unknown. The range starts in stream time at its `START-DATE` relative to the `EXT-X-PROGRAM-DATE-TIME` of the last fragment dated at or before it, plus that fragment's stream position; a playlist without a program date-time starts every range at the beginning of the stream - the mapping AVFoundation applies against the player item's current date.

After each media playlist load or update the element posts an `hls-date-ranges` element message: a `ranges` array of `date-range` structures carrying `id`, `class`, `start` and `duration` (`GST_CLOCK_TIME_NONE` while the end is unknown) in stream time, and the `attributes`.

## gst-plugins-bad-hlsdemux-variant-switch-nearest-fragment.patch

**Target:** `gst-plugins-bad-1.28.5`, `ext/hls/gsthlsdemux.c`
**Applied to:** libgsthls (hlsdemux)

On a variant switch in a VOD playlist, `gst_hls_demux_update_playlist` carries the stream position over to the new playlist and picks the fragment that contains it. That position is a fragment boundary in the old variant's timeline - the end of the fragment just played - and fragment durations differ between variants by frame rounding (7.992 s against 8.008 s in the same presentation), so whenever the new variant's fragments run longer the boundary lands inside the fragment just played and the switch refetches and decodes it from the start: the data for the position that is actually playing arrives one full fragment fetch late, and the pipeline runs dry at the switch. RFC 8216 §4.3.3.2 rules out matching by Media Sequence Number and directs clients to the relative position on the playlist timeline.

The patch matches the carried-over position to the fragment whose start is nearest, the rule the element's own seek handler applies under `GST_SEEK_FLAG_SNAP_NEAREST`. An exact fragment start, which is what the initial load and every seek carry, resolves as before.

## gst-plugins-bad-hlsdemux-resync-current-file.patch

**Target:** `gst-plugins-bad-1.28.5`, `ext/hls/gsthlsdemux.c`
**Applied to:** libgsthls (hlsdemux), after the manifest-lock patch

VOD resync assigns the selected list node to `current_file` alongside its sequence and timeline position, matching the seek handler. Playlist load initializes this cached node, and `gst_m3u8_get_next_fragment` reads it directly. All three fields must identify the same fragment, including a null node at the end of the playlist.

`bash MavericksSupport/tests/hls-resync.sh` checks the actual resync implementation with an in-memory playlist: rounded and exact boundaries, nonzero sequence numbers, returning to a cached variant, and the end of the playlist.

## gst-plugins-bad-adaptivedemux-release-manifest-lock-for-downloads.patch

**Target:** `gst-plugins-bad-1.28.5`, `gst-libs/gst/adaptivedemux/gstadaptivedemux.{c,h}`, `gst-libs/gst/uridownloader/gsturidownloader.c`, `ext/hls/gsthlsdemux.{c,h}`
**Applied to:** libgstadaptivedemux, libgsthls (hlsdemux)

Legacy `adaptivedemux` performs every `GstUriDownloader` fetch -- the media playlist on a variant switch, the periodic live-playlist refresh, alternate-rendition playlists, AES keys, the initial media playlist from `process_manifest` -- with its recursive **manifest lock held**. Everything else that takes that lock then waits behind the network: `gst_adaptive_demux_src_query` (duration, seeking, latency -- issued by decodebin when it plugs a new group), `gst_adaptive_demux_src_event` (the RECONFIGURE playsink sends while it holds its own lock inside `gst_play_sink_do_reconfigure`), seeks, and the PAUSED->READY transition (`gst_uri_downloader_cancel` runs first, but the bin transitions its children sink-first, so a downstream demuxer's pad deactivation blocks on a stream lock held by a thread waiting for the manifest lock long before hlsdemux is reached). `adaptivedemux2`'s demuxers run their downloads in their own loop with no lock held, and do their own networking, which is why WebKit demotes them.

With `souphttpsrc` the wait is a delay. With WebKit's `webkitwebsrc` it is a deadlock: the fetch's request and response are delivered on the WebKit main thread, and that same thread is the one blocked on the pipeline (tearing down, reading `mute`, querying duration, seeking), so the fetch never completes. Sampled cycles on nintendo.com's HLS players: main -> `gst_play_sink_get_mute` -> playsink lock <- multiqueue thread in `do_reconfigure` -> RECONFIGURE -> manifest lock <- queue thread in `finish_fragment -> change_playlist -> update_playlist -> fetch` <- webkitwebsrc parked for a response <- main; and main -> `GST_STATE_NULL` -> tsdemux pad deactivation -> stream lock <- multiqueue thread in `mpegts_base_chain -> pad_added -> decode_group_new -> query` -> manifest lock <- the same fetch.

The patch keeps the base class's existing discipline for the fragment path, which already drops the manifest lock around `gst_adaptive_demux_stream_download_uri` and re-checks the cancelled flags on re-lock, and extends it to the uridownloader fetches of the base class and of hlsdemux, the one adaptive demuxer this port plugs (`GStreamerCommon.cpp` leaves `dashdemux` and `mssdemux` at `GST_RANK_NONE`; their fetch sites keep upstream's locking):

- The lock is a `GRecMutex` and the fetch sites sit at depth 1 or 2 (`_src_event` -> `stream_advance_fragment` re-locks), so the base class tracks the owner's depth in `GST_MANIFEST_LOCK`/`UNLOCK` and exports `gst_adaptive_demux_manifest_unlock_for_download()` / `gst_adaptive_demux_manifest_relock()`. `gst_adaptive_demux_update_manifest_default` (dash/mss) releases around its fetch.
- hlsdemux routes its fetches through `gst_hls_demux_fetch_uri()`, which takes the calling stream: a stream's task refuses to start a download and drops one that completed once the demuxer stopped running or that stream's `cancelled` flag is set (`prepared_streams` included, since each task checks its own stream); the updates task and the **API-lock holder** (`process_manifest` at sink EOS, which sets those flags) pass no stream and stop only for a shutdown. The pre-fetch refusal stops `update_playlist`'s refetch and `change_playlist`'s failover once a task is told to stop.
- `gst_adaptive_demux_stop_tasks()` cancels the downloader after setting the cancelled flags and before joining the tasks (the order `PAUSED_TO_READY` uses), and `gst_adaptive_demux_start_tasks()` resets it, so the task a main-thread seek joins is never parked inside a fetch that only the main thread completes. The downloader's cancel is one-shot and cleared when the aborted fetch returns, so `gst_uri_downloader_cancel()` also bumps a generation counter: `gst_hls_demux_fetch_uri()` reads it (`gst_uri_downloader_get_cancel_generation()`) under the manifest lock before it reads the stop condition, and `gst_uri_downloader_fetch_uri_since()` ends the fetch, once it holds `download_lock`, if the generation moved -- so a cancel that lands after the read ends the fetch and one that landed before it set the flags the read sees, and a fetch queued behind the aborted one ends too. A fetch the cancel ended reports `GST_RESOURCE_ERROR_BUSY`, which callers tell apart from a download the network refused.
- `gst_hls_demux_seek()` records the trick-mode variant switch as `pending_variant`; the download task claims it under the manifest lock (so one task loads it) and applies it in `gst_hls_demux_update_fragment_info()`, where the playlist load runs in task context. Until the load succeeds the current variant is the one the streams were seeked on; a load the cancel ended hands the switch back for the restarted task.
- Every variant switch loads first and switches after: `gst_hls_demux_load_playlist()` loads a given variant's media playlist and renditions with the lock released, and `change_playlist`, the pending switch and `process_manifest` call `gst_hls_demux_set_current_variant()` only on UPDATED, then `gst_hls_demux_resync_playlist()` positions the loaded playlist on the stream position after the switch has copied it over. A refetched variant playlist is parsed (`gst_hls_demux_parse_variant_playlist()`), the matching variant loaded, and only then committed (`gst_hls_demux_commit_variant_playlist()`). So a reader that takes the manifest lock -- duration and seeking queries, `is_live`, the seek handler -- never sees a current variant whose playlist is not loaded. `update_playlist` (the refresh) returns UPDATED / SKIPPED / FAILED and reports SKIPPED when the current variant changed while its playlist loaded; `change_playlist` posts its statistics only for UPDATED. A refresh that the seek's cancel ended returns FLUSHING, which the updates loop reschedules without counting as a failed update; `stop_manifest_update_task` leaves the downloader alone (a refresh in flight returns on its own; a cancel there would end the other tasks' fetches), the cancels being in `stop_tasks` and `PAUSED_TO_READY`, which stop every consumer.
- `get_key` holds `keys_lock` only for the cache lookup and the insert (another stream's `start_fragment` takes the manifest lock before `keys_lock`, so holding it across a download that releases the manifest lock would invert the order); it re-checks the cache before inserting. A key fetch the cancel ended makes `start_fragment` return FALSE without posting `DECRYPT_NOKEY`, and `_src_chain` maps that to FLUSHING.

## gstreamer-input-selector-release-lock-for-upstream-events.patch

**Target:** `gstreamer-1.28.5`, `plugins/elements/gstinputselector.c`
**Applied to:** libgstcoreelements (input-selector, playbin's stream combiner)

`gst_input_selector_event()`, the src-pad handler for upstream events, takes `active_sinkpad_lock` in reader mode and holds it across `gst_pad_push_event()` to the active sink pad. A seek is such an event and its push is synchronous: upstream, the demuxer flushes the pipeline on the same thread, and on legacy `decodebin2` a FLUSH_STOP during a decode-group switch hides the old group -- its exposed pads are removed, playbin's `pad_removed_cb` finds the combiner emptied and sets it to `GST_STATE_NULL`, and `gst_input_selector_reset()` takes `active_sinkpad_lock` as a writer. Same thread, same `GRWLock`, which is not recursive: the seeking thread (WebKit's main thread) deadlocks against itself, with every streaming task idle. Sampled on an ABR HLS stream seeked during a variant switch.

The handler already holds a reference to the pad it pushes to; the patch releases the reader lock before the push, so the lock covers the choice of pad and nothing else.

## curl-reusable-preconnect.patch

**Target:** `curl-8.22.0`, `include/curl/curl.h`, `lib/urldata.h`, `lib/setopt.c`, `lib/url.c`, `lib/multi.c`, `lib/easy.c`
**Applied to:** libcurl

Adds `CURL_CONNECT_ONLY_REUSABLE` (3) as a `CURLOPT_CONNECT_ONLY` mode that completes DNS, proxy and
TLS setup and then leaves the connection in the pool. Stock `CONNECT_ONLY` excludes its connection
from reuse, so a preconnect through it would warm a connection and discard it; WebKit's
`ENABLE(SERVER_PRECONNECT)` needs the warmed connection to serve the request that follows.

## curl-boringssl-async-credentials.patch

**Target:** `curl-8.22.0`, `lib/vtls/openssl.c`
**Applied to:** libcurl

BoringSSL reports an in-flight private-key operation or certificate lookup with its own
asynchronous result codes. The patch resumes those through `curl_easy_pause()`, the same path stock
curl already uses for OpenSSL's retry verifier, so a handshake that is waiting on a `SecTrust`
decision or a keychain signature pauses instead of failing.

## curl-gss-explicit-credentials.patch

**Target:** `curl-8.22.0`, `lib/vauth/spnego_gssapi.c`, `lib/vauth/vauth.h`, `lib/curl_gssapi.h`, `configure.ac`, `configure`, `lib/curl_config.h.in`
**Applied to:** libcurl

Acquires Negotiate credentials for an explicit user name and password directly into a private
native `MEMORY` credential cache through Heimdal's `__ApplePrivate_gss_krb5_import_cred`, declared
to match the Heimdal-323.92.1 headers Mavericks ships. The password path Apple's public GSS API
offers creates an `API` cache it cannot move to `MEMORY` on 10.9, which leaves credentials from
WebKit's authentication sheet unusable for the connection that asked. `configure` checks for
`gss_acquire_cred_with_password` and `gssapi_ext.h`; the private import is declared under
`HAVE_GSSAPPLE`.

## curl-digest-request-target.patch

**Target:** `curl-8.22.0`, `lib/http.c`
**Applied to:** libcurl

Computes the Digest `uri` from the actual request-target, as RFC 7616 section 3.4.6 requires,
including requests sent through an HTTP proxy and requests carrying an explicit
`CURLOPT_REQUEST_TARGET`. CONNECT keeps its authority-form target.

## curl-http1-framing.patch

**Target:** `curl-8.22.0`, `lib/http.c`, `lib/http.h`, `lib/http_chunks.c`, `lib/http_chunks.h`,
`lib/cf-h1-proxy.c`
**Applied to:** libcurl

RFC 9112 framing: a status line may omit the reason phrase, and extra digits after the status
code are not one; chunk extensions are parsed incrementally, so bytes following the hexadecimal
size can never turn an invalid size into an accepted chunk; the CR that ends a chunk-size line must
be followed by LF.

Only 1xx is informational: a status code below 100 is a final response whose body reaches the
client, as `imported/w3c/web-platform-tests/fetch/h1-parsing/status-code.window.js` requires.

A line in a field section that carries no colon is not a field line (RFC 9112 section 5). Because a
bare LF terminates a line (section 2.2), a `Set-Cookie: test=13<LF>ZYX` header puts one on the wire.
`Curl_header_is_field_line()` reports the shape, and the three places that hand a header line to the
client -- response headers, chunked trailers and the CONNECT response -- drop such a line and carry
on with the message, charging its bytes to the header budget, which is what
`imported/w3c/web-platform-tests/cookies/value/value.html` ("Set cookie but ignore value after LF")
requires. `Curl_verify_header()` keeps the byte checks that reject a NUL or a bare CR.

## curl-http2-completed-stream.patch

**Target:** `curl-8.22.0`, `lib/http2.c`
**Applied to:** libcurl

A failed connection-level acknowledgement does not replace the result of a stream that already
completed. The connection is retired and the failure reaches only the streams still in flight.

## curl-idle-connection-input.patch

**Target:** `curl-8.22.0`, `lib/conncache.c`
**Applied to:** libcurl

An idle connection that is not multiplexed is polled for pending input every time a transfer would
reuse it, including within a second of its last check. Bytes a server writes past the end of a
response -- a body longer than its `Content-Length` that arrives after the response completed --
retire the connection, where stock curl reads them as the next response's status line and fails
that load. CFNetwork opens a new connection in that case, and
`imported/w3c/web-platform-tests/fetch/content-length/content-length.html` loads its second script
over it.

## curl-primary-canonical-name.patch

**Target:** `curl-8.22.0`, resolver, socket filters and `curl_easy_getinfo`
**Applied to:** libcurl

`CURLINFO_PRIMARY_CANONICAL_NAME` exposes the canonical name returned by the connection's
own resolver. The socket retains that name across pool reuse; each transfer owns its
result through completion and clears it on reset. Proxied or coalesced requests whose
origin differs from the socket peer have no local canonical name. Cocoa cookie policy
consumes this result alongside the connection's remote address.

## curl-idle-connection-expiry.patch

**Target:** `curl-8.22.0`, `include/curl/multi.h`, `lib/conncache.c`, `lib/multi.c`, `lib/urldata.h`
**Applied to:** libcurl

Idle connections schedule their `CURLOPT_MAXAGE_CONN` deadline through the multi handle's existing
timer callback. The connection pool prunes at that deadline and schedules the next oldest idle
connection. `CURLMINFO_CONNECTIONS` exposes the remaining pool count so an owner can release an
empty multi handle.


## gst-plugins-bad-vtdec-drain-queued-frames.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtdec.c`, `sys/applemedia/vtdec.h`
**Applied to:** libgstapplemedia (`vtdec`, `vtdec_hw`)

The normal drain sets `is_draining` after the native asynchronous-frame wait. Until then, callbacks can supply lower-PTS frames and the output loop retains its reorder window. A flush sets `is_flushing` before the wait because its output is discarded. `tests/video-decoder-reordering.sh` checks all six timestamps from the ordinary WebCodecs H.264 fixture on every run.

`gst_vtdec_drain_decoder()` waits for `VTDecompressionSessionWaitForAsynchronousFrames()`, whose output callbacks sort the remaining frames into `reorder_queue`, and then calls `gst_vtdec_pause_output_loop()` under the same comment vtenc carries, with the same result: frames queued after the loop's last pass are never pushed, so EOS loses the last frames of the reorder window. The drain waits the way vtenc's does, on the same `output_stopped` protocol: the loop sets it under `queue_mutex` after pausing itself on a downstream error, a flush drain that finds the error waits for it before clearing it and resuming, and the per-pop and pause wakes are broadcasts because `handle_frame()` waits on the same condition. Frames a stopped loop leaves queued are released by the next flush drain's resumed loop or by `gst_vtdec_stop()`.

Measured the same way (`VTDEC_DIAG_LOOP_SLEEP_US`, `VTDEC_DIAG_ERR_SLEEP_US`) on 10.9's software `vtdec`, decoding 59 1080p frames through `h264parse ! vtdec`: with a 300 ms pass gap the unpatched element drained 53, 58 and 49 frames at EOS and the patched one 59, 59 and 59. With the sink failing on the first frame of the EOS drain and a 1 s gap before the loop pauses itself, a drain that waits on the task state never returned in 3 of 3 runs; this one completed the EOS drain and the following flush drain in 3 of 3.

## gst-plugins-bad-vtenc-encode-errors.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtenc.c`, `sys/applemedia/vtenc.h`
**Applied to:** libgstapplemedia (every vtenc element)

A non-recoverable encode status — from `VTCompressionSessionEncodeFrame()` or in the output callback — posts `GST_ELEMENT_ERROR` and drops the frame, but `gst_vtenc_encode_frame()` returns `GST_FLOW_OK` and a drain returns the output loop's status, so a caller that watches flow returns sees every frame accepted and no output. The patch records the failure in `encode_failed`: the failing encode call returns `GST_FLOW_ERROR`, every later frame is dropped with `GST_FLOW_ERROR`, and a drain answers `GST_FLOW_ERROR`. `gst_vtenc_start()` and `gst_vtenc_flush()` clear it, as they reset `downstream_ret`. Recoverable statuses keep their session restart.

Measured by forcing -12348 (`H264_Baseline_3_0` at 1000x1000) through a `GStreamerElementHarness`-shaped pipeline: unpatched, all 12 frame pushes returned `ok`; patched, frames 2-11 returned `error` once the first failure was recorded. An unforced 1-frame encode still drains 1 output and 12+EOS+12 still drains 12.

## gst-plugins-good-osxaudio-host-owns-device-buffer-size.patch

**Target:** `gst-plugins-good-1.28.5`, `sys/osxaudio/gstosxcoreaudiohal.c`
**Applied to:** libgstosxaudio (osxaudiosink)

`gst_core_audio_initialize_impl()` lowers `kAudioDevicePropertyBufferFrameSize` to the ring buffer's own packet — `latency-time` × rate, 441 frames at 44.1 kHz — from every ring buffer acquire, i.e. once per media element per load. That size is handed to every audio unit in the process that drives the same device, and to nothing else (measured on 10.9: a unit rendering 512-frame slices is unmoved by another process setting 441, and by this process setting 441 on a different device). For the output device, WebKit is the one choosing it: `MediaSessionManagerCocoa::updateSessionState()` asks `AudioSession` for `kLowPowerVideoBufferSize` (4096 frames) for audible video, `AudioUtilities::renderQuantumSize` for Web Audio, and a 20 ms power of two while capturing. The sink overrides that per acquire (measured: with the process at 4096, an acquire puts it back to 441), so playback WebKit sized for power runs its audio I/O at ~100 wakeups a second instead of ~11.

The sink does not need the write: `gst_osx_audio_sink_io_proc()` — "HALOutput AudioUnit will request fairly arbitrarily-sized chunks of data, not of a fixed size" — carries `segoffset` across callbacks and serves any slice from any segmentation, and `gst_core_audio_initialize()` discards the size it reads back for a sink. The patch drops the write for sinks and keeps the read.

A source keeps it. `gst_core_audio_initialize()` sizes `recBufferList` from the size it reads back, so a source asks for the packet it wants; its device is an input device, which no other unit in a WebKit process drives.

## gst-plugins-bad-vtdec-completion-order.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtdec.c`, `sys/applemedia/vtdec.h`
**Applied to:** libgstapplemedia (`vtdec`, `vtdec_hw`)

VideoToolbox uses asynchronous submission, which reports malformed Annex B input as a native decode error on 10.9. Every submission records its `GstVideoCodecFrame` identity in submission order. Callbacks mark completion under the queue mutex; only the completed prefix enters the existing PTS-sorted output queue. Error and dropped-frame callbacks complete their positions too. The submission call holds a reference while checking callback ownership because 10.9 can both invoke the error callback and return an error for the same frame.

Native completion ordering and bitstream display ordering are separate stages. `MavericksSupport/tests/video-decoder-reordering.c` checks presentation order through the decoder.

## gst-plugins-bad-vtdec-h264-sps-colorimetry.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtdec.c`
**Applied to:** libgstapplemedia (`vtdec`, `vtdec_hw`)

H.264 SPS VUI colour descriptions populate decoder output colorimetry when input caps leave it unspecified. The mappings and precedence follow h264parse: explicit caps take precedence, and ISO matrix, transfer, primaries and full-range fields describe the compressed samples.

## gst-plugins-bad-vtenc-h264-output-colorimetry.patch

**Target:** `gst-plugins-bad-1.28.5`, `sys/applemedia/vtenc.c`
**Applied to:** libgstapplemedia (H.264 encoder output)

The encoder output state describes the SPS VUI written by VideoToolbox, using h264parse's ISO colour mappings. On 10.9, VideoToolbox rejects post-10.9 colour-property values; input colour metadata therefore does not necessarily describe the encoded SPS. Parsing the generated AVC configuration record before publishing output caps gives WebCodecs `decoderConfig.colorSpace` the encoded colour description. The input colour state supplies the values when the SPS contains no mapped description.

