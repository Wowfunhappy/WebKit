#!/bin/bash
# Build the third-party libraries WebKit links that the 10.9 system does not provide:
#
#   ICU 74.2 (static)                   -> JSC Intl (ucfpos_*/udtitvfmt_*/... that
#                                          10.9's ICU 51 libicucore lacks)
#   libgpg-error, libgcrypt, libtasn1   -> WebCore USE(GCRYPT) WebCrypto
#   brotli (common/dec/enc)             -> WOFF2 + Brotli Content-Encoding
#   woff2 (decoder)                     -> WOFF2 web font decompression
#   libwebp 1.3.2 (static)              -> WebCore's WEBPImageDecoder (10.9's ImageIO
#                                          cannot decode WebP)
#   libavif 1.3.0 (static, on dav1d)    -> WebCore's AVIFImageDecoder (10.9's ImageIO
#                                          predates AVIF)
#   libxml2 2.13.6 (shared)             -> WebCore XML/SVG parsing, in place of 10.9's
#                                          crash-prone system libxml2 2.9.0
#   GLib + GStreamer (GLIB_VER/GST_VER)  -> the media runtime (core, plugins-base/
#     (+ codecs, OpenSSL, libnice, ...)     good/bad, gst-libav on FFmpeg 7.1.2 with
#                                          dav1d AV1 decode, libvpx VP8/VP9) that
#                                          MediaPlayerPrivateGStreamer drives; built
#                                          shared with @rpath install names
#
# Built with the in-tree clang-22 / 10.9 toolchain. Output lands in
# MavericksSupport/deps/build/{include,lib,bin} -- a gitignored artifact this script
# regenerates. lib/ holds the static link libs plus the whole shared media runtime
# (with lib/gstreamer-1.0 plugins); bin/ holds gst-inspect-1.0/gst-launch-1.0 for
# on-box verification. Source tarballs cache in a gitignored dir next to this script.
#
# Everything here compiles against the modern SDK with deployment target 10.9 (SDKROOT
# below is clang's default -isysroot), so every libc symbol that postdates 10.9
# (openat/utimensat/fstatat$INODE64/getentropy/...) is a weak import that binds NULL on
# 10.9 and crashes on first call. The one exception is the gap archive, compiled against
# the REAL 10.9 SDK (-isysroot /) because only those headers emit the inode-ABI symbol
# spellings 64-bit callers reference; it force-loads into every media dylib, so those
# symbols resolve DEFINED at link time instead. A fail-fast gate at the end proves the
# shipped runtime resolves completely on this 10.9 host (see "fail-fast gate").
#
# Usage: MavericksSupport/deps/build_deps.sh [--clean]   (or via MavericksSupport/bootstrap.sh)
#
# Sources, build trees and the install prefix persist in a gitignored tree beside this script, so a
# rerun extracts and configures nothing it already has and each package's build system picks up where
# it left off. --clean discards that tree (the tarball and ccache caches are elsewhere and survive).
set -euo pipefail
# NB: the 10.9 system bash (3.2) does NOT abort when a ( ... ) section subshell fails,
# even under set -e / trap ERR -- hence the explicit `|| exit 1` on every section.

CLEAN=""
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *) echo "usage: build_deps.sh [--clean]" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"                   # repo root
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"
CMAKE="${MAVERICKS_CMAKE:-$REPO/MavericksSupport/toolchain/build/cmake/bin/cmake}"
NINJA="${MAVERICKS_NINJA:-$REPO/MavericksSupport/toolchain/build/ninja/bin/ninja}"
NASM="${MAVERICKS_NASM:-$REPO/MavericksSupport/toolchain/build/nasm/bin/nasm}"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"

