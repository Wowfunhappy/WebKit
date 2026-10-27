#!/bin/bash
# stage-headers.sh — the developer headers and module maps of JavaScriptCore.framework and
# WebKit.framework in the staged tree. Run by stage-frameworks.sh.
#
# The set of headers is Apple's for this WebKit version: it comes from the Xcode projects
# (JavaScriptCore and WebKit headers marked Public; for the legacy API, the MigratedHeaders
# xcfilelist entries public on macOS). Each file goes through the same header rules Xcode runs
# (Scripts/postprocess-header-rule, with WebKitLegacy's own rule first for the legacy headers), as
# Apple runs them for a WebKit that installs on a macOS older than its own
# (WK_USE_OVERRIDE_FRAMEWORKS_DIR = YES, the Safari staged frameworks): header postprocessing is
# off, so WKFoundation.h and JavaScriptCore's WebKitAvailability.h define the WK_ and JSC_
# availability macros empty. The few raw API_AVAILABLE and NS_CLASS_AVAILABLE annotations in
# upstream's text remain. A last pass then spells the headers for the 10.9 and 10.10 SDKs too.
#
# WebKit.framework carries both sets, as Apple's does: the legacy headers migrated into it, with
# their umbrella WebKitLegacy.h, and the WebKit (WK2) headers, whose umbrella WebKit.h imports it.
# The nested frameworks and WebKit2.framework ship no headers.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/framework-layout.sh"

REPO="$WK_REPO"
SRC="$REPO/Source"
STAGE="$WK_STAGE_ROOT"
WORK="$REPO/WebKitBuild/Release/header-postprocess"
DEPLOYMENT_TARGET=10.9
SDK="${AQUAWEBKIT_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"

rm -rf "$WORK"
mkdir -p "$WORK/derived" "$WORK/bin"
# The rules run unifdef by name, and /usr/bin/unifdef is an xcrun shim that rejects the SDKROOT
# they are given, so the tool itself goes first on PATH. The WebKit rule also runs
# replace-webkit-additions-includes.py through python3, which 10.9 lacks.
ln -s "$(xcrun -f unifdef)" "$WORK/bin/unifdef"
export PATH="$WORK/bin:$WK_SUPPORT/toolchain/build/python3/bin:$PATH"

# Every variable the rules and their config generators read, set as Xcode sets it for a
# Production build with WK_USE_OVERRIDE_FRAMEWORKS_DIR = YES.
export WK_PLATFORM_NAME=macosx PLATFORM_NAME=macosx
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export TARGET_MAC_OS_X_VERSION_MAJOR="${DEPLOYMENT_TARGET%%.*}0000"
export WK_FRAMEWORK_HEADER_POSTPROCESSING_DISABLED=YES JSC_FRAMEWORK_HEADER_POSTPROCESSING_DISABLED=YES
export WK_LIBRARY_HEADERS_FOLDER_PATH=/usr/local/include/safari-sdk
export BUILT_PRODUCTS_DIR="$WORK/products" SHARED_DERIVED_FILE_DIR="$WORK/derived"
mkdir -p "$BUILT_PRODUCTS_DIR"

SDKROOT="$SDK" SCRIPT_OUTPUT_FILE_0="$WORK/derived/WebKit-header-postprocess-config.sh" \
    bash "$SRC/WebKit/Scripts/generate-header-postprocess-config.sh"
SDKROOT="$SDK" SCRIPT_OUTPUT_FILE_0="$WORK/derived/JavaScriptCore-header-postprocess-config.sh" \
    bash "$SRC/JavaScriptCore/Scripts/generate-header-postprocess-config.sh"

# The one source file named $2 under Source/$1, skipping the other ports' copies.
git -C "$REPO" ls-files Source/JavaScriptCore Source/WebCore Source/WebKitLegacy Source/WebKit \
    | grep -vE '/(gtk|wpe|glib|win|playstation)/' > "$WORK/sources"
source_of() {
    local m
    m="$(grep "^Source/$1/" "$WORK/sources" | grep "/$2\$" || true)"
    if [ "$(echo "$m" | grep -c .)" != 1 ]; then
        echo "ERROR: public header $2 resolves to $(echo "$m" | grep -c .) files under Source/$1:" >&2
        echo "$m" >&2
        exit 1
    fi
    echo "$REPO/$m"
}

# Header names an Xcode project marks Public.
public_in_project() {
    grep 'ATTRIBUTES = (Public, ); }' "$SRC/$1/$1.xcodeproj/project.pbxproj" \
        | sed -E 's/.*\/\* ([^ ]+) in Headers.*/\1/' | sort -u
}

