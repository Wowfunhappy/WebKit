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
#   libpng 1.6.43 (static)              -> WebCore's PNGImageDecoder, for animated PNG (10.9's
#                                          ImageIO decodes only the first frame)
#   libavif 1.3.0 (static, on dav1d)    -> WebCore's AVIFImageDecoder (10.9's ImageIO
#                                          predates AVIF)
#   libxml2 2.13.6 (shared)             -> WebCore XML/SVG parsing, in place of 10.9's
#                                          crash-prone system libxml2 2.9.0
#   libxslt 1.1.43 (shared)             -> WebCore XSLT, built against the libxml2 above so one
#                                          process never holds two libxml2 images
#   BoringSSL (in-tree, shared)        -> curl TLS, WebCore SSL APIs and HLS AES-128 keys
#   libpsl 0.21.5 (shared, ICU)        -> public-suffix rejection in curl's cookie store
#   nghttp2 1.70.0 + libcurl 8.22.0     -> HTTP/2 networking, on that shared BoringSSL
#   GLib + GStreamer (GLIB_VER/GST_VER)  -> the media runtime (core, plugins-base/
#     (+ codecs)                           good/bad, gst-libav on FFmpeg 8.1.2 with
#                                          dav1d AV1 decode, libvpx VP8/VP9) that
#                                          MediaPlayerPrivateGStreamer drives; built
#                                          shared with @rpath install names
#
# Built with the in-tree clang-22 / 10.9 toolchain. Output lands in
# MavericksSupport/deps/build/{include,lib,bin} -- a gitignored artifact this script
# regenerates. lib/ holds the static link libs plus the whole shared media runtime
# (with lib/gstreamer-1.0 plugins); bin/ holds gst-inspect-1.0/gst-launch-1.0 for
# on-box verification. Downloaded source tarballs, build trees, the install prefix
# and its ccache live in the gitignored deps/work; vendored sources stay in Source/.
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
# Usage: MavericksSupport/deps/build_deps.sh [--clean | --check-recipes]
#        (or via MavericksSupport/bootstrap.sh)
#
# Sources, build trees and the install prefix persist in work/, so a rerun extracts and configures
# nothing it already has and each package's build system picks up where it left off. --clean discards
# work/trees; the tarball and ccache caches sit beside it and survive.
#
# --check-recipes asks whether deps/build was published by a completed run of this script and the
# patches beside it (see recipes_key).
set -euo pipefail
# NB: the 10.9 system bash (3.2) does NOT abort when a ( ... ) section subshell fails,
# even under set -e / trap ERR -- hence the explicit `|| exit 1` on every section.

CLEAN=""
CHECK=""
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        --check-recipes) CHECK=1 ;;
        *) echo "usage: build_deps.sh [--clean | --check-recipes]" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
LOG=/tmp/wk_build.log
# The one build log. One fd carries this script's package headers and every package's compile
# output, in order. --check-recipes answers on stdout, which under build.sh is this same log.
[ -n "$CHECK" ] || exec >> "$LOG" 2>&1
REPO="$(cd "$HERE/../.." && pwd)"                   # repo root
. "$REPO/MavericksSupport/scripts/cctools.sh"
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
GSTCMAKE="$REPO/MavericksSupport/cmake/OptionsMacGStreamer.cmake"
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

# /usr/bin/make, gnumake, ar, etc. are xcode-select shims that forward to whatever
# developer dir is selected at the time. The toolchain's own cctools lead the PATH, and
# the DEVELOPER_DIR below fixes where the remaining shims forward, so this script is
# independent of the machine's current xcode-select state. The in-tree ninja and nasm
# dirs join the PATH for meson and the assembly-heavy codec builds.
export PATH="$(dirname "$NASM"):$(dirname "$NINJA"):$CCTOOLS:$PATH"
# Same reason, for the sub-builds that reach a tool through `xcrun` rather than PATH (libavif's
# static-library merge runs `xcrun libtool`). xcrun resolves against DEVELOPER_DIR, and with an
# Xcode selected it first tries to read SDKROOT as an SDK NAME, fails on this absolute path, and
# then reports the utility itself as missing. Either developer dir carries the tools these
# sub-builds ask xcrun for; this names whichever one is installed.
if [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
else
    _devdir="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$_devdir" ]; then export DEVELOPER_DIR="$_devdir"; fi
    unset _devdir
fi

DEST="$HERE/build"                                 # gitignored output: include/ + lib/ + bin/, what WebKit links
WORK="$HERE/work"                                  # gitignored workspace, read by this script alone
# The build trees, the tools they need and the prefix they install into, kept between runs
# so a rerun is incremental. That is what makes an edit to a gap-archive source a relink of the media
# runtime rather than a rebuild of it: every object below is unchanged, only the archive force-loaded
# into them moved.
SCRATCH="$WORK/trees"
# Tarballs cache in a persistent dir so a rerun after a mid-script failure
# does not re-download everything.
SRC="$WORK/tarballs"
STAGE="$SCRATCH/install"                            # full autotools install prefix

# The TLS source is the same vendored tree libwebrtc compiles. Hash its content, including
# generated assembly and build files, so an upstream roll or local edit invalidates both
# BoringSSL and curl and the published recipe stamp.
BORINGSSL_SRC="$REPO/Source/ThirdParty/libwebrtc/Source/third_party/boringssl/src"
BORINGSSL_KEY=$( ( cd "$BORINGSSL_SRC" && find . -type f -print | LC_ALL=C sort \
    | tr '\n' '\0' | xargs -0 /usr/bin/shasum -a 256 ) \
    | /usr/bin/shasum -a 256 | awk '{ print $1 }') || exit 1

# recipes_key: this whole script and every patch beside it -- what a run of it builds from. The
# collect step drops deps/build's copy and the end of the run writes it back, so the key is in the
# tree only when a run carried every package, gate and manifest through to the end.
recipes_key() {
  local p
  { /usr/bin/shasum -a 256 < "$SELF"
    printf '%s\n' "$BORINGSSL_KEY"
    for p in "$HERE"/patches/*.patch; do printf '%s\n' "$p"; done | LC_ALL=C sort \
      | while read -r p; do printf '%s\n' "${p##*/}"; /usr/bin/shasum -a 256 < "$p"; done
  } | /usr/bin/shasum -a 256 | awk '{ print $1 }'
}
if [ -n "$CHECK" ]; then
    if [ "$(cat "$DEST/.recipes" 2>/dev/null)" = "$(recipes_key)" ]; then
        echo "### deps recipes: deps/build carries this script and these patches"
        exit 0
    fi
    echo "### deps recipes: deps/build was not published from this script and these patches"
    exit 1
fi

mkdir -p "$SCRATCH"

# One run owns the workspace, and it holds the lock before it reads or discards anything in it.
LOCK="$WORK/.lock"
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
# A build.sh that is blocked invoking this script has linked nothing yet and names itself in
# WK_BUILD_AWAITING_DEPS; every other one is a link in flight.
_refuse_under_webkit_build() {
    local pids
    pids="$(_webkit_build_pids | sort -un | awk -v self="${WK_BUILD_AWAITING_DEPS:-}" '$0 != self' | tr '\n' ' ')"
    [ -n "${pids// /}" ] || return 0
    echo "FATAL: a WebKit build is running (pids: $pids) and links from $DEST." >&2
    echo "       Rerun when it is done." >&2
    exit 1
}
_refuse_under_webkit_build

if [ -n "$CLEAN" ]; then
    echo "### --clean: discarding $SCRATCH"
    rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
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
# in work/ beside the build trees rather than in the output tree, so neither --clean nor the collect
# step below reaches it.
#
# CCACHE_BASEDIR rewrites absolute paths under the build tree to relative and CCACHE_NOHASHDIR keeps
# the build directory out of the hash, so the cache still answers when the tree moves with the
# checkout.
# ccache 3.7 hashes LANG, LC_ALL, LC_CTYPE and LC_MESSAGES. Agent command runners inject
# LC_ALL=C.UTF-8 and LC_CTYPE=C.UTF-8 even when an interactive shell does not, which otherwise
# puts every agent compilation in a distinct cache namespace. Match the canonical interactive
# build environment explicitly so human and agent builds share the existing cache entries.
export LANG=en_US.UTF-8
unset LC_ALL LC_CTYPE LC_MESSAGES
CCACHE="${MAVERICKS_CCACHE:-$REPO/MavericksSupport/toolchain/build/ccache/bin/ccache}"
if [ -x "$CCACHE" ]; then
    export CCACHE_DIR="$WORK/ccache"
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
# Classic BSD nm: libtool's symbol-pipe probing only understands its output.
export NM="$CCTOOLS/nm"
export MACOSX_DEPLOYMENT_TARGET=10.9
export CFLAGS="-O2 -mmacosx-version-min=10.9"
export CXXFLAGS="-O2 -mmacosx-version-min=10.9"
export OBJCFLAGS="-O2 -mmacosx-version-min=10.9"
export LDFLAGS="-mmacosx-version-min=10.9"

INT="$CCTOOLS/install_name_tool"
NMBIN="$CCTOOLS/nm"

# The clang-22 toolchain's clang.cfg/clang++.cfg add a default link set (libc++/
# objc/frameworks). That is correct for building WebKit but breaks autotools/gnulib
# feature probes: the auto-linked archives make AC_CHECK_FUNC/header-generation
# misbehave (libgcrypt decides getpid/clock are "missing" and compiles #error stubs;
# gnulib leaks raw typedefs into the Makefile -> /bin/sh syntax error).
#
# So the autotools deps (libgpg-error/libgcrypt/libtasn1) compile with a VANILLA
# clang (--no-default-config): the same 10.9-targeting compiler against the same SDK,
# minus that auto-linked set, so the probes measure the compiler rather than the config.

# One install prefix serves every package below, and several of them probe it: a configure run
# before another package installs into that prefix resolves a feature differently from one run
# after. So every optional feature this build depends on is stated on its own configure line --
# libgpg-error/libgcrypt/libtasn1 --disable-nls, flac --enable-ogg, -Dorc=enabled on the three
# GStreamer modules that have the option -- and a missing dependency then fails that configure
# instead of quietly dropping the feature. gnulib's search of $prefix is one such probe: it resolves
# libgpg-error's NLS against GLib's proxy libintl whenever that is already installed there.
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

