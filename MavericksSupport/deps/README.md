# deps — third-party libraries WebKit links

Libraries WebKit links that the 10.9 system doesn't provide. Two kinds live here:

- **`build_deps.sh`** builds ICU, libgcrypt/libgpg-error/libtasn1, brotli, and woff2
  from source with the in-tree toolchain into **`build/`** (`build/lib` + `build/include`).
  `build/` is a gitignored artifact — `MavericksSupport/bootstrap.sh` runs the script.
- **`gstreamer/`** is the vendored GStreamer runtime: a **committed** prebuilt x86_64
  binary (it can't be practically rebuilt from source on 10.9), plus `gstreamer/glib/`,
  the scripts that build the glib it carries.

`Source/cmake/OptionsMac.cmake` points `MAVERICKS_DEPS` at `build/`; `WebKitFindPackage.cmake`
finds ICU there; `OptionsMacGStreamer.cmake` points `GST_ROOT` at `gstreamer/`.

## Updating the built libraries (ICU / gcrypt / brotli / woff2)

1. Bump the version variable at the top of `build_deps.sh` (e.g. `ICU=`, `GCRYPT=`).
2. `rm -rf build && ./build_deps.sh` (or re-run `../bootstrap.sh`).
3. The output is gitignored, so the only thing to commit is the `build_deps.sh` change.

If a new library is needed, add its build to `build_deps.sh` and its include/link wiring
to `Source/WebCore/PlatformMac.cmake` (under `MAVERICKS_DEPS`).

## Updating the vendored GStreamer

The committed `gstreamer/` tree is an x86_64-thinned copy of the official GStreamer
macOS runtime with our glib swapped in. To move to a new GStreamer release:

1. Download the official GStreamer macOS runtime for the target version and extract it.
2. Thin every dylib to x86_64 (`lipo -thin x86_64`) and copy `lib/` + `include/` over
   `gstreamer/lib` + `gstreamer/include`.
3. The package bundles its own glib. If it's older than the glib the WebKit tree's GLib
   helper layer needs, build a newer one and swap it in: run `gstreamer/glib/build-glib.sh`
   (set `GLIB_VER` to the version you want) and follow the `NEXT` instructions it prints
   (copy the glib dylibs over the bundled ones, rewrite install names to `@rpath`, flatten
   `glibconfig.h` to x86_64). If the bundled glib already satisfies WebKit, skip this step —
   the swap exists only to bridge that version gap, so a new-enough package removes the need
   for it entirely.
4. Update the version in the `GStreamer is vendored at ...` comment in `OptionsMac.cmake`
   and `GSTREAMER_VERSION`/`GLIB_VERSION` in `OptionsMacGStreamer.cmake`.
5. `git add gstreamer` to commit the new binary.