# $1 = rule, $2 = input, $3 = output, $4 = visibility.
run_rule() {
    mkdir -p "$(dirname "$3")"
    SDKROOT="$SDK" SCRIPT_HEADER_VISIBILITY="$4" INPUT_FILE_PATH="$2" INPUT_FILE_NAME="$(basename "$2")" \
        SCRIPT_INPUT_FILE="$2" SCRIPT_OUTPUT_FILE_0="$3" "$1" \
        || { echo "ERROR: $1 failed on $2" >&2; exit 1; }
}

# A bundle's Headers and Modules directories, with the top-level links a framework carries.
new_header_dirs() {
    local bundle="$STAGE$1" d
    for d in Headers Modules; do
        rm -rf "$bundle/Versions/A/$d" "$bundle/$d"
        mkdir -p "$bundle/Versions/A/$d"
        ln -s "Versions/Current/$d" "$bundle/$d"
    done
}

# ---------------------------------------------------------------------------
echo "### JavaScriptCore.framework headers"
new_header_dirs "$JSC_BUNDLE"
JSC_HEADERS="$STAGE$JSC_BUNDLE/Versions/A/Headers"
for name in $(public_in_project JavaScriptCore); do
    run_rule "$SRC/JavaScriptCore/Scripts/postprocess-header-rule" \
        "$(source_of JavaScriptCore "$name")" "$JSC_HEADERS/$name" public
done
cp "$SRC/JavaScriptCore/JavaScriptCore.modulemap" "$STAGE$JSC_BUNDLE/Versions/A/Modules/module.modulemap"
# The Objective-C API headers, which the i386 slice (stock's, below) lacks, take the exclusion
# Apple's 10.9 map gives them there, with JSTypedArray.h, the one this WebKit adds.
python3 - "$STAGE$JSC_BUNDLE/Versions/A/Modules/module.modulemap" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read().rstrip()
assert text.endswith("}"), "unexpected module map shape"
text = text[:-1].rstrip() + """

  explicit module JSVirtualMachine {
    // FIXME: 32-bit x86 is a poor way to say "fragile Objective-C ABI"
    requires x86_32
    exclude header "JSValue.h"
    exclude header "JSContext.h"
    exclude header "JSExport.h"
    exclude header "JSManagedValue.h"
    exclude header "JSVirtualMachine.h"
    exclude header "JSTypedArray.h"
  }
}
"""
open(path, "w").write(text)
EOF
echo "  $(ls "$JSC_HEADERS" | wc -l | tr -d ' ') headers"

# ---------------------------------------------------------------------------
# The legacy API: Xcode copies each header into WebKitLegacy.framework/PrivateHeaders through
# WebKitLegacy's rule (WebCore's copies them verbatim), then WebKit's rule migrates it from there.
# The rule recognizes a migrated header by that directory name, so the intermediate copy keeps it.
# DOMNotation.h, the 10.9 SDK class this port restores, migrates the same way.
echo "### WebKit.framework headers"
new_header_dirs "$WEBKIT_BUNDLE"
WK_HEADERS="$STAGE$WEBKIT_BUNDLE/Versions/A/Headers"
while IFS='|' read -r input output; do
    case "$output" in
        '$(TARGET_BUILD_DIR)/$(WK_MAC_PUBLIC_IOS_PRIVATE_HEADERS_DIR)/'*|'$(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/'*) ;;
        *) continue;;
    esac
    name="${input##*/}"
    case "$input" in
        '$(WEBKITLEGACY_PRIVATE_HEADERS_DIR)/'*)
            mid="$WORK/WebKitLegacy.framework/PrivateHeaders/$name"
            run_rule "$SRC/WebKitLegacy/scripts/postprocess-header-rule" "$(source_of WebKitLegacy "$name")" "$mid" private;;
        '$(WEBCORE_PRIVATE_HEADERS_DIR)/'*)
            mid="$WORK/WebCore.framework/PrivateHeaders/$name"
            mkdir -p "$(dirname "$mid")"
            cp "$(source_of WebCore "$name")" "$mid";;
        *) echo "ERROR: unrecognized migrated header source $input" >&2; exit 1;;
    esac
    SRCROOT="$SRC/WebKit" run_rule "$SRC/WebKit/Scripts/postprocess-header-rule" "$mid" "$WK_HEADERS/${output##*/}" public
done < <(paste -d'|' <(grep -v '^#' "$SRC/WebKit/MigratedHeaders-input.xcfilelist" | grep .) \
                     <(grep -v '^#' "$SRC/WebKit/MigratedHeaders-output.xcfilelist" | grep .)
         echo '$(WEBKITLEGACY_PRIVATE_HEADERS_DIR)/DOMNotation.h|$(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/DOMNotation.h')
# The WebKit (WK2) headers, through WebKit's rule.
for name in $(public_in_project WebKit); do
    case "$name" in
        *.h)
            SRCROOT="$SRC/WebKit" run_rule "$SRC/WebKit/Scripts/postprocess-header-rule" \
                "$(source_of WebKit "$name")" "$WK_HEADERS/$name" public;;
        WebKit.apinotes)
            cp "$(source_of WebKit "$name")" "$WK_HEADERS/$name";;
        *) echo "ERROR: Public file $name in WebKit.xcodeproj has no staging rule" >&2; exit 1;;
    esac
