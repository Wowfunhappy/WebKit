#!/bin/bash
# Build the pinned Rust host tools and compiler with the Mavericks target floor.
# All installed/downloaded/generated products stay in toolchain/build.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../scripts/build-log.sh"
build_log_open
. "$HERE/rust-env.sh"
"$HERE/../build/python3/bin/python3" "$HERE/build_rust.py"
"$HERE/../build/python3/bin/python3" "$HERE/build_rust_compiler.py"
