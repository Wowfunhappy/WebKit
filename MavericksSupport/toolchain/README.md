# toolchain — the in-tree build tools

Everything needed to compile WebKit on a 10.9 host, organized so source vs. artifact
is obvious by location:

- **`vendor/`** — COMMITTED binaries we can't practically rebuild quickly. Today that's
  just clang: `clang-NN` + `lld` (bzip2-compressed), `llvm-ar`, the
  `clang.cfg`/`clang++.cfg` link set, the resource headers, and the private
  `libc++`/`libc++abi`/`libunwind` dylibs.
- **`scripts/`** — COMMITTED source: `build_{cctools,python3,nasm,ninja,cmake,ccache,git}.sh`.
- **`patches/`** — COMMITTED patches the build scripts apply to the tools they build;
  each patch's header states the defect it fixes.
- **`bootstrap.sh`** — assembles `build/` from `vendor/` + `scripts/`.
- **`build/`** — ARTIFACTS (gitignored): the unpacked, usable clang plus the
  from-source helper tools. Delete it and re-run `bootstrap.sh` to reconstruct.

The clang `.cfg` files use clang's `<CFGDIR>` token (`-L/-rpath <CFGDIR>/../lib`), so the
toolchain is relocatable: it finds its own `libc++`/`libc++abi`/`libunwind` wherever it's
unpacked.

## Updating the helper tools (cctools / cmake / ninja / python3 / nasm / ccache / git)

1. Bump `VERSION` (or `VER`) at the top of the relevant `scripts/build_*.sh`.
2. `rm -rf build/<tool>` and re-run `bootstrap.sh` (or just that script).
3. `build/` is gitignored, so the only thing to commit is the script change.

## Updating clang

clang runs **on the 10.9 host**, so a new clang must itself be built to deploy to 10.9.
The in-tree clang is the bootstrap compiler for the next one:

1. **Build the new clang from `llvm-project` source** using the current in-tree clang
   (`build/clang/bin/clang{,++}`) as `CMAKE_C/CXX_COMPILER`, with
   `CMAKE_OSX_DEPLOYMENT_TARGET=10.9` against the SDK, building the runtimes too
   (`clang;lld` in `LLVM_ENABLE_PROJECTS`, `libcxx;libcxxabi;libunwind;compiler-rt` in
   `LLVM_ENABLE_RUNTIMES`). The result must run on 10.9 — the same 10.9-targeting
   constraints the helper-tool scripts handle (SDKROOT for headers; an availability
   shim for `__isPlatformVersionAtLeast`, as in `build_python3.sh`).

2. **Re-vendor into `vendor/clang/`:**
   - `bin/`: copy the new `clang-NN`, `lld`, `llvm-ar` (dereference symlinks to the real
     binaries), then `bzip2 -9 -k` the two large ones (`clang-NN`, `lld`) and keep only the
     `.bz2` committed; carry `clang.cfg`/`clang++.cfg` forward (their `<CFGDIR>` paths are
     version-independent).
   - `lib/`: copy `lib/clang/NN/include` (resource headers), the `compiler-rt` archives
     under `lib/clang/NN/lib/darwin`, and the real `libc++.1.0`/`libc++abi.1.0`/`libunwind.1.0`
     dylibs.

   `vendor/` commits no symlinks: `bootstrap.sh` regenerates the multi-call binary names
   (`clang`/`clang++`/`ld64.lld`/`llvm-ranlib`) and the dylib version chain
   (`libX.dylib`->`libX.1.dylib`->`libX.1.0.dylib`) into `build/`.

3. **Fix the version-specific references** when the major version changes (`NN`):
   `bootstrap.sh` (the `clang-NN.bz2` / `clang-NN` names), the toolchain file
   `../cmake/mac10.9-toolchain.cmake` (the `EXISTS ${_TC}/bin/clang-NN` check), and
   `.gitignore` (`/clang/bin/clang-NN`).

4. `rm -rf build && ./bootstrap.sh`, rebuild WebKit, then `git add vendor/clang`.

## Rust

`scripts/build_rust.sh` prepares the Rust compiler used by the closed-caption
dependency. Producers source `scripts/rust-env.sh` for Cargo, the selected
compiler and its host wrapper. `rust-bootstrap-inputs.json` pins the official
nightly dated 2026-08-12, matching compiler source and LLVM, and the compiler-rt
sources required by the host tools. Generated products and caches live in
`build/rust`, `build/rust-bootstrap` and `build/rust-mavericks`.

The source compiler permits the x86_64 macOS deployment floor of 10.9, preserving
Darwin's ABI and AArch64's 11.0 minimum. Its host sysroot includes the full
upstream library target. Bootstrap checks the compiler's reported deployment
target, emitted Mach-O metadata, and actual Cargo build-script and procedural
macro execution. Source and runtime fingerprints govern reuse under shared
mutation locks.

Host tools bind missing system APIs through a two-level libSystem reexport
backed by the shared polyfill implementations. The matching LLVM provider is
retained, and its tools use native libc++ after an import audit. Explicit-target
Cargo builds rebuild `std` and `panic_unwind` for 10.9 and link the dependency
gap archive. `scripts/test_rust_target.py` verifies the target dylib's deployment
metadata and executes unwinding, destructors, threads, entropy, clocks and file
copying with the native unwinder. It keeps the test library resident through
process exit, matching GStreamer's plugin lifetime.
