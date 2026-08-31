#!/bin/bash
# Build the Ruby interpreter WebKit's build-time code generators run on (the 10.9
# system ships 2.0), together with the libyaml its psych extension links --
# GeneratePreferences.rb, GenerateSettings.rb and generate-abstract-heap.rb read
# their inputs through `require "yaml"`. Built with the in-tree clang-22 targeting
# 10.9 so it runs on the 10.9 build host. Installs into the toolchain tree
# (toolchain/build/ruby, gitignored; rebuilt by bootstrap.sh). All paths are derived
# relative to this script -- no absolute/user-specific paths.
set -euo pipefail
LOG=/tmp/wk_build.log
# The one build log: this script routes its own output there, so a bare invocation fills it.
exec >> "$LOG" 2>&1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${RUBY_PREFIX:-$TOOLCHAIN/build/ruby}"
CCDIR="$TOOLCHAIN/build/ruby-cc"
YAML_VER=0.2.5
VER=3.4.9
SCRATCH="$(mktemp -d -t rubybuild)"
trap 'rm -rf "$SCRATCH"' EXIT

# Vanilla cc wrapper: the in-tree clang without its forced config, tolerant of the
# legacy C in Ruby's configure probes. It lives in the toolchain build tree because
# rbconfig records this path as the interpreter's compiler.
mkdir -p "$CCDIR/bin"
printf '#!/bin/sh\nexec "%s/bin/clang" --no-default-config -Wno-implicit-function-declaration -Wno-implicit-int "$@"\n' "$CLANG" > "$CCDIR/bin/cc"
chmod +x "$CCDIR/bin/cc"

rm -rf "$PREFIX"
export MACOSX_DEPLOYMENT_TARGET=10.9
cd "$SCRATCH"

echo "### Downloading libyaml $YAML_VER"
curl -fsSLO "https://github.com/yaml/libyaml/releases/download/$YAML_VER/yaml-$YAML_VER.tar.gz"
tar xf "yaml-$YAML_VER.tar.gz"
( cd "yaml-$YAML_VER"
  echo "### Configuring libyaml (prefix=$PREFIX)"
  # Static only: psych links libyaml into its own bundle, so the interpreter carries
  # no library search of its own.
  ./configure CC="$CCDIR/bin/cc" CFLAGS="-O2" --prefix="$PREFIX" --disable-shared
  echo "### Building + installing libyaml"
  make -j"$(sysctl -n hw.ncpu)"
  make install )

echo "### Downloading Ruby $VER"
curl -fsSLO "https://cache.ruby-lang.org/pub/ruby/${VER%.*}/ruby-$VER.tar.gz"
tar xf "ruby-$VER.tar.gz"
cd "ruby-$VER"
echo "### Configuring Ruby (prefix=$PREFIX)"
# The wrapper drops clang's forced config, so the compile reads 10.9's own headers and
# configure can only detect API this host really has. Two of them Ruby reaches for
# without asking:
#   MAP_ANONYMOUS -- 10.9's <sys/mman.h> spells the anonymous-mapping flag MAP_ANON
#   alone, and io_buffer.c uses the later spelling of the same value.
#   FAST_FALLBACK_INIT_INETSOCK_IMPL 0 -- the socket extension's plain connect path.
#   Its Happy Eyeballs path, which ext/socket/rubysocket.h selects wherever pthreads
#   exist, times its resolution races with clock_gettime(CLOCK_MONOTONIC), 10.12 API.
# debugflags empty leaves this build-time tool without debug info, as with the
# toolchain's other from-source builds.
./configure CC="$CCDIR/bin/cc" \
    CPPFLAGS="-DMAP_ANONYMOUS=MAP_ANON -DFAST_FALLBACK_INIT_INETSOCK_IMPL=0" debugflags= \
    --prefix="$PREFIX" --with-libyaml-dir="$PREFIX" --disable-install-doc
echo "### Building + installing Ruby"
make -j"$(sysctl -n hw.ncpu)"
make install
echo "=== ruby built ==="
"$PREFIX/bin/ruby" --version
# Every stdlib WebKit's build-time generators require, in one load.
"$PREFIX/bin/ruby" -e 'require "date"; require "digest"; require "digest/sha1"; require "erb"; require "fileutils"; require "getoptlong"; require "json"; require "optparse"; require "pathname"; require "set"; require "shellwords"; require "stringio"; require "strscan"; require "yaml"; puts "ok #{RUBY_VERSION} psych #{Psych::LIBYAML_VERSION}"'
