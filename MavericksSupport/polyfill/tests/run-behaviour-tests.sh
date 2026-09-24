#!/bin/bash
# Behaviour tests for the polyfill layer, run against the built polyfill/build/ products.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/polyfill-env.sh"
. "$REPO/MavericksSupport/scripts/host-headers.sh"

REAL_CLANG="$CLANG"
REAL_CLANGXX="$CLANGXX"
run_clang() {
    "$REAL_CLANG" "$@" 2>&1 | tee -a /tmp/wk_build.log
    return ${PIPESTATUS[0]}
}
run_clangxx() {
    "$REAL_CLANGXX" "$@" 2>&1 | tee -a /tmp/wk_build.log
    return ${PIPESTATUS[0]}
}
CLANG=run_clang
CLANGXX=run_clangxx

TBEHAV="$POLY/tests/behaviour"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/polybehaviour.XXXXXX")"
T="$OBJ/tests"
trap 'rm -rf "$OBJ"' EXIT
mkdir -p "$T" "$OBJ/methods" "$OBJ/mech"

PROBE_LIBS="$OUT/libpolyfill.a $REPO/MavericksSupport/deps/build/lib/libots.a $REPO/MavericksSupport/deps/build/lib/libwoff2dec.a $REPO/MavericksSupport/deps/build/lib/libbrotlidec.a $REPO/MavericksSupport/deps/build/lib/libbrotlicommon.a $REPO/MavericksSupport/deps/build/lib/libpng16.a $REPO/MavericksSupport/deps/build/lib/libtiff.a $REPO/MavericksSupport/deps/build/lib/libjpeg.a $REPO/MavericksSupport/deps/build/lib/libicuuc.a $REPO/MavericksSupport/deps/build/lib/libpsl.5.dylib $REPO/MavericksSupport/deps/build/lib/libcrypto.dylib -L$REPO/MavericksSupport/deps/build/lib -lc++ -Wl,-rpath,$REPO/MavericksSupport/deps/build/lib -framework Foundation -framework CoreFoundation -framework CFNetwork -framework CoreGraphics -framework IOSurface -framework CoreText -framework Security -framework CoreMedia -Wl,-rpath,$OUT -lsqlite3 -lbsm -lsandbox -lobjc -lz"
ICU_LIBS="$REPO/MavericksSupport/deps/build/lib/libicuuc.a $REPO/MavericksSupport/deps/build/lib/libicudata.a -lc++"

APPKIT_OBJECT_STATE=unbuilt
FOUNDATION_OBJECT_STATE=unbuilt
AVFOUNDATION_OBJECT_STATE=unbuilt
QUARTZCORE_OBJECT_STATE=unbuilt
CRYPTOKITPRIVATE_OBJECT_STATE=unbuilt
DEPTH_SORTING_OBJECT_STATE=unbuilt
SELREF_OBJECT_STATE=unbuilt

build_method_object() {
    local unit="$1" state source
    case "$unit" in
        AppKit)
            state="$APPKIT_OBJECT_STATE"
            source="$PF/methods/AppKit.m"
            ;;
        Foundation)
            state="$FOUNDATION_OBJECT_STATE"
            source="$PF/methods/Foundation.m"
            ;;
        AVFoundation)
            state="$AVFOUNDATION_OBJECT_STATE"
            source="$PF/methods/AVFoundation.m"
            ;;
        QuartzCoreDepthSorting)
            state="$DEPTH_SORTING_OBJECT_STATE"
            source="$PF/methods/QuartzCoreDepthSorting.m"
            ;;
        QuartzCore)
            state="$QUARTZCORE_OBJECT_STATE"
            source="$PF/methods/QuartzCore.m"
            ;;
        CryptoKitPrivate)
            state="$CRYPTOKITPRIVATE_OBJECT_STATE"
            source="$PF/methods/CryptoKitPrivate.m"
            ;;
        *)
            return 1
            ;;
    esac
    [ "$state" = built ] && return 0
    [ "$state" = failed ] && return 1
    if "$CLANG" -c $MODERN $BLOCKCF $(methods_unitinc "$source") \
            -DWK_POLYFILL_UNIT="$unit" -o "$OBJ/methods/$unit.o" "$source"; then
        case "$unit" in
            AppKit) APPKIT_OBJECT_STATE=built ;;
            Foundation) FOUNDATION_OBJECT_STATE=built ;;
            AVFoundation) AVFOUNDATION_OBJECT_STATE=built ;;
            QuartzCore) QUARTZCORE_OBJECT_STATE=built ;;
            CryptoKitPrivate) CRYPTOKITPRIVATE_OBJECT_STATE=built ;;
            QuartzCoreDepthSorting) DEPTH_SORTING_OBJECT_STATE=built ;;
        esac
        return 0
    fi
    case "$unit" in
        AppKit) APPKIT_OBJECT_STATE=failed ;;
        Foundation) FOUNDATION_OBJECT_STATE=failed ;;
        AVFoundation) AVFOUNDATION_OBJECT_STATE=failed ;;
        QuartzCore) QUARTZCORE_OBJECT_STATE=failed ;;
        CryptoKitPrivate) CRYPTOKITPRIVATE_OBJECT_STATE=failed ;;
        QuartzCoreDepthSorting) DEPTH_SORTING_OBJECT_STATE=failed ;;
    esac
    return 1
}

