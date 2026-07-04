#!/bin/bash
# Build the third-party libraries WebKit links that are NOT available on the 10.9
# system and NOT vendored as a binary:
#
#   ICU 74.2 (static)                   -> JSC Intl (ucfpos_*/udtitvfmt_*/... that
#                                          10.9's ICU 51 libicucore lacks)
#   libgpg-error, libgcrypt, libtasn1   -> WebCore USE(GCRYPT) WebCrypto
#   brotli (common/dec/enc)             -> WOFF2 + Brotli Content-Encoding
#   woff2 (decoder)                     -> WOFF2 web font decompression
#   GLib 2.80.5 + GStreamer 1.26.6      -> the media runtime (core, plugins-base/
#     (+ codecs, OpenSSL, libnice, ...)     good/bad, gst-libav on FFmpeg 7.1.2) that
#                                          MediaPlayerPrivateGStreamer drives; built
#                                          shared with @rpath install names
#
# Built with the in-tree clang-22 / 10.9 toolchain. Output (headers + static libs)
# lands in MavericksSupport/deps/build/{include,lib} -- a gitignored artifact this
# script regenerates. Source tarballs download to a scratch dir outside the tree.
#
# Usage: MavericksSupport/deps/build_deps.sh   (or via MavericksSupport/bootstrap.sh)
set -euo pipefail
# NB: the 10.9 system bash (3.2) does NOT abort when a ( ... ) section subshell fails,
# even under set -e / trap ERR — hence the explicit `|| exit 1` on every section.

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
# Tarballs cache in a persistent (gitignored) dir so a rerun after a mid-script failure
# does not re-download everything.
SRC="$HERE/.tarball-cache"
STAGE="$SCRATCH/install"                            # full autotools install prefix

export CC="$TC/bin/clang"
export CXX="$TC/bin/clang++"
# meson probes objc separately; without these it picks up the CommandLineTools clang,
# which cannot read the modern SDK's .tbd stubs ("library not found for -lSystem").
export OBJC="$TC/bin/clang"
export OBJCXX="$TC/bin/clang++"
export AR="$TC/bin/llvm-ar"
export RANLIB="$TC/bin/llvm-ranlib"
# Classic BSD nm from CommandLineTools: libtool's symbol-pipe probing only understands
# its output, and the toolchain's llvm-nm binary does not run on this host (its libc++
# lacks the libc++abi reexport it was linked against).
export NM=/Library/Developer/CommandLineTools/usr/bin/nm
export MACOSX_DEPLOYMENT_TARGET=10.9
export CFLAGS="-O2 -mmacosx-version-min=10.9"
export CXXFLAGS="-O2 -mmacosx-version-min=10.9"
export OBJCFLAGS="-O2 -mmacosx-version-min=10.9"
export LDFLAGS="-mmacosx-version-min=10.9"

# /usr/bin/make and friends are xcode-select shims that error out when xcode-select
# points at an Xcode whose Developer dir lacks the CLI tools; use CommandLineTools
# directly, plus the in-tree ninja for meson.
export PATH="/Library/Developer/CommandLineTools/usr/bin:$(dirname "$NINJA"):$PATH"

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
# fetch <url> <dest-file>: download with curl. 10.9's Secure Transport cannot complete
# a TLS handshake with some hosts (freedesktop.org's CDN among them); those go through
# the local AquaProxy endpoint, which terminates TLS itself. Every other host is fetched
# directly.
fetch() {
  local url="$1" dest="$2"
  curl -fsSL -m 600 -o "$dest" "$url" 2>/dev/null \
    || https_proxy=http://localhost:6531 curl -fsSL -m 600 -o "$dest" "$url"
}

get() {
  local url="$1" label="$2" f; f="$SRC/$(basename "$url")"
  # NB: this function's stdout is captured by the caller ($(get ...)) as the build dir,
  # so the progress line must go to stderr or it corrupts the returned path.
  [ -f "$f" ] || ( echo "download $(basename "$url")" >&2 && fetch "$url" "$f" )
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
  && make -j4 && make install ) || exit 1

echo "==== libgpg-error ===="
d=$(get https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.51.tar.bz2 gpgerror)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc --disable-tests --disable-languages \
  && make -j4 && make install ) || exit 1

echo "==== libgcrypt ===="
d=$(get https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2 gcrypt)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc --disable-asm --with-libgpg-error-prefix="$STAGE" \
  && make -j4 && make install ) || exit 1

echo "==== libtasn1 ===="
d=$(get https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz tasn1)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc \
  && make -j4 && make install ) || exit 1

echo "==== brotli ===="
d=$(get https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz brotli)
( cd "$d" && mkdir -p out && cd out \
  && "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
       -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
       -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
       -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
       -DCMAKE_INSTALL_PREFIX="$STAGE" .. \
  && "$NINJA" && "$NINJA" install ) || exit 1

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
  && cp libwoff2dec.a "$STAGE/lib/" ) || exit 1

