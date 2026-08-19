# Sandbox profiles

The seatbelt profiles this port's child processes apply. `Source/WebKit/PlatformMac.cmake`
preprocesses each `.sb.in` here — with upstream's own `grep -o "^[^;]*" | clang -E -P` rule — into
`WebKit.framework/Versions/A/Resources/`, where `AuxiliaryProcess::initializeSandbox()` and
webpushd's `applySandbox()` look for them by name.

## Why these and not the ones beside the process sources

10.9's sandbox compiler has a smaller operation vocabulary than the profiles modern WebKit ships.
This is a profile-language gap, not an absent-API one: `/usr/lib/libsandbox.1.dylib` on 10.9 has
the complete, working compiler (`sandbox_compile_file` / `sandbox_compile_string` /
`sandbox_apply`, plus `SANDBOX_BUILD_ID`, so even the compiled-sandbox cache in
`AuxiliaryProcessMac.mm` works). What it does not have are the *operations* the current profiles
name. Feeding the generated `com.apple.WebProcess.sb` from `Source/WebKit/WebProcess/` to the real
`sandbox_compile_file()` on this machine fails at:

    line 88: unbound variable: nvram*

and `initializeSandbox()` `CRASH()`es rather than continue when a profile will not apply — which is
why every child process on this port used to run unsandboxed.

So the profiles applied here are the last ones upstream itself wrote for this OS, recovered from
git history rather than authored: `aab061ff1301` (2015-11-30), the revision immediately before
`c33fad6a4d19` "[Mac] WebKit contains dead source code for OS X Mavericks and earlier" deleted
10.9 support.

`com.apple.WebProcess.sb.in` and `com.apple.WebKit.NetworkProcess.sb.in` are **byte-identical to
that revision** — no header, no reformatting, no hand-resolved conditionals. That is deliberate,
and it is what makes the paragraph above a check rather than a claim:

```
git show aab061ff1301:Source/WebKit2/WebProcess/com.apple.WebProcess.sb.in \
    | diff - MavericksSupport/sandbox/com.apple.WebProcess.sb.in
git show aab061ff1301:Source/WebKit2/NetworkProcess/mac/com.apple.WebKit.NetworkProcess.sb.in \
    | diff - MavericksSupport/sandbox/com.apple.WebKit.NetworkProcess.sb.in
```

`scripts/check-sandbox-profiles.sh` runs both diffs, so the provenance is verified on every check.

Their three `__MAC_OS_X_VERSION_MIN_REQUIRED` conditionals resolve themselves: the CMake rule
passes `-mmacosx-version-min=10.9`, which pins `__MAC_OS_X_VERSION_MIN_REQUIRED` to 1090 and drops
the 10.10+ `com.apple.iconservices` names, the 10.11+ `com.apple.nesessionmanager.flow-divert-token`
name, and the 10.10+ `xattr-regex` spelling in favour of 10.9's `xattr`. That flag is load-bearing,
not decoration — the rule invokes a bare `clang` off `PATH`, so without it the deployment target
comes from whichever compiler is found, and a 10.10 answer emits an `xattr-regex` rule that 10.9's
sandbox cannot compile.

`com.apple.WebKit.webpushd.relocatable.mac.sb.in` has no such ancestor — webpushd postdates 10.9
entirely — so it is upstream's current relocatable profile re-expressed in this OS's vocabulary.
Its own header comment records what that re-expression changed.

## Changing a profile

Every rule these profiles hold beyond the recovered revision exists because a denial proved the
modern engine needs it. Nothing is granted speculatively: a sandbox that grants what nobody asked
for is not a sandbox.

Two things to know before editing:

* **A profile that will not compile takes the browser down.** `initializeSandbox()` `CRASH()`es on
  a profile it cannot apply, so a typo here is a WebContent process that dies at launch, not a
  warning. `scripts/check-sandbox-profiles.sh` compiles all three against 10.9's real compiler with
  the same named parameters WebKit passes; run it before building.
* **Denials are the source of truth.** `scripts/watch-sandbox-denials.sh` tails the kernel and
  sandboxd denial stream while you drive the browser. Reproduce the broken feature, read what was
  actually denied, and grant exactly that.

## Checking that it is on

A profile that compiles is not a profile that got applied, and a browser that works is not a
browser that is confined. `scripts/check-sandbox-applied.sh`, run with Safari open on a page, asks
the kernel about each live child process via `sandbox_check()` and fails if any of them is
unconfined or answers "permitted" to something its profile must deny.