build_selref_object() {
    [ "$SELREF_OBJECT_STATE" = built ] && return 0
    [ "$SELREF_OBJECT_STATE" = failed ] && return 1
    if "$CLANG" -c $MODERN $INC -DWK_POLYFILL_UNIT=mechanism \
            -o "$OBJ/mech/wk_selref_scope.o" "$MECH/wk_selref_scope.m"; then
        SELREF_OBJECT_STATE=built
        return 0
    fi
    SELREF_OBJECT_STATE=failed
    return 1
}

prepare_method_objects() {
    build_method_object "$1" && build_selref_object
}

matches_filter() {
    local name="$1" filter
    shift
    [ "$#" -eq 0 ] && return 0
    for filter in "$@"; do
        case "$name" in
            *"$filter"*) return 0 ;;
        esac
    done
    return 1
}

PASSED=0
FAILED=0
SELECTED=0
run_probe() {
    local name="$1" rc
    shift
    matches_filter "$name" "$@" || return 0
    SELECTED=$((SELECTED + 1))
    echo "### behaviour: $name"
    if "probe_$name"; then
        PASSED=$((PASSED + 1))
        echo "PASS $name"
    else
        rc=$?
        FAILED=$((FAILED + 1))
        echo "FAIL $name (exit $rc)"
    fi
}

probe_accent_color() {
    prepare_method_objects AppKit &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/accent_color" "$TBEHAV/AppKit-accent-color.m" \
            "$OBJ/methods/AppKit.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/accent_color"
}

probe_level_indicator_direction() {
    prepare_method_objects AppKit &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/level_indicator_direction" "$TBEHAV/AppKit-level-indicator-direction.m" \
            "$OBJ/methods/AppKit.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/level_indicator_direction"
}

probe_touch_bar() {
    prepare_method_objects AppKit &&
        "$CLANG" $HOST $INC -fno-objc-arc -fobjc-weak -o "$T/touch_bar" "$TBEHAV/AppKit-touch-bar.m" \
            "$OBJ/methods/AppKit.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/touch_bar"
}

probe_scrollview_insets() {
    "$CLANG" $MODERN $INC -fno-objc-arc -I"$PF/methods" -o "$T/scrollview_insets" "$TBEHAV/AppKit-scrollview-insets.m" \
        -framework AppKit -framework Foundation -lobjc &&
        "$T/scrollview_insets"
}

probe_color_popover_top_bar() {
    "$CLANG" $MODERN $INC -fno-objc-arc -I"$PF/methods" -o "$T/color_popover_top_bar" "$TBEHAV/AppKit-color-popover-top-bar.m" \
        -framework AppKit -framework Foundation -lobjc &&
        "$T/color_popover_top_bar"
}

probe_dispatch_activate() {
    "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/dispatch_activate" "$TBEHAV/libSystem-dispatch.m" $PROBE_LIBS &&
        "$T/dispatch_activate"
}

probe_getentropy() {
    "$CLANG" $HOST -I"$PF/shared/include" -o "$T/getentropy" "$TBEHAV/shared-getentropy.c" &&
        "$T/getentropy"
}

probe_clonefile() {
    "$CLANG" $HOST -I"$PF/shared/include" -o "$T/clonefile" "$TBEHAV/shared-clonefile.c" \
        "$PF/shared/clonefile.c" "$PF/shared/atcalls.c" "$PF/shared/statxx.c" "$PF/shared/pthread_chdir.c" &&
        "$T/clonefile"
}

probe_pthread_qos() {
    "$CLANG" $HOST -I"$PF/shared/include" -o "$T/pthread_qos" "$TBEHAV/shared-pthread-qos.c" "$PF/shared/pthread_qos.c" &&
        "$T/pthread_qos"
}

probe_pthread_stack() {
    "$CLANG" $HOST -I"$PF/shared/include" -o "$T/pthread_stack" "$TBEHAV/shared-pthread-stack.c" "$PF/shared/pthread_stack.c" &&
        "$T/pthread_stack"
}

probe_notify_tokens() {
    "$CLANG" $HOST $INC -fblocks -o "$T/notify_tokens" "$TBEHAV/libSystem-notify.c" $PROBE_LIBS &&
        "$T/notify_tokens"
}

probe_user_dir_suffix() {
    "$CLANG" $MODERN $INC -o "$T/user_dir_suffix" "$TBEHAV/libSystem-dirhelper.c" $PROBE_LIBS &&
        "$T/user_dir_suffix"
}

probe_sectask_identity() {
    "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/sectask_identity" "$TBEHAV/Security-sectask.m" $PROBE_LIBS &&
        "$T/sectask_identity"
}