# The media-runtime versions, which WebKit's build also states: OptionsMacGStreamer.cmake
# sets GSTREAMER_VERSION/GLIB_VERSION for the upstream version checks in
# Source/WebCore/platform/GStreamer.cmake and the GStreamer sources. The gate below holds
# the two in step -- a bump here that skips the CMake side compiles WebKit against version
# numbers the runtime does not have.
GST_VER=1.28.5
GLIB_VER=2.80.5
GSTCMAKE="$REPO/Source/cmake/OptionsMacGStreamer.cmake"
for pair in "GSTREAMER_VERSION:$GST_VER" "GLIB_VERSION:$GLIB_VER"; do
  var=${pair%%:*}; want=${pair#*:}
  got=$(sed -n "s/^set($var \"\\(.*\\)\")\$/\\1/p" "$GSTCMAKE")
  if [ "$got" != "$want" ]; then
    echo "FATAL: $GSTCMAKE sets $var \"$got\"; this script builds $want." >&2
    echo "       Update the CMake side, then re-run." >&2
    exit 1
  fi
done

# glib's libffi wrap tracks the meson-ports "meson" BRANCH; this pins it to an exact
# commit so the build is reproducible (update deliberately, with a rebuild).
LIBFFI_REV=83d0cfd00d7d37af4b4349511d29f1f0512621b3

# The in-tree clang ships the libc++ dylibs but not its headers; those live in the SDK.
# clang on Darwin reads SDKROOT as the default -isysroot, so this puts <memory>/<string>
# (and the system frameworks/headers) on the search path for every sub-build below.
export SDKROOT="$SDK"

# /usr/bin/make, gnumake, ar, etc. are xcode-select shims; when xcode-select points at
# an Xcode.app whose Developer dir lacks the CLI tools (Xcode 6.2), every shim errors
# with "unable to find utility". Prefer the CommandLineTools binaries directly so this
# script is independent of the machine's current xcode-select state. The in-tree ninja
# and nasm dirs join the PATH for meson and the assembly-heavy codec builds.
export PATH="$(dirname "$NASM"):$(dirname "$NINJA"):/Library/Developer/CommandLineTools/usr/bin:$PATH"
# Same reason, for the sub-builds that reach a tool through `xcrun` rather than PATH (libavif's
# static-library merge runs `xcrun libtool`). xcrun resolves against DEVELOPER_DIR, and with an
# Xcode selected it first tries to read SDKROOT as an SDK NAME, fails on this absolute path, and
# then reports the utility itself as missing. Pointing it at CommandLineTools resolves both.
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

DEST="$HERE/build"                                 # gitignored artifact: include/ + lib/ + bin/ + ccache/
# The build trees, the tools they need and the prefix they install into, kept between runs (gitignored)
# so a rerun is incremental. That is what makes an edit to a gap-archive source a relink of the media
# runtime rather than a rebuild of it: every object below is unchanged, only the archive force-loaded
# into them moved.
SCRATCH="$HERE/.build-tree"
# Tarballs cache in a persistent (gitignored) dir so a rerun after a mid-script failure
# does not re-download everything.
SRC="$HERE/.tarball-cache"
STAGE="$SCRATCH/install"                            # full autotools install prefix
mkdir -p "$SCRATCH"

# One run owns the tree, and it holds the lock before it reads or discards anything in it.
LOCK="$SCRATCH/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    HOLDER="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
        echo "FATAL: another build_deps.sh holds $LOCK (pid $HOLDER)." >&2
        exit 1
    fi
    echo "### taking over $LOCK from a run that is gone"
    rm -rf "$LOCK"; mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# The collect step at the end replaces deps/build/{include,lib,bin}, which every WebKit link reads.
# Candidates come from ps -axo pid=,command=, which lists every process with its full command line:
# those whose command ends in a build.sh, resolved below against this checkout's.
WEBKIT_BUILD="$(cd "$REPO/MavericksSupport" && pwd -P)/build.sh"
_webkit_build_pids() {
    local p tok cwd
    for p in $(ps -axo pid=,command= | awk '$0 !~ / -c / && $NF ~ /(^|\/)build\.sh$/ { print $1 }'); do
        tok=$(ps -o command= -p "$p" 2>/dev/null | tr ' ' '\n' | grep -E '(^|/)build\.sh$' | head -1)
        [ -n "$tok" ] || continue
        case "$tok" in
            /*) ;;
            *)  cwd=$(lsof -a -d cwd -Fn -p "$p" 2>/dev/null | sed -n 's/^n//p' | head -1); tok="$cwd/$tok";;
        esac
        [ "$(cd "$(dirname "$tok")" 2>/dev/null && echo "$(pwd -P)/$(basename "$tok")")" = "$WEBKIT_BUILD" ] \
            && echo "$p"
    done
}
_refuse_under_webkit_build() {
    local pids
    pids="$(_webkit_build_pids | sort -un | tr '\n' ' ')"
    [ -n "${pids// /}" ] || return 0
    echo "FATAL: a WebKit build is running (pids: $pids) and links from $DEST." >&2
    echo "       Rerun when it is done." >&2
    exit 1
}
_refuse_under_webkit_build

if [ -n "$CLEAN" ]; then
    echo "### --clean: discarding $SCRATCH"
    find "$SCRATCH" -mindepth 1 -maxdepth 1 ! -name '.lock' -print0 | xargs -0 rm -rf
fi

# The tree holds ONE version of every package, compiled by one toolchain, in build dirs keyed by
# label and in a single install prefix, so it records the set of versions, the SDK and the compiler
# it was built from. A change to any of them is a --clean: the prefix keeps what the last run
# installed under its own soname, and every object in the tree is the old compiler's.
for tool in "$TC/bin/clang" "$NASM" "$CMAKE" "$NINJA"; do
    [ -x "$tool" ] || { echo "FATAL: no $tool; run MavericksSupport/bootstrap.sh." >&2; exit 1; }
done
VERSION_SET="$( { grep -oE 'https://[^ ")]+' "${BASH_SOURCE[0]}"
                  grep -E '^(GST_VER|GLIB_VER|LIBFFI_REV)=' "${BASH_SOURCE[0]}"
                  printf '%s\n' "$SDK" "$TC"
                  "$TC/bin/clang" --version | head -1
                  "$NASM" -v
                  "$CMAKE" --version | head -1
                  "$NINJA" --version; } \
                | sort -u | /usr/bin/shasum -a 256 | awk '{ print $1 }')"
if [ -f "$SCRATCH/.version-set" ] && [ "$(cat "$SCRATCH/.version-set")" != "$VERSION_SET" ]; then
    echo "FATAL: $SCRATCH was built from other package versions, another compiler or another SDK," >&2
    echo "       and its install prefix still holds what they produced. Rerun with --clean." >&2
    exit 1
fi
echo "$VERSION_SET" > "$SCRATCH/.version-set"

# Per-run scratch: the gates below read whatever they find here, so it starts empty every time.
RUN="$SCRATCH/run"
rm -rf "$RUN"; mkdir -p "$RUN"

# ccache for the dependency builds. It gets its OWN cache, separate from the WebKit build's
# (WebKitBuild/ccache, ~20 GB): these are third-party sources that change only when a version here is
# bumped, so they neither need nor deserve room in the cache the WebKit tree churns through, and
# keeping them apart means a WebKit-side eviction storm cannot throw away a GStreamer rebuild's worth
# of objects (or the other way round). 1 GB holds the whole dependency set with room to spare. It sits
# in build/, so it is gitignored with the rest of the artifacts and a normal rerun keeps it (the collect
# step below only clears build/{include,lib,bin}).
#
# CCACHE_BASEDIR rewrites absolute paths under the build tree to relative and CCACHE_NOHASHDIR keeps
# the build directory out of the hash, so the cache still answers when the tree moves with the
# checkout.
CCACHE="${MAVERICKS_CCACHE:-$REPO/MavericksSupport/toolchain/build/ccache/bin/ccache}"
if [ -x "$CCACHE" ]; then
    export CCACHE_DIR="$DEST/ccache"
    export CCACHE_BASEDIR="$SCRATCH"
    export CCACHE_NOHASHDIR=1
    mkdir -p "$CCACHE_DIR"
    "$CCACHE" --max-size=1G > /dev/null || exit 1
else
    echo "### no ccache at $CCACHE — building the deps uncached"
    CCACHE=""
fi

# The bare compiler paths, for the sub-builds that need a single executable (CMake takes the launcher
# separately); everything else gets the ccache-prefixed form below, which autotools, meson and a
# direct "$CXX …" invocation all handle.
CC_BIN="$TC/bin/clang"
CXX_BIN="$TC/bin/clang++"
export CC="${CCACHE:+$CCACHE }$CC_BIN"
export CXX="${CCACHE:+$CCACHE }$CXX_BIN"
# meson probes objc separately; without these it picks up the CommandLineTools clang,
# which cannot read the modern SDK's .tbd stubs ("library not found for -lSystem").
export OBJC="$CC"
export OBJCXX="$CXX"
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

INT=/Library/Developer/CommandLineTools/usr/bin/install_name_tool
NMBIN=/Library/Developer/CommandLineTools/usr/bin/nm

# The clang-22 toolchain's clang.cfg/clang++.cfg add a default link set (libc++/
# objc/frameworks). That is correct for building WebKit but breaks autotools/gnulib
# feature probes: the auto-linked archives make AC_CHECK_FUNC/header-generation
# misbehave (libgcrypt decides getpid/clock are "missing" and compiles #error stubs;
# gnulib leaks raw typedefs into the Makefile -> /bin/sh syntax error).
#
# So the autotools deps (libgpg-error/libgcrypt/libtasn1) compile with a VANILLA
# clang (--no-default-config): the same 10.9-targeting compiler against the same SDK,
# minus that auto-linked set, so the probes measure the compiler rather than the config.
# The resulting .a is pure object code; the polyfill that resolves any post-10.9 symbol
# is linked later at WebKit link time.
VBIN="$SCRATCH/vanilla-bin"
mkdir -p "$VBIN"
# -Wno-implicit-function-declaration / -Wno-implicit-int: pre-C99 constructs that are
# hard errors in clang >= 16 (e.g. libgcrypt's bench-slope.c calls gettimeofday
# implicitly); relaxing them is the standard way to build old autotools C with new clang.
LENIENT='-Wno-implicit-function-declaration -Wno-implicit-int'
# These go through ccache too (see the cache setup above); "$CCACHE" is empty when there is none,
# which leaves the exec line exactly as it was.
printf '#!/bin/sh\nexec %s "%s/bin/clang" --no-default-config %s "$@"\n'   "$CCACHE" "$TC" "$LENIENT" > "$VBIN/cc";  chmod +x "$VBIN/cc"
printf '#!/bin/sh\nexec %s "%s/bin/clang++" --no-default-config %s "$@"\n' "$CCACHE" "$TC" "$LENIENT" > "$VBIN/cxx"; chmod +x "$VBIN/cxx"
CC_VANILLA="$VBIN/cc"
CXX_VANILLA="$VBIN/cxx"

mkdir -p "$SRC" "$STAGE" "$DEST/include" "$DEST/lib"

# fetch <url> <dest-file>. Lands via .part so an interrupted transfer cannot leave a truncated
# file at the cache path, which get() would then trust forever.
fetch() { curl -fsSL -m 600 -o "$2.part" "$1" && mv "$2.part" "$2"; }

# fetch_cached <url> <dest>: fetch into the tarball cache and copy from there, so a rerun
# reuses it. For the pinned subproject sources below, whose hosts rate-limit a repeated run.
fetch_cached() {
  local url="$1" dest="$2" f
  # Keyed by the URL, so bumping a pinned revision fetches afresh rather than reusing an
  # archive saved under the same destination name.
  f="$SRC/$(printf '%s' "$url" | shasum | cut -c1-12)-$(basename "$dest")"
  [ -f "$f" ] || ( echo "download $(basename "$dest")" >&2 && fetch "$url" "$f" ) || return 1
  cp "$f" "$dest"
}

# recipe_key <line>: what the package around <line> is built from -- its own section of this script
# (from its ==== banner to the next one, so its URL, its patches by name and its configure and build
# commands are all in it), the content of every patch it names, the ambient compile flags, and the
# values behind the shared setting names the section carries. The stamps below hold a build dir to
# this key.
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
recipe_key() {
  local start end section
  start=$(awk -v n="$1" 'NR <= n && /^echo "==== /{ s = NR } END { print s + 0 }' "$SELF")
  end=$(awk -v n="$start" 'NR > n && /^echo "==== /{ print NR - 1; exit } END { print NR }' "$SELF" | head -1)
  section=$(sed -n "${start},${end}p" "$SELF")
  { printf '%s\n' "$section"
    printf '%s\n' "$section" | { grep -oE 'patches/[A-Za-z0-9._-]+\.patch' || true; } | sort -u \
      | while read -r p; do /usr/bin/shasum -a 256 "$HERE/$p"; done
    printf '%s\n' "$CFLAGS" "$CXXFLAGS" "$OBJCFLAGS" "$LDFLAGS"
    # A setting a section reads by name, hashed for the sections that name it. Two are reached
    # through another name: the vanilla compiler wrappers carry $LENIENT, and "$MESON" is the pin.
    case "$section" in *'$GSTOPTS'*)          printf 'GSTOPTS=%s\n'   "${GSTOPTS:-}";; esac
    case "$section" in *_VANILLA*)            printf 'LENIENT=%s\n'   "${LENIENT:-}";; esac
    case "$section" in *'"$MESON"'*)          printf 'MESON_PIN=%s\n' "${MESON_PIN:-}";; esac
  } | /usr/bin/shasum -a 256 | awk '{ print $1 }'
}

# get <url> <label>: download the tarball (once) and extract it, echoing the build
# dir. To update a library, change its version in the URL on its line below.
# A dir prepared from this recipe is handed back as it stands; anything else -- a version bump, an
# edited patch or flag, an interrupted configure -- is extracted afresh.
get() {
  local url="$1" label="$2" f d key; f="$SRC/$(basename "$url")"; d="$SCRATCH/build-$label"
  key="$(recipe_key "${BASH_LINENO[0]}")"
  # NB: this function's stdout is captured by the caller ($(get ...)) as the build dir,
  # so the progress line must go to stderr or it corrupts the returned path.
  [ -f "$f" ] || ( echo "download $(basename "$url")" >&2 && fetch "$url" "$f" )
  if [ -f "$d/.prepared" ] && [ "$(cat "$d/.recipe" 2>/dev/null)" = "$key" ]; then
    echo "$d"; return 0
  fi
  rm -rf "${d:?}"; mkdir -p "$d"
  tar xf "$f" -C "$d" --strip-components=1
  printf '%s\n' "$key" > "$d/.recipe"
  echo "$d"
}

# prepare <dir> / prepared <dir>: the steps a build dir takes once -- patches, subproject downloads,
# configure -- around the compile and install, which every run repeats so a relink reaches every
# package. Meson refuses a second setup outright; the rest is repeated work. The stamp lands only
# once they have all succeeded, so an interrupted prepare re-extracts.
prepare()  { [ ! -f "$1/.prepared" ]; }
prepared() { : > "$1/.prepared"; }

# built <label> <product> / finished <label> <dir>: the whole-package skip, for the static libraries
# and the build tools. They are built before the force_load below reaches any link, so no archive
# change can invalidate one: once its product is in the tree the package is done for this recipe,
# and its build dir -- ICU's is the largest here -- is dropped. <product> is a path within the tree.
built() {
  [ -e "$SCRATCH/$2" ] || return 1
  [ "$(cat "$SCRATCH/stamps/$1" 2>/dev/null)" = "$(recipe_key "${BASH_LINENO[0]}")" ] || return 1
  echo "  already built"
}
finished() {
  mkdir -p "$SCRATCH/stamps" && recipe_key "${BASH_LINENO[0]}" > "$SCRATCH/stamps/$1" && rm -rf "${2:?}"
}

echo "==== ICU 74.2 ===="
# ICU is C++ and its build tools (makeconv/genrb) link C++ iostreams, so it uses the
# FULL clang wrapper (clang-22's libc++), not the vanilla one. --disable-renaming
# emits UNVERSIONED symbols (ucfpos_open, not ucfpos_open_74) to match WebKit's
# U_DISABLE_RENAMING=1; without it JSC's Intl symbols stay unresolved.
u=https://github.com/unicode-org/icu/releases/download/release-74-2/icu4c-74_2-src.tgz
if ! built icu install/lib/libicuuc.a; then
    d=$(get "$u" icu)
    ( cd "$d/source" \
      && CXXFLAGS="$CXXFLAGS -std=c++17" ./configure --prefix="$STAGE" \
           --enable-static --disable-shared --disable-renaming \
           --disable-samples --disable-tests --disable-extras --disable-icuio --disable-layoutex \
      && make -j2 && make install ) || exit 1
    finished icu "$d"
fi

echo "==== libgpg-error ===="
u=https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.51.tar.bz2
if ! built gpgerror install/lib/libgpg-error.a; then
    d=$(get "$u" gpgerror)
    ( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
        --enable-static --disable-doc --disable-tests --disable-languages \
      && make -j2 && make install ) || exit 1
    finished gpgerror "$d"
fi

echo "==== libgcrypt ===="
u=https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2
# --disable-asm: libgcrypt's configure accepts its amd64 MPI assembly under the vanilla clang
# wrapper, but the .S objects never reach the archive, so every C reference to them dangles at
# link time. Measured with the flag removed:
#   ld64.lld: error: undefined symbol: _gcry_mpih_lshift   (ec.o, mpi-bit.o)
#   ld64.lld: error: undefined symbol: _gcry_mpih_mul_1    (mpi-mul.o, mpih-mul.o)
#   ld64.lld: error: undefined symbol: _gcry_mpih_submul_1 (mpih-div.o)
# libgcrypt offers no per-implementation switch, so this is all-or-nothing. The cost is the
# pure-C MPI path for WebCrypto; restoring the assembly means finding why configure's choice and
# the build disagree, which is a change of its own.
if ! built gcrypt install/lib/libgcrypt.a; then
    d=$(get "$u" gcrypt)
    ( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
        --enable-static --disable-doc --disable-asm --with-libgpg-error-prefix="$STAGE" \
      && make -j2 && make install ) || exit 1
    finished gcrypt "$d"
fi

echo "==== libtasn1 ===="
u=https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz
if ! built tasn1 install/lib/libtasn1.a; then
    d=$(get "$u" tasn1)
    ( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
        --enable-static --disable-doc \
      && make -j2 && make install ) || exit 1
    finished tasn1 "$d"
fi

echo "==== brotli ===="
u=https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz
if ! built brotli install/lib/libbrotlidec.a; then
    d=$(get "$u" brotli)
    ( cd "$d" && mkdir -p out && cd out \
      && "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
           -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
           -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
           ${CCACHE:+-DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE"} \
           -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
           -DCMAKE_INSTALL_PREFIX="$STAGE" .. \
      && "$NINJA" -j2 && "$NINJA" install ) || exit 1
    finished brotli "$d"
fi

echo "==== woff2 (decoder) ===="
u=https://github.com/google/woff2/archive/refs/tags/v1.0.2.tar.gz
if ! built woff2 install/lib/libwoff2dec.a; then
    d=$(get "$u" woff2)
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
    finished woff2 "$d"
fi

echo "==== libwebp 1.3.2 ===="
# WebCore's own WEBPImageDecoder (USE_WEBP): 10.9's ImageIO cannot decode WebP, and the
# format is now ubiquitous. Only the decode side is used -- libwebp.a (decoder + the
# encoder objects that come with it), libwebpdemux.a for animated WebP, and libsharpyuv.a,
# which libwebp.a references. The command-line tools are off: they want libpng/libjpeg/
# giflib, none of which this build has or WebKit needs.
u=https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.3.2.tar.gz
if ! built libwebp install/lib/libwebp.a; then
    d=$(get "$u" libwebp)
    ( cd "$d" && mkdir -p out && cd out \
      && "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
           -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
           -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
           ${CCACHE:+-DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE"} \
           -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
           -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
           -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
           -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
           -DCMAKE_INSTALL_PREFIX="$STAGE" .. \
      && "$NINJA" -j2 && "$NINJA" install ) || exit 1
    finished libwebp "$d"
fi

# ============================ GStreamer media runtime ============================
# GLib + GStreamer (core, plugins-base/good/bad, gst-libav on FFmpeg) and their
# codec/transport libraries, all shared dylibs targeting 10.9. Meson drives most of
# these; the build tools it needs (meson itself, pkgconf, bison >= 2.4) build first
# since 10.9 ships none of them.

MESONENV="$SCRATCH/mesonenv"
TOOLS="$SCRATCH/tools"
MESON="$MESONENV/bin/meson"
# The venv carries the pin it was built from, so changing it builds a new one -- and reaches every
# meson package's recipe key, whose setup step is the pinned meson's.
MESON_PIN="meson==1.5.2 packaging"
if [ ! -x "$MESON" ] || [ "$(cat "$MESONENV/.pin" 2>/dev/null)" != "$MESON_PIN" ]; then
    rm -rf "$MESONENV"
    /usr/local/bin/python3 -m venv "$MESONENV"
    "$MESONENV/bin/pip" -q install $MESON_PIN
    printf '%s\n' "$MESON_PIN" > "$MESONENV/.pin"
fi
export PATH="$STAGE/bin:$TOOLS/bin:$MESONENV/bin:$PATH"
export PKG_CONFIG="$TOOLS/bin/pkg-config"
export PKG_CONFIG_PATH="$STAGE/lib/pkgconfig"

echo "==== pkgconf ===="
u=https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz
if ! built pkgconf tools/bin/pkgconf; then
    d=$(get "$u" pkgconf)
    ( cd "$d" && ./configure -q --prefix="$TOOLS" \
      && make -s -j2 && make -s install && ln -sf pkgconf "$TOOLS/bin/pkg-config" ) || exit 1
    finished pkgconf "$d"
fi

echo "==== bison ===="
u=https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz
if ! built bison tools/bin/bison; then
    d=$(get "$u" bison)
    ( cd "$d" && CC="$CC_VANILLA" ./configure -q --prefix="$TOOLS" > /dev/null \
      && make -s -j2 && make -s install ) || exit 1
    finished bison "$d"
fi

echo "==== 10.9 gap archive ===="
# The media dylibs below compile against the modern SDK, so every libc/LaunchServices
# symbol that postdates 10.9 is a weak import that binds NULL on 10.9 and crashes on
# first call. This archive supplies real definitions from the project's own
# polyfill sources (the same objects libpolyfill uses for WebKit),
# compiled against the REAL 10.9 SDK (-isysroot /): its headers emit the inode-ABI
# symbol spellings 64-bit callers reference (_fstatat$INODE64, _fdopendir$INODE64, ...).
#
# -Wl,-force_load makes every member a regular object in every link, and object-file
# definitions always beat dylib (SDK .tbd) exports in ld64 resolution -- so the gap
# functions link DEFINED, order-independent of -framework/-l flags. -fvisibility=hidden
# keeps the definitions out of each dylib's export table (private copies, no shadowing
# of anything the loader resolves; cf. the shadow gates in polyfill/build-polyfill.sh).
#
# Sources, named one by one rather than globbed: each is force-loaded into every deployed
# media binary, so adding one is a decision about ~200 dylibs and wants to be visible here.
# Most symbols below are a pure gap on 10.9; a few are deliberate OVERRIDES of a function 10.9 has,
# named in GAP_REPLACES. The shadow gate at the end of this section holds both halves to this
# host's answer: an undeclared symbol 10.9 already provides fails the build.
#
# From polyfill/polyfills/shared (plain C, so the builds with no polyfill registry compile the same
# source WebKit does; the tree carries more than this needs, hence the list):
#   time            clock_gettime/clock_gettime_nsec_np/timespec_get, mach_*_time
#   atcalls         openat + the *at() family (via per-thread chdir emulation)
#   utimensat       utimensat/futimens
#   fdopendir       fdopendir$INODE64 and friends
#   dirfuncs_compat internal opendir/readdir helpers for fdopendir
#   statxx          fstatat/fstatat$INODE64/fstatat64
#   getentropy      getentropy
#   pthread_chdir   __mpls_best_fchdir closure for atcalls (private helpers)
#   os_unfair_lock  os_unfair_lock_lock/trylock/unlock/assert_owner/assert_not_owner (10.12+),
#                   os_unfair_lock_lock_with_flags/_with_options (10.15+)
#   mkostemp            mkostemp/mkostemps
#   os_version          _availability_version_check (@available lowering; lld requires a
#                       definition for compiler-rt's weak-import reference)
#   aligned_alloc       C11 aligned_alloc (10.15+)
#   ccrandom            CCRandomGenerateBytes (10.10+)
#   cv_colorimetry      the CoreVideo wide-gamut/HDR tags applemedia references (10.11/10.13+)
#   launchservices      the two LaunchServices lookups GLib's gosxappinfo calls (10.10+)
#   videotoolbox        VTIsHardwareDecodeSupported, which applemedia's vtdec calls
#                       unguarded from its caps query (10.13+)
#   pthread_jit         pthread_jit_write_protect_np/_supported_np (11.0+), weak-imported
#                       from the modern SDK's pthread.h
#   mach_timebase_info  a deliberate OVERRIDE of a function 10.9 has: its libsystem_kernel entry
#                       is the bare trap, and GLib's g_get_monotonic_time (every GStreamer clock
#                       read) calls it before each mach_absolute_time; this reads the trap once and
#                       answers from a cache
#   audiounit_max_frames  a deliberate OVERRIDE of AudioUnitInitialize: 10.9 leaves an output unit's
#                       kAudioUnitProperty_MaximumFramesPerSlice at the device buffer size of the
#                       moment, so any client raising that shared size makes every later render fail
#                       with kAudioUnitErr_TooManyFramesToProcess -- silencing osxaudiosink and
#                       wedging the process on the CAMutex the failure path takes. This declares the
#                       top of every output device's supported range and holds it there from two
#                       listeners on the unit: the unit moving to another device, and AUHAL restating
#                       the property as the device's current buffer size, which it does on every
#                       initialized unit each time any client changes that size; AudioUnitUninitialize
#                       and AudioComponentInstanceDispose come with it as the units it tracks
#
# shared/jit.c is deliberately NOT here: its mmap override is a deliberate replacement of a
# function 10.9 HAS, wanted only where a caller passes MAP_JIT -- WebKit's JIT. Nothing in this
# dependency set does (glib, gstreamer, ffmpeg and libffi contain no reference to it), so
# shadowing mmap in every media binary would be gratuitous. Its pthread_jit half, which IS a
# pure gap and IS weak-imported here, lives in shared/pthread_jit.c and is listed above.
SHARED="$REPO/MavericksSupport/polyfill/polyfills/shared"
GAPDIR="$SCRATCH/gap"
# The archive persists between runs -- its mtime is what the coverage gate before the collect step
# reads. The objects do not, so a source dropped from GAP_SHARED leaves nothing for `ar` to pick up.
GAPOBJ="$GAPDIR/obj"
mkdir -p "$GAPDIR"; rm -rf "$GAPOBJ"; mkdir -p "$GAPOBJ"
GAP_SHARED="time atcalls utimensat fdopendir dirfuncs_compat statxx getentropy pthread_chdir os_unfair_lock mkostemp os_version aligned_alloc ccrandom cv_colorimetry launchservices videotoolbox pthread_jit mach_timebase_info audiounit_max_frames"
GAPCFLAGS="--no-default-config -isysroot / -mmacosx-version-min=10.9 -fPIC -fvisibility=hidden -O2 -I$SHARED/include"
( for s in $GAP_SHARED; do
    "$TC/bin/clang" $GAPCFLAGS -MD -MF "$GAPOBJ/$s.d" -c "$SHARED/$s.c" -o "$GAPOBJ/$s.o" || exit 1
  done ) || exit 1
GAP_A="$GAPDIR/libmavericks_gap.a"
# llvm-ar is deterministic, so unchanged sources produce the same archive byte for byte. Writing the
# file only when its bytes change makes its mtime the moment the media runtime last had to relink.
rm -f "$GAPOBJ/next.a"
( "$AR" rcs "$GAPOBJ/next.a" "$GAPOBJ"/*.o ) || exit 1
GAP_CHANGED=""
if cmp -s "$GAPOBJ/next.a" "$GAP_A"; then
    echo "  gap archive unchanged since the last run"
else
    mv "$GAPOBJ/next.a" "$GAP_A" || exit 1
    GAP_CHANGED=1
fi

# What went into the archive, for scripts/check-gap-archive-current.sh, which holds every binary
# below to this content. The -MD dependencies name the shim headers that reached the objects; those
# are gap content on the same terms as the .c files. Publication waits for the collect step at the
# end of this script, so the manifest lands with the binaries it describes.
GAP_MANIFEST="$GAPDIR/gap-sources.sha256"
( cd "$SHARED" && sed 's/\\$//' "$GAPOBJ"/*.d | tr '[:space:]' '\n' \
    | sed -n "s|^$SHARED/||p" | sort -u | xargs /usr/bin/shasum -a 256 ) > "$GAP_MANIFEST" || exit 1
GAP_SYMBOLS="$GAPDIR/gap-symbols.txt"
"$NMBIN" -g "$GAP_A" | awk '$2 ~ /^[TDSB]$/ { sub(/^_/, "", $3); print $3 }' | sort -u > "$GAP_SYMBOLS"
# The archive's own diagnostics, long enough to belong to nothing else and held in __cstring, which
# a build that strips its local symbols keeps. They identify the archive inside FFmpeg's stripped
# dylibs, where the symbol table answers nothing.
GAP_LITERALS="$GAPDIR/gap-literals.txt"
strings -a "$GAP_A" | { grep '^\[wk_polyfill\] .\{40,\}' || true; } | sort -u > "$GAP_LITERALS"
[ -s "$GAP_LITERALS" ] || { echo "  FATAL: no wk_polyfill diagnostic in the gap archive to identify it by"; exit 1; }
# The rest of the compile's inputs: the objects depend on these as much as on the sources.
GAP_BUILDINFO="$GAPDIR/gap-buildinfo.txt"
{ printf 'cflags\t%s\n' "${GAPCFLAGS//$SHARED/\$SHARED}"
  printf 'clang\t%s\n' "$("$TC/bin/clang" --version | head -1)"; } > "$GAP_BUILDINFO"
# deps/build ships two dylibs this script copies rather than links, so the force_load above never
# reaches them. The gate holds the deployed set to exactly this list.
GAP_UNLINKED="$GAPDIR/gap-unlinked.txt"
: > "$GAP_UNLINKED"

# Shadow gate. force_load makes every definition above win inside ~200 deployed dylibs with no
# forwarding to 10.9, so one written for a symbol 10.9 already provides silently replaces the working
# system one. tests/gates/shadow-present.c asks THIS machine's runtime -- dlsym on each library in
# turn, not the modern SDK's stubs and not a flat search -- which of the archive's definitions 10.9
# has, and every answer must appear in GAP_REPLACES. There is no allow file: an entry here is a
# stated intent, not an exemption, and the polyfill build holds the same sources to the same rule
# through its own registry (polyfill/build-polyfill.sh).
GAP_REPLACES="mach_timebase_info AudioUnitInitialize AudioUnitUninitialize AudioComponentInstanceDispose"
GAPGATE="$RUN/gapgate"; mkdir -p "$GAPGATE"
"$TC/bin/clang" --no-default-config -mmacosx-version-min=10.9 -o "$GAPGATE/present" \
    "$REPO/MavericksSupport/polyfill/tests/gates/shadow-present.c" || exit 1
"$NMBIN" -g "$GAP_A" 2>/dev/null | awk '$2 ~ /^[TDSB]$/ { sub(/^_/, "", $3); print $3 }' \
  | sort -u > "$GAPGATE/defined"
# The libraries a deployed media dylib's references can bind against, plus the frameworks owning the
# symbols the archive replaces.
"$GAPGATE/present" \
    /usr/lib/libSystem.B.dylib \
    /usr/lib/libobjc.A.dylib \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    /System/Library/Frameworks/CoreServices.framework/CoreServices \
    /System/Library/Frameworks/ApplicationServices.framework/ApplicationServices \
    /System/Library/Frameworks/CoreVideo.framework/CoreVideo \
    /System/Library/Frameworks/CoreMedia.framework/CoreMedia \
    /System/Library/Frameworks/VideoToolbox.framework/VideoToolbox \
    /System/Library/Frameworks/AudioToolbox.framework/AudioToolbox \
    /System/Library/Frameworks/AudioUnit.framework/AudioUnit \
    /System/Library/Frameworks/CoreAudio.framework/CoreAudio \
    < "$GAPGATE/defined" | sort -u > "$GAPGATE/on109"
printf '%s\n' $GAP_REPLACES | sort -u > "$GAPGATE/declared"
cut -f1 "$GAPGATE/on109" | sort -u > "$GAPGATE/present_names"
# An ABI-variant spelling (fdopendir$INODE64) is its own linker symbol but one C function, which is
# the name a declaration carries.
awk 'NR == FNR { declared[$0] = 1; next }
     { base = $0
       if (match($0, /\$[A-Z][A-Z0-9_]*$/)) base = substr($0, 1, RSTART - 1)
       if (!($0 in declared) && !(base in declared)) print $0 }' \
    "$GAPGATE/declared" "$GAPGATE/present_names" > "$GAPGATE/offenders"
if [ -s "$GAPGATE/offenders" ]; then
    echo "ERROR: the 10.9 gap archive defines symbols this host ALREADY provides, and nothing says so."
    echo "force_load makes the archive's definition win in every media dylib with no forwarding to 10.9:"
    while read -r symbol; do
        printf '  %-44s (10.9 has it in %s)\n' "$symbol" \
            "$(awk -F'\t' -v s="$symbol" '$1 == s { print $2 }' "$GAPGATE/on109")"
    done < "$GAPGATE/offenders"
    echo "If shadowing 10.9 is the POINT, add the name to GAP_REPLACES above; otherwise drop the source"
    echo "from GAP_SHARED and let the media dylibs bind 10.9's symbol."
    exit 1
fi
echo "  gap shadow gate: clean -- $(wc -l < "$GAPGATE/defined" | tr -d ' ') defined symbols, $(wc -l < "$GAPGATE/on109" | tr -d ' ') present on 10.9, all declared"

# Every media build below (meson via env, autotools via env, FFmpeg/OpenSSL via their
# own flag plumbing) links the gap archive.
#
# CoreFoundation rides along because force-loading pulls in every member whether the link needs it or
# not, and cv_colorimetry/launchservices/os_version are written against CF types. A configure step
# that links a bare C program -- CMake's "check for working C compiler" -- has no other reason to
# name a framework, so without this the gap archive's CF references are simply undefined and the
# compiler is reported broken.
export LDFLAGS="$LDFLAGS -Wl,-force_load,$GAP_A -framework CoreFoundation"

# carriers: NUL-separated candidate paths on stdin, one carrier path per line on stdout. A carrier is
# a Mach-O image the force_load reached, named by the archive's own diagnostics, which every
# generation of it holds.
carriers() {
  local err="$RUN/carriers.err"; : > "$err"
  { xargs -0 /usr/bin/grep -l -a -F '[wk_polyfill] ' 2>> "$err" || true; } \
    | tr '\n' '\0' \
    | { xargs -0 /usr/bin/file 2>> "$err" || true; } \
    | sed -n 's/: *Mach-O.*//p'
  [ -s "$err" ] || return 0
  echo "  FATAL: the gap-carrier scan could not read part of the tree:" >&2
  cat "$err" >&2
  return 1
}

# force_load resolves at link time and nothing below tracks what it loaded: meson and make see the
# same command line and the same archive path whatever its content. So when the content changes,
# every image built from the old one goes and each build system links it again -- the statement
# build.sh makes for libpolyfill.a and the four frameworks. The libtool archives go with them, being
# what a libtool package's make rules build and compare timestamps against. Only the build dirs are
# scanned: the archive itself lives in $GAPDIR, the install prefix holds copies the builds below
# replace, and the tools were linked before the force_load above joined LDFLAGS. The drop stands
# until the coverage gate below passes, so the next run continues one that stopped partway.
GAP_RELINK="$SCRATCH/.relink-pending"
if [ -n "$GAP_CHANGED" ] || [ -f "$GAP_RELINK" ]; then
    : > "$GAP_RELINK"
    find "$SCRATCH" \( -path "$STAGE" -o -path "$TOOLS" -o -path "$MESONENV" -o -path "$GAPDIR" \
        -o -path "$RUN" \) -prune -o -type f -print0 > "$RUN/candidates"
    carriers < "$RUN/candidates" > "$RUN/drop" || exit 1
    { tr '\0' '\n' < "$RUN/candidates" | grep '\.la$' || true; } >> "$RUN/drop"
    echo "  relinking the media runtime: dropping $(wc -l < "$RUN/drop" | tr -d ' ') images built from the archive"
    tr '\n' '\0' < "$RUN/drop" | xargs -0 rm -f
fi

echo "==== GLib $GLIB_VER ===="
# GLib's bundled subprojects come from meson wraps. The wrap-file tarballs pre-cache
# into subprojects/packagecache (meson verifies their hashes); the wrap-git ones
# land as plain directories at a pinned revision (gvdb/proxy-libintl by upstream URL,
# libffi by $LIBFFI_REV because its upstream wrap floats on a branch).
d=$(get https://download.gnome.org/sources/glib/${GLIB_VER%.*}/glib-$GLIB_VER.tar.xz glib)
if prepare "$d"; then
    ( cd "$d/subprojects" && mkdir -p packagecache && cd packagecache \
      && fetch_cached https://github.com/PhilipHazel/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.bz2 pcre2-10.42.tar.bz2 \
      && fetch_cached https://wrapdb.mesonbuild.com/v2/pcre2_10.42-2/get_patch pcre2_10.42-2_patch.zip \
      && fetch_cached https://zlib.net/fossils/zlib-1.2.11.tar.gz zlib-1.2.11.tar.gz \
      && fetch_cached https://wrapdb.mesonbuild.com/v2/zlib_1.2.11-6/get_patch zlib_1.2.11-6_patch.zip ) || exit 1
    ( cd "$d/subprojects" \
      && fetch_cached https://gitlab.gnome.org/GNOME/gvdb/-/archive/0854af0fdb6d527a8d1999835ac2c5059976c210/gvdb.tar.gz gvdb.tar.gz \
      && tar xzf gvdb.tar.gz && rm -rf gvdb && mv gvdb-0854af0* gvdb \
      && fetch_cached "https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/$LIBFFI_REV/libffi-$LIBFFI_REV.tar.gz" libffi-meson.tar.gz \
      && tar xzf libffi-meson.tar.gz && rm -rf libffi && mv "libffi-$LIBFFI_REV" libffi \
      && fetch_cached https://github.com/frida/proxy-libintl/archive/refs/tags/0.4.tar.gz proxy-libintl-0.4.tar.gz \
      && tar xzf proxy-libintl-0.4.tar.gz && rm -rf proxy-libintl && mv proxy-libintl-0.4 proxy-libintl ) || exit 1
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Ddefault_library=shared -Dbuildtype=release \
        -Dtests=false -Dglib_debug=disabled -Dman-pages=disabled -Ddocumentation=false \
        -Dintrospection=disabled > /tmp/depslog-glib-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-glib-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-glib-install.log 2>&1 ) || exit 1

echo "==== orc / ogg / vorbis / opus / flac ===="
d=$(get https://gstreamer.freedesktop.org/src/orc/orc-0.4.41.tar.xz orc)
if prepare "$d"; then
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release -Dtests=disabled \
        -Dexamples=disabled > /tmp/depslog-orc-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-orc-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-orc-install.log 2>&1 ) || exit 1
d=$(get https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz ogg)
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz vorbis)
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus)
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --disable-doc \
        --disable-extra-programs ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/flac/flac-1.4.3.tar.xz flac)
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --disable-programs \
        --disable-examples --disable-cpplibs ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1