# fetch <url> <dest-file>. Lands via a .part file carrying this run's pid, so an interrupted transfer
# cannot leave a truncated file at the cache path (which get() would then trust forever), and concurrent
# runs fetching the same URL each own their temp path.
fetch() {
  local url="$1" out="$2" tmp="$2.$$.part" rc
  curl -fsSL -m 600 -o "$tmp" "$url"; rc=$?
  if [ $rc -eq 0 ] && [ -s "$tmp" ]; then mv "$tmp" "$out"; return 0; fi
  echo "fetch: $url curl rc=$rc bytes=$(/usr/bin/stat -f%z "$tmp" 2>/dev/null || echo none)" >&2
  rm -f "$tmp"
  return 1
}

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
recipe_key() {
  local start end section names p
  start=$(awk -v n="$1" 'NR <= n && /^echo "==== /{ s = NR } END { print s + 0 }' "$SELF")
  end=$(awk -v n="$start" 'NR > n && /^echo "==== /{ print NR - 1; exit } END { print NR }' "$SELF" | head -1)
  section=$(sed -n "${start},${end}p" "$SELF")
  # The patches the section applies, named in the one form every application below is written in, so
  # a patch path belonging to another tree is not one of them. Each must be in the checkout: a name
  # that resolves to nothing otherwise hashes to a key stating a recipe the tree does not hold.
  names=$(printf '%s\n' "$section" | { grep -oE '\$HERE/patches/[A-Za-z0-9._-]+\.patch' || true; } \
          | sed 's|^\$HERE/||' | sort -u)
  for p in $names; do
    [ -f "$HERE/$p" ] || { echo "recipe_key: $p is applied by a recipe and is not in the checkout" >&2; return 1; }
  done
  { printf '%s\n' "$section"
    for p in $names; do /usr/bin/shasum -a 256 "$HERE/$p"; done
    printf '%s\n' "$CFLAGS" "$CXXFLAGS" "$OBJCFLAGS" "$LDFLAGS"
    # A setting a section reads by name, hashed for the sections that name it. Two are reached
    # through another name: the vanilla compiler wrappers carry $LENIENT, and "$MESON" is the pin.
    case "$section" in *BoringSSL*|*BORINGSSL*|*hls-crypto=openssl*)
                                            printf 'BORINGSSL_KEY=%s\n' "$BORINGSSL_KEY";; esac
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
  [ -f "$f" ] || ( echo "download $(basename "$url")" >&2 && fetch "$url" "$f" ) || return 1
  if [ -f "$d/.prepared" ] && [ "$(cat "$d/.recipe" 2>/dev/null)" = "$key" ]; then
    echo "$d"; return 0
  fi
  rm -rf "${d:?}"; mkdir -p "$d"
  tar xf "$f" -C "$d" --strip-components=1 || return 1
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
  local k
  k=$(recipe_key "${BASH_LINENO[0]}") || return 1
  mkdir -p "$SCRATCH/stamps" && printf '%s\n' "$k" > "$SCRATCH/stamps/$1" && rm -rf "${2:?}"
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
        --enable-static --disable-doc --disable-tests --disable-languages --disable-nls \
      && make -j2 && make install ) || exit 1
    finished gpgerror "$d"
fi

echo "==== libgcrypt ===="
u=https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2
# ac_cv_sys_symbol_underscore=yes: Mach-O prefixes every C symbol with an underscore, and
# mpi/sysdep.h's C_SYMBOL_NAME() adds it only when this is yes -- which is what makes the amd64 MPI
# assembly define the names the C code calls. libgcrypt's probe cannot reach that answer here:
# libtool's Darwin symbol pipe appends the bare name after the underscored one, "T _nm_test_func
# nm_test_func", so the probe's end-anchored ' _nm_test_func$' never matches and its ' nm_test_func$'
# fallback does, leaving the default no. The assembly then defines _gcry_mpih_lshift where the C
# code references __gcry_mpih_lshift. Stating the platform's own answer puts the amd64 MPI path in
# the archive instead of the pure-C one.
if ! built gcrypt install/lib/libgcrypt.a; then
    d=$(get "$u" gcrypt)
    ( cd "$d" && ./configure CC="$CC_VANILLA" ac_cv_sys_symbol_underscore=yes --prefix="$STAGE" \
        --disable-shared --enable-static --disable-doc --disable-nls --with-libgpg-error-prefix="$STAGE" \
      && make -j2 && make install ) || exit 1
    finished gcrypt "$d"
fi

