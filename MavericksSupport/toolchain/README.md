# toolchain — the in-tree build tools

Everything needed to compile WebKit on a 10.9 host, organized so source vs. artifact
is obvious by location:

- **`vendor/`** — COMMITTED binaries we can't practically rebuild quickly. Today that's
  just clang: `clang-NN` + `lld` (bzip2-compressed), `llvm-ar/nm/objcopy`, the
  `clang.cfg`/`clang++.cfg` link set, the resource headers, and the private
  `libc++`/`libc++abi`/`libunwind` dylibs.
- **`scripts/`** — COMMITTED source: `build_{python3,nasm,ninja,cmake,ccache}.sh`.
- **`patches/`** — COMMITTED patches the build scripts apply to the tools they build;
  each patch's header states the defect it fixes.
- **`bootstrap.sh`** — assembles `build/` from `vendor/` + `scripts/`.
- **`build/`** — ARTIFACTS (gitignored): the unpacked, usable clang plus the
  from-source helper tools. Delete it and re-run `bootstrap.sh` to reconstruct.

The clang `.cfg` files use clang's `<CFGDIR>` token (`-L/-rpath <CFGDIR>/../lib`), so the
toolchain is relocatable: it finds its own `libc++`/`libc++abi`/`libunwind` wherever it's
unpacked.

## Updating the helper tools (cmake / ninja / python3 / nasm / ccache)

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
   - `bin/`: copy the new `clang-NN`, `lld`, `llvm-ar`, `llvm-nm`, `llvm-objcopy`
     (dereference symlinks to the real binaries), then `bzip2 -9 -k` the two large ones
     (`clang-NN`, `lld`) and keep only the `.bz2` committed; carry `clang.cfg`/`clang++.cfg`
     forward (their `<CFGDIR>` paths are version-independent).
   - `lib/`: copy `lib/clang/NN/include` (resource headers), the `compiler-rt` archives
     under `lib/clang/NN/lib/darwin`, and the real `libc++.1.0`/`libc++abi.1.0`/`libunwind.1.0`
     dylibs.

   `vendor/` commits no symlinks: `bootstrap.sh` regenerates the multi-call binary names
   (`clang`/`clang++`/`ld64.lld`/`llvm-ranlib`/`llvm-strip`) and the dylib version chain
   (`libX.dylib`->`libX.1.dylib`->`libX.1.0.dylib`) into `build/`.

3. **Fix the version-specific references** when the major version changes (`NN`):
   `bootstrap.sh` (the `clang-NN.bz2` / `clang-NN` names), the toolchain file
   `../cmake/mac10.9-toolchain.cmake` (the `EXISTS ${_TC}/bin/clang-NN` check), and
   `.gitignore` (`/clang/bin/clang-NN`).

4. `rm -rf build && ./bootstrap.sh`, rebuild WebKit, then `git add vendor/clang`.
