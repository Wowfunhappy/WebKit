#!/bin/bash
# Run against the installed product, with independent libraries sharing its dependency names.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../scripts/framework-layout.sh"
WORK=$(mktemp -d /tmp/webkit-library-isolation.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
CC="$WK_SUPPORT/toolchain/build/clang/bin/clang"

for spec in crypto:crypto:101 ssl:ssl:202 avcodec.62:avcodec:303; do
    name=${spec%%:*}; rest=${spec#*:}; symbol=${rest%%:*}; value=${rest##*:}
    "$CC" --no-default-config -mmacosx-version-min=10.9 -dynamiclib "$HERE/library.c" \
        -DFIXTURE_SYMBOL=fixture_$symbol -DFIXTURE_VALUE=$value \
        -Wl,-headerpad_max_install_names \
        -Wl,-install_name,@rpath/lib$name.dylib -Wl,-compatibility_version,255.0 \
        -Wl,-current_version,255.0 -o "$WORK/lib$name.dylib" >> /tmp/wk_build.log 2>&1
done
"$CC" --no-default-config -mmacosx-version-min=10.9 -dynamiclib "$HERE/client.c" \
    "$WORK/libcrypto.dylib" "$WORK/libssl.dylib" "$WORK/libavcodec.62.dylib" \
    -Wl,-rpath,"$WORK" -o "$WORK/client.dylib" >> /tmp/wk_build.log 2>&1
"$CC" --no-default-config -mmacosx-version-min=10.9 "$HERE/host.c" \
    -o "$WORK/host" >> /tmp/wk_build.log 2>&1

for order in webkit-first client-first; do
    for scope in local global; do
        "$WORK/host" "$order" "$scope" "$WORK/client.dylib" \
            "$WEBKIT_BUNDLE/Versions/A/WebKit" "$GST_DEPLOY/gstreamer-1.0/libgstlibav.dylib"
    done
done
# Private runtime identities and imports are absolute. This applies to every dylib and plugin
# in the runtime directories, including libraries that WebCore only loads on demand.
wk_check_private_library_bindings() {
    local pre="$1" dir bin commands bad=0
    for dir in "$PRIVLIBCXX" "$PRIVLIB"; do
        [ -d "$pre$dir" ] || continue
        while IFS= read -r bin; do
            if ! commands="$("$OTOOL" -arch x86_64 -l "$bin")"; then
                echo "  VIOLATION: cannot read $bin" >&2; bad=1; continue
            fi
            if ! printf '%s\n' "$commands" | awk -v expected="${bin#$pre}" '
                $1 == "cmd" { cmd = $2 }
                cmd == "LC_RPATH" { bad = 1 }
                $1 == "name" && cmd ~ /DYLIB$/ {
                    name = $0; sub(/^[ \t]*name /, "", name); sub(/ \(offset [0-9]+\)$/, "", name)
                    if (cmd == "LC_ID_DYLIB") { ids++; if (name != expected) bad = 1 }
                    if (name !~ /^\//) bad = 1
                }
                END { exit (bad || ids != 1) }
            '; then
                echo "  VIOLATION: $bin needs its own absolute install name, absolute imports and no LC_RPATH" >&2
                bad=1
            fi
        done < <(find "$pre$dir" -type f -name '*.dylib')
    done
    return $bad
}

wk_check_private_library_bindings ""

# Exercise the manual audit with malformed copies of a private library.
STAGE="$WORK/staged"
LIB="$STAGE$GST_DEPLOY/libcrypto.dylib"
mkdir -p "$(dirname "$LIB")"
cp "$WORK/libcrypto.dylib" "$LIB"
"$INSTALL_NAME_TOOL" -id "$GST_DEPLOY/libcrypto.dylib" "$LIB"
wk_check_private_library_bindings "$STAGE"
expect_rejection() {
    if wk_check_private_library_bindings "$STAGE" > "$WORK/gate.log" 2>&1; then
        echo "FAIL: library audit accepted $1" >&2
        exit 1
    fi
    echo "PASS: library audit rejects $1"
}
"$INSTALL_NAME_TOOL" -id @rpath/libcrypto.dylib "$LIB"
expect_rejection 'a shared install name'
"$INSTALL_NAME_TOOL" -id "$GST_DEPLOY/libcrypto.dylib" "$LIB"
"$INSTALL_NAME_TOOL" -change /usr/lib/libSystem.B.dylib @rpath/libSystem.B.dylib "$LIB"
expect_rejection 'a relative dependency'
"$INSTALL_NAME_TOOL" -change @rpath/libSystem.B.dylib /usr/lib/libSystem.B.dylib "$LIB"
"$INSTALL_NAME_TOOL" -add_rpath @loader_path "$LIB"
expect_rejection 'a runtime search path'
