#!/bin/bash
# Build the third-party libraries WebKit links that are NOT available on the 10.9
# system and NOT vendored as a binary:
#
#   ICU 74.2 (static)                   -> JSC Intl (ucfpos_*/udtitvfmt_*/... that
#                                          10.9's ICU 51 libicucore lacks)
#   libgpg-error, libgcrypt, libtasn1   -> WebCore USE(GCRYPT) WebCrypto
#   brotli (common/dec/enc)             -> WOFF2 + Brotli Content-Encoding
#   woff2 (decoder)                     -> WOFF2 web font decompression
#   FFmpeg 5.1.6 (shared, @rpath)       -> codec backend for the gst-libav plugin
#   gst-libav 1.20.7                    -> GStreamer's libav codec plugin (video/audio
#                                          decode for MediaPlayerPrivateGStreamer)
#
# Built with the in-tree clang-22 / 10.9 toolchain. Output (headers + static libs)
# lands in MavericksSupport/deps/build/{include,lib} -- a gitignored artifact this
# script regenerates. Source tarballs download to a scratch dir outside the tree.
#
# Usage: MavericksSupport/deps/build_deps.sh   (or via MavericksSupport/bootstrap.sh)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"                   # repo root
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"
CMAKE="${MAVERICKS_CMAKE:-$REPO/MavericksSupport/toolchain/build/cmake/bin/cmake}"
NINJA="${MAVERICKS_NINJA:-$REPO/MavericksSupport/toolchain/build/ninja/bin/ninja}"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"

# The in-tree clang ships the libc++ dylibs but not its headers; those live in the SDK.
# clang on Darwin reads SDKROOT as the default -isysroot, so this puts <memory>/<string>
# (and the system frameworks/headers) on the search path for every sub-build below.
export SDKROOT="$SDK"

# /usr/bin/make, gnumake, ar, etc. are xcode-select shims; when xcode-select points at
# an Xcode.app whose Developer dir lacks the CLI tools (Xcode 6.2), every shim errors
# with "unable to find utility". Prefer the CommandLineTools binaries directly so this
# script is independent of the machine's current xcode-select state.
export PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"

DEST="$HERE/build"                                 # gitignored artifact: include/ + lib/
SCRATCH="$(mktemp -d -t depbuild)"
trap 'rm -rf "$SCRATCH"' EXIT
SRC="$SCRATCH/src"
STAGE="$SCRATCH/install"                            # full autotools install prefix

export CC="$TC/bin/clang"
export CXX="$TC/bin/clang++"
export AR="$TC/bin/llvm-ar"
export RANLIB="$TC/bin/llvm-ranlib"
export NM="$TC/bin/llvm-nm"
export MACOSX_DEPLOYMENT_TARGET=10.9
export CFLAGS="-O2 -mmacosx-version-min=10.9"
export CXXFLAGS="-O2 -mmacosx-version-min=10.9"

# The clang-22 toolchain's clang.cfg/clang++.cfg add a default link set (libc++/
# objc/frameworks). That is correct for building WebKit but breaks autotools/gnulib
# feature probes: the auto-linked archives make AC_CHECK_FUNC/header-generation
# misbehave (libgcrypt decides getpid/clock are "missing" and compiles #error stubs;
# gnulib leaks raw typedefs into the Makefile -> /bin/sh syntax error).
#
# So the autotools deps (libgpg-error/libgcrypt/libtasn1) compile with a VANILLA
# clang (--no-default-config): a plain 10.9-targeting compiler whose probes see the
# real 10.9 SDK feature set. The resulting .a is pure object code; the polyfill that
# resolves any post-10.9 symbol is linked later at WebKit link time.
VBIN="$SCRATCH/vanilla-bin"
mkdir -p "$VBIN"
# -Wno-implicit-function-declaration / -Wno-implicit-int: pre-C99 constructs that are
# hard errors in clang >= 16 (e.g. libgcrypt's bench-slope.c calls gettimeofday
# implicitly); relaxing them is the standard way to build old autotools C with new clang.
LENIENT='-Wno-implicit-function-declaration -Wno-implicit-int'
printf '#!/bin/sh\nexec "%s/bin/clang" --no-default-config %s "$@"\n'   "$TC" "$LENIENT" > "$VBIN/cc";  chmod +x "$VBIN/cc"
printf '#!/bin/sh\nexec "%s/bin/clang++" --no-default-config %s "$@"\n' "$TC" "$LENIENT" > "$VBIN/cxx"; chmod +x "$VBIN/cxx"
CC_VANILLA="$VBIN/cc"
CXX_VANILLA="$VBIN/cxx"