echo "==== libtasn1 ===="
u=https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz
if ! built tasn1 install/lib/libtasn1.a; then
    d=$(get "$u" tasn1)
    ( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
        --enable-static --disable-doc --disable-nls \
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

echo "==== libpng 1.6.43 ===="
# WebCore's own PNGImageDecoder (USE_PNG), which ScalableImageDecoder::create routes files
# carrying acTL to: 10.9's ImageIO reports an animated PNG as a single frame, so APNGs render
# static. Decode only, static, beside libwebp; zlib comes from the SDK. The command-line tools
# and the test programs are off.
u=https://download.sourceforge.net/libpng/libpng-1.6.43.tar.xz
if ! built libpng install/lib/libpng16.a; then
    d=$(get "$u" libpng)
    ( cd "$d" && mkdir -p out && cd out \
      && "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
           -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
           -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
           ${CCACHE:+-DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE"} \
           -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
           -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF \
           -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
           -DCMAKE_INSTALL_PREFIX="$STAGE" .. \
      && "$NINJA" -j2 && "$NINJA" install ) || exit 1
    finished libpng "$d"
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
#   audiounit_max_frames  a deliberate OVERRIDE of AudioUnitInitialize: 10.9's AUHAL keeps an output
#                       unit's kAudioUnitProperty_MaximumFramesPerSlice at the DEVICE's current
#                       buffer frame size, restating it on every initialized unit driving that
#                       device each time anything in the process changes that size, and delivering
#                       the restatement after the HAL is already rendering the new size -- so each
#                       change leaves a window in which a render exceeds the declaration and fails
#                       with kAudioUnitErr_TooManyFramesToProcess, which on 10.9 also enters the
#                       CAMutex deadlock in AUHAL's error path. This declares the top of every
#                       output device's supported range instead, and holds it there from two
#                       listeners on the unit: the unit moving to another device, and AUHAL
#                       restating the property; AudioUnitUninitialize and
#                       AudioComponentInstanceDispose come with it as the units it tracks
#
SHARED="$REPO/MavericksSupport/polyfill/polyfills/shared"
GAPDIR="$SCRATCH/gap"
# The archive persists between runs -- its mtime is what the coverage gate before the collect step
# reads. The objects do not, so a source dropped from GAP_SHARED leaves nothing for `ar` to pick up.
GAPOBJ="$GAPDIR/obj"
mkdir -p "$GAPDIR"; rm -rf "$GAPOBJ"; mkdir -p "$GAPOBJ"
GAP_SHARED="time atcalls utimensat fdopendir statxx getentropy pthread_chdir os_unfair_lock mkostemp os_version aligned_alloc ccrandom cv_colorimetry launchservices videotoolbox pthread_jit mach_timebase_info audiounit_max_frames"
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
"$CCTOOLS/strings" -a "$GAP_A" | { grep '^\[wk_polyfill\] .\{40,\}' || true; } | sort -u > "$GAP_LITERALS"
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

echo "==== BoringSSL (ThirdParty/libwebrtc's copy) ===="
# curl and WebCore exchange SSL_CTX/SSL objects and must bind the same shared ssl/crypto.
# HLS uses this same libcrypto through the OpenSSL-compatible EVP API. The vendored
# CMake project builds conventional libssl/libcrypto with its pregenerated assembly.
# The vanilla compiler has no automatic C++ runtime link set, so both runtime libraries
# are explicit, from the same toolchain whose dylibs the collect step deploys.
d="$SCRATCH/build-boringssl"
key=$(recipe_key "$LINENO") || exit 1
if [ "$(cat "$d/.recipe" 2>/dev/null)" != "$key" ]; then rm -rf "$d"; fi
mkdir -p "$d"
printf '%s\n' "$key" > "$d/.recipe"
if prepare "$d"; then
    ( cd "$d" && "$CMAKE" -S "$BORINGSSL_SRC" -B out -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
        -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
        "-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG -g0" "-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG -g0" \
        "-DCMAKE_ASM_FLAGS_RELEASE=-O2 -DNDEBUG -g0" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
        -DCMAKE_C_COMPILER_ARG1=--no-default-config -DCMAKE_CXX_COMPILER_ARG1=--no-default-config \
        -DCMAKE_ASM_COMPILER="$CC_BIN" -DCMAKE_ASM_COMPILER_ARG1=--no-default-config \
        ${CCACHE:+-DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE"} \
        -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_INSTALL_NAME_DIR=@rpath -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON \
        -DCMAKE_BUILD_RPATH="$STAGE/lib;$TC/lib" \
        -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS -L$TC/lib -lc++ -lc++abi -Wl,-headerpad_max_install_names" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS -L$TC/lib -lc++ -lc++abi" ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$NINJA" -C out -j2 ssl crypto \
  && cp -p out/libssl.dylib out/libcrypto.dylib "$STAGE/lib/" \
  && rm -rf "$STAGE/include/openssl" \
  && cp -Rp "$BORINGSSL_SRC/include/openssl" "$STAGE/include/" ) || exit 1
# Meson's dependency('openssl') selects BoringSSL's 1.1.1-compatible API level;
# Version is an API compatibility value, while Name identifies the implementation.
mkdir -p "$STAGE/lib/pkgconfig"
cat > "$STAGE/lib/pkgconfig/openssl.pc" <<EOF
prefix=$STAGE
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: BoringSSL
Description: In-tree BoringSSL, OpenSSL 1.1.1-compatible API (BoringSSL API $(sed -n 's/^#define BORINGSSL_API_VERSION //p' "$BORINGSSL_SRC/include/openssl/base.h"))
Version: 1.1.1
Libs: -L\${libdir} -lssl -lcrypto
Cflags: -I\${includedir}
EOF

echo "==== nghttp2 1.70.0 ===="
# HTTP/2 framing for libcurl. The library-only build needs none of nghttp2's servers,
# command-line clients, TLS backends or documentation generators.
d=$(get https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.gz nghttp2) || exit 1
if prepare "$d"; then
    ( cd "$d" && "$CMAKE" -S . -B out -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
        -DCMAKE_BUILD_TYPE=Release -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=ON \
        "-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG -g0" "-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG -g0" \
        -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF -DENABLE_DOC=OFF \
        -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
        -DCMAKE_C_COMPILER_ARG1=--no-default-config -DCMAKE_CXX_COMPILER_ARG1=--no-default-config \
        ${CCACHE:+-DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE"} \
        -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_INSTALL_PREFIX="$STAGE" -DCMAKE_INSTALL_NAME_DIR=@rpath \
        -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$NINJA" -C out -j2 && "$NINJA" -C out install ) || exit 1

echo "==== libpsl 0.21.5 ===="
# curl's cookie store rejects public-suffix domains using the bundled PSL. ICU supplies
# Unicode/IDNA conversion from the same static libraries WebCore uses; NLS is unused.
# U_DISABLE_RENAMING matches the unversioned exports of this tree's ICU build.
d=$(get https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz libpsl) || exit 1
if prepare "$d"; then
    ( cd "$d" && CC="$CC_VANILLA" CXX="$CXX_VANILLA" \
        LIBICU_CFLAGS="-I$STAGE/include -DU_DISABLE_RENAMING=1" LIBICU_LIBS="-L$STAGE/lib -licuuc -licudata" \
        LDFLAGS="$LDFLAGS -L$TC/lib -Wl,-rpath,$TC/lib -Wl,-rpath,$STAGE/lib" \
        LIBS="-lc++ -lc++abi" ./configure --prefix="$STAGE" --disable-static --enable-shared \
        --enable-runtime=libicu --enable-builtin --disable-nls --disable-gtk-doc --disable-man ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -j2 && make install ) || exit 1

echo "==== libcurl 8.22.0 ===="
# BoringSSL supplies both the conventional headers and shared -lssl/-lcrypto in STAGE.
# No built-in CA file/path: callers supply CAINFO or the native-trust SSL_CTX callback.
# The CLI accepts --cacert for verification on this host. Optional backends are explicit
# so a rerun cannot select another TLS, compression or transport library from $STAGE.
# The CLI stages outside bin/ so the dependency fetcher keeps using the host curl.
# Apple GSS.framework supplies Negotiate; NTLM is explicit because curl defaults it off.
# Brotli decodes br responses with the in-tree decoder. No zstd decoder is built, so
# Accept-Encoding advertises only the supported gzip/deflate/br encodings.
# libpsl protects curl's cookie store against cookies scoped to public suffixes.
d=$(get https://curl.se/download/curl-8.22.0.tar.gz curl) || exit 1
if prepare "$d"; then
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/curl-reusable-preconnect.patch" \
        && patch -p1 < "$HERE/patches/curl-reusable-preconnect.patch" ) || exit 1
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/curl-boringssl-async-credentials.patch" \
        && patch -p1 < "$HERE/patches/curl-boringssl-async-credentials.patch" ) || exit 1
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/curl-gss-explicit-credentials.patch" \
        && patch -p1 < "$HERE/patches/curl-gss-explicit-credentials.patch" ) || exit 1
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/curl-http2-completed-stream.patch" \
        && patch -p1 < "$HERE/patches/curl-http2-completed-stream.patch" ) || exit 1
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/curl-http1-framing.patch" \
        && patch -p1 < "$HERE/patches/curl-http1-framing.patch" ) || exit 1
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/curl-digest-request-target.patch" \
        && patch -p1 < "$HERE/patches/curl-digest-request-target.patch" ) || exit 1
    ( cd "$d" && CC="$CC_VANILLA" CXX="$CXX_VANILLA" PKG_CONFIG=/usr/bin/false \
        CPPFLAGS="-I$STAGE/include" \
        LDFLAGS="-L$STAGE/lib $LDFLAGS -L$TC/lib -Wl,-rpath,$STAGE/lib -Wl,-rpath,$TC/lib -Wl,-headerpad_max_install_names -F$SDK/System/Library/PrivateFrameworks" \
        LIBS="-lc++ -lc++abi -framework Heimdal" ./configure --prefix="$STAGE" --bindir="$STAGE/libexec" \
        --enable-shared --disable-static \
        --with-openssl="$STAGE" --with-nghttp2="$STAGE" --with-zlib \
        --with-libpsl="$STAGE" --without-libssh2 --without-libssh --without-librtmp \
        --without-libidn2 --without-apple-idn --with-brotli="$STAGE" --without-zstd \
        --without-ngtcp2 --without-nghttp3 --without-quiche --enable-gssapi-apple --enable-ntlm \
        --without-ca-bundle --without-ca-path --disable-ldap --disable-ldaps \
        --enable-threaded-resolver --disable-manual ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1

echo "==== GLib $GLIB_VER ===="
# GLib's bundled subprojects come from meson wraps. The wrap-file tarballs pre-cache
# into subprojects/packagecache (meson verifies their hashes); the wrap-git ones
# land as plain directories at a pinned revision (gvdb/proxy-libintl by upstream URL,
# libffi by $LIBFFI_REV because its upstream wrap floats on a branch).
d=$(get https://download.gnome.org/sources/glib/${GLIB_VER%.*}/glib-$GLIB_VER.tar.xz glib) || exit 1
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
        -Dintrospection=disabled ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 \
  && "$MESON" install -C b ) || exit 1

echo "==== orc / ogg / vorbis / mpg123 / opus / flac ===="
d=$(get https://gstreamer.freedesktop.org/src/orc/orc-0.4.41.tar.xz orc) || exit 1
if prepare "$d"; then
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release -Dtests=disabled \
        -Dexamples=disabled ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 \
  && "$MESON" install -C b ) || exit 1
d=$(get https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz ogg) || exit 1
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz vorbis) || exit 1
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1
# gst-plugins-good's mpg123 decoder. decodebin inserts a parser only when the decoder asks for one:
# avdec_mp3's sink caps are plain audio/mpeg with no parsed=true, so decodebin wires the typefinder
# straight to it and mpegaudioparse never runs -- the Xing/LAME gapless header goes unread and an mp3
# decodes with its encoder delay and padding still in it. mpg123audiodec demands parsed=true, which puts
# mpegaudioparse back in the chain. Measured on half-a-second-48000.mp3: decodebin alone answers 26496
# frames where mpegaudioparse ! avdec_mp3 answers the correct 24000.
d=$(get https://www.mpg123.de/download/mpg123-1.32.10.tar.bz2 mpg123) || exit 1
if prepare "$d"; then
    # libgstmpg123 links libmpg123 alone, so that is the only component built.
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --enable-shared \
        --disable-components --enable-libmpg123 ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus) || exit 1
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --disable-doc \
        --disable-extra-programs ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1
d=$(get https://downloads.xiph.org/releases/flac/flac-1.4.3.tar.xz flac) || exit 1
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --disable-programs \
        --disable-examples --disable-cpplibs --enable-ogg ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 && make -s install ) || exit 1

echo "==== libvpx 1.14.1 ===="
# VP8/VP9 encode + decode for the gst vpx plugin: WebRTC sends VP8/VP9 through vpxenc,
# which gst-libav does not provide (FFmpeg carries no VP8/VP9 encoder of its own).
# darwin13 is the 10.9 target triple; nasm assembles the SIMD code from the PATH.
d=$(get https://github.com/webmproject/libvpx/archive/refs/tags/v1.14.1.tar.gz vpx) || exit 1
if prepare "$d"; then
    ( cd "$d" && mkdir -p b && cd b \
      && ../configure --target=x86_64-darwin13-gcc --prefix="$STAGE" \
           --enable-shared --disable-static --enable-pic --enable-vp8 --enable-vp9 \
           --disable-examples --disable-tools --disable-docs --disable-unit-tests \
           --as=nasm \
           --extra-cflags="-isysroot $SDK -mmacosx-version-min=10.9" \
           --extra-cxxflags="-isysroot $SDK -mmacosx-version-min=10.9" ) || exit 1
    prepared "$d"
fi
( cd "$d/b" && make -s -j2 \
  && make -s install ) || exit 1
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
d=$(get https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.6.tar.xz libxml2) || exit 1
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --without-python --without-lzma ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 \
  && make -s install ) || exit 1

echo "==== libxslt 1.1.43 ===="
# Built against the libxml2 above, and that is the whole reason it is here. WebCore parses an XSLT
# stylesheet with libxml2 and hands the document to libxslt, which frees it again through
# xsltFreeStylesheet. 10.9's /usr/lib/libxslt.1.dylib binds the system libxml2 2.9.0, so linking it puts
# two libxml2 images in one process: measured on this host, a document allocated by one and freed by the
# other faults in xsltFreeStylesheet, while the same sequence against a single libxml2 -- either version
# -- completes. --without-crypto keeps the EXSLT crypto module (and its libgcrypt dependency) out; WebCore
# uses none of it. Not a GStreamer dependency -- it rides the same staging/collect/gate pipeline.
d=$(get https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz libxslt) || exit 1
if prepare "$d"; then
    ( cd "$d" && ./configure -q --prefix="$STAGE" --disable-static --without-python \
        --without-crypto --with-libxml-prefix="$STAGE" ) || exit 1
    prepared "$d"
fi
( cd "$d" && make -s -j2 \
  && make -s install ) || exit 1

echo "==== dav1d 1.4.3 ===="
# FFmpeg links it (--enable-libdav1d) for AV1 via the libdav1d wrapper codec, which
# gst-libav registers as avdec_libdav1d (see the libdav1d patch in the gst-libav
# section) -- the runtime's AV1 decoder, also serving libavif below.
d=$(get https://downloads.videolan.org/pub/videolan/dav1d/1.4.3/dav1d-1.4.3.tar.xz dav1d) || exit 1
if prepare "$d"; then
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release \
        -Denable_tools=false -Denable_tests=false ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 \
  && "$MESON" install -C b ) || exit 1

echo "==== libyuv (ThirdParty/libwebrtc's copy) ===="
# libavif's libyuv. Built without a system libyuv, libavif compiles a subset of it into libavif.a
# under libyuv's own global symbol names; built against a real one it references those symbols
# instead, which keeps one definition and one vendored copy of the source. That copy is
# Source/ThirdParty/libwebrtc/Source/third_party/libyuv, the tree libwebrtc already carries, and it
# collects into deps/build so WebCore links it beside libavif.
YUV_SRC="$REPO/Source/ThirdParty/libwebrtc/Source/third_party/libyuv"
if ! built libyuv install/lib/libyuv.a; then
    d="$SCRATCH/build-libyuv"; rm -rf "$d"; mkdir -p "$d"
    ( cd "$d" \
      && "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
           -DCMAKE_BUILD_TYPE=Release \
           -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
           ${CCACHE:+-DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE"} \
           -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
           -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON "$YUV_SRC" \
      && "$NINJA" -j2 yuv \
      && cp -p libyuv.a "$STAGE/lib/libyuv.a" \
      && rm -rf "$STAGE/include/libyuv" "$STAGE/include/libyuv.h" \
      && cp -Rp "$YUV_SRC/include/libyuv" "$STAGE/include/" \
      && cp -p "$YUV_SRC/include/libyuv.h" "$STAGE/include/" ) || exit 1
    finished libyuv "$d"
fi

echo "==== libavif 1.3.0 ===="
# WebCore's AVIFImageDecoder (USE_AVIF): 10.9's ImageIO predates AVIF entirely. Decode only --
# no encoder codec is enabled, so this is the demuxer plus the AV1 decode path. It builds here
# rather than beside libwebp because it needs the dav1d above, which it finds through
# pkg-config in $STAGE, and the libyuv above (see there for why it must be libwebrtc's).
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
           -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_LIBYUV=SYSTEM \
           -DLIBYUV_INCLUDE_DIR="$STAGE/include" -DLIBYUV_LIBRARY="$STAGE/lib/libyuv.a" \
           -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF -DAVIF_BUILD_EXAMPLES=OFF \
           -DAVIF_BUILD_MAN_PAGES=OFF \
           -DCMAKE_INSTALL_PREFIX="$STAGE" .. \
      && "$NINJA" -j2 \
      && "$NINJA" install ) || exit 1
    finished libavif "$d"
fi
# libavif builds happily with NO codec at all, and then every AVIF fails to decode at runtime
# with nothing said at build time. Ask the archive itself whether the dav1d codec is in it.
"$NMBIN" "$STAGE/lib/libavif.a" 2>/dev/null | grep "avifCodecCreateDav1d" > /dev/null \
  || { echo "  FATAL: libavif has no dav1d codec (avifCodecCreateDav1d absent); AVIF would decode nothing."; exit 1; }

echo "==== GStreamer $GST_VER (core) ===="
# -Dc_std=gnu11: GStreamer 1.28's project() sets c_std=gnu11,c11 (a meson fallback list),
# which add_languages('objc') propagates to objc_std; meson 1.5.2 rejects a list for
# objc_std ("Value gnu11,c11 ... is not one of the choices"). Pin c_std to the single
# value gnu11 (fully supported by clang-22) so objc_std inherits a valid single value.
GSTOPTS="-Dbuildtype=release -Dtests=disabled -Dexamples=disabled -Ddoc=disabled -Dc_std=gnu11"
# -Dtools=enabled: gst-inspect-1.0/gst-launch-1.0 deploy into deps/build/bin for
# on-box verification of the shipped runtime (plugins load, pipelines run).
d=$(get https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-$GST_VER.tar.xz gstcore) || exit 1
if prepare "$d"; then
    # multiqueue: report the queue's current buffering level. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gstreamer-multiqueue-report-current-buffering-level.patch" \
        && patch -p1 < "$HERE/patches/gstreamer-multiqueue-report-current-buffering-level.patch" ) \
      || { echo "gstreamer multiqueue buffering-level patch failed to apply"; exit 1; }
    # input-selector: active_sinkpad_lock covers the choice of pad for an upstream event,
    # released before the push; a seek's flush drives this element's own state change on the
    # pushing thread. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gstreamer-input-selector-release-lock-for-upstream-events.patch" \
        && patch -p1 < "$HERE/patches/gstreamer-input-selector-release-lock-for-upstream-events.patch" ) \
      || { echo "gstreamer input-selector patch failed to apply"; exit 1; }
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled \
        -Dtools=enabled -Dbenchmarks=disabled -Dlibunwind=disabled -Ddbghelp=disabled \
        -Dbash-completion=disabled ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 \
  && "$MESON" install -C b ) || exit 1

# The plugins named -Denabled below are the ones whose absence would break a feature this port
# ships, so a missing dependency fails the
# corresponding meson setup loudly instead of silently dropping the plugin from the
# shipped runtime.
echo "==== gst-plugins-base ===="
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-$GST_VER.tar.xz gstbase) || exit 1
if prepare "$d"; then
    # urisourcebin owns the parsebin in a playbin3 pipeline, and nothing resets it
    # when a stream's media type changes mid-play, so an MSE SourceBuffer handed a clear period and then
    # an encrypted one stops at the change. This gives urisourcebin the reset decodebin3 already performs
    # on the parsebin it owns. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-base-urisourcebin-reset-parsebin-on-caps-change.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-base-urisourcebin-reset-parsebin-on-caps-change.patch" ) \
      || { echo "gst-plugins-base urisourcebin parsebin-reset patch failed to apply"; exit 1; }
    # decodebin: size a pending decode group's queue with the buffering limits. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-base-decodebin2-prefill-pending-group.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-base-decodebin2-prefill-pending-group.patch" ) \
      || { echo "gst-plugins-base decodebin2 pending-group patch failed to apply"; exit 1; }
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled \
        -Dogg=enabled -Dvorbis=enabled -Dopus=enabled -Dorc=enabled ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 \
  && "$MESON" install -C b ) || exit 1