echo "==== libvpx 1.14.1 ===="
# VP8/VP9 encode + decode for the gst vpx plugin: WebRTC sends VP8/VP9 through vpxenc,
# which gst-libav does not provide (FFmpeg carries no VP8/VP9 encoder of its own).
# darwin13 is the 10.9 target triple; nasm assembles the SIMD code from the PATH.
d=$(get https://github.com/webmproject/libvpx/archive/refs/tags/v1.14.1.tar.gz vpx)
if prepare "$d"; then
    ( cd "$d" && mkdir -p b && cd b \
      && ../configure --target=x86_64-darwin13-gcc --prefix="$STAGE" \
           --enable-shared --disable-static --enable-pic --enable-vp8 --enable-vp9 \
           --disable-examples --disable-tools --disable-docs --disable-unit-tests \
           --as=nasm \
           --extra-cflags="-isysroot $SDK -mmacosx-version-min=10.9" \
           --extra-cxxflags="-isysroot $SDK -mmacosx-version-min=10.9" > /tmp/depslog-vpx-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d/b" && make -s -j2 > /tmp/depslog-vpx-compile.log 2>&1 \
  && make -s install > /tmp/depslog-vpx-install.log 2>&1 ) || exit 1
# libvpx's makefile stamps a BARE install name (libvpx.9.dylib) instead of the staged
# path, so consumers (libgstvpx) record a bare LC_LOAD_DYLIB that normalize()'s
# "^$STAGE/lib/" rewrite never matches and 10.9 dyld can never resolve. Stamp the
# staged path here, before anything links it, so consumers record the full path and
# normalize() turns it into @rpath like every other staged dependency.
for v in "$STAGE"/lib/libvpx.*.dylib; do
  [ -L "$v" ] && continue
  "$INT" -id "$STAGE/lib/$(basename "$v")" "$v" || exit 1
done

echo "==== libxml2 2.13.6 ===="
# WebCore links this in place of the 10.9 system libxml2 2.9.0, whose __xmlRaiseError
# crashes on fatal parse errors (OptionsMac.cmake repoints LIBXML2_INCLUDE_DIR/LIBRARY
# here). Not a GStreamer dependency — it rides the same staging/collect/gate pipeline.
# Ambient CFLAGS/LDFLAGS apply: the gap archive supplies getentropy (10.12+, which
# configure detects against the modern SDK and xmlInitRandom then calls) as a DEFINED
# symbol, the same way it does for every other media dylib.
d=$(get https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.6.tar.xz libxml2)
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --without-python --without-lzma \
        > /tmp/depslog-libxml2-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 > /tmp/depslog-libxml2-compile.log 2>&1 \
  && make -s install > /tmp/depslog-libxml2-install.log 2>&1 ) || exit 1

echo "==== dav1d 1.4.3 ===="
# FFmpeg links it (--enable-libdav1d) for AV1 via the libdav1d wrapper codec, which
# gst-libav registers as avdec_libdav1d (see the libdav1d patch in the gst-libav
# section) -- the runtime's AV1 decoder, also serving libavif below.
d=$(get https://downloads.videolan.org/pub/videolan/dav1d/1.4.3/dav1d-1.4.3.tar.xz dav1d)
if prepare "$d"; then
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release \
        -Denable_tools=false -Denable_tests=false > /tmp/depslog-dav1d-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-dav1d-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-dav1d-install.log 2>&1 ) || exit 1

echo "==== libavif 1.3.0 ===="
# WebCore's AVIFImageDecoder (USE_AVIF): 10.9's ImageIO predates AVIF entirely. Decode only --
# no encoder codec is enabled, so this is the demuxer plus the AV1 decode path. It builds here
# rather than beside libwebp because it needs the dav1d above, which it finds through
# pkg-config in $STAGE. libyuv is off: it is a conversion-speed option, and its absence only
# routes avifImageYUVToRGB through libavif's own built-in conversion.
u=https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.3.0.tar.gz
if ! built libavif install/lib/libavif.a; then
    d=$(get "$u" libavif)
    ( cd "$d" && mkdir -p out && cd out \
      && "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
           -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
           -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
           ${CCACHE:+-DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE"} \
           -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
           -DPKG_CONFIG_EXECUTABLE="$PKG_CONFIG" \
           -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_LIBYUV=OFF \
           -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF -DAVIF_BUILD_EXAMPLES=OFF \
           -DAVIF_BUILD_MAN_PAGES=OFF \
           -DCMAKE_INSTALL_PREFIX="$STAGE" .. > /tmp/depslog-avif-setup.log 2>&1 \
      && "$NINJA" -j2 > /tmp/depslog-avif-compile.log 2>&1 \
      && "$NINJA" install > /tmp/depslog-avif-install.log 2>&1 ) || exit 1
    finished libavif "$d"
fi
# libavif builds happily with NO codec at all, and then every AVIF fails to decode at runtime
# with nothing said at build time. Ask the archive itself whether the dav1d codec is in it.
"$NMBIN" "$STAGE/lib/libavif.a" 2>/dev/null | grep "avifCodecCreateDav1d" > /dev/null \
  || { echo "  FATAL: libavif has no dav1d codec (avifCodecCreateDav1d absent); AVIF would decode nothing."; exit 1; }

echo "==== OpenSSL 3.0.16 ===="
# WebRTC's DTLS-SRTP and WebKit's OpenSSL::Crypto cmake target consume these.
d=$(get https://www.openssl.org/source/openssl-3.0.16.tar.gz openssl)
if prepare "$d"; then
    ( cd "$d" && ./Configure darwin64-x86_64-cc shared --prefix="$STAGE" --libdir=lib \
        no-tests -mmacosx-version-min=10.9 > /dev/null ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 > /dev/null && make -s install_sw > /dev/null ) || exit 1

echo "==== libsrtp ===="
d=$(get https://github.com/cisco/libsrtp/archive/refs/tags/v2.6.0.tar.gz srtp)
if prepare "$d"; then
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release \
        -Ddefault_library=shared > /tmp/depslog-srtp-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-srtp-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-srtp-install.log 2>&1 ) || exit 1

echo "==== webrtc-audio-processing ===="
# Echo cancellation / noise suppression for getUserMedia audio (gst's webrtcdsp).
d=$(get https://www.freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-1.3.tar.xz webrtcap)
if prepare "$d"; then
    # Pre-populate meson's packagecache from the wrap files, so the subproject sources come down here
    # -- and into the tarball cache, so a later extraction of this tree needs no network -- rather
    # than at meson-setup time. A layout change must fail loudly: a silent no-op would quietly make
    # the build depend on the network reaching meson's wrapdb instead.
    [ -d "$d/subprojects" ] || { echo "  FATAL: $d has no subprojects/ to pre-cache"; exit 1; }
    ( cd "$d/subprojects" && mkdir -p packagecache && cd packagecache \
      && for w in ../*.wrap; do
           [ -f "$w" ] || continue
           su=$(sed -n 's/^source_url *= *//p' "$w"); sf=$(sed -n 's/^source_filename *= *//p' "$w")
           pu=$(sed -n 's/^patch_url *= *//p' "$w");  pf=$(sed -n 's/^patch_filename *= *//p' "$w")
           if [ -n "$su" ] && [ ! -f "$sf" ]; then fetch_cached "$su" "$sf" || exit 1; fi
           if [ -n "$pu" ] && [ ! -f "$pf" ]; then fetch_cached "$pu" "$pf" || exit 1; fi
         done ) || { echo "  FATAL: webrtc-audio-processing wrap pre-cache failed"; exit 1; }
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release > /tmp/depslog-webrtcap-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-webrtcap-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-webrtcap-install.log 2>&1 ) || exit 1

echo "==== GStreamer $GST_VER (core) ===="
# -Dc_std=gnu11: GStreamer 1.28's project() sets c_std=gnu11,c11 (a meson fallback list),
# which add_languages('objc') propagates to objc_std; meson 1.5.2 rejects a list for
# objc_std ("Value gnu11,c11 ... is not one of the choices"). Pin c_std to the single
# value gnu11 (fully supported by clang-22) so objc_std inherits a valid single value.
GSTOPTS="-Dbuildtype=release -Dtests=disabled -Dexamples=disabled -Ddoc=disabled -Dc_std=gnu11"
# -Dtools=enabled: gst-inspect-1.0/gst-launch-1.0 deploy into deps/build/bin for
# on-box verification of the shipped runtime (webrtcbin present, plugins load).
d=$(get https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-$GST_VER.tar.xz gstcore)
if prepare "$d"; then
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled \
        -Dtools=enabled -Dbenchmarks=disabled -Dlibunwind=disabled -Ddbghelp=disabled \
        -Dbash-completion=disabled > /tmp/depslog-gstcore-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-gstcore-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-gstcore-install.log 2>&1 ) || exit 1

# The plugins named -Denabled below are the ones whose absence would break a feature this port
# ships, so a missing dependency fails the
# corresponding meson setup loudly instead of silently dropping the plugin from the
# shipped runtime.
echo "==== gst-plugins-base ===="
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-$GST_VER.tar.xz gstbase)
if prepare "$d"; then
    # urisourcebin owns the parsebin in a playbin3 pipeline, and nothing resets it
    # when a stream's media type changes mid-play, so an MSE SourceBuffer handed a clear period and then
    # an encrypted one stops at the change. This gives urisourcebin the reset decodebin3 already performs
    # on the parsebin it owns. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-base-urisourcebin-reset-parsebin-on-caps-change.patch" \
        > /tmp/depslog-gstbase-patch.log 2>&1 && patch -p1 < "$HERE/patches/gst-plugins-base-urisourcebin-reset-parsebin-on-caps-change.patch" \
        >> /tmp/depslog-gstbase-patch.log 2>&1 ) \
      || { echo "gst-plugins-base urisourcebin parsebin-reset patch failed to apply"; cat /tmp/depslog-gstbase-patch.log; exit 1; }
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled \
        -Dogg=enabled -Dvorbis=enabled -Dopus=enabled > /tmp/depslog-gstbase-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-gstbase-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-gstbase-install.log 2>&1 ) || exit 1

