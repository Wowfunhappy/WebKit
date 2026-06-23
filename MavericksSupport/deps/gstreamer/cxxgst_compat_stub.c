/*
 * MAVERICKS_BACKPORT: marker translation unit for libcxxgst_compat.dylib (built by
 * build-cxxgst-compat.sh). The dylib's real job is its three LC_REEXPORT_DYLIBs — the bundle
 * libc++ / libc++abi / libunwind — which give the macOS-26-built C++17 GStreamer libs the complete
 * modern C++ runtime that 10.9's /usr/lib/libc++ lacks. This one exported symbol just makes it a
 * well-formed dylib.
 */
int __cxxgst_compat(void) { return 0; }