mkdir -p "$SRC" "$STAGE" "$DEST/include" "$DEST/lib"

# get <url> <label>: download the tarball (once) and extract it, echoing the build
# dir. To update a library, change its version in the URL on its line below.
get() {
  local url="$1" label="$2" f; f="$SRC/$(basename "$url")"
  # NB: this function's stdout is captured by the caller ($(get ...)) as the build dir,
  # so the progress line must go to stderr or it corrupts the returned path.
  [ -f "$f" ] || ( cd "$SRC" && echo "download $(basename "$url")" >&2 && curl -fsSL -m 300 -O "$url" )
  rm -rf "${SCRATCH:?}/build-$label"; mkdir -p "$SCRATCH/build-$label"
  tar xf "$f" -C "$SCRATCH/build-$label" --strip-components=1
  echo "$SCRATCH/build-$label"
}

echo "==== ICU 74.2 ===="
# ICU is C++ and its build tools (makeconv/genrb) link C++ iostreams, so it uses the
# FULL clang wrapper (clang-22's libc++), not the vanilla one. --disable-renaming
# emits UNVERSIONED symbols (ucfpos_open, not ucfpos_open_74) to match WebKit's
# U_DISABLE_RENAMING=1; without it JSC's Intl symbols stay unresolved.
icud=$(get https://github.com/unicode-org/icu/releases/download/release-74-2/icu4c-74_2-src.tgz icu)
( cd "$icud/source" \
  && CXXFLAGS="$CXXFLAGS -std=c++17" ./configure --prefix="$STAGE" \
       --enable-static --disable-shared --disable-renaming \
       --disable-samples --disable-tests --disable-extras --disable-icuio --disable-layoutex \
  && make -j4 && make install )

echo "==== libgpg-error ===="
d=$(get https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.51.tar.bz2 gpgerror)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc --disable-tests --disable-languages \
  && make -j4 && make install )

echo "==== libgcrypt ===="
d=$(get https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2 gcrypt)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc --disable-asm --with-libgpg-error-prefix="$STAGE" \
  && make -j4 && make install )

echo "==== libtasn1 ===="
d=$(get https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz tasn1)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc \
  && make -j4 && make install )

echo "==== brotli ===="
d=$(get https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz brotli)
( cd "$d" && mkdir -p out && cd out \
  && "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
       -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
       -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
       -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
       -DCMAKE_INSTALL_PREFIX="$STAGE" .. \
  && "$NINJA" && "$NINJA" install )

