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
- `include/cdm`, the Chromium Content Decryption Module interface (pinned to one revision of
  Chromium's own repository) that WebCore's `CDMWidevine.cpp` hosts. Headers only: the module
  is Google's Widevine CDM, which is not redistributable and which the UIProcess downloads and
  installs at runtime (`Source/WebKit/UIProcess/mac/WidevineCdmInstaller.h`).

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

Sources, build trees, build tools and the install prefix live in `.build-tree/` (gitignored),
kept between runs: a rerun re-extracts and re-configures nothing it already has, and each
package's own build system decides what to redo. What a package is built from — its section of
`build_deps.sh`, the patches it names, and the values of the settings that section reads without
defining (the ambient compile flags, the shared GStreamer option set, the pinned meson) — is
hashed into its build dir, so editing a patch or a flag re-extracts and rebuilds that package.
Static libraries and build tools are skipped whole once their product is in the tree and their
build dirs are dropped; they are linked before the gap archive joins `LDFLAGS`, so no archive
change reaches them. `--clean` discards the tree, as does a change of package versions, SDK or
compiler.

That is what makes an edit to one of the polyfill `shared/` sources cheap. They compile into
the gap archive force-loaded into every dylib here, and no build system tracks its content, so
when the archive's bytes change the script drops every image built from it — found by the
archive's own diagnostics inside them — and each package links again: a relink of the media
runtime, not a rebuild of it. Every image carrying the archive must then postdate it, which the
run checks before it collects anything.

`build_deps.sh` compiles through **its own ccache** in `build/ccache` (1 GB cap) — separate
from the WebKit build's much larger cache in `WebKitBuild/ccache` so neither can evict the
other. `MAVERICKS_CCACHE` overrides the binary; if none is executable the deps build compiles
uncached. Both caches sit outside `.build-tree/`, so `--clean` keeps them.

## Updating

1. Bump the version in `build_deps.sh` (the URL on the library's own line).
2. For a GStreamer bump, update `GSTREAMER_VERSION`/`GLIB_VERSION` in
   `OptionsMacGStreamer.cmake` to match. `build_deps.sh` checks the pair and fails if they
   disagree, so this cannot be skipped.
3. `./build_deps.sh --clean`; the tree holds one version of every package, and the script
   refuses to run against a tree built from a different set. The final gate must print
   `ok: ... every strong undefined resolves on 10.9`.
4. Re-point any prose that names the old version: this file, `patches/README.md`'s
   **Target:** lines, and the header comments in `OptionsMac.cmake` /
   `OptionsMacGStreamer.cmake` / `WebKitFindPackage.cmake`.
