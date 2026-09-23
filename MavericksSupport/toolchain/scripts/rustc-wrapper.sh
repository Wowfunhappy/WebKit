#!/bin/bash
# Cargo's RUSTC_WRAPPER protocol: first argument is the compiler. Cargo omits
# --target for its host build scripts/proc macros, and supplies it for the
# explicitly selected target even when host and target triples are identical.
set -euo pipefail
compiler="$1"
shift
for argument in "$@"; do
    case "$argument" in
        --target|--target=*|-V|--version|-vV|-h|--help|--explain|--print|--print=*)
            exec "$compiler" "$@" ;;
    esac
done
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
toolchain="$(cd "$scripts/.." && pwd)"
repo="$(cd "$toolchain/../.." && pwd)"
prefix="${MAVERICKS_RUST_PREFIX:-$toolchain/build/rust}"
sdk="${MAVERICKS_SDK:-$(dirname "$repo")/MacOSX26.1.sdk}"
exec "$compiler" "$@" \
    -C "linker=$toolchain/build/clang/bin/clang" \
    -C link-arg=--no-default-config \
    -C link-arg=-isysroot -C "link-arg=$sdk" \
    -C link-arg=-mmacosx-version-min=10.9 -C link-arg=-fuse-ld=lld \
    -C "link-arg=-Wl,-force_load,$prefix/lib/libRustHostSupport.a"
