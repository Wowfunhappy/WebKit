# Sourced by build.sh, test-products-snapshot.sh and the test programs' build scripts, which set ROOT.
#
# WebKitBuild/Release mixes links while a build runs: from its configure until staging has
# materialized the XPC service variants and the runtime is mirrored into the built frameworks, the
# tree holds some products of this build and some of the last. build.sh holds this lock for that span
# and test-products-snapshot.sh holds it while it copies the tree, so a copy never reads a tree a
# build is changing. PRODUCTS_COMPLETE names the build whose products the tree holds, by its start and
# finish: build.sh removes it when it takes the lock and writes it after a successful link, staging
# and mirror. A product written after it (a bare ninja, a one-target relink, a standalone
# build-polyfill.sh) means the tree no longer holds that build.
. "$ROOT/AquaWebKitSupport/scripts/fd-lock.sh"
PRODUCTS_LOCK="$ROOT/WebKitBuild/.products.lock"
PRODUCTS_LOCK_FD=8
PRODUCTS_COMPLETE="$ROOT/WebKitBuild/Release/.products-complete"
PRODUCTS_LOCK_HELD=""

# take_products_lock try|wait
take_products_lock() {
    fd_lock "$PRODUCTS_LOCK_FD" "$PRODUCTS_LOCK" "$1" || return 1
    PRODUCTS_LOCK_HELD=1
}

# Only a process that took the lock releases it; one still waiting for it stops waiting.
release_products_lock() {
    fd_lock_stop_waiter
    [ -n "$PRODUCTS_LOCK_HELD" ] && fd_unlock "$PRODUCTS_LOCK_FD"
    PRODUCTS_LOCK_HELD=""
    return 0
}

# The first product in WebKitBuild/Release newer than PRODUCTS_COMPLETE: what test-products-snapshot.sh
# copies (bin/ and lib/ less static libraries, headers, layout-test results, link temporaries and their
# own dot files) and the polyfill dylib the build links against.
product_newer_than_marker() {
    local build="$ROOT/WebKitBuild/Release" polyfill="$ROOT/AquaWebKitSupport/polyfill/build/libpolyfill_classes.dylib"
    if [ "$polyfill" -nt "$PRODUCTS_COMPLETE" ]; then
        echo "$polyfill"
        return 0
    fi
    find "$build/bin" "$build/lib" \( -name '*.tmp*' -o -name '*.a' -o -path "$build/bin/.*" -o -path "$build/lib/.*" \
        -o -path "$build/bin/layout-test-results" -o -path "$build/lib/*.framework/Headers" \
        -o -path "$build/lib/*.framework/PrivateHeaders" -o -path "$build/lib/*.framework/Modules" \
        -o -path "$build/lib/*.framework/Versions/*/Headers" -o -path "$build/lib/*.framework/Versions/*/PrivateHeaders" \
        -o -path "$build/lib/*.framework/Versions/*/Modules" \) -prune \
        -o ! -type d -newer "$PRODUCTS_COMPLETE" -print -quit 2>/dev/null
}

# The finished build WebKitBuild/Release holds; fails when it holds none.
finished_tree_build() {
    [ -f "$PRODUCTS_COMPLETE" ] && [ -z "$(product_newer_than_marker)" ] && cat "$PRODUCTS_COMPLETE"
}
