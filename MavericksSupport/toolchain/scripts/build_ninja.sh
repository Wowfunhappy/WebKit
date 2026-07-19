#!/bin/bash
# Build ninja from source into the toolchain build tree (toolchain/build/ninja,
# gitignored). Built with the in-tree clang. All paths relative to this script.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${NINJA_PREFIX:-$TOOLCHAIN/build/ninja}"
VERSION=1.12.1
# Host tools are C++: clang must find libc++ headers, which live in the SDK. configure.py
# forwards CXXFLAGS to both compiles and links, so the sysroot goes in there rather than in
# SDKROOT -- the /usr/bin/ar xcrun shim reads SDKROOT too, and on a host where Xcode is the
# selected developer dir it refuses to run when it names an SDK Xcode has no record of, which
# kills the post-bootstrap rebuild's libninja.a step (Command-Line-Tools-only hosts tolerate
# it). MACOSX_DEPLOYMENT_TARGET pins the 10.9 deploy target so the result still runs on host.
REPO="$(cd "$TOOLCHAIN/../.." && pwd)"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
export MACOSX_DEPLOYMENT_TARGET=10.9
# ninja's configure.py needs python3 (its ninja_syntax.py uses py3 annotations).
# Prefer the in-tree python3 (bootstrap.sh builds it before ninja); else a python3
# on PATH. Never fall back to python2.
PY="$TOOLCHAIN/build/python3/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3 || true)"
if [ -z "${PY:-}" ] || ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
    echo "build_ninja.sh needs python3. Run MavericksSupport/toolchain/bootstrap.sh (it builds the" >&2
    echo "in-tree python3 before ninja), or put a python3 on PATH." >&2
    exit 1
fi
WORK="$(mktemp -d -t ninja-build)"
trap 'rm -rf "$WORK"' EXIT

echo "### Downloading ninja $VERSION"
curl -fsSL -o "$WORK/ninja.tar.gz" "https://github.com/ninja-build/ninja/archive/refs/tags/v${VERSION}.tar.gz"
tar xzf "$WORK/ninja.tar.gz" -C "$WORK"
cd "$WORK/ninja-${VERSION}"
echo "### Bootstrapping ninja with the in-tree clang++"
CXX="$CLANG/bin/clang++" CXXFLAGS="-isysroot $SDK" "$PY" configure.py --bootstrap
mkdir -p "$PREFIX/bin"
cp ninja "$PREFIX/bin/ninja"
"$PREFIX/bin/ninja" --version
echo "### ninja OK -> $PREFIX/bin/ninja"
