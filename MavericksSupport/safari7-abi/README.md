# Safari 7 ABI contract

The target is the stock **Safari 7.0.6 (WebKit 9537.78.2)** that shipped with
macOS 10.9.5. We must NOT modify Safari; instead our backported frameworks
must export the symbols Safari binds against, installed where Safari looks.

## Where Safari 7 loads WebKit (absolute LC_LOAD_DYLIB paths in Safari.framework)

| Safari-7 framework | Path | current_version | Maps to modern WebKit |
|---|---|---|---|
| JavaScriptCore | `/System/Library/Frameworks/JavaScriptCore.framework` | 537.78.1 | JavaScriptCore.framework |
| WebKit (WebKit1 / `WebView`) | `/System/Library/Frameworks/WebKit.framework` | 537.78.2 | **WebKitLegacy.framework** |
| WebKit2 (WK2 C API / `WKView`) | `/System/Library/PrivateFrameworks/WebKit2.framework` | 537.78.2 | **WebKit.framework** |
| WebCore (internal) | nested in `WebKit.framework/Frameworks/WebCore.framework` | 537.78.2 | WebCore (built into the above) |

Note the **name shift**: in the 10.9 layout `WebKit.framework` is the *legacy*
WebView framework and `WebKit2.framework` is the multiprocess one. In modern
WebKit those are `WebKitLegacy.framework` and `WebKit.framework` respectively.
compatibility_version is 1.0.0 for all; our build's current_version 615.1.1
satisfies dyld's `>= 537.78.x` check.

StagedFrameworks/Safari (the Safari-9 mechanism the previous effort targeted)
is unused by Safari 7 and empty.

## The symbol contract (Safari.framework imports, by providing framework)

Computed as `comm -12 safari-imports.txt exports-<fw>.txt` from the stock
binaries (backed up at /Users/jonathan/Desktop/stock-webkit-backup):

| Provider | # symbols Safari needs | file |
|---|---|---|
| WebKit2 | 606 | `safari-needs-from-WebKit2.txt` |
| JavaScriptCore | 95 | `safari-needs-from-JavaScriptCore.txt` |
| WebKit | 24 | `safari-needs-from-WebKit.txt` |
| WebCore | 0 | — |
| (system: libobjc/Foundation/AppKit/…) | 1385 | `safari-imports-from-elsewhere.txt` |

Safari imports 2110 symbols total. Our three frameworks must export the
606 + 95 + 24 = 725 listed there (plus whatever the WebKit XPC services and
other system clients need — those services are part of our WebKit2 build so
their needs are internal). Many of the 606 WK2 C-API symbols (WKPage*,
WKContext*, WKArray*, …) still exist in modern WebKit and need no shim; the
gaps (e.g. `WKView`, `WKBrowsingContextController` ObjC classes removed
upstream) get polyfilled.

## Files here
- `exports-<fw>.txt` — defined external symbols of each stock 537 framework
- `safari-imports.txt` — all undefined symbols Safari.framework imports
- `safari-needs-from-<fw>.txt` — the per-framework contract (the must-export set)
- `all-webkit-exports.txt`, `safari-imports-from-elsewhere.txt` — derivations

Regenerate with the commands in the project history; inputs are the stock
framework backups.
