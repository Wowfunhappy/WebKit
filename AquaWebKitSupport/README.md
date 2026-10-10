# AquaWebKitSupport

Everything that makes this WebKit fork build and run on **macOS 10.9.5 Mavericks**
with the system-installed **Safari 7.0.6**, kept self-contained so a fresh clone
*is* the build environment.

The build runs on a 10.9 host with a modern compiler (clang-22) against a modern
macOS SDK, with the deployment target pinned to 10.9 so the binaries bind to 10.9's
real frameworks at runtime. This directory vendors the toolchain, the from-source
polyfills for genuinely-missing-on-10.9 symbols, and the build/install scripts.

## The one rule: source vs. artifact

> **If a script can regenerate it, it's an artifact → gitignored, never committed.
> Otherwise it's committed** (source, or a binary we genuinely can't rebuild).

You never have to consult `.gitignore` to know which is which — it's visible from
the directory a file lives in (`vendor/` = committed binary, `scripts/`/`source/`/
`polyfill/` = source, `build/` = regenerable artifact).

## Layout

```
AquaWebKitSupport/
│  (top level = the things you invoke)
├── README.md                   this file
├── LICENSE                     the BSD 2-Clause license of this port's own files
├── NOTICE                      the head of the Acknowledgements file (scripts/generate-acknowledgements.py)
├── bootstrap.sh                fresh-clone setup: toolchain, SDK patches, deps, polyfill archives
├── build.sh                    build: polyfill archives, ninja (configures on first run), stage, audits
├── install.sh                  installer: copy the staged product into the 10.9 system
│
├── cmake/                      the CMake side: mac10.9-toolchain.cmake (the toolchain file) and the
│                               overlays Source/cmake includes (OptionsMacAquaWebKit, *PlatformAquaWebKit)
├── source/                     out-of-tree WebKit source the overlays add to the build (WKViewAquaWebKit.mm, webpushd, …)
├── webclip/                    the Dashboard Web Clip widget's plug-in (WebClip.plugin, WebKit 2 page view) and
│                               WebClip.js.patch for the widget's script; its HTML, images and strings stay Apple's
├── scripts/                    stage-frameworks.sh (the build's last phase: assemble WebKitBuild/Release/staged),
│                               stage-headers.sh (the developer headers and module maps, through upstream's header rules),
│                               framework-layout.sh (sourced: the installed layout, shared by stage + install),
│                               check-absent-references.sh (build gate),
│                               check-gap-archive-current.sh (build.sh runs its --sources-only half; the rest by hand),
│                               check-backport-markers.sh (divergence gate),
│                               check-public-headers.sh (run by hand: every shipped header compiles),
│                               check-imageio-decode.sh (run by hand: no page bytes reach ImageIO),
│                               generate-acknowledgements.py (run by hand: the license texts a distributed build needs),
│                               build-log.sh and host-headers.sh (sourced: the one build log, and the 10.9 header probe),
│                               run-layout-tests.sh (--wk1 | --wk2), build-localized-strings.py
├── polyfill/                   the polyfill layer -- see polyfill/README.md
├── sandbox/                    the sandbox profiles 10.9's sandbox can compile, and scripts/ (check-sandbox-profiles.sh,
│                               the build gate; check-sandbox-applied.sh; watch-sandbox-denials.sh)
├── host-abi/                   the symbols 10.9 binaries bind from our frameworks (Safari 7, the public API, every
│                               binary on a 10.9 system) + check-abi-gap.sh (build gate)
├── sdk/                        patch-sdk.sh: the two edits the build needs in the macOS SDK (run by bootstrap.sh)
├── demangler/                  the demangler guard (_Z -> _z rename so symbolication can't crash), run by staging
├── toolchain/                  the in-tree compiler + helper build tools, incl. a modern git (vendor/ committed, build/ regenerated)
├── deps/                       third-party libraries WebKit links: build/ regenerated, work/ builds it (see deps/README.md)
├── docs/                       prose: upstream-merge notes, the private WebKit ABI reference, the MV2 compatibility API
└── tests/                      manual test pages (see tests/README.md)
```

Every regenerable artifact lives in one of two gitignored places, and everything else is
committed. Each component's `build/` (`toolchain/build`, `deps/build`, `polyfill/build`) holds
what the rest of the tree consumes. `deps/work/` holds what the deps build is made *with* and
nothing outside `deps/build_deps.sh` reads: the source tarballs, the per-package build trees
and install prefix, and that build's own ccache.

## Building (a fresh clone)

1. **Supply the SDK.** The macOS SDK is Apple-proprietary and not redistributed here. Place a
   `MacOSX26.1.sdk` as a **sibling of this checkout** (or set `AQUAWEBKIT_SDK`).

2. **Install Apple's Command Line Tools** (`xcode-select --install`). The toolchain's C tools, the
   third-party deps build and the polyfill layer all target 10.9's own libc, so they compile against
   the host headers in `/usr/include`, which the Command Line Tools install and Xcode.app does not.
   Also install **Xcode 6.2** at `/Applications/Xcode.app` (or put its working `ibtool` on `PATH`).
   Its Interface Builder compiler builds `WebAuthenticationPanel.nib`; bootstrap checks that
   `ibtool` runs before starting the toolchain and dependency builds.

