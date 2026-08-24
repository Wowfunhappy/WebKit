# The cctools this port reads Mach-O with, built by toolchain/scripts/build_cctools.sh.
#
# /usr/bin/{otool,lipo,install_name_tool,nm,strip,ar,ranlib,size,strings,libtool} are 14K xcselect
# shims that forward through xcode-select, and /usr/bin/dyldinfo does not exist at all, so reaching
# for these by name gets whatever developer-tools install the machine points at. Taking them from
# the toolchain is what makes every script here read the same Mach-O the same way.
#
# Sourced. Defines CCTOOLS. A check that cannot run must fail, never pass quietly, so every tool
# handed out is verified here rather than at the call site that would swallow its absence.

CCTOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../toolchain/build/cctools/bin" 2>/dev/null && pwd)"
for _wk_tool in otool lipo install_name_tool nm nmedit dyldinfo strip size strings libtool ar ranlib; do
    if [ -z "$CCTOOLS" ] || [ ! -x "$CCTOOLS/$_wk_tool" ]; then
        echo "cctools.sh: FATAL: no $_wk_tool in the toolchain." >&2
        echo "  Build them:  bash MavericksSupport/toolchain/scripts/build_cctools.sh" >&2
        exit 1
    fi
done
unset _wk_tool