probe_trust_serialize() {
    "$CLANG" $MODERN $INC -Wno-deprecated-declarations -o "$T/trust_serialize" "$TBEHAV/Security-trust-serialize.c" $PROBE_LIBS &&
        "$T/trust_serialize"
}

probe_rsa_pss_verify() {
    "$CLANG" $MODERN $INC -I"$REPO/MavericksSupport/deps/build/include" -o "$T/rsa_pss_verify" \
        "$TBEHAV/Security-rsa-pss-verify.c" $PROBE_LIBS &&
        "$T/rsa_pss_verify"
}

probe_ec_public_point() {
    "$CLANG" $MODERN $INC -o "$T/ec_public_point" "$TBEHAV/libcommonCrypto-ec-public-point.c" $PROBE_LIBS &&
        "$T/ec_public_point"
}

probe_gcrypt_ec_public_point() {
    "$CLANG" $MODERN $INC -I"$REPO/MavericksSupport/deps/build/include" -o "$T/gcrypt_ec_public_point" "$TBEHAV/libgcrypt-ec-public-point.c" \
        "$REPO/MavericksSupport/deps/build/lib/libgcrypt.a" "$REPO/MavericksSupport/deps/build/lib/libgpg-error.a" $PROBE_LIBS &&
        "$T/gcrypt_ec_public_point"
}

probe_public_suffix() {
    "$CLANG" $MODERN $INC -I"$PF/c" -o "$T/public_suffix" "$TBEHAV/CFNetwork-public-suffix.c" $PROBE_LIBS &&
        "$T/public_suffix"
}

probe_timebase() {
    "$CLANG" $MODERN $INC -o "$T/timebase" "$TBEHAV/libSystem-timebase.c" $PROBE_LIBS &&
        "$T/timebase"
}

probe_color_timebase() {
    "$CLANG" $MODERN $INC -Wno-unguarded-availability -Wno-unguarded-availability-new \
        -o "$T/color_timebase" "$TBEHAV/CoreMedia-color-timebase.c" \
        $PROBE_LIBS -framework CoreMedia -framework CoreVideo &&
        "$T/color_timebase"
}

probe_memory_entry_data_addr() {
    "$CLANG" $MODERN $INC -o "$T/memory_entry_data_addr" "$TBEHAV/mach-memory-entry-data-addr.c" $PROBE_LIBS &&
        "$T/memory_entry_data_addr"
}

probe_task_vm_info() {
    "$CLANG" $MODERN $INC -o "$T/task_vm_info" "$TBEHAV/libSystem-task-vm-info.c" $PROBE_LIBS &&
        "$T/task_vm_info"
}

probe_thread_extended_info() {
    "$CLANG" $MODERN $INC -o "$T/thread_extended_info" "$TBEHAV/libSystem-thread-extended-info.c" $PROBE_LIBS &&
        "$T/thread_extended_info"
}

probe_unfair_lock() {
    "$CLANG" $MODERN $INC -Wno-unguarded-availability-new -o "$T/unfair_lock" "$TBEHAV/libSystem-unfair-lock.c" $PROBE_LIBS &&
        "$T/unfair_lock"
}

probe_stroke_line_segments() {
    "$CLANG" $MODERN $INC -Wno-four-char-constants -o "$T/stroke_line_segments" "$TBEHAV/CoreGraphics-stroke-line-segments.c" \
        $PROBE_LIBS -framework CoreGraphics -framework IOSurface &&
        "$T/stroke_line_segments"
}

probe_ax_client_identification() {
    "$CLANG" $MODERN $INC -dynamiclib -DWK_PROBE_SIDE_A -o "$T/ax_client_side_a.dylib" "$TBEHAV/ApplicationServices-client-identification.c" $PROBE_LIBS &&
        "$CLANG" $MODERN $INC -dynamiclib -DWK_PROBE_SIDE_B -o "$T/ax_client_side_b.dylib" "$TBEHAV/ApplicationServices-client-identification.c" $PROBE_LIBS &&
        "$CLANG" $MODERN $INC -o "$T/ax_client_identification" "$TBEHAV/ApplicationServices-client-identification.c" &&
        "$T/ax_client_identification" "$T/ax_client_side_a.dylib" "$T/ax_client_side_b.dylib"
}

probe_cg_iosurface_image_colorspace() {
    "$CLANG" $MODERN $INC -Wno-four-char-constants -dynamiclib -DWK_PROBE_SIDE_A -o "$T/cg_iosurface_side_a.dylib" \
        "$TBEHAV/CoreGraphics-iosurface-image-colorspace.c" $PROBE_LIBS -framework CoreGraphics -framework IOSurface &&
        "$CLANG" $MODERN $INC -Wno-four-char-constants -dynamiclib -DWK_PROBE_SIDE_B -o "$T/cg_iosurface_side_b.dylib" \
            "$TBEHAV/CoreGraphics-iosurface-image-colorspace.c" $PROBE_LIBS -framework CoreGraphics -framework IOSurface &&
        "$CLANG" $MODERN $INC -Wno-four-char-constants -o "$T/cg_iosurface_image_colorspace" \
            "$TBEHAV/CoreGraphics-iosurface-image-colorspace.c" $PROBE_LIBS -framework CoreGraphics -framework IOSurface &&
        "$T/cg_iosurface_image_colorspace" "$T/cg_iosurface_side_a.dylib" "$T/cg_iosurface_side_b.dylib"
}

