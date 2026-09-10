#!/bin/bash
# host-headers.sh — the 10.9 C headers this port's own C is compiled against.
#
# The toolchain's C tools, the polyfill layer and the third-party deps all target 10.9's own libc,
# so they read the host headers in /usr/include, which Apple ships in the Command Line Tools rather
# than inside Xcode.app. The modern SDK is not a substitute: polyfill/polyfills/shared/include/*.h
# wrap 10.9's headers, and its time.h redefines the SDK's own clock ids.
#
# Sourced. Probes those headers with the compiler that compiles that C, and hands back the
# compiler's own answer.

_wk_hh_clang="${MAVERICKS_CLANG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/toolchain/build/clang}/bin/clang"
if [ ! -x "$_wk_hh_clang" ]; then
    echo "host-headers.sh: FATAL: no clang at $_wk_hh_clang." >&2
    echo "  Assemble the toolchain:  bash MavericksSupport/toolchain/bootstrap.sh" >&2
    exit 1
fi
if ! _wk_hh_err="$(printf '#include <errno.h>\nint probe(void) { return errno; }\n' \
        | "$_wk_hh_clang" -x c -c -mmacosx-version-min=10.9 -o /dev/null - 2>&1)"; then
    {   echo "host-headers.sh: FATAL: this port's C reads the host headers, and this host has none:"
        echo "$_wk_hh_err" | sed -n '1,4p'
        echo "  Apple ships them in the Command Line Tools:  xcode-select --install"
    } >&2
    exit 1
fi
unset _wk_hh_clang _wk_hh_err