echo "==== gst-plugins-good ===="
# Native HLS and DASH use gst-plugins-bad's legacy demuxers through webkitwebsrc.
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-$GST_VER.tar.xz gstgood) || exit 1
if prepare "$d"; then
    # matroskademux: post DURATION_CHANGED as a parsed duration grows and once when it is
    # final, not only for the first block. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-good-matroskademux-post-parsed-duration.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-good-matroskademux-post-parsed-duration.patch" ) \
      || { echo "gst-plugins-good matroskademux duration patch failed to apply"; exit 1; }
    # qtdemux: expose the video track of an ISO/IEC 23008-12 image sequence, whose media handler is
    # 'pict'. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-good-qtdemux-heif-image-sequence.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-good-qtdemux-heif-image-sequence.patch" ) \
      || { echo "gst-plugins-good qtdemux HEIF image sequence patch failed to apply"; exit 1; }
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS \
        -Dvpx=enabled -Dflac=enabled -Dmpg123=enabled -Dosxaudio=enabled -Dosxvideo=enabled \
        -Dorc=enabled -Dadaptivedemux2=disabled ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 \
  && "$MESON" install -C b ) || exit 1

echo "==== gst-plugins-bad ===="
# webp is off because the plugin has no caller: WebP images decode in WebCore's own
# WEBPImageDecoder. The WebRTC plugin set (webrtc, dtls, srtp, sctp, webrtcdsp) is off: WebRTC is
# libwebrtc, inside WebCore.
d=$(get https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-$GST_VER.tar.xz gstbad) || exit 1
if prepare "$d"; then
    # vtdec_hw inherits a sink template advertising codecs the machine cannot
    # hardware-decode, and the template is what picks the decoder for every caller that does not
    # instantiate the element -- WebKit's registry scanner among them, which hands the doomed
    # factory to ImageDecoderGStreamer's harness. This gives vtdec_hw its own sink template, built
    # from a per-codec RequireHardware session probe. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-vtdec-hw-hardware-caps-probe.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-bad-vtdec-hw-hardware-caps-probe.patch" ) \
      || { echo "gst-plugins-bad vtdec_hw caps-probe patch failed to apply"; exit 1; }
    # vtdec's static sink template advertises VP9, AV1 and HEVC, which 10.9's
    # VideoToolbox has no decoder for on any hardware; the template is what WebKit's registry
    # scanner answers isTypeSupported/MediaCapabilities from, and powerEfficient follows the matched
    # factory's Hardware klass, so the claim routes sites onto streams this machine decodes in
    # software or not at all. This removes the three entries. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-vtdec-109-sink-template-codecs.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-bad-vtdec-109-sink-template-codecs.patch" ) \
      || { echo "gst-plugins-bad vtdec sink-template patch failed to apply"; exit 1; }
    # vtenc registers an element per codec whether or not this machine's VideoToolbox
    # has an encoder for it, and the registry is what WebKit's scanner answers encoder support and
    # powerEfficient from: 10.9 has no HEVC encoder at all, and vtenc_h264_hw is registered on
    # machines with no hardware H.264 encoder. This registers each element only if a compression
    # session for its codec type, carrying its hardware-only requirement, can actually be created.
    # See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-vtenc-hardware-encoder-probe.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-bad-vtenc-hardware-encoder-probe.patch" ) \
      || { echo "gst-plugins-bad vtenc encoder-probe patch failed to apply"; exit 1; }
    # vtenc tells the compression session the color of its frames but hands it source
    # pixel buffers carrying no color attachments; 10.9's VideoToolbox reads the source color from
    # the buffer and answers kVTInsufficientSourceColorDataErr (-12917) for every frame. This
    # attaches the colorimetry the session was told. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-vtenc-source-colorimetry.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-bad-vtenc-source-colorimetry.patch" ) \
      || { echo "gst-plugins-bad vtenc source-colorimetry patch failed to apply"; exit 1; }
    # hlsdemux: create an output stream for a SUBTITLES rendition, convert the cue times of its
    # WebVTT fragments into stream time, and carry each rendition's name, language and flags.
    # See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-hlsdemux-subtitle-renditions.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-bad-hlsdemux-subtitle-renditions.patch" ) \
      || { echo "gst-plugins-bad hlsdemux subtitle-rendition patch failed to apply"; exit 1; }
    # hlsdemux: resync a variant switch to the nearest fragment start. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-hlsdemux-variant-switch-nearest-fragment.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-bad-hlsdemux-variant-switch-nearest-fragment.patch" ) \
      || { echo "gst-plugins-bad hlsdemux variant-switch patch failed to apply"; exit 1; }
    # adaptivedemux holds its manifest lock across every uridownloader fetch, so a src
    # query or event, a seek, or the shutdown state change waits behind a playlist download; with
    # webkitwebsrc that download completes only on the thread doing the waiting. This releases the
    # lock around those fetches and re-validates on re-lock. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-plugins-bad-adaptivedemux-release-manifest-lock-for-downloads.patch" \
        && patch -p1 < "$HERE/patches/gst-plugins-bad-adaptivedemux-release-manifest-lock-for-downloads.patch" ) \
      || { echo "gst-plugins-bad adaptivedemux manifest-lock patch failed to apply"; exit 1; }
    # Media HTTP requests use webkitwebsrc; libcurl is a WebCore networking dependency.
    # aes is disabled: WebKit uses HLS demuxers' EVP decryption and has no aesenc/aesdec caller.
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" $GSTOPTS -Dintrospection=disabled -Dcurl=disabled \
        -Daes=disabled -Dhls=enabled -Dhls-crypto=openssl -Ddash=enabled \
        -Dwebrtc=disabled -Dwebrtcdsp=disabled -Ddtls=disabled -Dsrtp=disabled -Dsctp=disabled \
        -Dapplemedia=enabled -Dwebp=disabled -Dorc=enabled ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 \
  && "$MESON" install -C b ) || exit 1

