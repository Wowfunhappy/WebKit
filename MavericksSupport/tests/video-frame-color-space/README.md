# Canvas video source color space

`bash MavericksSupport/tests/video-frame-color-space/run-native.sh` uses the native
10.9 frameworks without WebKit polyfills. Identical BGRA pixels fail conversion to
BT709 without source metadata, succeed with their sRGB profile, and produce a
different correct conversion with an explicit calibrated gamma1.8 profile. This
checks that preserving the producer's actual profile matters, rather than merely
inventing an sRGB encoder fallback.

`TestWebCore`'s `GStreamerCocoaPixelBuffer.Factory*` cases exercise the production
`VideoFrameCV::create` metadata boundary. They verify that empty or range-only
metadata preserves a custom producer profile, raw ARGB/BGRA colorimetry produces
the correct sRGB or linear profile, and explicit unsupported overrides do not
reuse the old profile. ICC-backed buffers retain their existing behavior.

After building/installing WebKit, run the existing
`http/wpt/mediarecorder/MediaRecorder-requestData.html` test through the coordinated
layout runner. Its canvas capture enters `VideoFrame::createFromPixelBuffer` and
VP8 encoding, covering the original production crash when native transfer returned
`kVTInsufficientSourceColorDataErr` and the encoder received a null CVPixelBuffer.
`http/wpt/webcodecs/copyTo-same-decoder.html` covers the raw RGBA producer followed
by VP8 encoding.
