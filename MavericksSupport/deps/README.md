# deps — third-party libraries WebKit links

Libraries WebKit links that the 10.9 system doesn't provide. **`build_deps.sh`** builds
them all from source with the in-tree toolchain into **`build/`** (`build/lib` +
`build/include` + `build/bin`):

- the static libraries WebKit links directly — ICU 74.2, libgcrypt/libgpg-error/libtasn1,
  brotli, woff2, libwebp 1.3.2, and libavif 1.3.0 (decode-only, on the dav1d below, for the
  AVIFImageDecoder);
- libxml2 2.13 (`lib/libxml2.2.dylib`, `include/libxml2`), which WebCore links in place of
  the crash-prone 10.9 system libxml2 2.9;
- the complete GStreamer 1.28.5 runtime — glib 2.80.5, gstreamer core/base/good/bad,
  FFmpeg + gst-libav, libvpx, dav1d, libnice/srtp/dtls + OpenSSL, WebRTC audio DSP —
  plus `bin/gst-inspect-1.0` and `bin/gst-launch-1.0` for on-box debugging;
- OpenWV 1.1.4 (`lib/libwidevinecdm.dylib`, `include/cdm`), the Widevine CDM WebCore's
  `CDMWidevine.cpp` hosts. The module is always built. The device identity it needs is a
  separate file it reads at load time from its own directory (`lib/widevine.wvd`, patched in
  — see `patches/README.md`), copied there when the operator supplies one at `widevine.wvd`
  or `MAVERICKS_WVD`. That file carries a real device's RSA private key, so it is an
  operator-supplied input, never a checked-in one, and `*.wvd` is gitignored here. With no
  device the module still loads but declines to create an instance, and
  `com.widevine.alpha` reports itself unsupported; dropping the file in beside the module
  (and relaunching) is all it takes to enable or rotate it, with no rebuild. Building the
  module needs a Rust toolchain and a libclang, neither of which runs on 10.9 unmodified;
  the section pins the versions that do and inserts shims built from the same
  `polyfill/legacy-support` sources as the gap archive.

Every deployed Mach-O targets 10.9, and the script ends with a symbol-resolution gate
checking, on this host, that every strong undefined symbol resolves and that no weak import
binds NULL beyond the documented allow-list. No compat or reexport shim dylibs are involved:
the post-10.9 libc gap is closed at link time by a gap archive built from this project's own
polyfill sources and force-loaded into each binary. The dylibs are
self-contained (own `@rpath` + `LC_RPATH @loader_path/../lib`, C++17 runtime alongside), so
`scripts/stage-frameworks.sh` deploys `build/lib` into WebCore.framework as-is, minus the
static libraries, with no repointing, shimming, or overlay step.

`build/` is a gitignored artifact — run `MavericksSupport/bootstrap.sh` (which runs this
script) before configuring WebKit. `Source/cmake/OptionsMac.cmake` points `MAVERICKS_DEPS`
at it and fails configuration with a pointer to bootstrap if it is empty;
`WebKitFindPackage.cmake` finds ICU there and `OptionsMacGStreamer.cmake` points `GST_ROOT`
there.

`build_deps.sh` compiles through **its own ccache** in `build/ccache` (1 GB cap) — separate
from the WebKit build's much larger cache in `WebKitBuild/ccache` so neither can evict the
other. Because each run builds in a fresh `mktemp -d`, the script sets
`CCACHE_BASEDIR`/`CCACHE_NOHASHDIR` so objects still hit across runs. `MAVERICKS_CCACHE`
overrides the binary; if none is executable the deps build compiles uncached. A normal
rerun keeps the cache (the script clears only `build/{include,lib,bin}`); the `rm -rf
build` in *Updating* below discards it too, costing one uncached rebuild.

## Updating

1. Bump the version in `build_deps.sh` (the URL on the library's own line).
2. For a GStreamer bump, update `GSTREAMER_VERSION`/`GLIB_VERSION` in
   `OptionsMacGStreamer.cmake` to match. `build_deps.sh` checks the pair and fails if they
   disagree, so this cannot be skipped.
3. `rm -rf build && ./build_deps.sh` (or re-run `../bootstrap.sh`); the script's final gate
   must print `ok: ... every strong undefined resolves on 10.9`.
4. Re-point any prose that names the old version: this file, `patches/README.md`'s
   **Target:** lines, and the header comments in `OptionsMac.cmake` /
   `OptionsMacGStreamer.cmake` / `WebKitFindPackage.cmake`.