# ============================ GStreamer media runtime ============================
# GLib + GStreamer (core, plugins-base/good/bad, gst-libav on FFmpeg) and their
# codec/transport libraries, all shared dylibs targeting 10.9. Meson drives most of
# these; the build tools it needs (meson itself, pkgconf, bison >= 2.4) build first
# since 10.9 ships none of them.

MESONENV="$SCRATCH/mesonenv"
TOOLS="$SCRATCH/tools"
/usr/local/bin/python3 -m venv "$MESONENV"
"$MESONENV/bin/pip" -q install meson==1.5.2 packaging
MESON="$MESONENV/bin/meson"
export PATH="$STAGE/bin:$TOOLS/bin:$MESONENV/bin:$PATH"
export PKG_CONFIG="$TOOLS/bin/pkg-config"
export PKG_CONFIG_PATH="$STAGE/lib/pkgconfig"

echo "==== pkgconf ===="
d=$(get https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz pkgconf)
( cd "$d" && ./configure -q --prefix="$TOOLS" \
  && make -s -j4 && make -s install && ln -sf pkgconf "$TOOLS/bin/pkg-config" ) || exit 1

echo "==== bison ===="
d=$(get https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz bison)
( cd "$d" && CC="$CC_VANILLA" ./configure -q --prefix="$TOOLS" > /dev/null \
  && make -s -j4 && make -s install ) || exit 1