3. **Bootstrap** (once): `bash AquaWebKitSupport/bootstrap.sh` — unpacks the in-tree clang and builds
   cctools/openssl/python3/ruby/nasm/ninja/cmake/ccache/git and GNU sort into `toolchain/build/`, applies the SDK patches, builds the
   third-party libraries into `deps/build/` and the polyfill archives into `polyfill/build/`. Budget
   a couple of hours for a cold run.

4. **Build**: `bash AquaWebKitSupport/build.sh` — configures `WebKitBuild/Release` on the first run,
   builds, stages the complete product in `WebKitBuild/Release/staged/` laid out exactly as it lands
   on disk, and runs the post-build audits. Everything logs to `/tmp/wk_build.log`; wait for
   `REBUILD DONE (rc=0)`.

5. **Install** onto the 10.9 target: `sudo bash AquaWebKitSupport/install.sh`. Installing copies the
   staged tree into `/System`, and reaches two things outside our own frameworks. It clears the
   `com.apple.webkit.webpushd.relocatable` job from the invoking user's launchd session, so the
   daemon serving the previous framework is gone. And because the Dock picks the DashboardClient
   architecture before any of our code runs, it clears the `AllowInternetPlugins` flag in each
   installed widget's `Info.plist` and the recorded `32bit` flags in each user's
   `com.apple.dashboard` preferences, then restarts the Dock to pick that up.

To run layout tests against the build tree (never the installed system), use
`bash AquaWebKitSupport/scripts/run-layout-tests.sh --wk1|--wk2 <tests...>` — the port flag is
mandatory, and the script's header lists the one-time driver-build prereqs.

This port's test suite is what its expectations do not skip, as for every port.
`run-layout-tests.sh --wk1|--wk2` with no test paths runs the layout suite: the suites whose behaviour
crosses into the parts of this port that differ from Apple's (the 10.9 frameworks, the polyfills, the
vendored dependencies and the process model) plus the platform/mac tests. The block at the top of
`LayoutTests/platform/mac-mavericks/TestExpectations` skips the rest; per-test exclusions live there and
in `-wk1` / `-wk2`. `run-api-tests.sh` with no binary runs TestWTF, TestWebCore and TestWebKitAPI against
upstream's `TestExpectations/apitests` and this port's `TestExpectations/platform/mac-mavericks/apitests`.
Alongside them run `tests/cocoa-curl/run.sh` and `polyfill/tests/run-behaviour-tests.sh`. Do not overlap
these runs with each other or with a build, and keep Safari closed during cookie tests (it shares the
system cookie store). Each exclusion records its evidence: an upstream record for the same symptom on the
backend whose code this port uses, a verified capability gap, or a maintainer scope decision; a
Mavericks-only failure is a port defect to fix. A `FAIL` line in an upstream text baseline is expected
output, not a reason to skip. Every executed test must pass; check the summary for zero unexpected
results and no unrun tests, not just the exit status.

## Building software against the installed frameworks

The installed frameworks carry the headers and module maps Apple's build emits for this WebKit
version (`scripts/stage-headers.sh`). The frameworks keep 10.9's names, so the APIs sit where
10.9 put them:

| Framework | Contents | Import | Link |
|---|---|---|---|
| `JavaScriptCore.framework` | the JavaScriptCore API | `<JavaScriptCore/JavaScriptCore.h>` | `-framework JavaScriptCore` |
| `WebKit.framework` | the legacy API (`WebView`, the DOM classes) | `<WebKit/WebKit.h>` | `-framework WebKit` |
| `PrivateFrameworks/WebKit2.framework` | the modern API (`WKWebView`, ...) | `<WebKit2/WebKit2.h>` or `@import WebKit2;` | `-F/System/Library/PrivateFrameworks -framework WebKit2` |

Build with a modern SDK and `-mmacosx-version-min=10.9`, and `-F` a directory holding links to
just these three frameworks: `-F/System/Library/Frameworks` would also put 10.9's own Foundation
and AppKit headers ahead of the SDK's. The headers keep Apple's availability annotations, so post-10.9 API
calls warn under `-Wunguarded-availability` and link weakly. The i386 slice of every framework
is stock 10.9's, whose API is the 10.9 SDK's.

## `polyfill/build/` contents

- `libpolyfill.a` — the C functions and data constants: the libc gap-fills plus the
  framework entry points 10.9 lacks or gets wrong. Force-loaded into every shipped framework
  (`WEBKIT_FRAMEWORK` in `Source/cmake/WebKitMacros.cmake`), which is what makes a polyfill win
  deterministically; also listed plainly by `cmake/OptionsMacAquaWebKit.cmake` for the build-time tools.
- `libpolyfill_methods.a` — the ObjC method polyfills + the selref-scope mechanism, force-loaded into
  WebCore (`Source/WebCore/CMakeLists.txt`).
- `libpolyfill_classes.dylib` — the ObjC class polyfills, one shared definition each.
- `libpolyfill_webkit.a` — force-loaded into WebKit.framework only (`Source/WebKit/CMakeLists.txt`).
- `libwtf_compat.a` — force-loaded into JavaScriptCore (`Source/JavaScriptCore/CMakeLists.txt`).
- `libwk_marker.a` — tags a binary as ours, so method polyfills apply to it and not to a host app.
- `libwidevinegap.dylib` — installed beside Google's Widevine module by WebKit at runtime.

See `polyfill/README.md` before adding a polyfill.
