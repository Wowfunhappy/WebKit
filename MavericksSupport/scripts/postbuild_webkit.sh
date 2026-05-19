#!/bin/bash
# Post-build steps for WebKit on macOS 10.9.
# Run after rebuilding WebKit to ensure both Versions/A and Versions/615.1.1
# are patched with the ObjC classlist limit.
set -e
LIB=/Users/jonathan/Desktop/WebKit/lib/lib/WebKit.framework
PY=/Users/jonathan/Desktop/clang/tools/python3/bin/python3
PATCHER=/Users/jonathan/Desktop/clang/patch_classlist.py

cp -p "$LIB/Versions/615.1.1/WebKit" "$LIB/Versions/A/WebKit"
# 2026-05-19: Truncation RE-DISABLED again. With truncation, classes past
# index 72 exist in __DATA but never get registered by libobjc, so
# +[NSBundle bundleForClass:] for one of them aborts with
# "no class for metaclass" — crashes Safari when About Safari is clicked.
# Without truncation (238 classes ship): About Safari works. The earlier
# slow-display/dead-clicks symptoms were caused by RequestIdleCallback,
# which is now also reverted.
# "$PY" "$PATCHER" "$LIB/Versions/A/WebKit" "$LIB/Versions/615.1.1/WebKit"
echo "Post-build done. (all 238 classes ship — truncation breaks About Safari)"

# Install to /System/Library so Safari (UIProcess) actually uses our build.
# WebContent picks up our build from @rpath, but Safari links the system
# WebKit framework binary directly. Without this step every IPC error path
# (e.g. provisional load failure → CoreIPCError encode) crashes Safari with
# garbage from polyfill stubs the new build fixes.
SYS=/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit
sudo cp -p "$LIB/Versions/A/WebKit" "$SYS"
sudo codesign -f -s - "$SYS"
echo "Installed + adhoc-signed $SYS"

# Safari.framework on this 10.9 build links WebKit from StagedFrameworks,
# NOT /System/Library/Frameworks. Without copying here, Safari runs an OLD
# WebKit binary even after my install — every fix appears silently dead.
STAGED=/System/Library/StagedFrameworks/Safari/WebKit.framework/Versions/A/WebKit
if [ -e "$STAGED" ]; then
    sudo cp -p "$LIB/Versions/A/WebKit" "$STAGED"
    sudo codesign -f -s - "$STAGED"
    echo "Installed + adhoc-signed $STAGED"
fi

# WebCore must be installed too when changed — otherwise WebKit (with new
# vtable layouts) calls into a stale WebCore and crashes mysteriously.
# 2026-05-17: ran for hours debugging a TCA crash that was actually
# rooted in WebCore being May 13 while WebKit was May 17. See
# project_tca_experiment_reverted_may17.md
WEBCORE_LOCAL=/Users/jonathan/Desktop/WebKit/lib/lib/WebCore.framework/Versions/A/WebCore
WEBCORE_STAGED=/System/Library/StagedFrameworks/Safari/WebCore.framework/Versions/A/WebCore
if [ "$WEBCORE_LOCAL" -nt "$WEBCORE_STAGED" ]; then
    sudo cp -p "$WEBCORE_LOCAL" "$WEBCORE_STAGED"
    sudo codesign -f -s - "$WEBCORE_STAGED"
    echo "Installed + adhoc-signed $WEBCORE_STAGED (was stale)"
else
    echo "WebCore unchanged — skipping install"
fi