probe_cg_live_image() {
    "$CLANG" $MODERN $INC -o "$T/cg_live_image" \
        "$TBEHAV/CoreGraphics-live-image.c" $PROBE_LIBS -framework CoreGraphics -framework IOSurface &&
        "$T/cg_live_image"
}

probe_cg_iosurface_image_reference() {
    "$CLANG" $MODERN $INC -o "$T/cg_iosurface_image_reference" \
        "$TBEHAV/CoreGraphics-iosurface-image-reference.c" $PROBE_LIBS -framework IOSurface &&
        "$T/cg_iosurface_image_reference"
}

probe_cg_iosurface_premultiplied_sanitize() {
    "$CLANG" $MODERN $INC -Wno-four-char-constants -o "$T/cg_iosurface_premultiplied_sanitize" \
        "$TBEHAV/CoreGraphics-iosurface-premultiplied-sanitize.c" $PROBE_LIBS -framework CoreGraphics -framework IOSurface &&
        "$T/cg_iosurface_premultiplied_sanitize"
}

probe_rsabssa() {
    build_method_object CryptoKitPrivate &&
        "$CLANG" $MODERN $INC -I"$REPO/MavericksSupport/deps/build/include" -fno-objc-arc -o "$T/rsabssa" \
            "$TBEHAV/CryptoKitPrivate-rsabssa.m" "$OBJ/methods/CryptoKitPrivate.o" $PROBE_LIBS &&
        "$T/rsabssa"
}

probe_accessibility_absent_framework() {
    "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/accessibility_absent_framework" "$TBEHAV/Accessibility-absent-framework.m" \
        -Wl,-rpath,"$OUT" "$OUT/libpolyfill_classes.dylib" $PROBE_LIBS &&
        "$T/accessibility_absent_framework"
}

probe_item_provider() {
    "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/item_provider" "$TBEHAV/Foundation-item-provider.m" \
        -Wl,-rpath,"$OUT" "$OUT/libpolyfill_classes.dylib" $PROBE_LIBS &&
        "$T/item_provider"
}

probe_samesite() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/samesite" "$TBEHAV/CFNetwork-samesite.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/samesite"
}

probe_suggested_filename() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/suggested_filename" "$TBEHAV/Foundation-suggested-filename.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/suggested_filename"
}

probe_backup_exclusion() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/backup_exclusion" "$TBEHAV/Foundation-backup-exclusion.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/backup_exclusion"
}

probe_cookie_notifications() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/cookie_notifications" "$TBEHAV/CFNetwork-cookie-notifications.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/cookie_notifications"
}

probe_shared_cookie_jar() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/shared_cookie_jar" "$TBEHAV/CFNetwork-shared-cookie-jar.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/shared_cookie_jar"
}

probe_cookie_change_churn() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/cookie_change_churn" "$TBEHAV/CFNetwork-cookie-change-churn.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/cookie_change_churn" ${WK_COOKIE_CHURN_ROUNDS:-20} ${WK_COOKIE_CHURN_MODE:-}
}

probe_private_storage_session() {
    "$CLANG" $MODERN $INC -fno-objc-arc -dynamiclib -DWK_PROBE_SECOND_IMAGE -o "$T/private_storage_session_image.dylib" \
        "$TBEHAV/CFNetwork-private-storage-session.m" $PROBE_LIBS &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/private_storage_session" "$TBEHAV/CFNetwork-private-storage-session.m" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" $PROBE_LIBS &&
        "$T/private_storage_session" "$T/private_storage_session_image.dylib"
}

probe_session_invalidation() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/session_invalidation" "$TBEHAV/CFNetwork-session-invalidation.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/session_invalidation"
}

probe_dd_secure_coding() {
    "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/dd_secure_coding" "$TBEHAV/DataDetectors-secure-coding.m" \
        $PROBE_LIBS && "$T/dd_secure_coding"
}

probe_keyed_coding() {
    "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/keyed_coding" "$TBEHAV/Foundation-keyed-coding.m" \
        $PROBE_LIBS && "$T/keyed_coding"
}

probe_secure_coding() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/secure_coding" "$TBEHAV/Foundation-secure-coding.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/secure_coding"
}

probe_url_request_coding() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/url_request_coding" "$TBEHAV/Foundation-url-request-coding.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/url_request_coding"
}

probe_url_data_representation() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/url_data_representation" "$TBEHAV/Foundation-url-data-representation.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/url_data_representation"
}

