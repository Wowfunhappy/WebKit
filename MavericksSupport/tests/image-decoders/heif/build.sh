#!/bin/bash
# Build the HEIF decode harness: heif_probe.cc is the libheif call sequence HEIFImageDecoder makes
# (limits, the HEVC-only item check, the decode options), heif-harness.cc drives it.
#
#   MavericksSupport/tests/image-decoders/heif/build.sh           # against deps/build's libheif.a
#   MavericksSupport/tests/image-decoders/heif/build.sh --ubsan   # against a UBSan-trap libheif
#
# --ubsan builds libheif itself from the tarball build_deps.sh cached, with build_deps.sh's own
# libheif configure options and patches, compiled -fsanitize=undefined -fsanitize-trap=undefined so
# undefined behaviour stops the process with SIGILL; the FFmpeg it decodes through is deps/build's.
# Everything lands in WebKitBuild/Release/heif-tests/. run.sh runs it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
DEPS="$ROOT/MavericksSupport/deps/build"
TC="$ROOT/MavericksSupport/toolchain/build/clang/bin"
CMAKE="$ROOT/MavericksSupport/toolchain/build/cmake/bin/cmake"
NINJA="$ROOT/MavericksSupport/toolchain/build/ninja/bin/ninja"
OUT="$ROOT/WebKitBuild/Release/heif-tests"
LOG=/tmp/wk_build.log
export SDKROOT="$(dirname "$ROOT")/MacOSX26.1.sdk"
mkdir -p "$OUT"

MODE=release
[ "${1:-}" = "--ubsan" ] && MODE=ubsan
PREFIX="$DEPS"
FLAGS="-O2 -g"

if [ "$MODE" = ubsan ]; then
    FLAGS="-O1 -g -fno-omit-frame-pointer -fsanitize=undefined -fno-sanitize=vptr,function -fsanitize-trap=undefined"
    PREFIX="$OUT/libheif-ubsan"
    VERSION=$(sed -n 's/^echo "==== libheif \([0-9.]*\) ====".*/\1/p' "$ROOT/MavericksSupport/deps/build_deps.sh")
    TARBALL="$ROOT/MavericksSupport/deps/work/tarballs/libheif-$VERSION.tar.gz"
    [ -f "$TARBALL" ] || { echo "heif tests: $TARBALL is missing; run build_deps.sh" >&2; exit 1; }
    SRC="$OUT/libheif-ubsan-src"
    rm -rf "$SRC" "$PREFIX"
    mkdir -p "$SRC"
    tar -xzf "$TARBALL" -C "$SRC" --strip-components=1
    for p in $(grep -o 'patches/libheif-[A-Za-z0-9._-]*\.patch' "$ROOT/MavericksSupport/deps/build_deps.sh" | sort -u); do
        ( cd "$SRC" && patch -p1 < "$ROOT/MavericksSupport/deps/$p" )
    done
    # The configure options are build_deps.sh's libheif section's, read from it.
    OPTIONS=$(awk '/^echo "==== libheif /{on=1} on && /-DENABLE_PLUGIN_LOADING|-DWITH_|-DCMAKE_DISABLE_FIND_PACKAGE_|-DBUILD_TESTING|-DBUILD_DOCUMENTATION/{print} on && /finished libheif/{exit}' \
        "$ROOT/MavericksSupport/deps/build_deps.sh" | tr -d '\\' | sed 's/"\$STAGE"/'"$(printf '%s' "$DEPS" | sed 's/[\/&]/\\&/g')"'/g')
    {
        echo "### heif tests: UBSan-trap libheif $VERSION"
        mkdir -p "$SRC/out"
        cd "$SRC/out"
        CFLAGS="$FLAGS -mmacosx-version-min=10.9" CXXFLAGS="$FLAGS -mmacosx-version-min=10.9" \
        "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_BUILD_TYPE=None -DBUILD_SHARED_LIBS=OFF \
            -DCMAKE_C_COMPILER="$TC/clang" -DCMAKE_CXX_COMPILER="$TC/clang++" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 $OPTIONS \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib .. \
        && "$NINJA" -j2 heif && "$CMAKE" --install .
    } >> "$LOG" 2>&1 || { echo "heif tests: the UBSan libheif build failed; see $LOG" >&2; exit 1; }
fi

{
    echo "### heif tests: harness ($MODE)"
    for src in heif_probe heif-harness; do
        "$TC/clang++" -std=c++20 $FLAGS -mmacosx-version-min=10.9 -I"$PREFIX/include" \
            -c "$HERE/$src.cc" -o "$OUT/$src-$MODE.o"
    done
    "$TC/clang++" -mmacosx-version-min=10.9 "$OUT/heif_probe-$MODE.o" "$OUT/heif-harness-$MODE.o" \
        "$PREFIX/lib/libheif.a" -L"$DEPS/lib" -lavcodec -lavutil -Wl,-rpath,"$DEPS/lib" \
        -o "$OUT/heif-harness-$MODE"
} >> "$LOG" 2>&1 || { echo "heif tests: the harness build failed; see $LOG" >&2; exit 1; }
echo "$OUT/heif-harness-$MODE"