echo "==== gst-plugins-good ===="
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-$GST_VER.tar.xz gstgood)
if prepare "$d"; then
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS \
        -Dvpx=enabled -Dflac=enabled -Dosxaudio=enabled -Dosxvideo=enabled > /tmp/depslog-gstgood-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-gstgood-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-gstgood-install.log 2>&1 ) || exit 1

echo "==== libnice ===="
# libnice sits between gst core (its own "nice" ICE-transport gst plugin needs
# gstreamer-1.0 discoverable) and gst-plugins-bad (whose webrtc option needs nice.pc
# discoverable at setup time -- webrtcbin, libgstwebrtc and libgstwebrtcnice only
# build when libnice is already installed).
# libnice >= 0.1.23 is required by gst-plugins-bad 1.28 (gst-libs/gst/webrtc/nice).
d=$(get https://libnice.freedesktop.org/releases/libnice-0.1.23.tar.gz nice)
if prepare "$d"; then
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release -Dtests=disabled \
        -Dexamples=disabled -Dgtk_doc=disabled -Dintrospection=disabled -Dgupnp=disabled \
        -Dgstreamer=enabled -Dcrypto-library=openssl > /tmp/depslog-nice-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-nice-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-nice-install.log 2>&1 ) || exit 1

echo "==== gst-plugins-bad ===="
# sctp (WebRTC datachannels) builds from the usrsctp copy bundled in the tarball's
# ext/sctp/usrsctp -- no extra download. webp is off because the plugin has no caller: WebP
# images decode in WebCore's own WEBPImageDecoder, and this build produces no libwebpmux for
# the plugin to find.
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-$GST_VER.tar.xz gstbad)
if prepare "$d"; then
    # patch webrtcbin's over-strict remote-ICE-credential charset check so
    # base64url ufrag/pwd (Google Meet) don't fail set-remote-description. See
    # patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-ice-credential-charset.patch" \
        > /tmp/depslog-gstbad-patch.log 2>&1 && patch -p1 < "$HERE/patches/gst-plugins-bad-ice-credential-charset.patch" \
        >> /tmp/depslog-gstbad-patch.log 2>&1 ) \
      || { echo "gst-plugins-bad ICE patch failed to apply"; cat /tmp/depslog-gstbad-patch.log; exit 1; }
    # vtenc wraps its source pixel buffers around raw GstMemory without stating
    # their colorimetry, and 10.9's VideoToolbox cannot color-match an untagged source: every frame
    # fails with kVTInsufficientSourceColorDataErr (-12917), so WebRTC outbound H.264 encodes nothing.
    # This tags those buffers from the negotiated caps. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-vtenc-tag-source-colorimetry.patch" \
        > /tmp/depslog-gstbad-patch2.log 2>&1 && patch -p1 < "$HERE/patches/gst-plugins-bad-vtenc-tag-source-colorimetry.patch" \
        >> /tmp/depslog-gstbad-patch2.log 2>&1 ) \
      || { echo "gst-plugins-bad vtenc colorimetry patch failed to apply"; cat /tmp/depslog-gstbad-patch2.log; exit 1; }
    # vtdec_hw advertises codecs the machine cannot hardware-decode; the -8973
    # session failure then lands outside decodebin3's candidate window and kills playbin3 (MSE)
    # pipelines that avdec could have played. This gates its getcaps on a per-codec RequireHardware
    # session probe. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-vtdec-hw-hardware-caps-probe.patch" \
        > /tmp/depslog-gstbad-patch3.log 2>&1 && patch -p1 < "$HERE/patches/gst-plugins-bad-vtdec-hw-hardware-caps-probe.patch" \
        >> /tmp/depslog-gstbad-patch3.log 2>&1 ) \
      || { echo "gst-plugins-bad vtdec_hw caps-probe patch failed to apply"; cat /tmp/depslog-gstbad-patch3.log; exit 1; }
    # vtdec's static sink template advertises VP9, AV1 and HEVC, which 10.9's
    # VideoToolbox has no decoder for on any hardware; the template is what WebKit's registry
    # scanner answers isTypeSupported/MediaCapabilities from, and powerEfficient follows the matched
    # factory's Hardware klass, so the claim routes sites onto streams this machine decodes in
    # software or not at all. This removes the three entries. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-vtdec-109-sink-template-codecs.patch" \
        > /tmp/depslog-gstbad-patch4.log 2>&1 && patch -p1 < "$HERE/patches/gst-plugins-bad-vtdec-109-sink-template-codecs.patch" \
        >> /tmp/depslog-gstbad-patch4.log 2>&1 ) \
      || { echo "gst-plugins-bad vtdec sink-template patch failed to apply"; cat /tmp/depslog-gstbad-patch4.log; exit 1; }
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled \
        -Dwebrtc=enabled -Dwebrtcdsp=enabled -Ddtls=enabled -Dsrtp=enabled -Dsctp=enabled \
        -Dapplemedia=enabled -Dwebp=disabled > /tmp/depslog-gstbad-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-gstbad-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-gstbad-install.log 2>&1 ) || exit 1