probe_relative_file_url() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/relative_file_url" "$TBEHAV/Foundation-relative-file-url.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/relative_file_url"
}

probe_language_minimization() {
    prepare_method_objects Foundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/language_minimization" "$TBEHAV/Foundation-language-minimization.m" \
            "$OBJ/methods/Foundation.o" "$OBJ/mech/wk_selref_scope.o" $ICU_LIBS \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/language_minimization"
}

probe_avf_display_color() {
    "$CLANG" $HOST -fno-objc-arc -I"$PF/methods" -I"$PF/c" -o "$T/avf_display_color" "$TBEHAV/AVFoundation-display-color.m" \
        "$PF/methods/Accelerate.m" "$PF/shared/wk_symbols.c" -framework Cocoa -framework QuartzCore -framework CoreMedia -framework CoreVideo -framework Accelerate &&
        "$T/avf_display_color"
}

probe_avf_resource_loader_drain() {
    prepare_method_objects AVFoundation &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/avf_resource_loader_drain" "$TBEHAV/AVFoundation-resource-loader-drain.m" \
            "$OBJ/methods/AVFoundation.o" "$OBJ/mech/wk_selref_scope.o" "$PF/methods/Accelerate.m" -I"$PF/c" -framework Accelerate \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AVFoundation -framework CoreMedia -framework AppKit -framework Foundation \
            -framework CoreServices -Wl,-rpath,"$OUT" "$OUT/libpolyfill_classes.dylib" $PROBE_LIBS &&
        "$T/avf_resource_loader_drain"
}

probe_avf_display_color_kvo() {
    prepare_method_objects AVFoundation &&
        "$CLANG" $MODERN $INC -Wno-unguarded-availability -Wno-unguarded-availability-new -fno-objc-arc -o "$T/avf_display_color_kvo" "$TBEHAV/AVFoundation-display-color-kvo.m" \
            "$OBJ/methods/AVFoundation.o" "$OBJ/mech/wk_selref_scope.o" "$PF/methods/Accelerate.m" -I"$PF/c" -framework Accelerate \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework AVFoundation -framework CoreMedia -framework AppKit -framework Foundation \
            -framework CoreServices -Wl,-rpath,"$OUT" "$OUT/libpolyfill_classes.dylib" $PROBE_LIBS &&
        "$T/avf_display_color_kvo"
}

probe_constant_packet_input() {
    "$CLANG" $MODERN $INC -o "$T/constant_packet_input" "$TBEHAV/AudioToolbox-constant-packet-input.c" \
        $PROBE_LIBS -framework AudioToolbox -framework AudioUnit &&
        "$T/constant_packet_input"
}

probe_delay_mode_excess_input() {
    "$CLANG" $MODERN $INC -o "$T/delay_mode_excess_input" "$TBEHAV/AudioToolbox-delay-mode-excess-input.c" \
        $PROBE_LIBS -framework AudioToolbox -framework AudioUnit &&
        "$T/delay_mode_excess_input"
}

probe_optical_size() {
    "$CLANG" $MODERN $INC -o "$T/optical_size" "$TBEHAV/CoreText-optical-size.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/optical_size"
}

probe_face_selection() {
    "$CLANG" $MODERN $INC -o "$T/face_selection" "$TBEHAV/CoreText-face-selection.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/face_selection"
}

probe_display_p3_profile() {
    "$CLANG" $MODERN $INC -I"$REPO/MavericksSupport/deps/build/include" \
        -Wno-unguarded-availability -Wno-unguarded-availability-new -o "$T/display_p3_profile" "$TBEHAV/CoreGraphics-display-p3-profile.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -framework ImageIO &&
        "$T/display_p3_profile" "$REPO/LayoutTests/imported/w3c/web-platform-tests/html/canvas/element/manual/wide-gamut-canvas/resources/Display-P3-FF0000FF.png"
}

probe_pq_profile() {
    "$CLANG" $MODERN $INC -Wno-unguarded-availability -Wno-unguarded-availability-new -o "$T/pq_profile" "$TBEHAV/CoreGraphics-pq-profile.c" $PROBE_LIBS &&
        "$T/pq_profile"
}

probe_hdr_gainmap() {
    "$CLANG" $MODERN $INC -Wno-unguarded-availability -Wno-unguarded-availability-new -fno-objc-arc -o "$T/hdr_gainmap" "$TBEHAV/ImageIO-hdr-gainmap.m" $PROBE_LIBS \
        -framework CoreVideo -framework ImageIO &&
        "$T/hdr_gainmap" "$REPO/LayoutTests/fast/images/resources/gainmap-red-green-1920x1920.jpg"
}

probe_cmyk_row_mask() {
    local resources="$REPO/LayoutTests/imported/w3c/web-platform-tests/html/canvas/element/manual/wide-gamut-canvas/resources"
    "$CLANG" $MODERN $INC -I"$REPO/MavericksSupport/deps/build/include" \
        -o "$T/cmyk_row_mask" "$TBEHAV/CoreGraphics-cmyk-row-mask.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -framework ImageIO &&
        "$T/cmyk_row_mask" "$resources/Display-P3-FF0000FF.png" \
            "$resources/Generic-CMYK-FF000000.jpg" "$resources/Generic-CMYK-BE000000.jpg"
}

