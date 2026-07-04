# deps — third-party libraries WebKit links

Libraries WebKit links that the 10.9 system doesn't provide. Two kinds live here:

- **`build_deps.sh`** builds ICU, libgcrypt/libgpg-error/libtasn1, brotli, woff2,
  FFmpeg, and the gst-libav plugin from source with the in-tree toolchain into
  **`build/`** (`build/lib` + `build/include`). `build/` is a gitignored artifact —
  `MavericksSupport/bootstrap.sh` runs the script.
- The GStreamer media runtime (GLib, GStreamer core + plugins, codecs, OpenSSL,
  FFmpeg, gst-libav) is part of the same `build_deps.sh` output: shared dylibs under
  `build/lib` (+ `build/lib/gstreamer-1.0` plugins), built from source targeting 10.9
  with `@rpath` install names. `install-safari7.sh` deploys `build/lib` as-is.

`Source/cmake/OptionsMac.cmake` points `MAVERICKS_DEPS` at `build/`; `WebKitFindPackage.cmake`
finds ICU there; `OptionsMacGStreamer.cmake` points `GST_ROOT` at `build/`.

## Updating the built libraries (ICU / gcrypt / brotli / woff2)

1. Bump the version variable at the top of `build_deps.sh` (e.g. `ICU=`, `GCRYPT=`).
2. `rm -rf build && ./build_deps.sh` (or re-run `../bootstrap.sh`).
3. The output is gitignored, so the only thing to commit is the `build_deps.sh` change.

If a new library is needed, add its build to `build_deps.sh` and its include/link wiring
to `Source/WebCore/PlatformMac.cmake` (under `MAVERICKS_DEPS`).

