// The linked-on-or-after gates for the SDK-aligned behaviors that RuntimeApplicationChecksCocoa.mm leaves to Apple's
// internal additions. Each behavior is gated at an SDK released after it was introduced.

static void disableAdditionalSDKAlignedBehaviors(SDKAlignedBehaviors& behaviors)
{
    auto disableBehaviors = [&](std::initializer_list<SDKAlignedBehavior> list) {
        for (auto behavior : list)
            behaviors.clear(static_cast<size_t>(behavior));
    };

    if (linkedBefore(dyld_2025_SU_B_os_versions, DYLD_IOS_VERSION_26_1, DYLD_MACOSX_VERSION_26_1)) {
        disableBehaviors({
            SDKAlignedBehavior::ConvertsInvalidURLsToNull,
            SDKAlignedBehavior::MutationEventsDisabledByDefault,
            SDKAlignedBehavior::EnableTrustedTypesByDefault,
            SDKAlignedBehavior::BrowsingContextControllerMethodStubRemoved,
            SDKAlignedBehavior::AutoLayoutInWKWebView,
            SDKAlignedBehavior::DidFailProvisionalNavigationWithErrorForFileURLNavigation,
            SDKAlignedBehavior::CrashWhenPreconnectingFromBackgroundThread,
            SDKAlignedBehavior::ExecutionTimingChangeOfModuleScripts,
            SDKAlignedBehavior::JavaScriptEvaluationResultWithoutSerializedScriptValue,
            SDKAlignedBehavior::CrashWhenMutatingProcessAssertionsFromBackgroundThread,
        });
    }

    if (linkedBefore(dyld_fall_2026_os_versions, DYLD_IOS_VERSION_27_0, DYLD_MACOSX_VERSION_27_0)) {
        disableBehaviors({
            SDKAlignedBehavior::NoFontFaceSetConstructor,
            SDKAlignedBehavior::NoHTMLEnhancedSelectParsingQuirk,
            SDKAlignedBehavior::DataURLForPastedImages,
            SDKAlignedBehavior::SuppressKeypressForModifierShortcuts,
            SDKAlignedBehavior::ScrollColorExtensionGrowsDuringRubberBanding,
            SDKAlignedBehavior::ManagedRefreshControlAppearance,
            SDKAlignedBehavior::AllBackForwardItemsWithoutUserGestureInvisibleToUI,
            SDKAlignedBehavior::ExposePartitionFromWKHTTPCookieStoreAPI,
            SDKAlignedBehavior::MediaSessionPauseOnInterruption,
            SDKAlignedBehavior::AdjustColorExtensionsForHorizontalBannerViewOverlays,
        });
    }
}
