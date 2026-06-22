// MAVERICKS_BACKPORT: AudioToolbox compatibility shim for the vendored GStreamer (Cerbero 1.26.6,
// deploy target 10.13). libgstosxaudio (osxaudiosink / osxaudiosrc) imports the AudioComponent API
//   AudioComponentFindNext / AudioComponentInstanceNew / AudioComponentInstanceDispose
// and the 26.1 SDK homes those symbols in AudioToolbox. On 10.9 the plain _AudioComponent* symbols
// live in AudioUnit.framework (10.9's AudioToolbox only exports the internal __AT_ aliases), so the
// two-level bind to AudioToolbox fails and dlopen of libgstosxaudio aborts with
// "Symbol not found: _AudioComponentFindNext" — leaving GStreamer with no macOS audio SINK, i.e. no
// audio output. This shim REEXPORTS the real AudioToolbox (every symbol libgstosxaudio actually uses
// still resolves) AND AudioUnit (so the AudioComponent symbols resolve from where 10.9 keeps them).
// install-safari7.sh repoints libgstosxaudio's AudioToolbox dependency to @rpath/libaudiotoolbox_compat.dylib.
