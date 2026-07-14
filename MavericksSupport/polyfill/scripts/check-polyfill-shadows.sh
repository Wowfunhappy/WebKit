#!/bin/bash
# Fail the build if the polyfill defines a symbol the 10.9 runtime ALREADY provides, unless that
# symbol is a deliberate override on the allowlist below.
#
# libpolyfill.a exists to supply symbols 10.9 lacks. Accidentally defining one 10.9 already has is a
# latent trap: libpolyfill.a is a normal archive, so an object pulled in for one symbol drags in all
# its other (now-duplicate) definitions, and for the embedded libcg_polyfill.dylib the winner is
# decided by dylib order on the consumer's link line. Either way a later relink can silently flip the
# binding from the real symbol to the stub, with no link error — this is how a working CoreGraphics
# colour-space comparison got replaced by a subtly-different stub and broke label-background fills.
#
# Some overrides ARE deliberate: they shadow a present-but-broken 10.9 function on purpose (mmap
# strips the 10.14 MAP_JIT flag; SecTrustEvaluate swaps trust policies around a 10.9 crash; ...).
# Those are listed in ALLOWED with a reason and must stay strong to win. Everything else that
# resolves on the runtime is an accident: remove it from polyfill/src and let WebKit link the system
# symbol. Ground truth is this machine's runtime (dlopen + dlsym), not the modern SDK.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/../build"
NM=/Library/Developer/CommandLineTools/usr/bin/nm
CC=/Library/Developer/CommandLineTools/usr/bin/clang

# Deliberate overrides of present-but-broken 10.9 symbols (see polyfill/legacy-support/src).
# Every entry must shadow ON PURPOSE, with the reason stated. Constants/functions the 10.9
# runtime provides CORRECTLY must never be listed here — remove them from the polyfill and
# let the linker bind the system symbol (that is this script's whole point; a name-string
# copy of a CFString constant, for example, silently breaks every value comparison).
ALLOWED="
mmap                                  strips the 10.14 MAP_JIT flag so JIT mmap() works on 10.9 (jit.c)
SecTrustEvaluate                      swaps in a basic X.509 policy to avoid 10.9 compareRevocationPolicies crash (security.c)
SecPolicyCreateRevocation             returns NULL so 10.9 skips the crashing revocation policy (security.c)
sysconf                               adds _SC_PHYS_PAGES et al. that 10.9 sysconf does not answer (sysconf.c)
pthread_get_stacksize_np              reports the real main-thread stack size 10.9 under-reports (pthread_get_stacksize_np.c)
TCCAccessPreflight                    dlopen-redirect shim: TCCLibrary() loads libtcc_polyfill by explicit path over the misbehaving 10.9 TCC (tcc_polyfill.c)
kTCCServiceAccessibility              dlopen-redirect shim constant, same mechanism (tcc_polyfill.c)
CTFontManagerCreateFontDescriptorFromData  10.9's returns descriptors that crash in TFontFeatures at realize; replacement builds CGFont-backed descriptors, real impl via dlsym fallback (graphics_shims.c)
"
allowed_set() { echo "$ALLOWED" | awk 'NF{print $1}' | sort -u; }

PROBE="$(mktemp -t shadowprobe).c"; BIN="${PROBE%.c}"
trap 'rm -f "$PROBE" "$BIN" "$BIN.syms"' EXIT

# Strong (T/D/S), non-weak defined globals the polyfill ships; weak defs cannot shadow so they are ignored.
syms() { $NM -g "$1" 2>/dev/null | awk '$2 ~ /^[TDS]$/ { sub(/^_/,"",$3); print $3 }'; }
{ syms "$BUILD/libpolyfill.a"; syms "$BUILD/libcg_polyfill.dylib"; \
  syms "$BUILD/libpolyfill_classes.a"; syms "$BUILD/libwtf_compat.a"; \
  syms "$BUILD/libtcc_polyfill.dylib"; } | sort -u > "$BIN.syms"

cat > "$PROBE" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    const char* fw[] = {
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/Frameworks/CoreText.framework/CoreText",
        "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/AppKit.framework/AppKit",
        "/System/Library/Frameworks/Security.framework/Security",
        "/System/Library/Frameworks/CFNetwork.framework/CFNetwork",
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        "/System/Library/Frameworks/ImageIO.framework/ImageIO",
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",
        "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
        "/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        /* NOT AVFoundation: on 10.9 dlsym(handle) walks the whole dependency tree and
         * AVFoundation drags in CoreWiFi, whose PRIVATE internal clock_gettime copy
         * false-positives symbols no real two-level bind could reach. The polyfill's
         * AVFoundation additions are ObjC classes, covered by their mangled names. */
        0 };
    /* Per-handle dlsym (NOT RTLD_DEFAULT): a flat global search also finds PRIVATE
     * exports of transitively loaded frameworks (e.g. 10.9 CoreWiFi ships an internal
     * clock_gettime) that no two-level-namespace bind against these frameworks could
     * ever reach — false positives. dlsym(handle) searches just that framework and
     * its reexports, which is what a real link-time bind sees. */
    void* handles[32];
    int n = 0;
    for (int i = 0; fw[i]; i++) {
        void* h = dlopen(fw[i], RTLD_NOW | RTLD_LOCAL);
        if (h) handles[n++] = h;
    }
    char line[512];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0]) continue;
        for (int i = 0; i < n; i++) {
            if (dlsym(handles[i], line)) { printf("%s\n", line); break; }
        }
    }
    return 0;
}
EOF
"$CC" "$PROBE" -o "$BIN"
shadows=$("$BIN" < "$BIN.syms" | sort -u)
unexpected=$(comm -23 <(echo "$shadows" | sed '/^$/d') <(allowed_set) || true)
if [ -n "$unexpected" ]; then
    echo "ERROR: the polyfill defines symbols the 10.9 runtime already provides and that are NOT on the" >&2
    echo "deliberate-override allowlist (they would silently shadow the real ones on some relink):" >&2
    echo "$unexpected" | sed 's/^/  /' >&2
    echo "Remove them from MavericksSupport/polyfill/src (let WebKit link the system symbol), or, if the" >&2
    echo "shadow is intentional, add it to ALLOWED in $(basename "$0") with a reason." >&2
    exit 1
fi
echo "  polyfill shadow check: clean ($(echo "$shadows" | sed '/^$/d' | wc -l | tr -d ' ') allowlisted overrides)"