echo "==== FFmpeg 7.1.2 ===="
# Apple-framework codepaths stay off: decoding runs through FFmpeg's own codecs so
# behavior is identical on every 10.9 install. libdav1d supplies AV1 inside FFmpeg,
# surfaced as gst-libav's avdec_libdav1d (see the dav1d note above).
# FFmpeg's configure ignores the LDFLAGS environment, so the gap archive rides in
# --extra-ldflags here.
d=$(get https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz ffmpeg)
if prepare "$d"; then
    ( cd "$d" && ./configure --cc="$CC" --prefix="$STAGE" --install-name-dir='@rpath' \
        --enable-shared --disable-static --disable-programs --disable-doc --disable-debug \
        --disable-audiotoolbox --disable-videotoolbox --disable-securetransport \
        --disable-iconv --disable-lzma --disable-sdl2 --disable-xlib --disable-coreimage \
        --enable-libdav1d \
        --x86asmexe="$NASM" \
        --extra-cflags="-mmacosx-version-min=10.9" \
        --extra-ldflags="-mmacosx-version-min=10.9 -Wl,-force_load,$GAP_A" > /dev/null ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 > /dev/null && make -s install > /dev/null ) || exit 1

echo "==== gst-libav ===="
d=$(get https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-$GST_VER.tar.xz gstlibav)
if prepare "$d"; then
    # gst-libav skips FFmpeg's external-library ("lib*") decoders on the
    # premise that native GStreamer elements cover them; this runtime has no native AV1
    # decoder, so that rule would leave video/x-av1 with a parser and no decoder. The patch
    # admits the libdav1d wrapper (the dav1d built above, inside FFmpeg) as avdec_libdav1d.
    # See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-libav-register-libdav1d.patch" \
        > /tmp/depslog-gstlibav-patch.log 2>&1 && patch -p1 < "$HERE/patches/gst-libav-register-libdav1d.patch" \
        >> /tmp/depslog-gstlibav-patch.log 2>&1 ) \
      || { echo "gst-libav libdav1d patch failed to apply"; cat /tmp/depslog-gstlibav-patch.log; exit 1; }
    # gst-libav's option set has no "examples"; it takes the shared options minus that one.
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release -Dtests=disabled \
        -Ddoc=disabled > /tmp/depslog-gstlibav-setup.log 2>&1 ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 > /tmp/depslog-gstlibav-compile.log 2>&1 \
  && "$MESON" install -C b > /tmp/depslog-gstlibav-install.log 2>&1 ) || exit 1