echo "==== woff2 (decoder) ===="
d=$(get https://github.com/google/woff2/archive/refs/tags/v1.0.2.tar.gz woff2)
( cd "$d" && \
  $CXX -std=c++11 -O2 -mmacosx-version-min=10.9 -fno-exceptions \
    -Iinclude -Isrc -I"$STAGE/include" -c \
    src/woff2_dec.cc src/table_tags.cc src/variable_length.cc \
    src/woff2_common.cc src/woff2_out.cc \
  && "$AR" rcs libwoff2dec.a woff2_dec.o table_tags.o variable_length.o \
       woff2_common.o woff2_out.o \
  && mkdir -p "$STAGE/include/woff2" \
  && cp include/woff2/*.h "$STAGE/include/woff2/" \
  && cp libwoff2dec.a "$STAGE/lib/" )

echo "==== FFmpeg 5.1.6 ===="
# Shared dylibs with @rpath install names; the GStreamer runtime's rpath covers them
# at load time. Apple-framework codepaths (audiotoolbox/videotoolbox/securetransport)
# stay off: decoding runs through FFmpeg's own codecs so behavior is identical on
# every 10.9 install.
FFSTAGE="$SCRATCH/ffstage"
d=$(get https://ffmpeg.org/releases/ffmpeg-5.1.6.tar.gz ffmpeg)
( cd "$d" && ./configure --cc="$CC_VANILLA" --prefix="$FFSTAGE" \
    --install-name-dir='@rpath' \
    --enable-shared --disable-static --disable-programs --disable-doc \
    --disable-debug --disable-audiotoolbox --disable-videotoolbox \
    --disable-securetransport --disable-iconv --disable-lzma \
    --disable-sdl2 --disable-xlib --disable-coreimage \
    --x86asmexe="$REPO/MavericksSupport/toolchain/build/nasm/bin/nasm" \
    --extra-cflags="-mmacosx-version-min=10.9" \
    --extra-ldflags="-mmacosx-version-min=10.9" \
  && make -j4 && make install )

echo "==== gst-libav 1.20.7 ===="
# The plugin's sources build directly with clang against the GStreamer headers in
# gstreamer/ and the FFmpeg stage above (its meson build adds nothing we need).
# config.h carries the handful of defines the sources read.
GSTLIB="$HERE/gstreamer/lib"
GSTINC="$HERE/gstreamer/include"
d=$(get https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-1.20.7.tar.xz gstlibav)
( cd "$d/ext/libav" && \
  printf '%s\n' \
    '#define PACKAGE "gst-libav"' \
    '#define PACKAGE_VERSION "1.20.7"' \
    '#define VERSION "1.20.7"' \
    '#define GST_API_VERSION "1.0"' \
    '#define GST_LICENSE "LGPL"' \
    '#define GST_PACKAGE_NAME "GStreamer FFMPEG Plug-ins source release"' \
    '#define GST_PACKAGE_ORIGIN "Unknown package origin"' \
    '#define LIBAV_SOURCE "system install"' \
    > config.h && \
  "$CC" -O2 -mmacosx-version-min=10.9 -DHAVE_CONFIG_H -I. \
    -I"$GSTINC/gstreamer-1.0" -I"$GSTINC/glib-2.0" \
    -I"$GSTLIB/glib-2.0/include" -I"$FFSTAGE/include" \
    -c ./*.c && \
  "$CC" -dynamiclib -mmacosx-version-min=10.9 -o libgstlibav.dylib ./*.o \
    -install_name @rpath/libgstlibav.dylib \
    -L"$FFSTAGE/lib" -lavcodec -lavformat -lavutil -lavfilter -lswscale -lswresample \
    -L"$GSTLIB" -lgstreamer-1.0 -lgstbase-1.0 -lgstvideo-1.0 -lgstaudio-1.0 \
    -lgstpbutils-1.0 -lgsttag-1.0 -lglib-2.0 -lgobject-2.0 )
GSTLIBAV_BUILD="$d/ext/libav"

echo "==== collect into deps/build ===="
rm -rf "$DEST/include" "$DEST/lib"; mkdir -p "$DEST/include" "$DEST/lib"
# headers
cp -R "$STAGE/include/unicode"    "$DEST/include/"
cp "$STAGE/include/gpg-error.h"   "$DEST/include/"
cp "$STAGE/include/gcrypt.h"      "$DEST/include/"
cp "$STAGE/include/libtasn1.h"    "$DEST/include/"
cp -R "$STAGE/include/brotli"     "$DEST/include/"
cp -R "$STAGE/include/woff2"      "$DEST/include/"
# static libs
for l in libicuuc.a libicui18n.a libicudata.a \
         libgpg-error.a libgcrypt.a libtasn1.a \
         libbrotlicommon.a libbrotlidec.a libbrotlienc.a libwoff2dec.a; do
  cp "$STAGE/lib/$l" "$DEST/lib/"
done
# shared dylibs: FFmpeg (real files only, stored under their @rpath majored install
# names) and the gst-libav plugin; the install scripts stage these next to the
# GStreamer runtime libraries.
mkdir -p "$DEST/lib/gstreamer-1.0"
for f in "$FFSTAGE"/lib/*.dylib; do
  [ -L "$f" ] && continue
  cp "$f" "$DEST/lib/$(basename "$(otool -D "$f" | tail -1)")"
done
cp "$GSTLIBAV_BUILD/libgstlibav.dylib" "$DEST/lib/gstreamer-1.0/"

echo "==== done. deps/build: ===="
ls -la "$DEST/lib" "$DEST/include"