done
cp "$SRC/WebKit/Modules/OSX.modulemap" "$STAGE$WEBKIT_BUNDLE/Versions/A/Modules/module.modulemap"

# The stock headers this WebKit lacks, which the last step below adds (the 32-bit Carbon API and the
# NPAPI plug-in interface), take the module map entries Apple's 10.9 map gives them.
python3 - "$STAGE$WEBKIT_BUNDLE/Versions/A/Modules/module.modulemap" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read().rstrip()
assert text.endswith("}"), "unexpected module map shape"
text = text[:-1].rstrip() + """

  explicit module NPAPI {
    header "nptypes.h"
    header "npapi.h"
    header "npfunctions.h"
    header "npruntime.h"
    export *
  }

  exclude header "HIWebView.h"
  exclude header "CarbonUtils.h"
}
"""
open(path, "w").write(text)
EOF
echo "  $(ls "$WK_HEADERS" | wc -l | tr -d ' ') headers"

# ---------------------------------------------------------------------------
# The headers serve the macOS 10.9 and 10.10 SDKs and the compilers Xcode 6 ships with them as
# well as a modern SDK. The platform conditionals those SDKs do not define take their macOS values,
# and legacy-sdk-headers.py spells modern syntax through the macros of legacy-sdk-prelude.h, which
# each framework's base headers carry.
echo "### headers for the 10.9 and 10.10 SDKs"
ALL_HEADERS=("$JSC_HEADERS"/*.h "$WK_HEADERS"/*.h)
PLATFORMS=(-DTARGET_OS_OSX=1 -DTARGET_OS_IOS=0 -DTARGET_OS_MACCATALYST=0 -DTARGET_OS_VISION=0 -DTARGET_OS_TV=0
           -DTARGET_OS_WATCH=0)
for h in "${ALL_HEADERS[@]}"; do
    rc=0
    unifdef -B "${PLATFORMS[@]}" -o "$WORK/unifdef.h" "$h" || rc=$?
    [ "$rc" -lt 2 ] || { echo "ERROR: unifdef failed on $h" >&2; exit 1; }
    mv "$WORK/unifdef.h" "$h"
done
python3 "$HERE/legacy-sdk-headers.py" --prelude "$HERE/legacy-sdk-prelude.h" --sdk "$SDK" "${PLATFORMS[@]}" \
    --base "$JSC_HEADERS/JSBase.h" --base "$WK_HEADERS/WKFoundation.h" --base "$WK_HEADERS/WebKitAvailability.h" \
    "${ALL_HEADERS[@]}"

# ---------------------------------------------------------------------------
# The i386 slice of each framework is stock 10.9's, so an i386 compile reads the stock framework's
# headers: each header carries this WebKit's declarations under __LP64__ and the stock one's
# otherwise, and a stock header this WebKit lacks ships as it is.
echo "### stock headers for the i386 slice"
python3 - "$STAGE$JSC_BUNDLE" "$STOCK_BACKUP/JavaScriptCore.framework" "$STAGE$WEBKIT_BUNDLE" "$STOCK_BACKUP/WebKit.framework" <<'EOF'
import os, sys

def read(directory, name):
    with open(os.path.join(directory, name), errors="surrogateescape") as f:
        text = f.read()
    return text if text.endswith("\n") else text + "\n"

for bundle, stock_bundle in zip(sys.argv[1::2], sys.argv[2::2]):
    ours_dir = os.path.join(bundle, "Versions/A/Headers")
    stock_dir = os.path.join(stock_bundle, "Versions/A/Headers")
    stock = {n for n in os.listdir(stock_dir) if n.endswith(".h")}
    if not stock:
        sys.exit("ERROR: no stock headers in %s" % stock_dir)
    ours = {n for n in os.listdir(ours_dir) if n.endswith(".h")}
    for name in sorted(ours | stock):
        if name not in ours:
            text = read(stock_dir, name)
        elif name in stock:
            text = ("#ifdef __LP64__\n" + read(ours_dir, name)
                    + "#else /* the i386 slice: the macOS 10.9 WebKit */\n" + read(stock_dir, name) + "#endif\n")
        else:
            text = ("#ifdef __LP64__ /* the i386 slice, the macOS 10.9 WebKit, lacks this header */\n"
                    + read(ours_dir, name) + "#endif\n")
        with open(os.path.join(ours_dir, name), "w", errors="surrogateescape") as f:
            f.write(text)
EOF

for b in "$JSC_BUNDLE" "$WEBKIT_BUNDLE"; do
    chmod -R a+rX "$STAGE$b/Versions/A/Headers" "$STAGE$b/Versions/A/Modules"
done