echo "==== GLib 2.80.5 ===="
# GLib's bundled subprojects come from meson wraps. The wrap-file tarballs pre-cache
# into subprojects/packagecache (meson verifies their hashes); the wrap-git ones
# check out as plain directories at the wrap's pinned revision.
d=$(get https://download.gnome.org/sources/glib/2.80/glib-2.80.5.tar.xz glib)
( cd "$d/subprojects" && mkdir -p packagecache && cd packagecache \
  && fetch https://github.com/PhilipHazel/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.bz2 pcre2-10.42.tar.bz2 \
  && fetch https://wrapdb.mesonbuild.com/v2/pcre2_10.42-2/get_patch pcre2_10.42-2_patch.zip \
  && fetch https://zlib.net/fossils/zlib-1.2.11.tar.gz zlib-1.2.11.tar.gz \
  && fetch https://wrapdb.mesonbuild.com/v2/zlib_1.2.11-6/get_patch zlib_1.2.11-6_patch.zip ) || exit 1
( cd "$d/subprojects" \
  && fetch https://gitlab.gnome.org/GNOME/gvdb/-/archive/0854af0fdb6d527a8d1999835ac2c5059976c210/gvdb.tar.gz gvdb.tar.gz \
  && tar xzf gvdb.tar.gz && rm -rf gvdb && mv gvdb-0854af0* gvdb \
  && fetch https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/meson/libffi-meson.tar.gz libffi-meson.tar.gz \
  && tar xzf libffi-meson.tar.gz && rm -rf libffi && mv libffi-meson libffi \
  && fetch https://github.com/frida/proxy-libintl/archive/refs/tags/0.4.tar.gz proxy-libintl-0.4.tar.gz \
  && tar xzf proxy-libintl-0.4.tar.gz && rm -rf proxy-libintl && mv proxy-libintl-0.4 proxy-libintl ) || exit 1
( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Ddefault_library=shared -Dbuildtype=release \
    -Dtests=false -Dglib_debug=disabled -Dman-pages=disabled -Ddocumentation=false \
    -Dintrospection=disabled > /tmp/depslog-01-setup.log 2>&1 \
  && "$MESON" compile -C b -j 4 > /tmp/depslog-01-compile.log 2>&1 && "$MESON" install -C b > /tmp/depslog-01-install.log 2>&1 ) || exit 1

echo "==== orc / ogg / vorbis / opus / flac ===="
d=$(get https://gstreamer.freedesktop.org/src/orc/orc-0.4.41.tar.xz orc)
( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release -Dtests=disabled \
    -Dexamples=disabled > /dev/null && "$MESON" compile -C b -j 4 > /tmp/depslog-02-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-02-install.log 2>&1 ) || exit 1
d=$(get https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz ogg)
( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static && make -s -j4 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz vorbis)
( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static && make -s -j4 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus)
( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --disable-doc \
    --disable-extra-programs && make -s -j4 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/flac/flac-1.4.3.tar.xz flac)
( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --disable-programs \
    --disable-examples --disable-cpplibs && make -s -j4 && make -s install ) || exit 1

echo "==== OpenSSL 3.0.16 ===="
# WebRTC's DTLS-SRTP and WebKit's OpenSSL::Crypto cmake target consume these.
d=$(get https://www.openssl.org/source/openssl-3.0.16.tar.gz openssl)
( cd "$d" && ./Configure darwin64-x86_64-cc shared --prefix="$STAGE" --libdir=lib \
    no-tests -mmacosx-version-min=10.9 > /dev/null \
  && make -s -j4 > /dev/null && make -s install_sw > /dev/null ) || exit 1

echo "==== libsrtp ===="
d=$(get https://github.com/cisco/libsrtp/archive/refs/tags/v2.6.0.tar.gz srtp)
( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release \
    -Ddefault_library=shared > /dev/null && "$MESON" compile -C b -j 4 > /tmp/depslog-03-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-03-install.log 2>&1 ) || exit 1

echo "==== webrtc-audio-processing ===="
# Echo cancellation / noise suppression for getUserMedia audio (gst's webrtcdsp).
d=$(get https://www.freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-1.3.tar.xz webrtcap)
( cd "$d/subprojects" 2>/dev/null && mkdir -p packagecache && cd packagecache \
  && { for w in ../*.wrap; do
         [ -f "$w" ] || continue
         su=$(sed -n 's/^source_url *= *//p' "$w"); sf=$(sed -n 's/^source_filename *= *//p' "$w")
         pu=$(sed -n 's/^patch_url *= *//p' "$w");  pf=$(sed -n 's/^patch_filename *= *//p' "$w")
         [ -n "$su" ] && [ ! -f "$sf" ] && fetch "$su" "$sf"
         [ -n "$pu" ] && [ ! -f "$pf" ] && fetch "$pu" "$pf"
       done; true; } ) || true
( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release > /tmp/depslog-03-setup.log 2>&1 \
  && "$MESON" compile -C b -j 4 > /tmp/depslog-05-compile.log 2>&1 && "$MESON" install -C b > /tmp/depslog-05-install.log 2>&1 ) || exit 1

echo "==== GStreamer 1.26.6 (core) ===="
GSTOPTS="-Dbuildtype=release -Dtests=disabled -Dexamples=disabled -Ddoc=disabled"
d=$(get https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.26.6.tar.xz gstcore)
( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled \
    -Dbenchmarks=disabled -Dlibunwind=disabled -Ddbghelp=disabled -Dbash-completion=disabled > /tmp/depslog-04-setup.log 2>&1 \
  && "$MESON" compile -C b -j 4 > /tmp/depslog-06-compile.log 2>&1 && "$MESON" install -C b > /tmp/depslog-06-install.log 2>&1 ) || exit 1

echo "==== gst-plugins-base ===="
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.26.6.tar.xz gstbase)
( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled > /tmp/depslog-05-setup.log 2>&1 \
  && "$MESON" compile -C b -j 4 > /tmp/depslog-07-compile.log 2>&1 && "$MESON" install -C b > /tmp/depslog-07-install.log 2>&1 ) || exit 1

echo "==== gst-plugins-good ===="
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.26.6.tar.xz gstgood)
( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS > /tmp/depslog-06-setup.log 2>&1 \
  && "$MESON" compile -C b -j 4 > /tmp/depslog-08-compile.log 2>&1 && "$MESON" install -C b > /tmp/depslog-08-install.log 2>&1 ) || exit 1

echo "==== gst-plugins-bad ===="
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-1.26.6.tar.xz gstbad)
( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled > /tmp/depslog-07-setup.log 2>&1 \
  && "$MESON" compile -C b -j 4 > /tmp/depslog-09-compile.log 2>&1 && "$MESON" install -C b > /tmp/depslog-09-install.log 2>&1 ) || exit 1

echo "==== libnice ===="
# Builds after the GStreamer modules: libnice's own gst plugin (the "nice" ICE
# transport elements webrtcbin instantiates) is only built when gstreamer-1.0 is
# already discoverable.
d=$(get https://libnice.freedesktop.org/releases/libnice-0.1.22.tar.gz nice)
( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release -Dtests=disabled \
    -Dexamples=disabled -Dgtk_doc=disabled -Dintrospection=disabled -Dgupnp=disabled > /tmp/depslog-02-setup.log 2>&1 \
  && "$MESON" compile -C b -j 4 > /tmp/depslog-04-compile.log 2>&1 && "$MESON" install -C b > /tmp/depslog-04-install.log 2>&1 ) || exit 1

echo "==== FFmpeg 7.1.2 ===="
# Apple-framework codepaths stay off: decoding runs through FFmpeg's own codecs so
# behavior is identical on every 10.9 install.
d=$(get https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz ffmpeg)
( cd "$d" && ./configure --cc="$CC" --prefix="$STAGE" --install-name-dir='@rpath' \
    --enable-shared --disable-static --disable-programs --disable-doc --disable-debug \
    --disable-audiotoolbox --disable-videotoolbox --disable-securetransport \
    --disable-iconv --disable-lzma --disable-sdl2 --disable-xlib --disable-coreimage \
    --x86asmexe="$REPO/MavericksSupport/toolchain/build/nasm/bin/nasm" \
    --extra-cflags="-mmacosx-version-min=10.9" --extra-ldflags="-mmacosx-version-min=10.9" > /dev/null \
  && make -s -j4 > /dev/null && make -s install > /dev/null ) || exit 1

echo "==== gst-libav ===="
d=$(get https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-1.26.6.tar.xz gstlibav)
# gst-libav's option set has no "examples"; it takes the shared options minus that one.
( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release -Dtests=disabled -Ddoc=disabled > /tmp/depslog-08-setup.log 2>&1 \
  && "$MESON" compile -C b -j 4 > /tmp/depslog-10-compile.log 2>&1 && "$MESON" install -C b > /tmp/depslog-10-install.log 2>&1 ) || exit 1

echo "==== collect into deps/build ===="
ls -la "$STAGE/lib" > /tmp/deps_stage_snapshot.txt 2>&1; ls "$STAGE/lib/gstreamer-1.0" >> /tmp/deps_stage_snapshot.txt 2>&1 || true
rm -rf "$DEST/include" "$DEST/lib"; mkdir -p "$DEST/include" "$DEST/lib/gstreamer-1.0"
# headers (WebKit's own link deps + the GStreamer/GLib trees WebCore compiles against)
cp -R "$STAGE/include/unicode"    "$DEST/include/"
cp "$STAGE/include/gpg-error.h"   "$DEST/include/"
cp "$STAGE/include/gcrypt.h"      "$DEST/include/"
cp "$STAGE/include/libtasn1.h"    "$DEST/include/"
cp -R "$STAGE/include/brotli"     "$DEST/include/"
cp -R "$STAGE/include/woff2"      "$DEST/include/"
for inc in glib-2.0 gio-unix-2.0 gstreamer-1.0 orc-0.4 openssl nice; do
  [ -d "$STAGE/include/$inc" ] && cp -R "$STAGE/include/$inc" "$DEST/include/"
done
mkdir -p "$DEST/lib/glib-2.0/include"
cp "$STAGE/lib/glib-2.0/include/glibconfig.h" "$DEST/lib/glib-2.0/include/"
# static libs
for l in libicuuc.a libicui18n.a libicudata.a \
         libgpg-error.a libgcrypt.a libtasn1.a \
         libbrotlicommon.a libbrotlidec.a libbrotlienc.a libwoff2dec.a; do
  cp "$STAGE/lib/$l" "$DEST/lib/"
done
# shared dylibs: real files only, stored under their majored names; every install name
# and inter-library reference is @rpath so the deployed runtime is relocatable.
INT=/Library/Developer/CommandLineTools/usr/bin/install_name_tool
normalize() {  # normalize <file> <rpath-to-libdir>: @rpath id + @rpath deps + LC_RPATH
  local f="$1" rp="$2" dep base
  "$INT" -id "@rpath/$(basename "$f")" "$f" || exit 1
  otool -L "$f" | awk 'NR>1 {print $1}' | { grep "^$STAGE/lib/" || true; } | while read -r dep; do
    base=$(basename "$dep")
    "$INT" -change "$dep" "@rpath/$base" "$f" || exit 1
  done
  # so each dylib's sibling @rpath dependencies resolve from its own location at load
  # time (WebCore dlopens these by absolute path, so nothing above them supplies an rpath).
  "$INT" -add_rpath "$rp" "$f" 2>/dev/null || true
}
for f in "$STAGE"/lib/*.dylib; do
  [ -L "$f" ] && continue
  base=$(basename "$f")
  out="$DEST/lib/$base"
  cp "$f" "$out"; normalize "$out" "@loader_path/../lib"
  # majored name (what LC_LOAD_DYLIBs reference, from the install name) and the
  # unversioned dev name (what the cmake imported targets link).
  major=$(basename "$(otool -D "$out" | tail -1)")
  [ "$major" != "$base" ] && [ "$major" != "${major#lib}" ] && ln -sf "$base" "$DEST/lib/$major"
  dev=$(echo "$major" | sed 's/\.[0-9][0-9]*\.dylib$/.dylib/')
  [ "$dev" != "$major" ] && ln -sf "$base" "$DEST/lib/$dev"
done
for f in "$STAGE"/lib/gstreamer-1.0/*.dylib; do
  [ -L "$f" ] && continue
  out="$DEST/lib/gstreamer-1.0/$(basename "$f")"
  cp "$f" "$out"; normalize "$out" "@loader_path/../../lib"
done

echo "==== done. deps/build: ===="
ls "$DEST/lib" | head -40; ls "$DEST/lib/gstreamer-1.0" | wc -l
