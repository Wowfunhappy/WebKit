#!/bin/bash
# Build the WebKit-on-Mavericks third-party dependencies that are NOT vendored
# elsewhere and NOT available on the 10.9 system:
#
#   libgpg-error, libgcrypt, libtasn1   -> WebCore USE(GCRYPT) WebCrypto
#   brotli (common/dec/enc)             -> WOFF2 + Brotli Content-Encoding
#   woff2 (decoder)                     -> WOFF2 web font decompression
#
# Everything is built with the clang-22 / macOS 10.9 toolchain (which force-
# includes the 10.9 compat header and links the polyfill + MacPorts legacy
# support archives, so the results both build and run on 10.9.5).
#
# Headers + static libs are installed in-tree under MavericksSupport/deps/
# {include,lib} and committed. Source tarballs are downloaded to a scratch
# dir outside the tree. Re-running rebuilds from scratch.
#
# Usage: MavericksSupport/deps/build_deps.sh
set -euo pipefail

TC=/Users/jonathan/Desktop/Compilers/toolchains/clang-22
CMAKE=/Users/jonathan/Desktop/Compilers/toolchains/tools/cmake/bin/cmake
NINJA=/Users/jonathan/Desktop/Compilers/toolchains/tools/ninja/bin/ninja

DEPS_DIR="$(cd "$(dirname "$0")" && pwd)"          # .../MavericksSupport/deps
SCRATCH=/Users/jonathan/Desktop/Compilers/depbuild
SRC="$SCRATCH/src"
STAGE="$SCRATCH/install"                            # full autotools install prefix
DEST="$DEPS_DIR"                                    # in-tree: include/ + lib/

export CC="$TC/bin/clang"
export CXX="$TC/bin/clang++"
export AR="$TC/bin/llvm-ar"
export RANLIB="$TC/bin/llvm-ranlib"
export NM="$TC/bin/llvm-nm"
export MACOSX_DEPLOYMENT_TARGET=10.9
export CFLAGS="-O2 -mmacosx-version-min=10.9"
export CXXFLAGS="-O2 -mmacosx-version-min=10.9"

# The clang-22 toolchain ships clang.cfg / clang++.cfg that force-include the
# 10.9 compat header and link libpolyfill.a + libMacportsLegacySupport.a into
# every invocation. That is correct for building WebKit, but it breaks
# autotools/gnulib feature probes: the force-included header and the
# auto-linked archives make AC_CHECK_FUNC/header-generation misbehave (e.g.
# libgcrypt decides getpid/clock are "missing" and tries to compile #error
# replacement stubs; gnulib's header generator leaks raw typedefs into the
# Makefile -> /bin/sh "syntax error near unexpected token }").
#
# So the autotools deps (libgpg-error/libgcrypt/libtasn1) are compiled with a
# VANILLA clang (--no-default-config): a plain 10.9-targeting compiler whose
# probes see exactly the real 10.9 SDK feature set. The resulting .a is pure
# object code; any post-10.9 libc symbols it might reference (it won't, since
# the 10.9 SDK doesn't declare them) would resolve later at WebKit link time
# where the polyfill IS linked.
VBIN="$SCRATCH/vanilla-bin"
mkdir -p "$VBIN"
# -Wno-implicit-function-declaration / -Wno-implicit-int: these pre-C99 C
# constructs are hard errors in clang >= 16 but were warnings when this code
# was written (e.g. libgcrypt's bench-slope.c calls gettimeofday implicitly).
# Relaxing them is the standard way to build old autotools C with new clang.
LENIENT='-Wno-implicit-function-declaration -Wno-implicit-int'
printf '#!/bin/sh\nexec "%s/bin/clang" --no-default-config %s "$@"\n'   "$TC" "$LENIENT" > "$VBIN/cc";  chmod +x "$VBIN/cc"
printf '#!/bin/sh\nexec "%s/bin/clang++" --no-default-config %s "$@"\n' "$TC" "$LENIENT" > "$VBIN/cxx"; chmod +x "$VBIN/cxx"
CC_VANILLA="$VBIN/cc"
CXX_VANILLA="$VBIN/cxx"

GPG_ERROR=libgpg-error-1.51
GCRYPT=libgcrypt-1.11.0
TASN1=libtasn1-4.20.0
BROTLI=brotli-1.1.0
WOFF2=woff2-1.0.2

mkdir -p "$SRC" "$STAGE" "$DEST/include" "$DEST/lib"

fetch() { # url
  local f; f="$(basename "$1")"
  [ -f "$SRC/$f" ] || ( cd "$SRC" && echo "download $f" && curl -fsSL -m 300 -O "$1" )
}
fresh() { # tarball-basename dirname
  rm -rf "${SCRATCH:?}/build-$2"; mkdir -p "$SCRATCH/build-$2"
  tar xf "$SRC/$1" -C "$SCRATCH/build-$2" --strip-components=1
  echo "$SCRATCH/build-$2"
}

echo "==== sources ===="
fetch https://gnupg.org/ftp/gcrypt/libgpg-error/$GPG_ERROR.tar.bz2
fetch https://gnupg.org/ftp/gcrypt/libgcrypt/$GCRYPT.tar.bz2
fetch https://ftp.gnu.org/gnu/libtasn1/$TASN1.tar.gz
fetch https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz
fetch https://github.com/google/woff2/archive/refs/tags/v1.0.2.tar.gz

echo "==== libgpg-error ===="
d=$(fresh $GPG_ERROR.tar.bz2 gpgerror)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc --disable-tests --disable-languages \
  && make -j4 && make install )

echo "==== libgcrypt ===="
d=$(fresh $GCRYPT.tar.bz2 gcrypt)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc --disable-asm --with-libgpg-error-prefix="$STAGE" \
  && make -j4 && make install )

echo "==== libtasn1 ===="
d=$(fresh $TASN1.tar.gz tasn1)
( cd "$d" && ./configure CC="$CC_VANILLA" --prefix="$STAGE" --disable-shared \
    --enable-static --disable-doc \
  && make -j4 && make install )

echo "==== brotli ===="
d=$(fresh v1.1.0.tar.gz brotli)
( cd "$d" && mkdir -p out && cd out \
  && "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
       -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
       -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
       -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
       -DCMAKE_INSTALL_PREFIX="$STAGE" .. \
  && "$NINJA" && "$NINJA" install )

echo "==== woff2 (decoder) ===="
d=$(fresh v1.0.2.tar.gz woff2)
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

echo "==== collect in-tree artifacts ===="
rm -rf "$DEST/include" "$DEST/lib"; mkdir -p "$DEST/include" "$DEST/lib"
# headers
cp "$STAGE/include/gpg-error.h"   "$DEST/include/"
cp "$STAGE/include/gcrypt.h"      "$DEST/include/"
cp "$STAGE/include/libtasn1.h"    "$DEST/include/"
cp -R "$STAGE/include/brotli"     "$DEST/include/"
cp -R "$STAGE/include/woff2"      "$DEST/include/"
# static libs
for l in libgpg-error.a libgcrypt.a libtasn1.a \
         libbrotlicommon.a libbrotlidec.a libbrotlienc.a libwoff2dec.a; do
  cp "$STAGE/lib/$l" "$DEST/lib/"
done

echo "==== done. in-tree deps: ===="
ls -la "$DEST/lib" "$DEST/include"
