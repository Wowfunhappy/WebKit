# deps — third-party libraries WebKit links

Libraries WebKit links that the 10.9 system doesn't provide. Two kinds live here:

- **`build_deps.sh`** builds ICU, libgcrypt/libgpg-error/libtasn1, brotli, woff2,
  FFmpeg, and the gst-libav plugin from source with the in-tree toolchain into
  **`build/`** (`build/lib` + `build/include`). `build/` is a gitignored artifact —
  `MavericksSupport/bootstrap.sh` runs the script.
- **`gstreamer/`** is the vendored GStreamer runtime: a **committed** prebuilt x86_64
  binary, thinned from the official GStreamer macOS runtime. The deployed runtime is
  assembled from this tree plus the codec dylibs `build_deps.sh` builds (FFmpeg and
  `gstreamer-1.0/libgstlibav.dylib`) — `install-safari7.sh` overlays `build/lib` over
  the staged copy.

`Source/cmake/OptionsMac.cmake` points `MAVERICKS_DEPS` at `build/`; `WebKitFindPackage.cmake`
finds ICU there; `OptionsMacGStreamer.cmake` points `GST_ROOT` at `gstreamer/`.

## Updating the built libraries (ICU / gcrypt / brotli / woff2)

1. Bump the version variable at the top of `build_deps.sh` (e.g. `ICU=`, `GCRYPT=`).
2. `rm -rf build && ./build_deps.sh` (or re-run `../bootstrap.sh`).
3. The output is gitignored, so the only thing to commit is the `build_deps.sh` change.

If a new library is needed, add its build to `build_deps.sh` and its include/link wiring
to `Source/WebCore/PlatformMac.cmake` (under `MAVERICKS_DEPS`).

## Updating the vendored GStreamer

The committed `gstreamer/` tree is an x86_64-thinned copy of the official GStreamer macOS
runtime. The package ships everything WebKit's GStreamer path links — including glib and the
OpenSSL the WebRTC DTLS-SRTP crypto uses (`lib/libcrypto`/`libssl`, consumed via the
`OpenSSL::Crypto` cmake target). Both are used as-shipped; there is no separate build or swap
step. To move to a new GStreamer release:

1. Download the official GStreamer macOS runtime for the target version and extract it.
2. Thin every dylib to x86_64 (`lipo -thin x86_64`) and copy `lib/` + `include/` over
   `gstreamer/lib` + `gstreamer/include`. Flatten the arch-specific glibconfig
   (`lib/glib-2.0/include/<arch>/glibconfig.h` → `lib/glib-2.0/include/glibconfig.h`).
3. Confirm the bundled dylibs are 10.9-self-sufficient: `nm -u` on each must show no
   post-10.9 symbol imports (the install names are already `@rpath`-relative, so no rewriting).
4. Update the version in the `GStreamer is vendored at ...` comment in `OptionsMac.cmake`
   and `GSTREAMER_VERSION` in `OptionsMacGStreamer.cmake`.
5. `git add gstreamer` to commit the new binary.

