#!/bin/bash
# check-sandbox-profiles.sh — compile every profile in MavericksSupport/sandbox/ against 10.9's
# real sandbox compiler, the way AuxiliaryProcess::initializeSandbox() will at launch, and confirm
# the two recovered profiles are still byte-identical to the upstream revision they came from.
#
# initializeSandbox() CRASH()es on a profile it cannot apply, so an uncompilable profile is a
# WebContent process that dies immediately rather than a warning in a log. Run this after editing
# any .sb.in and before building.
#
# Preprocessing is the byte-identical command line Source/WebKit/PlatformMac.cmake runs — same
# flags, same -include, same -I set — so what gets compiled here is what will ship. That requires a
# configured build tree for the generated WTF/bmalloc headers; this fails loudly rather than
# quietly checking something other than what ships.
#
# Compiling only. This never applies a profile.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_DIR="$(dirname "$HERE")"
REPO="$(cd "$SANDBOX_DIR/../.." && pwd)"
BUILD="${WEBKIT_BUILD_DIR:-$REPO/WebKitBuild/Release}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-sandbox-profiles.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Keep in step with the add_custom_command rules in Source/WebKit/PlatformMac.cmake.
WTF_HEADERS="$BUILD/WTF/Headers"
BMALLOC_HEADERS="$BUILD/bmalloc/Headers"
WEBKIT_DIR="$REPO/Source/WebKit"

PROFILES="com.apple.WebProcess
com.apple.WebKit.NetworkProcess
com.apple.WebKit.GPUProcess
com.apple.WebKit.webpushd.relocatable.mac"

# The upstream revision the two recovered profiles were taken from: the commit immediately before
# c33fad6a4d19 "[Mac] WebKit contains dead source code for OS X Mavericks and earlier" removed 10.9
# support. See MavericksSupport/sandbox/README.md.
UPSTREAM_REV=aab061ff1301851d0f4626b4f76f9f454ad2e889
UPSTREAM_PATHS="com.apple.WebProcess:Source/WebKit2/WebProcess/com.apple.WebProcess.sb.in
com.apple.WebKit.NetworkProcess:Source/WebKit2/NetworkProcess/mac/com.apple.WebKit.NetworkProcess.sb.in"

for dir in "$WTF_HEADERS" "$BMALLOC_HEADERS"; do
    if [ ! -d "$dir" ]; then
        echo "ERROR: $dir is missing — this check needs a configured build tree so it can run the" >&2
        echo "       same preprocessing the build runs. Configure/build first, or point" >&2
        echo "       WEBKIT_BUILD_DIR at an existing build." >&2
        exit 2
    fi
done

# Build against the system clang and the system libsandbox: the question is what THIS OS accepts,
# not what the in-tree toolchain would.
if ! /usr/bin/clang -o "$WORK/sbcheck" "$HERE/sbcheck.c" -lsandbox; then
    echo "ERROR: could not build the profile compiler harness" >&2
    exit 2
fi

status=0

# --- Provenance: the recovered profiles must still be upstream's, unmodified. ---------------
for entry in $UPSTREAM_PATHS; do
    profile="${entry%%:*}"
    upstream_path="${entry#*:}"
    # A gate that cannot check its invariant FAILS. Passing while verifying nothing is the same
    # thing as not having the gate, only harder to notice.
    if ! git -C "$REPO" cat-file -e "$UPSTREAM_REV:$upstream_path" 2>/dev/null; then
        echo "FAIL  $profile: upstream revision $UPSTREAM_REV is not in this checkout, so the" >&2
        echo "      provenance of the recovered profile cannot be verified." >&2
        status=1
        continue
    fi
    if git -C "$REPO" show "$UPSTREAM_REV:$upstream_path" | diff -q - "$SANDBOX_DIR/$profile.sb.in" > /dev/null; then
        echo "ok    $profile.sb.in is byte-identical to upstream $UPSTREAM_REV"
    else
        echo "FAIL  $profile.sb.in has diverged from upstream $UPSTREAM_REV" >&2
        git -C "$REPO" show "$UPSTREAM_REV:$upstream_path" | diff - "$SANDBOX_DIR/$profile.sb.in" >&2
        status=1
    fi
done

# --- Compilation: exactly what the build will emit, fed to 10.9's real compiler. -------------
for profile in $PROFILES; do
    source_file="$SANDBOX_DIR/$profile.sb.in"
    if [ ! -f "$source_file" ]; then
        echo "MISSING  $source_file" >&2
        status=1
        continue
    fi
    # The recovered profiles ship as upstream's file plus this port's .additions.sb, concatenated
    # before preprocessing — same as the CMake rule.
    additions="$SANDBOX_DIR/$profile.additions.sb"
    [ -f "$additions" ] || additions=""
    if ! cat "$source_file" $additions \
        | grep -o "^[^;]*" \
        | clang -E -P -w -mmacosx-version-min=10.9 -include wtf/Platform.h \
            -I "$WTF_HEADERS" -I "$BMALLOC_HEADERS" -I "$WEBKIT_DIR" - > "$WORK/$profile.sb"; then
        echo "FAIL  $profile (preprocessing)" >&2
        status=1
        continue
    fi
    "$WORK/sbcheck" "$WORK/$profile.sb" || status=1
done

if [ "$status" != 0 ]; then
    echo
    echo "A profile above will not compile on 10.9, or is no longer the upstream policy it claims" >&2
    echo "to be. Applying an uncompilable profile CRASH()es the process that loads it. See" >&2
    echo "MavericksSupport/sandbox/README.md for the vocabulary this OS accepts." >&2
fi
exit $status