echo "==== gap archive coverage ===="
# Every image the archive force-loads into was linked after the archive itself: the drop above took
# the ones built from an older generation, and the builds since linked them again. An older one is a
# build that did not relink.
find "$STAGE" -type f -print0 > "$RUN/staged"
carriers < "$RUN/staged" > "$RUN/linked" || exit 1
[ -s "$RUN/linked" ] || { echo "  FATAL: nothing under $STAGE carries the gap archive"; exit 1; }
: > "$RUN/stale"
while read -r f; do [ "$f" -nt "$GAP_A" ] || echo "$f" >> "$RUN/stale"; done < "$RUN/linked"
if [ -s "$RUN/stale" ]; then
    echo "  FATAL: linked before the gap archive they carry:"
    sed "s|^$STAGE/|    |" "$RUN/stale"
    exit 1
fi
rm -f "$GAP_RELINK"
echo "  ok: all $(wc -l < "$RUN/linked" | tr -d ' ') images carrying the archive postdate it"

echo "==== collect into deps/build ===="
# Asked again immediately before the collect step replaces the tree those links read from.
_refuse_under_webkit_build
rm -rf "$DEST/include" "$DEST/lib" "$DEST/bin"
mkdir -p "$DEST/include" "$DEST/lib/gstreamer-1.0" "$DEST/bin"
# headers (WebKit's own link deps + the GStreamer/GLib trees WebCore compiles against)
cp -R "$STAGE/include/unicode"    "$DEST/include/"
cp "$STAGE/include/gpg-error.h"   "$DEST/include/"
cp "$STAGE/include/gcrypt.h"      "$DEST/include/"
cp "$STAGE/include/libtasn1.h"    "$DEST/include/"
cp -R "$STAGE/include/brotli"     "$DEST/include/"
cp -R "$STAGE/include/woff2"      "$DEST/include/"
cp -R "$STAGE/include/webp"       "$DEST/include/"
cp -R "$STAGE/include/avif"       "$DEST/include/"
# libxml2 headers: WebCore compiles against these. OptionsMac.cmake points
# LIBXML2_INCLUDE_DIR here so the headers match the 2.13 dylib deployed alongside them.
cp -R "$STAGE/include/libxml2"    "$DEST/include/"
for inc in glib-2.0 gio-unix-2.0 gstreamer-1.0 orc-0.4 openssl nice; do
  [ -d "$STAGE/include/$inc" ] && cp -R "$STAGE/include/$inc" "$DEST/include/"
done
mkdir -p "$DEST/lib/glib-2.0/include"
cp "$STAGE/lib/glib-2.0/include/glibconfig.h" "$DEST/lib/glib-2.0/include/"
# static libs
for l in libicuuc.a libicui18n.a libicudata.a \
         libgpg-error.a libgcrypt.a libtasn1.a \
         libbrotlicommon.a libbrotlidec.a libbrotlienc.a libwoff2dec.a \
         libwebp.a libwebpdemux.a libsharpyuv.a libavif.a; do
  cp "$STAGE/lib/$l" "$DEST/lib/"
done

# Nothing here links 10.9's /usr/lib/libc++.1.dylib: it predates the C++17 symbols this C++
# needs, and one process must not carry two C++ runtimes. clang++.cfg points every C++ link at
# the toolchain's own (@rpath/libc++.1.dylib and friends) -- the same runtime WebKit's own
# frameworks bind, so a loaded WebKit and its media stack share one copy. The pair stages
# here so the collect loop deploys it next to them and the runtime is self-contained
# -- the deployed set loads with the toolchain directory absent. The UNWINDER is not
# copied: a process must have exactly one _Unwind_* implementation and system frames
# always drive /usr/lib/system/libunwind.dylib, so every @rpath/libunwind.1.dylib
# reference is bound to the system unwinder instead (fixed up in the collect loop;
# MavericksSupport/scripts/stage-frameworks.sh enforces the same rule when it stages the tree).
for cxxlib in libc++.1.dylib libc++abi.1.dylib; do
  [ -f "$TC/lib/$cxxlib" ] || { echo "  FATAL: $TC/lib/$cxxlib not found"; exit 1; }
  cp "$TC/lib/$cxxlib" "$STAGE/lib/$cxxlib"
  echo "$cxxlib" >> "$GAP_UNLINKED"
done