echo "==== FFmpeg 8.1.2 ===="
# Apple-framework codepaths stay off: decoding runs through FFmpeg's own codecs so
# behavior is identical on every 10.9 install. libdav1d supplies AV1 inside FFmpeg,
# surfaced as gst-libav's avdec_libdav1d (see the dav1d note above).
# FFmpeg's configure ignores the LDFLAGS environment, so the gap archive rides in
# --extra-ldflags here.
d=$(get https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz ffmpeg) || exit 1
if prepare "$d"; then
    # The hevc decoder's VPS-extension parser answers the non-standard extension Apple's
    # VideoToolbox writes for HEVC-with-alpha with AVERROR_INVALIDDATA, which drops the VPS
    # and with it every frame of the stream. Upstream commit eedf8f0165fe keeps the already
    # parsed alpha-layer topology on that path, so both layers decode. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/ffmpeg-hevc-alpha-videotoolbox-vps.patch" \
        && patch -p1 < "$HERE/patches/ffmpeg-hevc-alpha-videotoolbox-vps.patch" ) \
      || { echo "FFmpeg hevc-alpha VPS patch failed to apply"; exit 1; }
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
d=$(get https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-$GST_VER.tar.xz gstlibav) || exit 1
if prepare "$d"; then
    # gst-libav skips FFmpeg's external-library ("lib*") decoders on the
    # premise that native GStreamer elements cover them; this runtime has no native AV1
    # decoder, so that rule would leave video/x-av1 with a parser and no decoder. The patch
    # admits the libdav1d wrapper (the dav1d built above, inside FFmpeg) as avdec_libdav1d.
    # See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-libav-register-libdav1d.patch" \
        && patch -p1 < "$HERE/patches/gst-libav-register-libdav1d.patch" ) \
      || { echo "gst-libav libdav1d patch failed to apply"; exit 1; }
    # avviddec installs no get_format callback, so avcodec_default_get_format() takes the
    # LAST software format FFmpeg offers -- for an HEVC stream with an alpha layer that is
    # the plain yuv420p, and the alpha layer is never decoded. The patch selects the first
    # software format, as the ffmpeg tool does. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-libav-avviddec-select-first-software-format.patch" \
        && patch -p1 < "$HERE/patches/gst-libav-avviddec-select-first-software-format.patch" ) \
      || { echo "gst-libav get_format patch failed to apply"; exit 1; }
    # avviddec marks each incoming frame decode-only until get_buffer2 requests a buffer for
    # it, and clears that only inside get_buffer2. FFmpeg calls get_buffer2 only for decoders
    # allocating through ff_get_buffer, which libdav1d (no AV_CODEC_CAP_DR1, own dav1d pool) does
    # not, so avviddec's copy fallback supplies the buffer while finish_frame still drops every
    # AV1 frame. The patch clears the flag once that fallback has the buffer. See patches/README.md.
    ( cd "$d" && patch -p1 --dry-run < "$HERE/patches/gst-libav-avviddec-clear-decode-only-on-copied-output.patch" \
        && patch -p1 < "$HERE/patches/gst-libav-avviddec-clear-decode-only-on-copied-output.patch" ) \
      || { echo "gst-libav decode-only patch failed to apply"; exit 1; }
    # gst-libav's option set has no "examples"; it takes the shared options minus that one.
    ( cd "$d" && "$MESON" setup b --prefix="$STAGE" -Dbuildtype=release -Dtests=disabled \
        -Ddoc=disabled ) || exit 1
    prepared "$d"
fi
( cd "$d" && "$MESON" compile -C b -j 2 \
  && "$MESON" install -C b ) || exit 1

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
rm -f "$DEST/.recipes"
rm -rf "$DEST/include" "$DEST/lib" "$DEST/bin"
mkdir -p "$DEST/include" "$DEST/lib/gstreamer-1.0" "$DEST/bin"
# headers (WebKit's own link deps + the GStreamer/GLib trees WebCore compiles against).
# -p carries each staged file's mtime across, and mtime is what ninja compares: the staged
# tree only restamps a header when its package actually rebuilds, so a rerun that changes
# nothing leaves every WebKit object valid.
cp -Rp "$STAGE/include/unicode"    "$DEST/include/"
cp -p "$STAGE/include/gpg-error.h"   "$DEST/include/"
cp -p "$STAGE/include/gcrypt.h"      "$DEST/include/"
cp -p "$STAGE/include/libtasn1.h"    "$DEST/include/"
cp -p "$STAGE/include/libpsl.h"      "$DEST/include/"
cp -Rp "$STAGE/include/brotli"     "$DEST/include/"
cp -Rp "$STAGE/include/woff2"      "$DEST/include/"
cp -Rp "$STAGE/include/webp"       "$DEST/include/"
cp -Rp "$STAGE/include/avif"       "$DEST/include/"
# libpng installs its headers at the include root and again under libpng16/; PNGImageDecoder
# includes <png.h>, and png.h includes pngconf.h, which includes pnglibconf.h.
cp -p "$STAGE/include/png.h" "$STAGE/include/pngconf.h" "$STAGE/include/pnglibconf.h" "$DEST/include/"
# libxml2 headers: WebCore compiles against these. OptionsMac.cmake points
# LIBXML2_INCLUDE_DIR here so the headers match the 2.13 dylib deployed alongside them.
cp -Rp "$STAGE/include/libxml2"    "$DEST/include/"
# libxslt headers, from the same build and for the same reason: WebCore compiles its XSLT against these
# rather than the SDK's, so the declarations match the dylib deployed beside them.
cp -Rp "$STAGE/include/libxslt"    "$DEST/include/"
[ -d "$STAGE/include/libexslt" ] && cp -Rp "$STAGE/include/libexslt" "$DEST/include/"
for inc in glib-2.0 gio-unix-2.0 gstreamer-1.0 orc-0.4 openssl nghttp2 curl; do
  [ -d "$STAGE/include/$inc" ] && cp -Rp "$STAGE/include/$inc" "$DEST/include/"
done
# FFmpeg headers: WebCore's MediaRecorder MP4 writer (MediaRecorderPrivateWriterMP4.cpp) compiles
# against libavformat's ISO base media muxer, beside the three dylibs the media runtime already
# deploys for gst-libav. The required-artifacts gate below names avformat.h, so a tree that did not
# install stops the run here rather than at the gate.
for inc in libavformat libavcodec libavutil; do
  cp -Rp "$STAGE/include/$inc" "$DEST/include/" || { echo "  FATAL: $STAGE/include/$inc did not install"; exit 1; }
done
mkdir -p "$DEST/lib/glib-2.0/include"
cp -p "$STAGE/lib/glib-2.0/include/glibconfig.h" "$DEST/lib/glib-2.0/include/"
# static libs
for l in libicuuc.a libicui18n.a libicudata.a \
         libgpg-error.a libgcrypt.a libtasn1.a \
         libbrotlicommon.a libbrotlidec.a libbrotlienc.a libwoff2dec.a \
         libwebp.a libwebpdemux.a libsharpyuv.a libavif.a libyuv.a libpng16.a; do
  cp -p "$STAGE/lib/$l" "$DEST/lib/"
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
  "$CCTOOLS/otool" -L "$f" | awk 'NR>1 {print $1}' | { grep "^$STAGE/lib/" || true; } | while read -r dep; do
    "$INT" -change "$dep" "@rpath/$(basename "$dep")" "$f" || exit 1
  done
  # a stray system-libc++ reference repoints onto the deployed toolchain copy (the
  # 10.9 system libc++ lacks the modern C++ runtime symbols; the deployed copy is a
  # superset, so non-C++17 users keep working too)
  # NB: grep writes to /dev/null instead of -q throughout this script -- -q exits at
  # first match, the upstream otool then dies of SIGPIPE, and pipefail turns that
  # into a spurious failure status.
  if "$CCTOOLS/otool" -L "$f" | grep '/usr/lib/libc++\.1\.dylib' > /dev/null; then
    "$INT" -change /usr/lib/libc++.1.dylib "@rpath/libc++.1.dylib" "$f" || exit 1
  fi
  if "$CCTOOLS/otool" -L "$f" | grep '/usr/lib/libc++abi\.dylib' > /dev/null; then
    "$INT" -change /usr/lib/libc++abi.dylib "@rpath/libc++abi.1.dylib" "$f" || exit 1
  fi
  # single-unwinder rule (see the C++ runtime staging comment above): the toolchain's
  # clang++.cfg links @rpath/libunwind.1.dylib; bind it to the system unwinder.
  if "$CCTOOLS/otool" -L "$f" | grep '@rpath/libunwind\.1\.dylib' > /dev/null; then
    "$INT" -change @rpath/libunwind.1.dylib /usr/lib/system/libunwind.dylib "$f" || exit 1
  fi
  # drop every absolute LC_RPATH (staged libdir, toolchain libdir) so nothing points
  # off-tree; the gate below fails if any survives.
  "$CCTOOLS/otool" -l "$f" | awk '/LC_RPATH/{g=1} g&&/ path /{print $2; g=0}' | { grep "^/" || true; } | while read -r r; do
    "$INT" -delete_rpath "$r" "$f" || exit 1
  done
  # each binary resolves its sibling @rpath dependencies from its own location at
  # load time (WebCore dlopens these by absolute path, so nothing above them supplies
  # an rpath).
  if ! "$CCTOOLS/otool" -l "$f" | awk '/LC_RPATH/{g=1} g&&/ path /{print $2; g=0}' | grep -x -F "$rp" > /dev/null; then
    "$INT" -add_rpath "$rp" "$f" || exit 1
  fi
}
collect_dylib() {  # collect_dylib <staged-real-file> <dest-dir> <rpath-to-libdir>
  local f="$1" destdir="$2" rp="$3" id idbase filebase out
  # The canonical deployed name is the basename of the STAGED install name -- read
  # here, BEFORE the -id rewrite below replaces it. (Reading it from the copy after
  # the rewrite yields the file name instead of the majored name, the majored name
  # then never exists in the deployed tree, and every dependent -- gst-libav on
  # libavcodec.62.dylib first among them -- fails to load.)
  id=$("$CCTOOLS/otool" -D "$f" | tail -1)
  idbase=$(basename "$id"); filebase=$(basename "$f")
  case "$idbase" in *.dylib) : ;; *) idbase="$filebase" ;; esac
  out="$destdir/$idbase"
  cp "$f" "$out"
  "$INT" -id "@rpath/$idbase" "$out" || exit 1
  normalize "$out" "$rp"
  # the original on-disk name (e.g. libavcodec.62.28.102.dylib) aliases the canonical
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
  cname=$(basename "$("$CCTOOLS/otool" -D "$real" | tail -1)")
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

