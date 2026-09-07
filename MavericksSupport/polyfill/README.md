# The polyfill layer

This port's approach to a 10.9 incompatibility is to polyfill it, so that WebKit's own source stays
byte-identical to upstream. This directory is where those polyfills live.

**Writing one should require no knowledge of how any of this loads.** Declare the polyfill for a
symbol 10.9 lacks; the layer guarantees it is what WebKit uses, and that nothing outside WebKit is
affected. Verify the symbol really is absent on 10.9 — the build gate (below) fails if it is not — but
you never have to reason about archives, link order or export tables. If you find yourself doing that,
something here has failed and should be fixed rather than worked around.

## Where things go

| Directory | What it holds |
|---|---|
| `polyfills/` | **The polyfills.** The rule below says which file. |
| `mechanism/` | How the layer loads. You should not need to read this to add a polyfill. |
| `headers/` | Header overlays on every WebKit compile's include path (`-idirafter`): declarations the modern tree includes that no SDK provides, and the port's `WebKitAdditions/AdditionalPlatformHave.h`. |
| `tests/` | `mechanism/` checks the layer's guarantees hold on this OS, `behaviour/` checks one polyfill each (named after its framework), `gates/` holds the shadow gates' probe programs. `build-polyfill.sh` runs them all on every build. |
| `build-polyfill.sh` | The build. |
| `build/` | Its output (gitignored). |

Inside `polyfills/`, **the directory says which image(s) the code lands in and how, and the file is
named after the system framework or library that owns the symbols** (the first argument of every
`WK_POLYFILL_*` macro):

| Directory | Lands in | Holds |
|---|---|---|
| `c/` | `libpolyfill.a`, force-loaded into **every** WebKit image, hidden | C functions and data constants, and the load-time patches that run from a constructor. `CoreText.c`, `AppKit.m`, `libSystem.m` (libc, dyld, xpc, dispatch, os_log, pthread, mach), `Security.c`, `CFNetwork.c`, `GStreamer.c` … A helper two files need goes in a header in `c/`. |
| `methods/` | `libpolyfill_methods.a`, force-loaded into **WebCore** (with the selref-scope mechanism) | Objective-C methods on system classes, by the framework owning the class: `AppKit.m`, `Foundation.m`, `QuartzCore.m`, `PDFKit.m`, `AVFoundation.m` … |
| `classes/` | `libpolyfill_classes.dylib`, one shared, exported definition each | Objective-C classes 10.9 does not have at all, by owning framework. |
| `shared/` | `libpolyfill.a` **and** the vendored non-WebKit builds (`deps/build_deps.sh`, `toolchain/scripts/build_python3.sh`) | Plain C compiled against the host headers, with no `wk_polyfill.h` dependency: the libc gap-fills (`shared/LICENSE`, wrapper headers in `shared/include/`) and this port's own. A registry entry may be added under `#ifdef WK_POLYFILL_REGISTERED`, which only this layer's build defines — that is how `jit.c`'s deliberate `mmap` override shows up in `WK_POLYFILL_REPORT`. Put a polyfill here only when something outside WebKit compiles it. |
| `webkit/` | `libpolyfill_webkit.a`, force-loaded into **WebKit.framework** only (ARC) | Units whose ObjC classes must register in WebKit alone: `websocket.mm` (NSURLSessionWebSocketTask over CFStream), the stub classes Safari binds out of WebKit. |
| `jsc/` | `libwtf_compat.a`, force-loaded into **JavaScriptCore** only | The WTF C++ entry points Safari 7 binds by mangled name. |
| `cdm/` | `libwidevinegap.dylib`, loaded by the Widevine CDM | The libSystem entry points Google's module imports and 10.9 lacks. |

## Adding a polyfill

### A C function or data constant

Include `wk_polyfill.h`. The first argument names whichever framework owns the symbol on 10.9
(`"CoreText"`, an absolute path for a non-framework library, or `NULL` for libSystem).

```c
// The default, for a symbol 10.9 LACKS. The body runs. If 10.9 turns out to have the symbol, the
// build gate rejects it -- so verify absence on-host rather than guessing.
WK_POLYFILL_ABSENT("CoreGraphics", CGImageRef, CGIOSurfaceContextCreateImageReference,
                   (CGContextRef context))
{
    return CGIOSurfaceContextCreateImage(context);
}

// Use this when 10.9 HAS the function but it misbehaves and you mean to replace it. The body always
// runs, and WK_ORIGINAL reaches 10.9's version (NULL if there isn't one).
WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontManagerCreateFontDescriptorFromData,
                     (CFDataRef data))
{
    ...
    if (WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData))
        return WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)(data);
    return NULL;
}

// A data constant 10.9 LACKS. The declared value is the value; there is no mirroring. As with a
// function, the gate rejects a gap-fill constant 10.9 actually exports.
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedRange,
                  CFSTR("kCGColorSpaceExtendedRange"));
```

`WK_POLYFILL_ABSENT` and `WK_POLYFILL_REPLACES` are one mechanism, differing only in the intent the
gate reads; both take a single parameter list and run the body directly (a variadic function is fine).

If the body needs to call some *other* 10.9 function that WebKit's frameworks may not all link,
declare it with `WK_SYSTEM_FN` and call it through `WK_SYSTEM(name)` instead of calling it directly.

### An Objective-C method on a system class

In `methods/<Framework>.m`, write the method under its real name inside a block naming the class:

```objc
WK_POLYFILL_ADD_METHODS(NSGraphicsContext)
- (CGContextRef)CGContext { ... }
@end
```

WebKit's call sites keep saying `[ctx CGContext]`; only WebKit's own binaries are redirected to a
private selector the mechanism installs on the class, so the public selector never appears on it. The
block is a subclass of the named class that nothing instantiates: the compiler checks the signature
against the SDK's declaration and `self` is typed. You do not need to work out which other classes
might share the selector — a class that has the real method gets its own implementation automatically.

Like a C gap-fill, this is for a method 10.9 LACKS: the body runs, and the build gate rejects an
`ADD` whose method 10.9 actually implements. When *deliberately shadowing* a method 10.9 HAS is the
point, use the counterpart of `WK_POLYFILL_REPLACES`, and reach the implementation replaced with
`WK_ORIGINAL_METHOD(RET, (ARG TYPES), args...)`:

```objc
WK_POLYFILL_REPLACE_METHODS(NSPopover)
- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)edge
{
    WK_ORIGINAL_METHOD(void, (NSRect, NSView *, NSRectEdge), rect, view, edge);
    ...
}
@end
```

For a class the archive cannot link against — one that moved frameworks after 10.9, a private class,
or a class cluster whose private concrete class must be listed too — the `_ON` forms name the classes
by string; the first argument is only the typing superclass:

```objc
WK_POLYFILL_ADD_METHODS_ON(NSObject, "NSURLSessionTask", "__NSCFURLSessionTask")
- (float)priority { ... }
@end
```

### An Objective-C class 10.9 lacks entirely

Add the stub to `classes/<Framework>.m`.

### Looking up a private symbol of a system framework

`polyfills/c/wk_symbols.h` provides image-local symbol lookup for the protection-space secure-coding
bridge in `CFNetwork.c` (`SerializableArchive::add`). This lets the bridge archive the actual native
protection space used by Safari's authentication and certificate APIs.

Cookie parsing and mutation notifications are WebCore's. The polyfill keeps the native jar metadata
10.9 needs to preserve SameSite across storage and process boundaries.

## Checking what actually happened

Set `WK_POLYFILL_REPORT=1` in the environment to have each process print its polyfill table: every
symbol, whether 10.9 has it, and which side won. `WK_POLYFILL_REPORT=abort` additionally fails the
process if a `WK_POLYFILL_REPLACES` targets a symbol 10.9 does not have — i.e. if the premise behind
a replacement ("10.9 has this but it is broken") is wrong.

`build-polyfill.sh` runs `tests/mechanism/wk_polyfill_test.c` on every build, which checks the layer's
guarantees against real system symbols on both sides of the present/absent line, then the rest of
`tests/mechanism/` and every probe in `tests/behaviour/`.

It then runs the shadow gates (probe programs `tests/gates/`), which ask the running 10.9 (via
`dlopen`/`dlsym`, not the build SDK) whether any symbol the built archives define is one 10.9 already
provides. Because every polyfill body runs unconditionally, a defined symbol 10.9 also has is a silent
shadow, so it must be declared `WK_POLYFILL_REPLACES` or the build fails — for registry symbols and for
the plain-C `shared/` and mechanism units alike. There is no allowlist: every symbol the layer knowingly
shadows says so in the registry, where the loader and `WK_POLYFILL_REPORT` see it.

The gates ask the ObjC runtime the same question about every method block: they enumerate each
block's methods and target classes out of the built method objects, and then — in a second program
with none of the layer linked in, so what it sees is the system's own — walk each target class and its
superclasses for the public selector. An `ADD` method 10.9 already implements fails the build (the
rewrite makes WebKit run the body in place of 10.9's) unless it is in a `REPLACE` block; so does the
same method defined for one class by two blocks, or a `REPLACE` of one selector on two classes of a
single inheritance chain. A `WK_POLYFILL_CLASS` stub for a class 10.9 has fails the same way.

## How it works, in brief

Read this only if you are changing the mechanism itself.

- **C functions and data constants** are compiled into `libpolyfill.a`, which is **force-loaded** into
  each shipped framework. Every member therefore becomes part of the image, and an image binds its own
  references to its own definitions in preference to importing from a dylib — so the polyfill wins
  regardless of link order and regardless of weak imports. force_load is what makes that hold: an
  ordinary archive contributes a member only when it resolves a still-undefined symbol at the point the
  linker reaches it, which makes the winner depend on where the archive sits on the link line and on
  whether some unrelated symbol drags the member in — a choice that flips under unrelated edits.
- The polyfills are compiled `-fvisibility=hidden`, so they satisfy references inside WebKit's own
  binaries and are invisible to everything else in the process.
- A registry emitted alongside each declaration lets the loader (`mechanism/wk_polyfill_runtime.c`)
  resolve `WK_ORIGINAL` on first use and answer `dlsym` for polyfilled names — the latter so that
  WebKit's soft-linking (`SOFT_LINK_CONSTANT`, `SOFT_LINK_FUNCTION`), which looks symbols up on a
  framework handle, sees the same answer the linker would.
- **Objective-C methods** cannot be scoped by the linker, since dispatch keys on the selector. Each
  block's methods are installed on the target class under a private `wk_` selector at load and each of
  our own binaries has its `__objc_selrefs` rewritten to match, so a host app embedding WebKit still
  sees the unmodified class and its `respondsToSelector:` answers are unchanged.