# Shared dylibs: each real file deploys UNDER ITS MAJORED INSTALL-NAME BASENAME (the
# name every dependent's LC_LOAD_DYLIB references), with the original file name and
# the staged dev-name symlinks pointing at it. Every install name, inter-library
# reference and rpath is @rpath / @loader_path relative so the deployed runtime is
# relocatable; absolute build-machine rpaths get stripped and verified gone below.
normalize() {  # normalize <file> <rpath-to-libdir>: @rpath deps, strip abs rpaths, add LC_RPATH
  local f="$1" rp="$2" dep r
  # staged-prefix dependencies -> @rpath/<install-name basename>
  otool -L "$f" | awk 'NR>1 {print $1}' | { grep "^$STAGE/lib/" || true; } | while read -r dep; do
    "$INT" -change "$dep" "@rpath/$(basename "$dep")" "$f" || exit 1
  done
  # a stray system-libc++ reference repoints onto the deployed toolchain copy (the
  # 10.9 system libc++ lacks the modern C++ runtime symbols; the deployed copy is a
  # superset, so non-C++17 users keep working too)
  # NB: grep writes to /dev/null instead of -q throughout this script -- -q exits at
  # first match, the upstream otool then dies of SIGPIPE, and pipefail turns that
  # into a spurious failure status.
  if otool -L "$f" | grep '/usr/lib/libc++\.1\.dylib' > /dev/null; then
    "$INT" -change /usr/lib/libc++.1.dylib "@rpath/libc++.1.dylib" "$f" || exit 1
  fi
  if otool -L "$f" | grep '/usr/lib/libc++abi\.dylib' > /dev/null; then
    "$INT" -change /usr/lib/libc++abi.dylib "@rpath/libc++abi.1.dylib" "$f" || exit 1
  fi
  # single-unwinder rule (see the C++ runtime staging comment above): the toolchain's
  # clang++.cfg links @rpath/libunwind.1.dylib; bind it to the system unwinder.
  if otool -L "$f" | grep '@rpath/libunwind\.1\.dylib' > /dev/null; then
    "$INT" -change @rpath/libunwind.1.dylib /usr/lib/system/libunwind.dylib "$f" || exit 1
  fi
  # drop every absolute LC_RPATH (staged libdir, toolchain libdir) so nothing points
  # off-tree; the gate below fails if any survives.
  otool -l "$f" | awk '/LC_RPATH/{g=1} g&&/ path /{print $2; g=0}' | { grep "^/" || true; } | while read -r r; do
    "$INT" -delete_rpath "$r" "$f" || exit 1
  done
  # each binary resolves its sibling @rpath dependencies from its own location at
  # load time (WebCore dlopens these by absolute path, so nothing above them supplies
  # an rpath).
  if ! otool -l "$f" | awk '/LC_RPATH/{g=1} g&&/ path /{print $2; g=0}' | grep -x -F "$rp" > /dev/null; then
    "$INT" -add_rpath "$rp" "$f" || exit 1
  fi
}
collect_dylib() {  # collect_dylib <staged-real-file> <dest-dir> <rpath-to-libdir>
  local f="$1" destdir="$2" rp="$3" id idbase filebase out
  # The canonical deployed name is the basename of the STAGED install name -- read
  # here, BEFORE the -id rewrite below replaces it. (Reading it from the copy after
  # the rewrite yields the file name instead of the majored name, the majored name
  # then never exists in the deployed tree, and every dependent -- gst-libav on
  # libavcodec.61.dylib first among them -- fails to load.)
  id=$(otool -D "$f" | tail -1)
  idbase=$(basename "$id"); filebase=$(basename "$f")
  case "$idbase" in *.dylib) : ;; *) idbase="$filebase" ;; esac
  out="$destdir/$idbase"
  cp "$f" "$out"
  "$INT" -id "@rpath/$idbase" "$out" || exit 1
  normalize "$out" "$rp"
  # the original on-disk name (e.g. libavcodec.61.19.101.dylib) aliases the canonical
  # majored name
  if [ "$filebase" != "$idbase" ]; then ln -sf "$idbase" "$destdir/$filebase"; fi
}
collect_tool() {  # collect_tool <staged-executable>: deploy into DEST/bin, wired to ../lib
  local f="$1" out="$DEST/bin/$(basename "$1")"
  cp "$f" "$out"
  normalize "$out" "@executable_path/../lib"
}
for f in "$STAGE"/lib/*.dylib; do
  [ -L "$f" ] && continue
  collect_dylib "$f" "$DEST/lib" "@loader_path/../lib"
done
for f in "$STAGE"/lib/gstreamer-1.0/*.dylib; do
  [ -L "$f" ] && continue
  collect_dylib "$f" "$DEST/lib/gstreamer-1.0" "@loader_path/../../lib"
done
# Alias symlinks reproduce the STAGED symlink structure (dev names like
# libgstreamer-1.0.dylib, majored aliases like libogg.0.dylib), each retargeted at
# the canonical deployed name of its ultimate target. Deriving these from the staged
# tree -- rather than pattern-editing version suffixes -- keeps multi-dotted names
# (libgstreamer-1.0.0.dylib) correct.
for l in "$STAGE"/lib/*.dylib; do
  [ -L "$l" ] || continue
  base=$(basename "$l"); real="$l"; n=0
  while [ -L "$real" ] && [ $n -lt 8 ]; do
    tgt=$(readlink "$real")
    case "$tgt" in /*) real="$tgt" ;; *) real="$(dirname "$real")/$tgt" ;; esac
    n=$((n+1))
  done
  [ -f "$real" ] || continue
  cname=$(basename "$(otool -D "$real" | tail -1)")
  case "$cname" in *.dylib) : ;; *) cname=$(basename "$real") ;; esac
  if [ "$base" != "$cname" ] && [ ! -e "$DEST/lib/$base" ]; then
    ln -sf "$cname" "$DEST/lib/$base"
  fi
done
# verification tools (see the gate below)
for t in gst-inspect-1.0 gst-launch-1.0; do
  [ -f "$STAGE/bin/$t" ] || { echo "  FATAL: $STAGE/bin/$t not built"; exit 1; }
  collect_tool "$STAGE/bin/$t"
done

echo "==== Widevine CDM interface ===="
# Headers only. The module itself is Google's own Widevine CDM, which is not redistributable and
# which WebKit downloads and installs at runtime (Source/WebKit/UIProcess/mac/WidevineCdmInstaller.h);
# what is needed at build time is the Chromium interface it implements and WebCore's CDMWidevine.cpp
# hosts, taken from the repository Chromium keeps it in and pinned to one revision. Googlesource
# serves a file base64-encoded.
CDM_API_REV=d6c4e1ea4c8fc3dcd98ac3ab5a981f63067223a4
mkdir -p "$DEST/include/cdm"
for h in content_decryption_module.h content_decryption_module_export.h content_decryption_module_ext.h; do
  f="$SRC/cdm-$CDM_API_REV-$h"
  if [ ! -f "$f" ]; then
    echo "download $h" >&2
    fetch "https://chromium.googlesource.com/chromium/cdm/+/$CDM_API_REV/$h?format=TEXT" "$f.b64" || exit 1
    base64 -D -i "$f.b64" -o "$f" || exit 1
    rm -f "$f.b64"
  fi
  cp "$f" "$DEST/include/cdm/$h" || exit 1
done
echo "  cdm interface headers at $CDM_API_REV"

echo "==== required artifacts ===="
# Every media-critical artifact must exist by name; a silent dropout (plugin skipped,
# majored name missing) fails here even if everything else builds.
REQFAIL=0
require_glob() {
  if ! ls $1 > /dev/null 2>&1; then echo "  MISSING required artifact: $1"; REQFAIL=1; fi
}
# The Chromium CDM interface WebCore's Widevine key system is written against.
require_glob "$DEST/include/cdm/content_decryption_module.h"
require_glob "$DEST/lib/libglib-2.0.*.dylib"
require_glob "$DEST/lib/libgstreamer-1.0.*.dylib"
require_glob "$DEST/lib/libgstwebrtc-1.0.*.dylib"
require_glob "$DEST/lib/libgstwebrtcnice-1.0.*.dylib"
require_glob "$DEST/lib/libnice.*.dylib"
require_glob "$DEST/lib/libavcodec.*.dylib"
require_glob "$DEST/lib/libvpx.*.dylib"
require_glob "$DEST/lib/libxml2.*.dylib"
require_glob "$DEST/lib/libdav1d.*.dylib"
require_glob "$DEST/lib/libc++.1.dylib"
require_glob "$DEST/lib/libc++abi.1.dylib"
# The static link libraries WebKit's CMake resolves out of this tree by exact path
# (MavericksSupport/cmake/*.cmake, Source/cmake/*.cmake); naming them here catches a
# dropout now instead of as an unresolved-symbol link failure in WebCore.
for a in libicuuc.a libicui18n.a libicudata.a libgpg-error.a libgcrypt.a libtasn1.a \
         libbrotlicommon.a libbrotlidec.a libbrotlienc.a libwoff2dec.a \
         libwebp.a libwebpdemux.a libsharpyuv.a libavif.a; do
  require_glob "$DEST/lib/$a"
done
require_glob "$DEST/include/webp/decode.h"
require_glob "$DEST/include/avif/avif.h"
require_glob "$DEST/include/libxml2/libxml/parser.h"
# single-unwinder rule: no libunwind may exist in the deployed set.
if [ -e "$DEST/lib/libunwind.1.dylib" ]; then
  echo "  FAIL: $DEST/lib/libunwind.1.dylib exists (mixed-unwinder hazard; must bind /usr/lib/system/libunwind.dylib)"; REQFAIL=1
fi
for p in libgstcoreelements libgstlibav libgstwebrtc libgstnice libgstdtls libgstsrtp \
         libgstsctp libgstvpx libgstwebrtcdsp libgstopus libgstapplemedia libgstosxaudio \
         libgsttypefindfunctions libgstplayback libgstisomp4 libgstmatroska \
         libgstvideoconvertscale libgstaudioconvert libgstaudioresample libgstapp \
         libgstvorbis libgstogg libgstflac libgstwavparse libgstdeinterlace \
         libgstautodetect; do
  require_glob "$DEST/lib/gstreamer-1.0/$p.dylib"
done
require_glob "$DEST/bin/gst-inspect-1.0"
if [ "$REQFAIL" = 1 ]; then echo "  FAIL: required artifacts missing (see above)"; exit 1; fi
echo "  ok: all required artifacts present"

# The AV1 decoder is a patched-in registration (gst-libav-register-libdav1d.patch), so its
# dylib existing does not prove the element exists; ask the registry itself.
if ! GST_REGISTRY="$RUN/gate-registry.bin" GST_PLUGIN_PATH="$DEST/lib/gstreamer-1.0" \
     GST_PLUGIN_SYSTEM_PATH= "$DEST/bin/gst-inspect-1.0" avdec_libdav1d > /dev/null 2>&1; then
  echo "  FAIL: avdec_libdav1d is not registered (AV1 has a parser but no decoder)"; exit 1
fi
echo "  ok: avdec_libdav1d registered"

echo "==== fail-fast gate ===="
# Ground truth on this 10.9 host: every deployed Mach-O must resolve completely --
# every undefined symbol comes from the deployed set or from a library the real
# 10.9 runtime supplies (proved by dlsym, which follows umbrella reexports), and any
# weak import that resolves NOWHERE must be on the documented weak-allowed list
# (references the SDK guards behind __builtin_available). Anything else fails loudly.
GATE="$RUN/gate"; mkdir -p "$GATE/und"
FAILS="$GATE/failures.txt"; : > "$FAILS"

# Weak imports allowed to bind NULL on 10.9. An entry earns its place only by being
# UNREACHABLE on this OS; a symbol that some code path calls needs a gap-archive
# definition instead, not an exemption here.
#
#   ___darwin_check_fd_set_overflow
#     emitted by the modern SDK's FD_SET() inline. $SDK/usr/include/sys/_types/_fd_def.h
#     calls it only behind `if ((uintptr_t)&__darwin_check_fd_set_overflow != (uintptr_t)0)`,
#     a weak-symbol address test, so a NULL binding takes the other branch.
#
#   _VTRegisterSupplementalVideoDecoderIfAvailable
#     emitted by GStreamer's applemedia (sys/applemedia/vtutil.c), where the direct call sits
#     under __builtin_available(macOS 11.0) -- false here -- and the fallback dlsyms it.
#
# VTIsHardwareDecodeSupported is NOT here: vtdec.c calls it unguarded from
# gst_vtdec_check_{vp9,av1}_support, i.e. from gst_vtdec_getcaps, so a NULL binding is a call
# through address 0. It is defined in the gap archive (polyfills/shared/videotoolbox.c).
WEAK_ALLOWED="___darwin_check_fd_set_overflow _VTRegisterSupplementalVideoDecoderIfAvailable"

# dlsym ground-truth probe. macOS binds undefineds PER SOURCE LIBRARY (two-level namespace),
# so each symbol is asked of the library its own import record names -- not of the process.
# Searching process-wide would pass a symbol that some unrelated image happens to export and
# that the binary under test never loads, which is the whole failure this gate exists to catch.
# stdin carries "<symbol>\t<library path>" per line; the probe prints the pairs the named
# library does not provide, plus one OPEN-FAILED line per library that will not load (an
# unchecked dlopen would silently downgrade every symbol from it to "unresolved").
cat > "$GATE/dlsym_probe.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define MAXLIBS 1024
int main(void) {
    static char *paths[MAXLIBS]; static void *handles[MAXLIBS]; static int nlibs;
    char line[8192];
    while (fgets(line, sizeof line, stdin)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = 0;
        if (!n) continue;
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = 0;
        const char *sym = line; const char *path = tab + 1;
        int i, slot = -1;
        for (i = 0; i < nlibs; i++) if (!strcmp(paths[i], path)) { slot = i; break; }
        if (slot < 0) {
            if (nlibs >= MAXLIBS) { printf("TOO-MANY-LIBS\t%s\n", path); continue; }
            void *h = dlopen(path, RTLD_LAZY);
            if (!h) printf("OPEN-FAILED\t%s\n", path);
            paths[nlibs] = strdup(path); handles[nlibs] = h; slot = nlibs; nlibs++;
        }
        if (!handles[slot]) continue;   /* already reported once */
        const char *bare = (sym[0] == '_') ? sym + 1 : sym;
        if (!dlsym(handles[slot], bare)) printf("%s\t%s\n", sym, path);
    }
    return 0;
}
EOF
( "$CC_VANILLA" -O2 -mmacosx-version-min=10.9 -o "$GATE/dlsym_probe" "$GATE/dlsym_probe.c" ) || exit 1

