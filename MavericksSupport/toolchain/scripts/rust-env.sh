#!/bin/bash
# Sourced by Cargo producers. Host tools use their pinned standard library;
# shipped target crates explicitly select a target and rebuild std for 10.9.
_wk_rust_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MAVERICKS_RUST_PREFIX="${MAVERICKS_RUST_PREFIX:-$(cd "$_wk_rust_scripts/.." && pwd)/build/rust}"
export CARGO="$MAVERICKS_RUST_PREFIX/bin/cargo"
export RUSTC="$(cd "$_wk_rust_scripts/.." && pwd)/build/rust-mavericks/bin/rustc"
export RUSTC_WRAPPER="$_wk_rust_scripts/rustc-wrapper.sh"
export CARGO_HOME="$MAVERICKS_RUST_PREFIX/cargo-home"
unset _wk_rust_scripts