probe_encode_cadence() {
    "$CLANG" $MODERN $INC -Wno-unused-function -o "$T/encode_cadence" "$TBEHAV/VideoToolbox-encode-cadence.c" $PROBE_LIBS \
        -framework VideoToolbox -framework CoreVideo &&
        "$T/encode_cadence"
}

probe_h264_parameter_sets() {
    "$CLANG" $MODERN $INC -o "$T/h264_parameter_sets" "$TBEHAV/CoreMedia-h264-parameter-sets.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -framework ImageIO -framework VideoToolbox -framework CoreVideo &&
        "$T/h264_parameter_sets"
}

probe_font_collections() {
    "$CLANG" $MODERN $INC -o "$T/font_collections" "$TBEHAV/CoreText-font-collections.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -framework ImageIO &&
        "$T/font_collections" "$REPO/LayoutTests"
}

probe_colr_filled_paths() {
    "$CLANG" $MODERN $INC -o "$T/colr_filled_paths" "$TBEHAV/CoreText-colr-filled-paths.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -framework ImageIO &&
        "$T/colr_filled_paths" "$REPO/LayoutTests/fast/text/resources/Ahem-COLR.ttf"
}

probe_font_provenance() {
    "$CLANG" $MODERN $INC -o "$T/font_provenance" "$TBEHAV/CoreText-font-provenance.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/font_provenance"
}

probe_font_data_descriptors() {
    "$CLANG" $MODERN $INC -o "$T/font_data_descriptors" "$TBEHAV/CoreText-font-data-descriptors.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/font_data_descriptors" "$REPO/LayoutTests/resources/Ahem.otf" "$REPO/LayoutTests/resources/Ahem.ttf" \
            /Library/Fonts/Skia.ttf
}

probe_feature_clear() {
    "$CLANG" $MODERN $INC -o "$T/feature_clear" "$TBEHAV/CoreText-feature-clear.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/feature_clear"
}

probe_descriptor_options() {
    "$CLANG" $MODERN $INC -o "$T/descriptor_options" "$TBEHAV/CoreText-descriptor-options.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/descriptor_options"
}

probe_sbix_bitmap_placement() {
    "$CLANG" $MODERN $INC -o "$T/sbix_bitmap_placement" "$TBEHAV/CoreText-sbix-bitmap-placement.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -framework ImageIO -lc++ &&
        "$T/sbix_bitmap_placement" &&
    "$CLANG" $MODERN $INC -o "$T/color_font_matrix" "$TBEHAV/CoreText-color-font-matrix.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -framework ImageIO -lc++ &&
        "$T/color_font_matrix" "$REPO/LayoutTests/http/tests/canvas/color-fonts/resources/Ahem-sbix.ttf" \
            "$REPO/LayoutTests/fast/text/resources/Ahem-COLR.ttf"
}

probe_typo_metrics() {
    "$CLANG" $MODERN $INC -o "$T/typo_metrics" "$TBEHAV/CoreText-typo-metrics.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/typo_metrics" "$REPO/LayoutTests/imported/w3c/web-platform-tests/fonts/CanvasTest.ttf"
}

probe_font_heights() {
    mkdir -p "$T/font-height-fixtures" &&
        "$REPO/MavericksSupport/toolchain/build/python3/bin/python3" "$TBEHAV/CoreText-font-heights-fixtures.py" \
            "$T/font-height-fixtures" \
            "$REPO/LayoutTests/imported/w3c/web-platform-tests/css/css-fonts/support/fonts/RobotoExtremo-VF.subset.ttf" \
            "$REPO/LayoutTests/imported/w3c/web-platform-tests/css/css-fonts/resources/avar/rvrnTest[opsz,wdth,wght].ttf" &&
        "$CLANG" $MODERN $INC -I"$PF/c" -o "$T/font_heights" "$TBEHAV/CoreText-font-heights.c" $PROBE_LIBS \
            -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/font_heights" "$T/font-height-fixtures" \
            "$REPO/LayoutTests/imported/w3c/web-platform-tests/css/css-fonts/resources/avar/rvrnTestAvar1[opsz,wdth,wght].ttf" \
            "$REPO/LayoutTests/imported/w3c/web-platform-tests/css/css-fonts/resources/avar/rvrnTestAvar2[opsz,wdth,wght].ttf"
}

probe_variable_font_tables() {
    "$CLANGXX" $MODERN -std=c++17 -nostdinc++ -isystem "$SDK/usr/include/c++/v1" \
        "$TBEHAV/CoreText-variable-font-tables.cpp" -nostdlib++ \
        "$REPO/MavericksSupport/deps/build/lib/libc++.1.dylib" \
        "$REPO/MavericksSupport/deps/build/lib/libc++abi.1.dylib" \
        -Wl,-rpath,"$REPO/MavericksSupport/deps/build/lib" -framework CoreFoundation \
        -o "$T/variable_font_tables" &&
        "$T/variable_font_tables"
}

