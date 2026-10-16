# Sourced by run-layout-tests.sh, run-api-tests.sh, run-jsc-tests.sh, run-test262.sh,
# tests/cocoa-curl/run.sh, tests/image-decoders/incremental-video-image.sh and
# tests/cdm-proxy-key-system/run.sh, which set ROOT, take the test-run lock before taking a snapshot,
# and release the products lock on exit.
#
# A run's binaries, frameworks and WebKit2 XPC services are a copy of WebKitBuild/Release, so a build
# that relinks the tree during the run leaves them alone. The copy is taken under the shared products
# lock (products-lock.sh), and only of a tree that holds a finished build with nothing changed since: while
# a build holds the lock, or when the tree holds no finished build, a run tests the copy of the last
# one. The copy keeps the tree's bin/ and lib/ layout, which the drivers, the injected bundles and the
# XPC services find each other by, and holds the C++ runtime and polyfill dylib the build links
# against; make-build-binaries-runnable.sh --products makes it loadable from where it is. One copy, in
# $AQUAWEBKIT_TEST_PRODUCTS_DIR (default: WebKitBuild/TestProducts), serves every run; its .complete
# names the build it holds.
. "$ROOT/AquaWebKitSupport/scripts/products-lock.sh"
TEST_PRODUCTS="${AQUAWEBKIT_TEST_PRODUCTS_DIR:-$ROOT/WebKitBuild/TestProducts}"
mkdir -p "$TEST_PRODUCTS/bin" "$TEST_PRODUCTS/lib" && TEST_PRODUCTS="$(cd "$TEST_PRODUCTS" && pwd -P)" || exit 1
TEST_PRODUCTS_COMPLETE="$TEST_PRODUCTS/.complete"
# The build the copy holds, and why the copy was not refreshed when it was not.
TEST_PRODUCTS_BUILD=""
TEST_PRODUCTS_KEPT=""

# Refreshes the copy when the tree holds a finished build, and otherwise keeps the copy of the last one.
# lib/ is copied less static libraries and headers, bin/ less layout-test results; a link's temporary
# output (lld's <output>.tmpXXXXXXX) is not a product. The toolchain names its C++ runtime through
# links, and the copy holds the files they name. rsync replaces a changed file by renaming a new one
# over it.
snapshot_test_products() {
    local build="$ROOT/WebKitBuild/Release" product changed status link
    local runtime="${AQUAWEBKIT_CLANG:-$ROOT/AquaWebKitSupport/toolchain/build/clang}/lib"
    if ! take_products_lock try shared; then
        TEST_PRODUCTS_KEPT="a build is changing WebKitBuild/Release"
    elif [ ! -f "$PRODUCTS_COMPLETE" ]; then
        TEST_PRODUCTS_KEPT="the last build of WebKitBuild/Release did not finish"
    elif changed=$(product_newer_than_marker) && [ -n "$changed" ]; then
        TEST_PRODUCTS_KEPT="$changed changed after the last finished build"
    else
        product=$(cat "$PRODUCTS_COMPLETE")
        rm -f "$TEST_PRODUCTS_COMPLETE"
        echo "Copying the build $product to $TEST_PRODUCTS ..."
        rsync -a --delete --exclude='*.tmp*' --exclude='/.*' --exclude='*.a' \
            --exclude='/*.framework/Headers' --exclude='/*.framework/PrivateHeaders' --exclude='/*.framework/Modules' \
            --exclude='/*.framework/Versions/*/Headers' --exclude='/*.framework/Versions/*/PrivateHeaders' \
            --exclude='/*.framework/Versions/*/Modules' \
            --exclude='/libc++.1.dylib' --exclude='/libc++abi.1.dylib' --exclude='/libpolyfill_classes.dylib' \
            "$build/lib/" "$TEST_PRODUCTS/lib/" &&
        rsync -a --delete --exclude='*.tmp*' --exclude='/.*' --exclude='/layout-test-results' \
            "$build/bin/" "$TEST_PRODUCTS/bin/" &&
        rsync -aL "$runtime/libc++.1.dylib" "$runtime/libc++abi.1.dylib" \
            "$ROOT/AquaWebKitSupport/polyfill/build/libpolyfill_classes.dylib" "$TEST_PRODUCTS/lib/"
        status=$?
        changed=$(product_newer_than_marker)
        [ "$(cat "$PRODUCTS_COMPLETE" 2>/dev/null)" = "$product" ] || changed="${changed:-its build marker}"
        release_products_lock
        if [ $status -ne 0 ]; then
            echo "ERROR: could not copy the build products to $TEST_PRODUCTS" >&2
            return 1
        fi
        if [ -n "$changed" ]; then
            echo "ERROR: WebKitBuild/Release changed while it was copied ($changed)" >&2
            return 1
        fi
        while IFS= read -r link; do
            case "$(readlink "$link")" in
                "$ROOT"/*) echo "ERROR: $link links into the checkout" >&2; return 1 ;;
            esac
        done < <(find "$TEST_PRODUCTS/bin" "$TEST_PRODUCTS/lib" -type l)
        bash "$ROOT/AquaWebKitSupport/scripts/make-build-binaries-runnable.sh" --products="$TEST_PRODUCTS" || return 1
        echo "$product" > "$TEST_PRODUCTS_COMPLETE"
        TEST_PRODUCTS_BUILD="$product"
        return 0
    fi
    release_products_lock
    if [ -f "$TEST_PRODUCTS_COMPLETE" ]; then
        TEST_PRODUCTS_BUILD=$(cat "$TEST_PRODUCTS_COMPLETE")
        echo "Not copying: $TEST_PRODUCTS_KEPT."
        return 0
    fi
    echo "ERROR: $TEST_PRODUCTS_KEPT, and $TEST_PRODUCTS holds no finished build" >&2
    return 1
}

# The line a runner prints when its run starts and as its last line.
tested_build_report() {
    [ -n "$TEST_PRODUCTS_BUILD" ] || return 0
    if [ -n "$TEST_PRODUCTS_KEPT" ]; then
        echo "Tested build: $TEST_PRODUCTS_BUILD -- an earlier copy, NOT the build now in WebKitBuild/Release ($TEST_PRODUCTS_KEPT)."
    else
        echo "Tested build: $TEST_PRODUCTS_BUILD"
    fi
}

# program_matches_copy <program> <stamp file>: a program compiled against the tree runs only against the
# copy of the build it was compiled against, which its stamp names.
program_matches_copy() {
    local stamp
    stamp=$(cat "$2" 2>/dev/null)
    [ -n "$stamp" ] && [ "$stamp" = "$TEST_PRODUCTS_BUILD" ] && return 0
    echo "ERROR: $1 was compiled against the build ${stamp:-(unrecorded)}, but the copy holds the build $TEST_PRODUCTS_BUILD; rebuild it" >&2
    return 1
}
