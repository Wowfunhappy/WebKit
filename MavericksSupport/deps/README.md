# deps — third-party libraries WebKit links

Libraries WebKit links that the 10.9 system doesn't provide. Two kinds live here:

- **`build_deps.sh`** builds EVERYTHING from source with the in-tree
  toolchain into **`build/`** (`build/lib` + `build/include` + `build/bin`): the
  static libraries WebKit links directly (ICU 74.2, libgcrypt/libgpg-error/libtasn1,
  brotli, woff2) and the complete GStreamer 1.26.6 runtime (glib 2.80.5, gstreamer
  core/base/good/bad, FFmpeg + gst-libav, libvpx, dav1d, libnice/srtp/dtls + OpenSSL,
  WebRTC audio DSP). Every deployed Mach-O targets 10.9 and the script ends with a
  symbol-resolution gate proving, on this host, that every strong undefined symbol
  resolves and no weak import binds NULL beyond the documented allow-list — no compat
  or reexport shims. `build/` is a gitignored artifact — `MavericksSupport/bootstrap.sh`
  runs the script.
- **`gstreamer/`** is the vendored GStreamer runtime: the **committed** copy of the
  script's runtime output (`lib/` dylibs + plugins, `include/` build-time headers,
  `bin/` gst-inspect/gst-launch for debugging) including libxml2 2.13
  (`lib/libxml2.2.dylib`, `include/libxml2`), which WebCore links in place of the
  crash-prone 10.9 system libxml2 2.9. `scripts/stage-frameworks.sh` deploys `gstreamer/lib`
  into WebCore.framework as-is — the dylibs are self-contained (own `@rpath` +
  `LC_RPATH @loader_path/../lib`, C++17 runtime vendored in-tree), so there is no
  repointing, shimming, or overlay step.

`Source/cmake/OptionsMac.cmake` points `MAVERICKS_DEPS` at `build/` and libxml2 at
`gstreamer/` (built by the same script); `WebKitFindPackage.cmake` finds ICU there; `OptionsMacGStreamer.cmake`
points `GST_ROOT` at `gstreamer/`.

## Updating

1. Bump the version variable in `build_deps.sh`.
2. `rm -rf build && ./build_deps.sh` (or re-run `../bootstrap.sh`); the
   script's final gate must print `ok: ... every strong undefined resolves on 10.9`.
3. Refresh the committed runtime: replace `gstreamer/{lib,include,bin}` with the
   `build/` output (drop the static `*.a`).
4. Update `GSTREAMER_VERSION`/`GLIB_VERSION` in `OptionsMacGStreamer.cmake` and the
   version in the `GStreamer is vendored at ...` comment in `OptionsMac.cmake`.
5. `git add gstreamer` to commit the new binaries.