collect_tool "$STAGE/libexec/curl"

echo "==== Widevine CDM interface ===="
# Headers only. The module itself is Google's own Widevine CDM, which is not redistributable and
# which WebKit downloads and installs at runtime
# (MavericksSupport/source/WebCore/platform/graphics/gstreamer/eme/WidevineCdmInstaller.h);
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
require_glob "$DEST/lib/libssl.dylib"
require_glob "$DEST/lib/libcrypto.dylib"
require_glob "$DEST/lib/libpsl.5.dylib"
require_glob "$DEST/lib/libnghttp2.14.dylib"
require_glob "$DEST/lib/libnghttp2.dylib"
require_glob "$DEST/lib/libcurl.4.dylib"
require_glob "$DEST/lib/libcurl.dylib"
require_glob "$DEST/include/openssl/ssl.h"
require_glob "$DEST/include/openssl/crypto.h"
require_glob "$DEST/include/nghttp2/nghttp2.h"
require_glob "$DEST/include/curl/curl.h"
require_glob "$DEST/bin/curl"
require_glob "$DEST/lib/libglib-2.0.*.dylib"
require_glob "$DEST/lib/libgstreamer-1.0.*.dylib"
require_glob "$DEST/lib/libgstadaptivedemux-1.0.0.dylib"
require_glob "$DEST/lib/libgsturidownloader-1.0.0.dylib"
require_glob "$DEST/lib/libavcodec.*.dylib"
require_glob "$DEST/lib/libavformat.*.dylib"
require_glob "$DEST/lib/libavutil.*.dylib"
# The MediaRecorder MP4 writer includes <libavformat/avformat.h>.
require_glob "$DEST/include/libavformat/avformat.h"
require_glob "$DEST/lib/libvpx.*.dylib"
require_glob "$DEST/lib/libxml2.*.dylib"
require_glob "$DEST/lib/libxslt.*.dylib"
require_glob "$DEST/lib/libdav1d.*.dylib"
require_glob "$DEST/lib/libmpg123.*.dylib"
# Without this plugin decodebin skips mpegaudioparse and every mp3 keeps its encoder delay.
require_glob "$DEST/lib/gstreamer-1.0/libgstmpg123.dylib"
require_glob "$DEST/lib/libc++.1.dylib"
require_glob "$DEST/lib/libc++abi.1.dylib"
# The static link libraries WebKit's CMake resolves out of this tree by exact path
# (MavericksSupport/cmake/*.cmake, Source/cmake/*.cmake); naming them here catches a
# dropout now instead of as an unresolved-symbol link failure in WebCore.
for a in libicuuc.a libicui18n.a libicudata.a libgpg-error.a libgcrypt.a libtasn1.a \
         libbrotlicommon.a libbrotlidec.a libbrotlienc.a libwoff2dec.a \
         libwebp.a libwebpdemux.a libsharpyuv.a libavif.a libyuv.a libpng16.a; do
  require_glob "$DEST/lib/$a"
done
require_glob "$DEST/include/webp/decode.h"
require_glob "$DEST/include/png.h"
require_glob "$DEST/include/avif/avif.h"
require_glob "$DEST/include/libxml2/libxml/parser.h"
require_glob "$DEST/include/libxslt/xslt.h"
# single-unwinder rule: no libunwind may exist in the deployed set.
if [ -e "$DEST/lib/libunwind.1.dylib" ]; then
  echo "  FAIL: $DEST/lib/libunwind.1.dylib exists (mixed-unwinder hazard; must bind /usr/lib/system/libunwind.dylib)"; REQFAIL=1
fi
for p in libgstcoreelements libgstlibav libgstvpx libgstopus libgstapplemedia libgstosxaudio \
         libgsttypefindfunctions libgstplayback libgstisomp4 libgstmatroska \
         libgstvideoconvertscale libgstaudioconvert libgstaudioresample libgstapp \
         libgstvorbis libgstogg libgstflac libgstwavparse libgstdeinterlace \
         libgstautodetect libgsthls libgstdash; do
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

