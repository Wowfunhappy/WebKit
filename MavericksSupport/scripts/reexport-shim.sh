#!/bin/bash
# Shared builder for the 10.9 "reexport shim" dylibs.
#
# A reexport shim REEXPORTS a system framework (or libSystem) — so every real symbol of it still resolves
# through the shim — and additionally DEFINES the handful of symbols that 10.9 lacks but the modern-SDK-built
# consumers import: gap C functions / constants, or absent-on-10.9 ObjC class stubs. The consumer's
# dependency on the original framework is then install_name_tool -change'd to the shim by
# stage-frameworks.sh. Because the shim reexports the framework, the consumer's other (real) symbols pass
# straight through, while the missing ones resolve in the shim.
#
# Users: polyfill/scripts/build-polyfill.sh (libpolyfill_classes.dylib). The matching staging-side repoint
# helper lives in stage-frameworks.sh (repoint_framework_dep).
#
# Usage:
#   build_reexport_shim --clang <clang> --out <out.dylib> --install-name <name> \
#       --compat <ver> --current <ver> [--sysroot <path>] [--cflags "<extra cc/ld flags>"] \
#       [--reexport-framework <FW>]... [--reexport-lib <L>]... [--framework <FW>]... \
#       [--exported-symbols-list <file>] [--] <inputs (.c / .o / .a) ...>

build_reexport_shim() {
    local clang="" out="" iname="" compat="1.0.0" current="1.0.0" sysroot="/"
    local reexp="" fwflags="" expflags="" cflags=""
    local -a inputs=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --clang)                  clang="$2"; shift 2;;
            --out)                    out="$2"; shift 2;;
            --install-name)           iname="$2"; shift 2;;
            --compat)                 compat="$2"; shift 2;;
            --current)                current="$2"; shift 2;;
            --sysroot)                sysroot="$2"; shift 2;;
            --cflags)                 cflags="$2"; shift 2;;
            --reexport-framework)     reexp="$reexp -Wl,-reexport_framework,$2"; shift 2;;
            --reexport-lib)           reexp="$reexp -Wl,-reexport-l$2"; shift 2;;
            --framework)              fwflags="$fwflags -framework $2"; shift 2;;
            --exported-symbols-list)  expflags="-Wl,-exported_symbols_list,$2"; shift 2;;
            --)                       shift; inputs+=("$@"); break;;
            *)                        inputs+=("$1"); shift;;
        esac
    done
    : "${clang:?build_reexport_shim: --clang required}"
    : "${out:?build_reexport_shim: --out required}"
    : "${iname:?build_reexport_shim: --install-name required}"
    mkdir -p "$(dirname "$out")"
    rm -f "$out"
    # -headerpad_max_install_names: a shim is staged into a framework bundle and its install name
    # rewritten to that absolute in-bundle path, which is far longer than the @rpath name it links
    # with. install_name_tool can only write a longer name into padding the linker reserved here.
    #
    # $cflags/$fwflags/$reexp/$expflags are intentionally unquoted so each token splits into its own argument;
    # the inputs are kept as an array so paths with spaces survive.
    "$clang" --no-default-config -isysroot "$sysroot" -mmacosx-version-min=10.9 -dynamiclib \
        -Wl,-headerpad_max_install_names \
        -install_name "$iname" -compatibility_version "$compat" -current_version "$current" \
        $cflags $fwflags $reexp $expflags "${inputs[@]}" -o "$out"
}
