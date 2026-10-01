#!/bin/bash
# stage-headers.sh — the developer headers and module maps of JavaScriptCore.framework,
# WebKit.framework and WebKit2.framework in the staged tree. Run by stage-frameworks.sh.
#
# Each header is the one Apple's shipping (Production) build emits for this WebKit version: the
# set comes from the Xcode projects (JavaScriptCore and WebKit headers marked Public; for the
# legacy API, the MigratedHeaders xcfilelist entries public on macOS), and each file goes through
# the same header rules Xcode runs (Scripts/postprocess-header-rule, with WebKitLegacy's own rule
# first for the legacy headers). The deployment target fills in WK_MAC_TBA, as in any build
# without WebKitAdditions.
#
# The headers then follow the binaries' name shift: WebKitLegacy's headers are already spelled
# <WebKit/...> by the migrate rule, and keep their own umbrella WebKit.h; the WebKit (WK2) headers
# become <WebKit2/...>, with the umbrella WebKit.h as WebKit2.h and its <WebKit/WebKitLegacy.h>
# import naming the legacy umbrella <WebKit/WebKit.h>. The nested WebCore.framework ships no
# headers, as on stock 10.9.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/framework-layout.sh"

REPO="$WK_REPO"
SRC="$REPO/Source"
STAGE="$WK_STAGE_ROOT"
WORK="$REPO/WebKitBuild/Release/header-postprocess"
DEPLOYMENT_TARGET=10.9
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"

rm -rf "$WORK"
mkdir -p "$WORK/derived" "$WORK/bin"
# The rules run unifdef by name, and /usr/bin/unifdef is an xcrun shim that rejects the SDKROOT
# they are given, so the tool itself goes first on PATH. The WebKit rule also runs
# replace-webkit-additions-includes.py through python3, which 10.9 lacks.
ln -s "$(xcrun -f unifdef)" "$WORK/bin/unifdef"
export PATH="$WORK/bin:$WK_SUPPORT/toolchain/build/python3/bin:$PATH"

# Every variable the rules and their config generators read, set as Xcode sets it for a
# Production build installed to /System (WK_USE_OVERRIDE_FRAMEWORKS_DIR = NO).
export WK_PLATFORM_NAME=macosx PLATFORM_NAME=macosx
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export TARGET_MAC_OS_X_VERSION_MAJOR="${DEPLOYMENT_TARGET%%.*}0000"
export WK_FRAMEWORK_HEADER_POSTPROCESSING_DISABLED=NO JSC_FRAMEWORK_HEADER_POSTPROCESSING_DISABLED=NO
export WK_LIBRARY_HEADERS_FOLDER_PATH=/usr/local/include
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
echo "  $(ls "$JSC_HEADERS" | wc -l | tr -d ' ') headers"

# ---------------------------------------------------------------------------
# The legacy API: Xcode copies each header into WebKitLegacy.framework/PrivateHeaders through
# WebKitLegacy's rule (WebCore's copies them verbatim), then WebKit's rule migrates it from there.
# The rule recognizes a migrated header by that directory name, so the intermediate copy keeps it.
echo "### WebKit.framework headers (WebKitLegacy)"
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
    SRCROOT="$SRC/WebKit" run_rule "$SRC/WebKit/Scripts/postprocess-header-rule" "$mid" "$WK_HEADERS/$name" public
done < <(paste -d'|' <(grep -v '^#' "$SRC/WebKit/MigratedHeaders-input.xcfilelist" | grep .) \
                     <(grep -v '^#' "$SRC/WebKit/MigratedHeaders-output.xcfilelist" | grep .))
cp "$SRC/WebKit/Modules/OSX.modulemap" "$STAGE$WEBKIT_BUNDLE/Versions/A/Modules/module.modulemap"
cp "$(source_of WebKit WebKit.apinotes)" "$WK_HEADERS/WebKit.apinotes"
echo "  $(ls "$WK_HEADERS" | wc -l | tr -d ' ') headers"

# ---------------------------------------------------------------------------
echo "### WebKit2.framework headers (WebKit)"
new_header_dirs "$WEBKIT2_BUNDLE"
WK2_HEADERS="$STAGE$WEBKIT2_BUNDLE/Versions/A/Headers"
WK2_NAMES="$(public_in_project WebKit)"
# The name shift: a WK2 header is <WebKit2/...> (its umbrella WebKit2.h), the legacy umbrella is
# <WebKit/WebKit.h>, and every other <WebKit/...> header is a legacy one that keeps its spelling.
shift_name() { case "$1" in WebKit.h) echo WebKit2.h;; WebKit.apinotes) echo WebKit2.apinotes;; *) echo "$1";; esac; }
WK2_NAMES_FILE="$WORK/wk2-names"
echo "$WK2_NAMES" > "$WK2_NAMES_FILE"
for name in $WK2_NAMES; do
    case "$name" in
        *.h)
            SRCROOT="$SRC/WebKit" run_rule "$SRC/WebKit/Scripts/postprocess-header-rule" \
                "$(source_of WebKit "$name")" "$WORK/WebKit.framework/Headers/$name" public
            perl -pe 'BEGIN { open my $f, "<", shift or die; chomp(my @n = <$f>); %wk2 = map { $_ => 1 } @n }
                      s{<WebKit/([^>]+)>}{ $wk2{$1} ? "<WebKit2/" . ($1 eq "WebKit.h" ? "WebKit2.h" : $1) . ">"
                                         : $1 eq "WebKitLegacy.h" ? "<WebKit/WebKit.h>" : "<WebKit/$1>" }ge' \
                "$WK2_NAMES_FILE" < "$WORK/WebKit.framework/Headers/$name" > "$WK2_HEADERS/$(shift_name "$name")";;
        WebKit.apinotes)
            sed 's/^Name: WebKit$/Name: WebKit2/' "$(source_of WebKit "$name")" > "$WK2_HEADERS/WebKit2.apinotes";;
        *) echo "ERROR: Public file $name in WebKit.xcodeproj has no staging rule" >&2; exit 1;;
    esac
done
cat > "$STAGE$WEBKIT2_BUNDLE/Versions/A/Modules/module.modulemap" <<'EOF'
framework module WebKit2 [system] {
  umbrella header "WebKit2.h"
  module * { export * }
  export *
}
EOF
echo "  $(ls "$WK2_HEADERS" | wc -l | tr -d ' ') headers"

for b in "$JSC_BUNDLE" "$WEBKIT_BUNDLE" "$WEBKIT2_BUNDLE"; do
    chmod -R a+rX "$STAGE$b/Versions/A/Headers" "$STAGE$b/Versions/A/Modules"
done