# Load commands and two-level imports prove who supplies TLS and HLS decryption;
# an unused dylib load command alone cannot satisfy the EVP checks.
for pair in 'libcurl.4.dylib:libssl.dylib' 'libcurl.4.dylib:libcrypto.dylib' \
            'libcurl.4.dylib:libnghttp2.14.dylib' 'libcurl.4.dylib:libpsl.5.dylib' \
            'libssl.dylib:libcrypto.dylib' \
            'gstreamer-1.0/libgsthls.dylib:libcrypto.dylib'; do
  f=${pair%%:*}; dep=${pair#*:}
  if ! "$CCTOOLS/otool" -L "$DEST/lib/$f" | awk 'NR>1{print $1}' | grep -x -F "@rpath/$dep" > /dev/null; then
    echo "$f does not bind @rpath/$dep" >> "$FAILS"
  fi
done
if ! "$CCTOOLS/otool" -L "$DEST/lib/libcurl.4.dylib" | awk 'NR>1{print $1}' \
     | grep -x '/System/Library/Frameworks/GSS.framework/Versions/A/GSS' > /dev/null; then
  echo 'libcurl does not bind the system GSS.framework' >> "$FAILS"
fi
for plugin in libgsthls; do
  "$NMBIN" -m "$DEST/lib/gstreamer-1.0/$plugin.dylib" > "$GATE/$plugin.nm"
  for sym in EVP_CIPHER_CTX_new EVP_CIPHER_CTX_free EVP_CIPHER_CTX_set_padding \
             EVP_DecryptInit_ex EVP_DecryptUpdate EVP_DecryptFinal_ex EVP_aes_128_cbc; do
    if ! grep -E "\\(undefined\\) external _$sym \\(from libcrypto\\)$" "$GATE/$plugin.nm" > /dev/null; then
      echo "$plugin does not import $sym from shared libcrypto" >> "$FAILS"
    fi
  done
done
"$NMBIN" -gU "$DEST/lib/libcrypto.dylib" | awk '{print $NF}' > "$GATE/crypto.exports"
for sym in EVP_CIPHER_CTX_new EVP_CIPHER_CTX_free EVP_CIPHER_CTX_set_padding \
           EVP_DecryptInit_ex EVP_DecryptUpdate EVP_DecryptFinal_ex EVP_aes_128_cbc \
           EVP_CipherInit_ex EVP_CipherUpdate EVP_CipherFinal_ex EVP_get_cipherbyname; do
  if ! grep -Fx "_$sym" "$GATE/crypto.exports" > /dev/null; then
    echo "BoringSSL libcrypto does not export $sym" >> "$FAILS"
  fi
done
for pair in SSL_CTX_new:libssl SSL_new:libssl X509_free:libcrypto; do
  sym=${pair%%:*}; dep=${pair#*:}
  if ! "$NMBIN" -m "$DEST/lib/libcurl.4.dylib" | grep -E "\\(undefined\\) external _$sym \\(from $dep\\)$" > /dev/null; then
    echo "libcurl does not import $sym from $dep" >> "$FAILS"
  fi
done
if "$NMBIN" -gU "$DEST/lib/libcurl.4.dylib" | grep -E ' _(SSL_|SSL_CTX_|OPENSSL_|X509_)' > /dev/null; then
  echo "libcurl exports an embedded TLS implementation" >> "$FAILS"
fi
# Reject extra adaptive/TLS artifacts in both prefixes. Matching the entire public header
# directory also rejects an include/openssl tree from another provider.
for prefix in "$STAGE" "$DEST"; do
  if [ -e "$prefix/lib/gstreamer-1.0/libgstadaptivedemux2.dylib" ] \
     || [ -L "$prefix/lib/gstreamer-1.0/libgstadaptivedemux2.dylib" ]; then
    echo "unexpected adaptive plugin: $prefix/lib/gstreamer-1.0/libgstadaptivedemux2.dylib (rerun with --clean)" >> "$FAILS"
  fi
  extras=$(find "$prefix" \( -name 'libssl.*.dylib' -o -name 'libcrypto.*.dylib' \
      -o -name 'libboringssl*' -o -name 'libboringcrypto*' -o -name libssl.a -o -name libcrypto.a \
      -o -name libgstaes.dylib -o -path '*/include/boringssl' \) -print)
  [ -z "$extras" ] || printf 'unexpected TLS/AES artifact: %s\n' "$extras" >> "$FAILS"
  if ! diff -qr "$BORINGSSL_SRC/include/openssl" "$prefix/include/openssl"; then
    echo "$prefix headers differ from in-tree BoringSSL" >> "$FAILS"
  fi
done
if [ "$("$PKG_CONFIG" --modversion openssl)" != 1.1.1 ] \
   || [ "$("$PKG_CONFIG" --variable=prefix openssl)" != "$STAGE" ]; then
  echo 'openssl.pc does not resolve the staged BoringSSL API' >> "$FAILS"
fi
for element in hlsdemux hlssink hlssink2 dashdemux; do
  if ! GST_REGISTRY="$RUN/gate-registry.bin" GST_PLUGIN_PATH="$DEST/lib/gstreamer-1.0" \
       GST_PLUGIN_SYSTEM_PATH= "$DEST/bin/gst-inspect-1.0" "$element" > /dev/null; then
    echo "$element is not registered" >> "$FAILS"
  fi
done
curl_version=$("$DEST/bin/curl" -q --version) || exit 1
printf '%s\n' "$curl_version"
features=$(printf '%s\n' "$curl_version" | sed -n 's/^Features: //p' | tr ' ' '\n')
for feature in HTTP2 SSL brotli GSS-API SPNEGO NTLM PSL; do
  if ! printf '%s\n' "$features" | grep -Fx "$feature" > /dev/null; then
    echo "curl is missing $feature" >> "$FAILS"
  fi
done

# A loopback TLS server exercises the deployed client: verified TLS 1.3, HTTP/2
# framing, SSL_CTX object exchange, exact plaintext after Brotli decoding, rejection
# of untrusted certificates and corrupt br. AES has a known-answer check; GSS must
# expose SPNEGO, and PSL must reject a public-suffix cookie while accepting a site cookie.
cat > "$GATE/capabilities.c" <<'CAPABILITIES_C'
#include <curl/curl.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/cipher.h>
#include <brotli/encode.h>
#include <libpsl.h>
#include <GSS/GSS.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef OPENSSL_IS_BORINGSSL
#error The deployed headers must be BoringSSL
#endif
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "capability FAIL line %d: %s\n", __LINE__, #x); ERR_print_errors_fp(stderr); exit(1); } } while (0)
static const char body[] = "BoringSSL curl local decrypted response: 0123456789 abcdefghijklmnopqrstuvwxyz\n";
static unsigned char compressed[1024];
static size_t compressed_size = sizeof compressed;
static int ctx_calls, verify_calls;
static char received[1024];
static size_t received_size;
static int verify(int ok, X509_STORE_CTX *store) {
    SSL *ssl = X509_STORE_CTX_get_ex_data(store, SSL_get_ex_data_X509_STORE_CTX_idx());
    CHECK(ssl && SSL_CTX_get_app_data(SSL_get_SSL_CTX(ssl)) == &ctx_calls);
    ++verify_calls;
    return ok;
}
static CURLcode ctx_callback(CURL *curl, void *ctx, void *unused) {
    ++ctx_calls;
    SSL_CTX_set_app_data(ctx, &ctx_calls);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, verify);
    return CURLE_OK;
}
static size_t consume(char *p, size_t size, size_t count, void *unused) {
    size_t n = size * count;
    if (n > sizeof received - received_size) return 0;
    memcpy(received + received_size, p, n); received_size += n;
    return n;
}
static void read_exact(SSL *ssl, void *p, size_t n) {
    while (n) { int r = SSL_read(ssl, p, n); CHECK(r > 0); p = (char *)p + r; n -= r; }
}
static void write_exact(SSL *ssl, const void *p, size_t n) {
    while (n) { int r = SSL_write(ssl, p, n); CHECK(r > 0); p = (const char *)p + r; n -= r; }
}
static int alpn(SSL *ssl, const unsigned char **out, unsigned char *len,
                const unsigned char *in, unsigned int n, void *arg) {
    const unsigned char h2[] = {2,'h','2'};
    CHECK(SSL_select_next_proto((unsigned char **)out, len, h2, sizeof h2, in, n) == OPENSSL_NPN_NEGOTIATED);
    *out = (const unsigned char *)"h2"; *len = 2;
    return SSL_TLSEXT_ERR_OK;
}
static void frame(SSL *ssl, int type, int flags, unsigned stream, const void *p, unsigned n) {
    unsigned char h[9] = {n >> 16, n >> 8, n, type, flags, stream >> 24, stream >> 16, stream >> 8, stream};
    write_exact(ssl, h, sizeof h); if (n) write_exact(ssl, p, n);
}
static void server(int listener, const char *cert, const char *key, int mode) {
    alarm(20);
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method()); CHECK(ctx);
    CHECK(SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM));
    CHECK(SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM));
    CHECK(SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION));
    if ((mode == 1 || mode == 6)) SSL_CTX_set_alpn_select_cb(ctx, alpn, NULL);
    int fd = accept(listener, NULL, NULL); CHECK(fd >= 0);
    SSL *ssl = SSL_new(ctx); CHECK(ssl && SSL_set_fd(ssl, fd));
    int accepted = SSL_accept(ssl);
    if (mode == 3) { CHECK(accepted <= 0); SSL_free(ssl); SSL_CTX_free(ctx); close(fd); return; }
    CHECK(accepted == 1);
    if ((mode == 1 || mode == 6)) {
        char preface[24]; read_exact(ssl, preface, sizeof preface);
        CHECK(!memcmp(preface, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", 24));
        frame(ssl, 4, 0, 0, NULL, 0);
        unsigned stream = 0;
        while (!stream) {
            unsigned char h[9]; read_exact(ssl, h, 9);
            unsigned n = ((unsigned)h[0] << 16) | ((unsigned)h[1] << 8) | h[2];
            CHECK(n < 65536); unsigned char buf[65536]; read_exact(ssl, buf, n);
            if (h[3] == 4 && !(h[4] & 1)) frame(ssl, 4, 1, 0, NULL, 0);
            if (h[3] == 1) {
                CHECK(h[4] & 4);
                stream = ((unsigned)(h[5] & 127) << 24) | ((unsigned)h[6] << 16) | ((unsigned)h[7] << 8) | h[8];
            }
        }
        const unsigned char status200 = 0x88;
        frame(ssl, 1, 4, stream, &status200, 1);
        frame(ssl, 0, 1, stream, body, sizeof body - 1);
    } else {
        char request[8192]; size_t n = 0;
        while (n < sizeof request - 1) { read_exact(ssl, request + n, 1); request[++n] = 0; if (strstr(request, "\r\n\r\n")) break; }
        CHECK(strstr(request, "GET / HTTP/1.1\r\n"));
        CHECK(strstr(request, "Accept-Encoding:") && strstr(request, "br"));
        const char bad[] = "\xff\xff\xff\xff";
        const void *data = mode == 2 ? compressed : mode == 4 ? (const void *)bad : (const void *)body;
        size_t size = mode == 2 ? compressed_size : mode == 4 ? sizeof bad - 1 : sizeof body - 1;
        char header[512];
        int len = snprintf(header, sizeof header, "HTTP/1.1 200 OK\r\nContent-Length: %lu\r\n%sConnection: close\r\n\r\n", (unsigned long)size, mode == 2 || mode == 4 ? "Content-Encoding: br\r\n" : "");
        write_exact(ssl, header, len); write_exact(ssl, data, size);
    }
    SSL_shutdown(ssl); SSL_free(ssl); SSL_CTX_free(ctx); close(fd);
}
static void transfer(const char *cert, const char *key, int mode) {
    int listener = socket(AF_INET, SOCK_STREAM, 0); CHECK(listener >= 0);
    struct sockaddr_in addr; memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(!bind(listener, (struct sockaddr *)&addr, sizeof addr) && !listen(listener, 1));
    socklen_t len = sizeof addr; CHECK(!getsockname(listener, (struct sockaddr *)&addr, &len));
    fflush(NULL); pid_t pid = fork(); CHECK(pid >= 0);
    if (!pid) { server(listener, cert, key, mode); _exit(0); }
    char url[128]; snprintf(url, sizeof url, "https://localhost:%u/", ntohs(addr.sin_port));
    char resolve[128]; snprintf(resolve, sizeof resolve, "localhost:%u:127.0.0.1", ntohs(addr.sin_port));
    struct curl_slist *hosts = curl_slist_append(NULL, resolve); CHECK(hosts);
    CURL *curl = curl_easy_init(); CHECK(curl);
#define OPT(k, v) CHECK(curl_easy_setopt(curl, k, v) == CURLE_OK)
    char error[CURL_ERROR_SIZE] = {0};
    received_size = 0; ctx_calls = 0; verify_calls = 0;
    OPT(CURLOPT_URL, url); OPT(CURLOPT_RESOLVE, hosts); OPT(CURLOPT_PROXY, ""); OPT(CURLOPT_NOPROXY, "*");
    OPT(CURLOPT_TIMEOUT, 15L); OPT(CURLOPT_ERRORBUFFER, error); OPT(CURLOPT_ACCEPT_ENCODING, "");
    OPT(CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_3); OPT(CURLOPT_SSL_CTX_FUNCTION, ctx_callback);
    OPT(CURLOPT_SSL_VERIFYPEER, 1L); OPT(CURLOPT_SSL_VERIFYHOST, 2L);
    OPT(CURLOPT_CAINFO, mode == 3 ? NULL : cert); OPT(CURLOPT_CAPATH, NULL);
    OPT(CURLOPT_HTTP_VERSION, (mode == 1 || mode == 6) ? CURL_HTTP_VERSION_2TLS : CURL_HTTP_VERSION_1_1);
    OPT(CURLOPT_WRITEFUNCTION, consume);
    if (mode == 5 || mode == 6) {
        OPT(CURLOPT_CONNECT_ONLY, CURL_CONNECT_ONLY_REUSABLE);
        CHECK(curl_easy_perform(curl) == CURLE_OK);
        long request_bytes = -1, connections = -1;
        CHECK(curl_easy_getinfo(curl, CURLINFO_REQUEST_SIZE, &request_bytes) == CURLE_OK);
        CHECK(curl_easy_getinfo(curl, CURLINFO_NUM_CONNECTS, &connections) == CURLE_OK);
        CHECK(request_bytes == 0 && connections == 1 && received_size == 0);
        OPT(CURLOPT_CONNECT_ONLY, 0L);
    }
    CURLcode rc = curl_easy_perform(curl);
    if (mode == 5 || mode == 6) {
        long connections = -1;
        CHECK(curl_easy_getinfo(curl, CURLINFO_NUM_CONNECTS, &connections) == CURLE_OK);
        CHECK(connections == 0);
        puts("reusable preconnect: no HTTP request, subsequent transfer reused TLS connection PASS");
    }
    long status = 0, version = 0, proxy = -1;
    CHECK(!curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status));
    CHECK(!curl_easy_getinfo(curl, CURLINFO_HTTP_VERSION, &version));
    CHECK(!curl_easy_getinfo(curl, CURLINFO_USED_PROXY, &proxy));
    fprintf(stdout, "curl capability mode=%d rc=%d http=%ld version=%ld proxy=%ld ctx=%d verify=%d bytes=%lu error=%s\n", mode, rc, status, version, proxy, ctx_calls, verify_calls, (unsigned long)received_size, error);
    curl_easy_cleanup(curl); curl_slist_free_all(hosts); close(listener);
    int child; CHECK(waitpid(pid, &child, 0) == pid && WIFEXITED(child) && !WEXITSTATUS(child));
    CHECK(proxy == 0 && ctx_calls == 1 && verify_calls > 0);
    if (mode == 3) { CHECK(rc == CURLE_PEER_FAILED_VERIFICATION && !received_size); return; }
    if (mode == 4) { CHECK(rc == CURLE_BAD_CONTENT_ENCODING && !received_size); return; }
    CHECK(rc == CURLE_OK && status == 200);
    CHECK(version == ((mode == 1 || mode == 6) ? CURL_HTTP_VERSION_2_0 : CURL_HTTP_VERSION_1_1));
    CHECK(received_size == sizeof body - 1 && !memcmp(received, body, received_size));
}
int main(int argc, char **argv) {
    CHECK(argc == 4); signal(SIGPIPE, SIG_IGN); alarm(110);
    CHECK(strstr(OpenSSL_version(OPENSSL_VERSION), "BoringSSL"));
    CHECK(!curl_global_init(CURL_GLOBAL_DEFAULT));
    const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
    unsigned required = CURL_VERSION_SSL | CURL_VERSION_HTTP2 | CURL_VERSION_BROTLI | CURL_VERSION_GSSAPI | CURL_VERSION_SPNEGO | CURL_VERSION_NTLM | CURL_VERSION_PSL;
    CHECK((info->features & required) == required && strstr(info->ssl_version, "BoringSSL"));
    CHECK(info->nghttp2_ver_num && info->brotli_ver_num);
    void *handle = dlopen(argv[3], RTLD_NOW | RTLD_LOCAL); CHECK(handle);
    CHECK(dlsym(handle, "SSL_CTX_new") == (void *)SSL_CTX_new);
    CHECK(dlsym(handle, "EVP_DecryptUpdate") == (void *)EVP_DecryptUpdate);
    CHECK(dlsym(handle, "X509_free") == (void *)X509_free);
    const psl_ctx_t *psl = psl_builtin(); CHECK(psl && psl_suffix_count(psl) > 1000);
    CHECK(!psl_is_cookie_domain_acceptable(psl, "example.co.uk", "co.uk"));
    CHECK(psl_is_cookie_domain_acceptable(psl, "www.example.co.uk", "example.co.uk"));
    OM_uint32 minor; gss_OID_set mechs = GSS_C_NO_OID_SET;
    CHECK(gss_indicate_mechs(&minor, &mechs) == GSS_S_COMPLETE);
    const unsigned char spnego[] = {0x2b,0x06,0x01,0x05,0x05,0x02}; int found = 0;
    for (size_t i = 0; i < mechs->count; ++i) if (mechs->elements[i].length == sizeof spnego && !memcmp(mechs->elements[i].elements, spnego, sizeof spnego)) found = 1;
    CHECK(found); CHECK(gss_release_oid_set(&minor, &mechs) == GSS_S_COMPLETE);
    /* NIST SP 800-38A F.2.1 AES-128-CBC, first block. */
    const unsigned char k[16] = {0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c};
    const unsigned char iv[16] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
    const unsigned char cipher[16] = {0x76,0x49,0xab,0xac,0x81,0x19,0xb2,0x46,0xce,0xe9,0x8e,0x9b,0x12,0xe9,0x19,0x7d};
    const unsigned char plain[16] = {0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a};
    EVP_CIPHER_CTX *aes = EVP_CIPHER_CTX_new(); CHECK(aes); unsigned char decoded[32]; int n, end;
    CHECK(EVP_DecryptInit_ex(aes, EVP_aes_128_cbc(), NULL, k, iv)); CHECK(EVP_CIPHER_CTX_set_padding(aes, 0));
    CHECK(EVP_DecryptUpdate(aes, decoded, &n, cipher, sizeof cipher)); CHECK(EVP_DecryptFinal_ex(aes, decoded + n, &end));
    CHECK(n + end == 16 && !memcmp(decoded, plain, 16)); EVP_CIPHER_CTX_free(aes);
    CHECK(BrotliEncoderCompress(5, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_TEXT, sizeof body - 1, (const unsigned char *)body, &compressed_size, compressed));
    puts("capability: shared BoringSSL identity, AES known answer, public-suffix rejection, GSS SPNEGO mechanism PASS");
    for (int mode = 0; mode < 7; ++mode) transfer(argv[1], argv[2], mode);
    dlclose(handle); curl_global_cleanup(); puts("curl local TLS/HTTP2/SSL_CTX/Brotli capability PASS"); return 0;
}
CAPABILITIES_C
RANDFILE="$GATE/random-state" /usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -days 1 -subj /CN=localhost \
    -keyout "$GATE/server.key" -out "$GATE/server.pem" || exit 1
