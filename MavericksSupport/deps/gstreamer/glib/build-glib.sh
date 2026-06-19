#!/bin/bash
# MAVERICKS_BACKPORT: build glib 2.74.7 from source for macOS 10.9 (clang-22 + 26.1 SDK), then swap it
# into the vendored GStreamer tree. WHY: the official GStreamer 1.20.7 macOS pkg bundles glib 2.62.6,
# but this WebKit checkout requires glib >= 2.70 (URL.h declares URL(GUri*) under USE(GLIB); GUri is
# glib 2.66+). glib's 2.x ABI is forward-compatible, so the 1.20.7 GStreamer dylibs load fine against
# 2.74. Everything lives in the source tree (NOT /tmp, which is ephemeral on this VM).
#
# Network: system curl can't do modern TLS; use the AquaProxy (http://localhost:6531). meson/pip can't
# verify the proxy's TLS-interception cert, so we fetch wraps/tarballs with curl and run meson in-place.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # MavericksSupport/deps/gstreamer/glib
GST="$(cd "$HERE/.." && pwd)"                   # the vendored GStreamer tree (glib swaps into this)
WEBKIT="$(cd "$HERE/../../../.." && pwd)"
REPO="$WEBKIT"                                 # repo root
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"   # clang toolchain dir
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"               # SDK is a sibling of the repo
NINJA_DIR="${MAVERICKS_NINJA_DIR:-$REPO/MavericksSupport/toolchain/build/ninja/bin}"
PROXY=http://localhost:6531
WORK="${GLIB_BUILD_WORK:-/tmp/glib-work}"     # scratch only; rebuildable
GLIB_VER=2.74.7
MESON_VER=1.3.2
PATH="$NINJA_DIR:$PATH"                        # ninja
mkdir -p "$WORK" && cd "$WORK"

dl() { curl -sL -x "$PROXY" --retry 6 --retry-delay 3 --max-time 1200 -o "$1" "$2"; }

# --- meson (pure python, run in place) ---
[ -d meson-$MESON_VER ] || { dl meson.tgz "https://github.com/mesonbuild/meson/releases/download/$MESON_VER/meson-$MESON_VER.tar.gz"; tar xzf meson.tgz; }
MESON="python3 $WORK/meson-$MESON_VER/meson.py"

# --- glib source ---
[ -d glib-$GLIB_VER ] || { dl glib.txz "https://download.gnome.org/sources/glib/2.74/glib-$GLIB_VER.tar.xz"; tar xf glib.txz; }
cd glib-$GLIB_VER
SP=subprojects; mkdir -p $SP/packagecache

# --- subprojects meson can't auto-download through the TLS-intercepting proxy: pre-fetch via curl ---
# pcre2 (glib 2.74 uses PCRE2): source from github + meson patch from wrapdb
[ -f $SP/packagecache/pcre2-10.40.tar.bz2 ] || dl $SP/packagecache/pcre2-10.40.tar.bz2 "https://github.com/PhilipHazel/pcre2/releases/download/pcre2-10.40/pcre2-10.40.tar.bz2"
[ -f $SP/packagecache/pcre2_10.40-3_patch.zip ] || dl $SP/packagecache/pcre2_10.40-3_patch.zip "https://wrapdb.mesonbuild.com/v2/pcre2_10.40-3/get_patch"
# zlib: forced as a subproject so system zlib's CMake `-I/usr/include` doesn't shadow the 26.1 SDK headers
[ -f $SP/packagecache/zlib-1.2.11.tar.gz ] || dl $SP/packagecache/zlib-1.2.11.tar.gz "https://zlib.net/fossils/zlib-1.2.11.tar.gz"
[ -f $SP/packagecache/zlib_1.2.11-6_patch.zip ] || dl $SP/packagecache/zlib_1.2.11-6_patch.zip "https://wrapdb.mesonbuild.com/v2/zlib_1.2.11-6/get_patch"
# libffi (gstreamer meson-port) + proxy-libintl (no-op gettext, since nls=disabled): wrap-git -> archive tarballs
[ -d $SP/libffi ] || { dl libffi.tgz "https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/meson/libffi-meson.tar.gz"; tar xzf libffi.tgz; mv libffi-meson "$SP/libffi"; }
PLI_REV=c03e1a74b17fa7ec467e110130775409e4828a4c
[ -d $SP/proxy-libintl ] || { dl pli.tgz "https://github.com/frida/proxy-libintl/archive/$PLI_REV.tar.gz"; tar xzf pli.tgz; mv proxy-libintl-$PLI_REV "$SP/proxy-libintl"; }

# zlib 1.2.11's zutil.h misfires the Classic-Mac "no fdopen" branch on modern macOS (TARGET_OS_MAC),
# mangling the SDK fdopen prototype. Real macOS has fdopen — neutralize that dead branch.
$MESON wrap promote subprojects/zlib.wrap >/dev/null 2>&1 || true   # ensure cache is recognized

# --- generate the meson native file from the template (it can't derive paths at runtime) ---
sed -e "s|@TC@|$TC|g" -e "s|@SDK@|$SDK|g" -e "s|@HERE@|$HERE|g" \
    "$HERE/glib-native.ini.in" > "$HERE/glib-native.ini"

# --- configure + build + install ---
rm -rf "$WORK/build" "$WORK/install"
$MESON setup "$WORK/build" . \
    --native-file "$HERE/glib-native.ini" --prefix "$WORK/install" \
    --buildtype release --default-library shared --wrap-mode=nodownload --force-fallback-for=zlib \
    -Dtests=false -Dman=false -Dgtk_doc=false -Dnls=disabled -Ddtrace=false \
    -Dsystemtap=false -Dlibmount=disabled -Dselinux=disabled -Dlibelf=disabled -Dxattr=false
# Patch the zlib subproject AFTER setup extracts it.
ZUTIL="$WORK/build/subprojects/zlib-1.2.11/zutil.h"; [ -f "$ZUTIL" ] || ZUTIL=subprojects/zlib-1.2.11/zutil.h
perl -0pi -e 's/(#      )ifndef fdopen\n(#        define fdopen\(fd,mode\) NULL)/${1}if 0 \/* MAVERICKS: macOS has fdopen *\/\n${2}/' "$ZUTIL" 2>/dev/null || true
ninja -C "$WORK/build" -j4
$MESON install -C "$WORK/build"

echo "glib built at $WORK/install (deploy target 10.9, GLIB $GLIB_VER)."
cat <<EOF

NEXT — swap into the vendored GStreamer tree ($GST):
  copy $WORK/install/lib/{libglib,libgobject,libgio,libgmodule,libgthread}-2.0.0.dylib + libpcre2-8 +
  libffi.7 + libintl.8 over the bundled 2.62.6 ones (recreate the unversioned symlinks), rewrite
  install names $WORK/install/lib/X -> @rpath/X with install_name_tool, and replace include/glib-2.0,
  include/gio-unix-2.0 and lib/glib-2.0/include/glibconfig.h (flatten the universal glibconfig.h to the
  x86_64 one). See [[webkit-mavericks-gstreamer-migration]] for the exact swap.
EOF