probe_feature_settings_order() {
    "$CLANG" $MODERN $INC -o "$T/feature_settings_order" "$TBEHAV/CoreText-feature-settings-order.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/feature_settings_order" "$REPO/LayoutTests/imported/w3c/web-platform-tests/css/css-fonts/support/fonts/FontWithFancyFeatures.otf"
}

probe_variation_axes() {
    "$CLANG" $MODERN $INC -o "$T/variation_axes" "$TBEHAV/CoreText-variation-axes.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/variation_axes"
}

probe_variation_axes_from_data() {
    "$CLANG" $MODERN $INC -o "$T/variation_axes_from_data" "$TBEHAV/CoreText-variation-axes-from-data.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/variation_axes_from_data" \
            "$REPO/LayoutTests/imported/w3c/web-platform-tests/css/css-fonts/matching/resources/variabletest_matching.ttf" /Library/Fonts/Skia.ttf
}

probe_path_glyph_range() {
    "$CLANG" $MODERN $INC -o "$T/path_glyph_range" "$TBEHAV/CoreText-path-glyph-range.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/path_glyph_range"
}

probe_sbix_sanitizer() {
    "$CLANG" $MODERN $INC -o "$T/sbix_sanitizer" "$TBEHAV/CoreText-sbix-sanitizer.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -lc++ &&
        "$T/sbix_sanitizer"
}

probe_aat_validators() {
    "$CLANGXX" $MODERN $INC -I"$PF/c" -std=c++17 -o "$T/aat_validators" "$TBEHAV/CoreText-aat-validators.cpp" \
        $PROBE_LIBS -lc++ &&
        "$T/aat_validators"
}

probe_aat_dispatch() {
    "$CLANG" $MODERN $INC -I"$PF/c" -o "$T/aat_dispatch" "$TBEHAV/CoreText-aat-dispatch.c" \
        $PROBE_LIBS -framework CoreText -framework CoreGraphics -framework ImageIO -lc++ &&
        "$T/aat_dispatch" "/Library/Fonts/AlBayan.ttf" "/Library/Fonts/Apple Chancery.ttf"
}

probe_character_clusters() {
    "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/character_clusters" "$TBEHAV/CoreFoundation-character-clusters.m" \
        $PROBE_LIBS &&
        "$T/character_clusters"
}

probe_cluster_fallback() {
    "$CLANG" $MODERN $INC -o "$T/cluster_fallback" "$TBEHAV/CoreText-cluster-fallback.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics &&
        "$T/cluster_fallback"
}

probe_logical_order() {
    "$CLANG" $MODERN $INC -I"$REPO/MavericksSupport/deps/build/include" -o "$T/logical_order" "$TBEHAV/CoreText-logical-order.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics &&
        "$T/logical_order"
}

probe_shape_glyphs_context() {
    "$CLANG" $MODERN $INC -o "$T/shape_glyphs_context" "$TBEHAV/CoreText-shape-glyphs-character-context.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics &&
        "$T/shape_glyphs_context" "$REPO/LayoutTests/imported/w3c/web-platform-tests"
}

probe_css_family_language() {
    "$CLANG" $MODERN $INC -o "$T/css_family_language" "$TBEHAV/CoreText-css-family-language.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics &&
        "$T/css_family_language"
}

probe_clipped_glyphs() {
    "$CLANG" $MODERN $INC -o "$T/clipped_glyphs" "$TBEHAV/CoreText-clipped-glyphs.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics -framework IOSurface &&
        "$T/clipped_glyphs"
}

probe_user_installed_matching() {
    "$CLANG" $MODERN $INC -o "$T/user_installed_matching" "$TBEHAV/CoreText-user-installed-matching.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics &&
        "$T/user_installed_matching" "$REPO/LayoutTests/resources/Ahem.ttf" "$REPO/Tools/WebKitTestRunner/fonts/FakeHelvetica-SingleExtendedCharacter.ttf"
}

probe_gpos_last_pair_set() {
    "$CLANG" $MODERN $INC -o "$T/gpos_last_pair_set" "$TBEHAV/CoreText-gpos-last-pair-set.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics &&
        "$T/gpos_last_pair_set" "$REPO/LayoutTests/imported/w3c/web-platform-tests"
}

probe_control_character_glyphs() {
    "$CLANG" $MODERN $INC -o "$T/control_character_glyphs" "$TBEHAV/CoreText-control-character-glyphs.c" $PROBE_LIBS \
        -framework CoreText -framework CoreGraphics &&
        "$T/control_character_glyphs"
}

probe_depth_sorting() {
    prepare_method_objects QuartzCore &&
        "$CLANG" $MODERN $INC -fno-objc-arc -o "$T/depth_sorting" "$TBEHAV/QuartzCore-depth-sorting.m" \
            "$OBJ/methods/QuartzCore.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework QuartzCore -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/depth_sorting"
}

