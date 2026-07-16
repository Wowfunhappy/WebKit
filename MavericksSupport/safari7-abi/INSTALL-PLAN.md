# Safari-7 install plan (name-shift + runtime deps)

Derived from inspecting the built frameworks and the stock 10.9 layout. This
records decisions so the install script (`install-safari7.sh`) is auditable.

## Framework name shift

Our CMake build emits, in `WebKitBuild/Release/lib/*.framework`, four frameworks
with `@rpath`-relative install names. They install to the absolute locations
Safari 7 hard-codes in its `LC_LOAD_DYLIB`s, with two renames:

| Built framework  | Installs to                                             | Binary rename       |
|------------------|--------------------------------------------------------|---------------------|
| JavaScriptCore   | `/System/Library/Frameworks/JavaScriptCore.framework`  | (none)              |
| WebKitLegacy     | `/System/Library/Frameworks/WebKit.framework`          | WebKitLegacy→WebKit |
| WebKit (WK2)     | `/System/Library/PrivateFrameworks/WebKit2.framework`  | WebKit→WebKit2      |
| WebCore          | `…/WebKit.framework/Versions/A/Frameworks/WebCore.framework` (nested, stock layout) | (none) |

Safari needs 0 symbols from WebCore directly, but WebKit/WebKitLegacy load it, so
it must sit at a fixed absolute path.

For each installed framework:
- `install_name_tool -id <abs path>` to set LC_ID_DYLIB to the absolute location.
- `install_name_tool -change @rpath/<X>.framework/Versions/A/<X> <abs> ...` to
  rewrite every inter-framework reference from `@rpath/...` to the absolute path.
- Rename the binary file and the `Versions/A/<name>` and the `Versions/Current`
  symlink target; fix `Info.plist` `CFBundleExecutable`.

## libc++ / libc++abi  (DECISION: private deployment, do NOT overwrite /usr/lib)

Our frameworks link the clang-22 toolchain libc++ (C++20/23). Findings:

- The installed system `/usr/lib/libc++.1.dylib` is already a *modern* build
  (2103 exported names, `std::__1` namespace) but is **missing** symbols our
  build needs: `std::__fs::filesystem::*`, `std::bad_optional_access`,
  `std::__1::basic_filebuf`, `std::__1::__libcpp_verbose_abort`,
  `std::__1::__hash_memory`, … (JSC needs ~32, WebCore ~13 real ones).
- The toolchain libc++ HAS all of those, but it is **not a strict superset** of
  the system one: 155 legacy symbols the system exports are absent from the
  toolchain build (old explicit `basic_string` instantiations, `bad_array_length`,
  `adopt_lock`/`defer_lock` data symbols, `__codecvt_utf8` instantiations, …).
  Overwriting `/usr/lib/libc++.1.dylib` could therefore break any pre-existing
  system binary that imports one of those 155.

Therefore: deploy the toolchain `libc++.1.dylib` + `libc++abi.1.dylib`
**privately** and have only our frameworks bind to them. Two-level namespace keeps
our libc++ distinct from the system one in any shared process; our C++ world is
closed and exposes only ObjC/C across the framework ABI, so two libc++ coexist
safely.

Mechanism (per Source/cmake/OptionsMac.cmake:177-184): the build links
`${MAVERICKS_TC}/lib/libc++.1.dylib` + `libc++abi.1.dylib` *dynamically* — they
carry `install_name @rpath/libc++.1.dylib` (resp. abi), and each framework's
LC_RPATH currently lists the toolchain lib dir and the build lib dir (that is how
`@rpath/libc++.1.dylib` resolves at build/test time). The private deployment the
cmake comment refers to is done by `install-safari7.sh` (not a CMake postbuild):
for each installed framework it (1) copies `libc++.1.dylib`/`libc++abi.1.dylib`
into the base framework bundle (`JavaScriptCore.framework`, which every WebKit
framework links), and (2) rewrites `@rpath/libc++*.dylib` to that absolute
in-bundle path with `install_name_tool -change`. It does NOT rely on the
toolchain/build dirs in LC_RPATH — those are developer paths absent on a clean
target.

## ABI gap (see check-abi-gap.sh)

- JavaScriptCore: 95/95 satisfied — no gap.
- WebKit (legacy): 24 needed; 1 gap, `_OBJC_CLASS_$_WebKeyGenerator`, now
  implemented for real in `Source/WebKitLegacy/mac/Misc/WebKeyGenerator.{h,mm}`
  (+sharedGenerator / -addCertificatesToKeychainFromData:, the only two
  selectors Safari sends; the latter imports downloaded certs via SecItemImport).
- WebKit2: 606 needed = 602 C-API funcs (mostly still present upstream) + 4 ObjC
  symbols. WKView and WKBrowsingContextController are built from in-tree source
  (UIProcess/API/mac/WKView.mm, UIProcess/API/Cocoa/WKBrowsingContextController.mm),
  backed by the reconstructed MinimalPageClient. WKWebInspectorProxyObjCAdapter is
  a stub in Source/WebKit/PolyfillClasses_109.mm. Re-run check-abi-gap.sh after WK2
  links for the precise residual C-function gap.

## Backups

Stock frameworks backed up in a `stock-webkit-backup` directory beside the
checkout (verified byte-identical). The install script must back up any existing
target at the install path before overwriting (including /usr/lib/libc++ if ever
touched).