( "$CC_VANILLA" -O2 -I"$DEST/include" -I"$STAGE/include" "$GATE/capabilities.c" \
    "$DEST/lib/libcurl.dylib" "$DEST/lib/libssl.dylib" "$DEST/lib/libcrypto.dylib" \
    "$DEST/lib/libpsl.5.dylib" "$DEST/lib/libbrotlienc.a" "$DEST/lib/libbrotlicommon.a" \
    $LDFLAGS -framework GSS -L"$TC/lib" -lc++ -lc++abi \
    -Wl,-rpath,"$DEST/lib" -o "$GATE/capabilities" ) || exit 1
if ! "$GATE/capabilities" "$GATE/server.pem" "$GATE/server.key" "$DEST/lib/libcurl.4.dylib"; then
  echo 'local TLS/HTTP2/SSL_CTX/Brotli/AES/GSS/PSL capability test failed' >> "$FAILS"
fi

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
  "$CCTOOLS/otool" -l "$f" | awk '$1=="cmd"{t=$2}
    $1=="name" && (t=="LC_LOAD_DYLIB"||t=="LC_LOAD_WEAK_DYLIB"||t=="LC_REEXPORT_DYLIB"){print $2}' \
    | sort -u > "$GATE/und/$b.deps"
  # A second ssl/crypto load could give a two-level import another provider with
  # the same basename. Every direct TLS load must name the deployed BoringSSL pair.
  while read -r dep; do
    case "$dep" in
      */libssl.*|*/libcrypto.*)
        case "$dep" in @rpath/libssl.dylib|@rpath/libcrypto.dylib) ;;
          *) echo "TLS library outside the shared BoringSSL pair in $b: $dep" >> "$FAILS";;
        esac;;
    esac
  done < "$GATE/und/$b.deps"
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
  "$CCTOOLS/otool" -l "$f" | awk '$1=="cmd"{t=$2}
    $1=="name" && (t=="LC_LOAD_DYLIB"||t=="LC_LOAD_WEAK_DYLIB"||t=="LC_REEXPORT_DYLIB"){print t, $2}' \
    >> "$GATE/sysdeps.txt"
  # (c) verified: no absolute build-machine LC_RPATH survives normalize
  absrp=$("$CCTOOLS/otool" -l "$f" | awk '/LC_RPATH/{g=1} g&&/ path /{print $2; g=0}' | { grep '^/' || true; })
  if [ -n "$absrp" ]; then echo "absolute LC_RPATH in $b: $absrp" >> "$FAILS"; fi
  # (d) no text-relocation attributes: 10.9 dyld trusts S_ATTR_EXT_RELOC(0x200)/
  # S_ATTR_LOC_RELOC(0x100) on __text and takes its text-relocation path, which leaves the
  # whole __TEXT segment mapped without the execute bit -- the first call into the image
  # (dlopen running the module initializers) dies with SIGBUS. The bits are wrong in a
  # deployed image whether they are genuine (non-PIC code) or inherited from an object file
  # (toolchain/patches/nasm-macho-object-reloc-attrs.patch keeps nasm from stamping them).
  textflags=$("$CCTOOLS/otool" -l "$f" | awk '/sectname __text/{t=1} t&&/flags 0x/{print $2; exit}')
  if [ -n "$textflags" ] && [ $(( textflags & 0x300 )) -ne 0 ]; then
    echo "relocation attributes on __text in $b (flags $textflags)" >> "$FAILS"
  fi
  # no deployed binary may lean on the (pre-C++17) system libc++
  if "$CCTOOLS/otool" -L "$f" | grep '/usr/lib/libc++' > /dev/null; then
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
# Past every gate: deps/build is now what this script and the patches beside it build.
RECIPES_KEY=$(recipes_key) || exit 1
printf '%s\n' "$RECIPES_KEY" > "$DEST/.recipes"
ls "$DEST/lib" | head -40; ls "$DEST/lib/gstreamer-1.0" | wc -l
echo "  build tree: $(du -sh "$SCRATCH" | awk '{ print $1 }') at $SCRATCH, $(df -h / | awk 'NR == 2 { print $4 }') free on /"