# dlopen probe: dyld is the final authority on whether a deployed image loads -- it checks
# what no static inspection can (segment protections, section attributes, initializers).
# RTLD_NOW forces full symbol binding at load. The probe carries the deployed tree's rpaths,
# the same way WebCore's media stack reaches these images.
cat > "$GATE/dlopen_probe.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    if (!dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    return 0;
}
EOF
( "$CC_VANILLA" -O2 -mmacosx-version-min=10.9 -o "$GATE/dlopen_probe" "$GATE/dlopen_probe.c" \
    -Wl,-rpath,"$DEST/lib" -Wl,-rpath,"$DEST/lib/gstreamer-1.0" ) || exit 1

GATE_FILES=""
for f in "$DEST"/lib/*.dylib "$DEST"/lib/gstreamer-1.0/*.dylib "$DEST"/bin/*; do
  [ -L "$f" ] && continue
  [ -f "$f" ] || continue
  GATE_FILES="$GATE_FILES $f"
done

# pass 1: per-file undefineds (strong/weak), load commands, rpath + libc++ checks
: > "$GATE/all-strong.txt"; : > "$GATE/all-weak.txt"; : > "$GATE/sysdeps.txt"
: > "$GATE/unattributed.txt"
: > "$GATE/deployed-exports.txt"
for f in $GATE_FILES; do
  b=$(basename "$f")
  "$NMBIN" -arch x86_64 -gU "$f" 2>/dev/null | awk 'NF>=3{print $3}' >> "$GATE/deployed-exports.txt"
  # dyld_stub_binder is the lazy-binding glue every 10.9-deployment Mach-O references;
  # libdyld.dylib provides it on 10.9. It has no C underscore prefix, so the dlsym probe
  # (which prepends one) can never see it — exclude it rather than false-FAIL every binary.
  # Keep the "(from X)" field: it names the library this binary binds the symbol against,
  # and the probe asks that library specifically rather than the whole process.
  "$NMBIN" -m -arch x86_64 "$f" | awk '
    /\(undefined\)/ {
      from="-"
      if (match($0, /\(from [^)]*\)/)) from=substr($0, RSTART+6, RLENGTH-7)
      line=$0; sub(/ \(from [^)]*\)[^)]*$/, "", line)
      n=split(line, a, " "); sym=a[n]
      if (sym == "dyld_stub_binder") next
      if (index($0, " weak ")) print "W " sym " " from; else print "S " sym " " from
    }' | sort -u > "$GATE/und/$b.und"
  # Resolve each "(from X)" token to a loadable path through this binary's own load commands:
  # X is the install-name basename minus its version/extension tail.
  otool -l "$f" | awk '$1=="cmd"{t=$2}
    $1=="name" && (t=="LC_LOAD_DYLIB"||t=="LC_LOAD_WEAK_DYLIB"||t=="LC_REEXPORT_DYLIB"){print $2}' \
    | sort -u > "$GATE/und/$b.deps"
  : > "$GATE/und/$b.pairs"
  while read -r kind sym from; do
    [ "$from" = "-" ] && { echo "$kind $sym -" >> "$GATE/und/$b.pairs"; continue; }
    dep=$(awk -v tok="$from" '{ b=$0; sub(/.*\//,"",b); if (b==tok || index(b, tok ".")==1) { print $0; exit } }' "$GATE/und/$b.deps")
    case "$dep" in
      @rpath/*) r="${dep#@rpath/}"
                if [ -e "$DEST/lib/$r" ]; then dep="$DEST/lib/$r"; else dep="$DEST/lib/gstreamer-1.0/$r"; fi ;;
      "")       dep="-" ;;
    esac
    echo "$kind $sym $dep" >> "$GATE/und/$b.pairs"
  done < "$GATE/und/$b.und"
  awk '$1=="S" && $3!="-"{print $2 "\t" $3}' "$GATE/und/$b.pairs" >> "$GATE/all-strong.txt"
  awk '$1=="W" && $3!="-"{print $2 "\t" $3}' "$GATE/und/$b.pairs" >> "$GATE/all-weak.txt"
  awk '$3=="-"{print $2}' "$GATE/und/$b.pairs" >> "$GATE/unattributed.txt"
  otool -l "$f" | awk '$1=="cmd"{t=$2}
    $1=="name" && (t=="LC_LOAD_DYLIB"||t=="LC_LOAD_WEAK_DYLIB"||t=="LC_REEXPORT_DYLIB"){print t, $2}' \
    >> "$GATE/sysdeps.txt"
  # (c) verified: no absolute build-machine LC_RPATH survives normalize
  absrp=$(otool -l "$f" | awk '/LC_RPATH/{g=1} g&&/ path /{print $2; g=0}' | { grep '^/' || true; })
  if [ -n "$absrp" ]; then echo "absolute LC_RPATH in $b: $absrp" >> "$FAILS"; fi
  # (d) no text-relocation attributes: 10.9 dyld trusts S_ATTR_EXT_RELOC(0x200)/
  # S_ATTR_LOC_RELOC(0x100) on __text and takes its text-relocation path, which leaves the
  # whole __TEXT segment mapped without the execute bit -- the first call into the image
  # (dlopen running the module initializers) dies with SIGBUS. The bits are wrong in a
  # deployed image whether they are genuine (non-PIC code) or inherited from an object file
  # (toolchain/patches/nasm-macho-object-reloc-attrs.patch keeps nasm from stamping them).
  textflags=$(otool -l "$f" | awk '/sectname __text/{t=1} t&&/flags 0x/{print $2; exit}')
  if [ -n "$textflags" ] && [ $(( textflags & 0x300 )) -ne 0 ]; then
    echo "relocation attributes on __text in $b (flags $textflags)" >> "$FAILS"
  fi
  # no deployed binary may lean on the (pre-C++17) system libc++
  if otool -L "$f" | grep '/usr/lib/libc++' > /dev/null; then
    echo "system libc++ reference in $b" >> "$FAILS"
  fi
done
sort -u -o "$GATE/all-strong.txt" "$GATE/all-strong.txt"
sort -u -o "$GATE/all-weak.txt"   "$GATE/all-weak.txt"
sort -u -o "$GATE/deployed-exports.txt" "$GATE/deployed-exports.txt"

# (e) every deployed dylib and plugin must dlopen on this 10.9 host. One image per process,
# so a loader crash in one cannot mask the rest; an exit above 128 is dyld or an initializer
# dying on a signal (the __text-attribute case in (d) is SIGBUS here), anything else is
# dlerror text captured verbatim.
for f in $GATE_FILES; do
  case "$f" in */bin/*) continue ;; esac
  b=$(basename "$f")
  err=$("$GATE/dlopen_probe" "$f" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -gt 128 ]; then
    echo "dlopen of $b crashed (signal $((rc-128)))" >> "$FAILS"
  elif [ "$rc" -ne 0 ]; then
    echo "dlopen of $b failed: $err" >> "$FAILS"
  fi
done

# every non-@rpath load command must exist on this 10.9 host (weak dylib loads may
# be absent -- dyld tolerates that); every @rpath one must exist in the deployed tree
for dep in $(awk '{print $2}' "$GATE/sysdeps.txt" | grep -v '^@' | sort -u); do
  if [ ! -e "$dep" ]; then
    kinds=$(awk -v d="$dep" '$2==d{print $1}' "$GATE/sysdeps.txt" | sort -u)
    case "$kinds" in
      LC_LOAD_WEAK_DYLIB) echo "  note: weak dylib absent on 10.9 (tolerated): $dep" ;;
      *) echo "hard-linked library absent on 10.9: $dep" >> "$FAILS" ;;
    esac
  fi
done
for dep in $(awk '{print $2}' "$GATE/sysdeps.txt" | grep '^@rpath/' | sort -u); do
  base="${dep#@rpath/}"
  if [ ! -e "$DEST/lib/$base" ] && [ ! -e "$DEST/lib/gstreamer-1.0/$base" ]; then
    echo "@rpath dependency missing from deployed tree: $base" >> "$FAILS"
  fi
done

# Every undefined must be attributable to a source library; an unattributed one cannot be
# checked against anything and is not silently passed.
sort -u -o "$GATE/unattributed.txt" "$GATE/unattributed.txt"
if [ -s "$GATE/unattributed.txt" ]; then
  echo "undefined symbols with no resolvable source library:" >> "$FAILS"
  sed 's/^/  /' "$GATE/unattributed.txt" >> "$FAILS"
fi

# strong undefineds: each must be provided by the library its own import record names
: > "$GATE/strong-missing.txt"
if [ -s "$GATE/all-strong.txt" ]; then
  "$GATE/dlsym_probe" < "$GATE/all-strong.txt" | sort -u > "$GATE/strong-missing.txt"
fi
if [ -s "$GATE/strong-missing.txt" ]; then
  echo "strong undefined symbols their own source library does not provide on 10.9:" >> "$FAILS"
  sed 's/^/  /' "$GATE/strong-missing.txt" >> "$FAILS"
fi

# weak undefineds: those with no provider anywhere bind NULL at load; each must be on
# the documented allow-list
: > "$GATE/weak-missing.txt"
if [ -s "$GATE/all-weak.txt" ]; then
  "$GATE/dlsym_probe" < "$GATE/all-weak.txt" | sort -u > "$GATE/weak-missing.txt"
fi
printf '%s\n' $WEAK_ALLOWED | sort -u > "$GATE/weak-allowed.txt"
awk -F'\t' 'NR==FNR{ok[$1]=1; next} !ok[$1]' "$GATE/weak-allowed.txt" "$GATE/weak-missing.txt" > "$GATE/weak-bad.txt"
if [ -s "$GATE/weak-bad.txt" ]; then
  echo "weak imports that bind NULL on 10.9 and are not allow-listed:" >> "$FAILS"
  sed 's/^/  /' "$GATE/weak-bad.txt" >> "$FAILS"
fi

if [ -s "$FAILS" ]; then
  echo "  ---- GATE FAILURES ----"
  sed 's/^/  /' "$FAILS"
  echo "  FAIL: the deployed runtime does not resolve cleanly on 10.9 (see above)"
  exit 1
fi
echo "  ok: $(echo $GATE_FILES | wc -w | tr -d ' ') binaries; every strong undefined resolves on 10.9;"
echo "      every dylib and plugin dlopens; no NULL-binding weak imports beyond the"
echo "      allow-list; no absolute rpaths"

echo "==== gap archive manifest ===="
cp "$GAP_MANIFEST"  "$DEST/gap-sources.sha256" || exit 1
cp "$GAP_SYMBOLS"   "$DEST/gap-symbols.txt"    || exit 1
cp "$GAP_LITERALS"  "$DEST/gap-literals.txt"   || exit 1
cp "$GAP_BUILDINFO" "$DEST/gap-buildinfo.txt"  || exit 1
cp "$GAP_UNLINKED"  "$DEST/gap-unlinked.txt"   || exit 1
echo "  $(wc -l < "$DEST/gap-sources.sha256" | tr -d ' ') source files, $(wc -l < "$DEST/gap-symbols.txt" | tr -d ' ') defined symbols, $(wc -l < "$DEST/gap-literals.txt" | tr -d ' ') literals, $(wc -l < "$DEST/gap-unlinked.txt" | tr -d ' ') copied-not-linked"

echo "==== done. deps/build: ===="
ls "$DEST/lib" | head -40; ls "$DEST/lib/gstreamer-1.0" | wc -l
echo "  build tree: $(du -sh "$SCRATCH" | awk '{ print $1 }') at $SCRATCH, $(df -h / | awk 'NR == 2 { print $4 }') free on /"