probe_frame_rate_range() {
    prepare_method_objects QuartzCore &&
        "$CLANG" $MODERN $INC -fno-objc-arc -Wno-unguarded-availability-new -o "$T/frame_rate_range" "$TBEHAV/QuartzCore-frame-rate-range.m" \
            "$OBJ/methods/QuartzCore.o" "$OBJ/mech/wk_selref_scope.o" \
            -Wl,-force_load,"$OUT/libwk_marker.a" "$OUT/libpolyfill.a" \
            -framework QuartzCore -framework AppKit -framework Foundation -framework CoreServices "$OUT/libpolyfill_classes.dylib" \
            $PROBE_LIBS &&
        "$T/frame_rate_range"
}

probe_audiounit_max_frames() {
    "$CLANG" $HOST -Wno-deprecated-declarations $INC -o "$T/audiounit_max_frames" "$TBEHAV/AudioUnit-max-frames.c" \
        $PROBE_LIBS -framework AudioUnit -framework CoreAudio &&
        "$T/audiounit_max_frames"
}

run_probe accent_color "$@"
run_probe level_indicator_direction "$@"
run_probe touch_bar "$@"
run_probe scrollview_insets "$@"
run_probe color_popover_top_bar "$@"
run_probe dispatch_activate "$@"
run_probe sectask_identity "$@"
run_probe trust_serialize "$@"
run_probe ec_public_point "$@"
run_probe rsa_pss_verify "$@"
run_probe gcrypt_ec_public_point "$@"
run_probe timebase "$@"
run_probe color_timebase "$@"
run_probe clonefile "$@"
run_probe pthread_qos "$@"
run_probe pthread_stack "$@"
run_probe memory_entry_data_addr "$@"
run_probe task_vm_info "$@"
run_probe thread_extended_info "$@"
run_probe unfair_lock "$@"
run_probe stroke_line_segments "$@"
run_probe ax_client_identification "$@"
run_probe cg_iosurface_image_colorspace "$@"
run_probe cg_live_image "$@"
run_probe cg_iosurface_image_reference "$@"
run_probe cg_iosurface_premultiplied_sanitize "$@"
run_probe accessibility_absent_framework "$@"
run_probe rsabssa "$@"
run_probe item_provider "$@"
run_probe samesite "$@"
run_probe suggested_filename "$@"
run_probe backup_exclusion "$@"
run_probe shared_cookie_jar "$@"
run_probe cookie_change_churn "$@"
run_probe private_storage_session "$@"
run_probe session_invalidation "$@"
run_probe secure_coding "$@"
run_probe url_request_coding "$@"
run_probe dd_secure_coding "$@"
run_probe keyed_coding "$@"
run_probe getentropy "$@"
run_probe notify_tokens "$@"
run_probe user_dir_suffix "$@"
run_probe url_data_representation "$@"
run_probe relative_file_url "$@"
run_probe language_minimization "$@"
run_probe avf_display_color "$@"
run_probe avf_resource_loader_drain "$@"
run_probe avf_display_color_kvo "$@"
run_probe constant_packet_input "$@"
run_probe delay_mode_excess_input "$@"
run_probe optical_size "$@"
run_probe face_selection "$@"
run_probe font_provenance "$@"
run_probe font_data_descriptors "$@"
run_probe font_collections "$@"
run_probe h264_parameter_sets "$@"
run_probe encode_cadence "$@"
run_probe public_suffix "$@"
run_probe cookie_notifications "$@"
run_probe display_p3_profile "$@"
run_probe pq_profile "$@"
run_probe hdr_gainmap "$@"
run_probe cmyk_row_mask "$@"
run_probe colr_filled_paths "$@"
run_probe feature_clear "$@"
run_probe descriptor_options "$@"
run_probe sbix_bitmap_placement "$@"
run_probe typo_metrics "$@"
run_probe font_heights "$@"
run_probe variable_font_tables "$@"
run_probe feature_settings_order "$@"
run_probe variation_axes "$@"
run_probe variation_axes_from_data "$@"
run_probe path_glyph_range "$@"
run_probe sbix_sanitizer "$@"
run_probe aat_validators "$@"
run_probe aat_dispatch "$@"
run_probe audiounit_max_frames "$@"
run_probe character_clusters "$@"
run_probe cluster_fallback "$@"
run_probe logical_order "$@"
run_probe depth_sorting "$@"
run_probe frame_rate_range "$@"
run_probe shape_glyphs_context "$@"
run_probe css_family_language "$@"
run_probe clipped_glyphs "$@"
run_probe user_installed_matching "$@"
run_probe gpos_last_pair_set "$@"
run_probe control_character_glyphs "$@"

if [ "$SELECTED" -eq 0 ]; then
    echo "No behaviour tests matched: $*"
    exit 2
fi
echo "### behaviour summary: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
