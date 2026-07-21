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
| `polyfills/` | **The polyfills.** Grouped by what the symbol is. |
| `mechanism/` | How the layer loads. You should not need to read this to add a polyfill. |
| `legacy-support/` | Vendored POSIX/libc gap-fills (macports-legacy-support), kept close to upstream. |
| `tests/` | Checks that the layer's guarantees actually hold on this OS. |
| `scripts/` | The build. |

Inside `polyfills/`:

| File | What belongs in it |
|---|---|
| `constants.m` | Every data constant. |
| `runtime.m` | libSystem: libc, dyld, xpc, dispatch, os_log, pthread, mach. |
| `graphics.c` | CoreGraphics, CoreText, QuartzCore, Accelerate, ImageIO, CoreVideo, IOKit. |
| `system-spi.m` | Other framework entry points: Security, CFNetwork, CoreServices, Foundation, AppKit, sqlite3. |
| `methods.m` | Objective-C methods on system classes. |
| `classes.m` | Objective-C classes 10.9 does not have at all. |
| `shared/` | The few polyfills the vendored non-WebKit binaries compile too (see below). |

`shared/` is the exception to everything below: the vendored GStreamer/FFmpeg media stack and the
build's own python3 need some of the same gaps filled, and they carry no polyfill registry, so the
bodies there stay plain C that compiles with no `wk_polyfill.h`. A registry entry may still be added
under `#ifdef WK_POLYFILL_REGISTERED`, which only this layer's own build defines — that is how
`jit.c`'s deliberate `mmap` override shows up in `WK_POLYFILL_REPORT` without the vendored builds
gaining a dependency on the registry. Put a polyfill in `shared/` only when something outside WebKit
compiles it (`deps/build_deps.sh`, `toolchain/scripts/build_python3.sh` name the ones that do);
everything else belongs in the files above.

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

In `methods.m`, implement the method under a `wk_`-prefixed name and register it:

```objc
@implementation NSGraphicsContext (WKPolyfill)
- (CGContextRef)wk_CGContext { ... }
@end
WK_POLYFILL_SEL("CGContext", "wk_CGContext");
```

WebKit's call sites keep saying `[ctx CGContext]`; only WebKit's own binaries are redirected to the
private name. You do not need to work out which other classes might share the selector — a class
that has the real method gets its own implementation automatically.

Like a C gap-fill, this is for a method 10.9 LACKS: the body runs, and the build gate rejects a
`WK_POLYFILL_SEL` whose method 10.9 actually implements. When *deliberately shadowing* a method 10.9
HAS is the point, use the counterpart of `WK_POLYFILL_REPLACES`:

```objc
WK_POLYFILL_SEL_REPLACES("foo", "wk_foo");
```

### An Objective-C class 10.9 lacks entirely

Add the stub to `classes.m`.

## Checking what actually happened

Set `WK_POLYFILL_REPORT=1` in the environment to have each process print its polyfill table: every
symbol, whether 10.9 has it, and which side won. `WK_POLYFILL_REPORT=abort` additionally fails the
process if a `WK_POLYFILL_REPLACES` targets a symbol 10.9 does not have — i.e. if the premise behind
a replacement ("10.9 has this but it is broken") is wrong.

`scripts/build-polyfill.sh` runs `tests/wk_polyfill_test.c` on every build, which checks the layer's
guarantees against real system symbols on both sides of the present/absent line.

It then runs `scripts/check-polyfill-shadows.sh`, which asks the running 10.9 (via `dlopen`/`dlsym`,
not the build SDK) whether any symbol the built archives define is one 10.9 already provides. Because
every polyfill body now runs unconditionally, a defined symbol 10.9 also has is a silent shadow, so it
must be declared `WK_POLYFILL_REPLACES` or the build fails — for registry symbols and for the plain-C
`legacy-support/`, `polyfills/shared/` and mechanism units alike. There is no allowlist: every symbol
the layer knowingly shadows says so in the registry, where the loader and `WK_POLYFILL_REPORT` see it.

The same script asks the ObjC runtime the same question about every `WK_POLYFILL_SEL`: it reads the
registry out of the built `methods.o`, works out which class each `wk_` method lands on, and then —
in a second program with none of the layer linked in, so what it sees is the system's own — walks
that class and its superclasses for the public selector. A `WK_POLYFILL_SEL` whose method 10.9 already
implements fails the build (the rewrite makes WebKit run the body in place of 10.9's) unless it is
declared `WK_POLYFILL_SEL_REPLACES`; so does a registration whose `wk_` method exists on no class at
all, since the rewrite would then send WebKit at a selector nothing implements.

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
- **Objective-C methods** cannot be scoped by the linker, since dispatch keys on the selector. They are
  registered under a private `wk_` selector and each of our own binaries has its `__objc_selrefs`
  rewritten to match, so a host app embedding WebKit still sees the unmodified class and its
  `respondsToSelector:` answers are unchanged.
