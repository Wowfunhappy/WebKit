// The linked-on-or-after gates for the SDK-aligned behaviors that RuntimeApplicationChecksCocoa.mm leaves to Apple's
// internal additions. Each behavior is gated at an SDK released after it was introduced. An app's Info.plist can then
// turn individual behaviors on or off (AquaWebKitSupport/docs/SDK-ALIGNED-BEHAVIORS.md).

// Every behavior, in enum order.
static constexpr std::pair<ASCIILiteral, SDKAlignedBehavior> sdkAlignedBehaviorNames[] = {
    { "AllowsWheelEventGesturesToBecomeNonBlocking"_s, SDKAlignedBehavior::AllowsWheelEventGesturesToBecomeNonBlocking },
    { "ApplicationStateTrackerDoesNotObserveWindow"_s, SDKAlignedBehavior::ApplicationStateTrackerDoesNotObserveWindow },
    { "AuthorizationHeaderOnSameOriginRedirects"_s, SDKAlignedBehavior::AuthorizationHeaderOnSameOriginRedirects },
    { "BlanksViewOnJSPrompt"_s, SDKAlignedBehavior::BlanksViewOnJSPrompt },
    { "BlocksConnectionsToAddressWithOnlyZeros"_s, SDKAlignedBehavior::BlocksConnectionsToAddressWithOnlyZeros },
    { "BrowsingContextControllerMethodStubRemoved"_s, SDKAlignedBehavior::BrowsingContextControllerMethodStubRemoved },
    { "ContextMenuTriggersLinkActivationNavigationType"_s, SDKAlignedBehavior::ContextMenuTriggersLinkActivationNavigationType },
    { "ConvertsInvalidURLsToBlank"_s, SDKAlignedBehavior::ConvertsInvalidURLsToBlank },
    { "ConvertsInvalidURLsToNull"_s, SDKAlignedBehavior::ConvertsInvalidURLsToNull },
    { "DataURLFragmentRemoval"_s, SDKAlignedBehavior::DataURLFragmentRemoval },
    { "DecidesPolicyBeforeLoadingQuickLookPreview"_s, SDKAlignedBehavior::DecidesPolicyBeforeLoadingQuickLookPreview },
    { "DefaultsToExcludingBackgroundsWhenPrinting"_s, SDKAlignedBehavior::DefaultsToExcludingBackgroundsWhenPrinting },
    { "DefaultsToPassiveTouchListenersOnDocument"_s, SDKAlignedBehavior::DefaultsToPassiveTouchListenersOnDocument },
    { "DefaultsToPassiveWheelListenersOnDocument"_s, SDKAlignedBehavior::DefaultsToPassiveWheelListenersOnDocument },
    { "DoesNotDrainTheMicrotaskQueueWhenCallingObjC"_s, SDKAlignedBehavior::DoesNotDrainTheMicrotaskQueueWhenCallingObjC },
    { "DoesNotParseStringEndingWithFullStopAsFloatingPointNumber"_s, SDKAlignedBehavior::DoesNotParseStringEndingWithFullStopAsFloatingPointNumber },
    { "DoesNotAddIntrinsicMarginsToFormControls"_s, SDKAlignedBehavior::DoesNotAddIntrinsicMarginsToFormControls },
    { "DOMWindowReuseRestriction"_s, SDKAlignedBehavior::DOMWindowReuseRestriction },
    { "DownloadDelegatesCalledOnTheMainThread"_s, SDKAlignedBehavior::DownloadDelegatesCalledOnTheMainThread },
    { "DropToNavigateDisallowedByDefault"_s, SDKAlignedBehavior::DropToNavigateDisallowedByDefault },
    { "ExceptionsForDuplicateCompletionHandlerCalls"_s, SDKAlignedBehavior::ExceptionsForDuplicateCompletionHandlerCalls },
    { "ExceptionsForRelatedWebViewsUsingDifferentDataStores"_s, SDKAlignedBehavior::ExceptionsForRelatedWebViewsUsingDifferentDataStores },
    { "ExpiredOnlyReloadBehavior"_s, SDKAlignedBehavior::ExpiredOnlyReloadBehavior },
    { "ForbidsDotPrefixedFonts"_s, SDKAlignedBehavior::ForbidsDotPrefixedFonts },
    { "FullySuspendsBackgroundContent"_s, SDKAlignedBehavior::FullySuspendsBackgroundContent },
    { "FullySuspendsBackgroundContentImmediately"_s, SDKAlignedBehavior::FullySuspendsBackgroundContentImmediately },
    { "HasUIContextMenuInteraction"_s, SDKAlignedBehavior::HasUIContextMenuInteraction },
    { "HTMLDocumentSupportedPropertyNames"_s, SDKAlignedBehavior::HTMLDocumentSupportedPropertyNames },
    { "InitializeWebKit2MainThreadAssertion"_s, SDKAlignedBehavior::InitializeWebKit2MainThreadAssertion },
    { "InspectableDefaultsToDisabled"_s, SDKAlignedBehavior::InspectableDefaultsToDisabled },
    { "JavaScriptEvaluationResultWithoutSerializedScriptValue"_s, SDKAlignedBehavior::JavaScriptEvaluationResultWithoutSerializedScriptValue },
    { "LazyGestureRecognizerInstallation"_s, SDKAlignedBehavior::LazyGestureRecognizerInstallation },
    { "LinkPreviewEnabledByDefault"_s, SDKAlignedBehavior::LinkPreviewEnabledByDefault },
    { "MainThreadReleaseAssertionInWebPageProxy"_s, SDKAlignedBehavior::MainThreadReleaseAssertionInWebPageProxy },
    { "MediaTypesRequiringUserActionForPlayback"_s, SDKAlignedBehavior::MediaTypesRequiringUserActionForPlayback },
    { "MinimizesLanguages"_s, SDKAlignedBehavior::MinimizesLanguages },
    { "ModernCompabilityModeByDefault"_s, SDKAlignedBehavior::ModernCompabilityModeByDefault },
    { "MutationEventsDisabledByDefault"_s, SDKAlignedBehavior::MutationEventsDisabledByDefault },
    { "NavigationActionSourceFrameNonNull"_s, SDKAlignedBehavior::NavigationActionSourceFrameNonNull },
    { "NoClientCertificateLookup"_s, SDKAlignedBehavior::NoClientCertificateLookup },
    { "NoExpandoIndexedPropertiesOnWindow"_s, SDKAlignedBehavior::NoExpandoIndexedPropertiesOnWindow },
    { "NoPokerBrosBuiltInTagQuirk"_s, SDKAlignedBehavior::NoPokerBrosBuiltInTagQuirk },
    { "NoShowModalDialog"_s, SDKAlignedBehavior::NoShowModalDialog },
    { "NoTypedArrayAPIQuirk"_s, SDKAlignedBehavior::NoTypedArrayAPIQuirk },
    { "NoUnconditionalUniversalSandboxExtension"_s, SDKAlignedBehavior::NoUnconditionalUniversalSandboxExtension },
    { "NoUNIQLOLazyIframeLoadingQuirk"_s, SDKAlignedBehavior::NoUNIQLOLazyIframeLoadingQuirk },
    { "NullOriginForNonSpecialSchemedURLs"_s, SDKAlignedBehavior::NullOriginForNonSpecialSchemedURLs },
    { "ObservesClassProperty"_s, SDKAlignedBehavior::ObservesClassProperty },
    { "PictureInPictureMediaPlayback"_s, SDKAlignedBehavior::PictureInPictureMediaPlayback },
    { "PushStateFilePathRestriction"_s, SDKAlignedBehavior::PushStateFilePathRestriction },
    { "RequiresUserGestureToLoadVideo"_s, SDKAlignedBehavior::RequiresUserGestureToLoadVideo },
    { "RestrictsBaseURLSchemes"_s, SDKAlignedBehavior::RestrictsBaseURLSchemes },
    { "RunningBoardThrottling"_s, SDKAlignedBehavior::RunningBoardThrottling },
    { "ScrollViewContentInsetsAreNotObscuringInsets"_s, SDKAlignedBehavior::ScrollViewContentInsetsAreNotObscuringInsets },
    { "SendsNativeMouseEvents"_s, SDKAlignedBehavior::SendsNativeMouseEvents },
    { "SessionCleanupByDefault"_s, SDKAlignedBehavior::SessionCleanupByDefault },
    { "SiteSpecificQuirksAreEnabledByDefault"_s, SDKAlignedBehavior::SiteSpecificQuirksAreEnabledByDefault },
    { "SnapshotAfterScreenUpdates"_s, SDKAlignedBehavior::SnapshotAfterScreenUpdates },
    { "SupportsDeviceOrientationAndMotionPermissionAPI"_s, SDKAlignedBehavior::SupportsDeviceOrientationAndMotionPermissionAPI },
    { "SupportsInitConstructors"_s, SDKAlignedBehavior::SupportsInitConstructors },
    { "TimerThreadSafetyChecks"_s, SDKAlignedBehavior::TimerThreadSafetyChecks },
    { "UIScrollViewDoesNotApplyKeyboardInsetsUnconditionally"_s, SDKAlignedBehavior::UIScrollViewDoesNotApplyKeyboardInsetsUnconditionally },
    { "UnprefixedPlaysInlineAttribute"_s, SDKAlignedBehavior::UnprefixedPlaysInlineAttribute },
    { "WebIconDatabaseWarning"_s, SDKAlignedBehavior::WebIconDatabaseWarning },
    { "WebSQLDisabledByDefaultInLegacyWebKit"_s, SDKAlignedBehavior::WebSQLDisabledByDefaultInLegacyWebKit },
    { "WKWebsiteDataStoreInitReturningNil"_s, SDKAlignedBehavior::WKWebsiteDataStoreInitReturningNil },
    { "UIBackForwardSkipsHistoryItemsWithoutUserGesture"_s, SDKAlignedBehavior::UIBackForwardSkipsHistoryItemsWithoutUserGesture },
    { "ProgrammaticFocusDuringUserScriptShowsInputViews"_s, SDKAlignedBehavior::ProgrammaticFocusDuringUserScriptShowsInputViews },
    { "ScreenOrientationAPIEnabled"_s, SDKAlignedBehavior::ScreenOrientationAPIEnabled },
    { "PopoverAttributeEnabled"_s, SDKAlignedBehavior::PopoverAttributeEnabled },
    { "DoesNotOverrideUAFromNSUserDefault"_s, SDKAlignedBehavior::DoesNotOverrideUAFromNSUserDefault },
    { "EvaluateJavaScriptWithoutTransientActivation"_s, SDKAlignedBehavior::EvaluateJavaScriptWithoutTransientActivation },
    { "ResettingTransitionCancelsRunningTransitionQuirk"_s, SDKAlignedBehavior::ResettingTransitionCancelsRunningTransitionQuirk },
    { "OnlyLoadWellKnownAboutURLs"_s, SDKAlignedBehavior::OnlyLoadWellKnownAboutURLs },
    { "AsyncFragmentNavigationPolicyDecision"_s, SDKAlignedBehavior::AsyncFragmentNavigationPolicyDecision },
    { "DoNotLoadStyleSheetIfHTTPStatusIsNotOK"_s, SDKAlignedBehavior::DoNotLoadStyleSheetIfHTTPStatusIsNotOK },
    { "ScrollViewSubclassImplementsAddGestureRecognizer"_s, SDKAlignedBehavior::ScrollViewSubclassImplementsAddGestureRecognizer },
    { "ThrowIfCanDeclareGlobalFunctionFails"_s, SDKAlignedBehavior::ThrowIfCanDeclareGlobalFunctionFails },
    { "ThrowOnKVCInstanceVariableAccess"_s, SDKAlignedBehavior::ThrowOnKVCInstanceVariableAccess },
    { "LaxCookieSameSiteAttribute"_s, SDKAlignedBehavior::LaxCookieSameSiteAttribute },
    { "UseCFNetworkNetworkLoader"_s, SDKAlignedBehavior::UseCFNetworkNetworkLoader },
    { "AutoLayoutInWKWebView"_s, SDKAlignedBehavior::AutoLayoutInWKWebView },
    { "BlockCrossOriginRedirectDownloads"_s, SDKAlignedBehavior::BlockCrossOriginRedirectDownloads },
    { "BlobFileAccessEnforcementAndNetworkProcessRoundTrip"_s, SDKAlignedBehavior::BlobFileAccessEnforcementAndNetworkProcessRoundTrip },
    { "DevolvableWidgets"_s, SDKAlignedBehavior::DevolvableWidgets },
    { "SetSelectionRangeCachesSelectionIfNotFocusedOrSelected"_s, SDKAlignedBehavior::SetSelectionRangeCachesSelectionIfNotFocusedOrSelected },
    { "DispatchFocusEventBeforeNotifyingClient"_s, SDKAlignedBehavior::DispatchFocusEventBeforeNotifyingClient },
    { "EnableTrustedTypesByDefault"_s, SDKAlignedBehavior::EnableTrustedTypesByDefault },
    { "BlobFileAccessEnforcement"_s, SDKAlignedBehavior::BlobFileAccessEnforcement },
    { "SupportGameControllerEventInteractionAPI"_s, SDKAlignedBehavior::SupportGameControllerEventInteractionAPI },
    { "DidFailProvisionalNavigationWithErrorForFileURLNavigation"_s, SDKAlignedBehavior::DidFailProvisionalNavigationWithErrorForFileURLNavigation },
    { "CrashWhenPreconnectingFromBackgroundThread"_s, SDKAlignedBehavior::CrashWhenPreconnectingFromBackgroundThread },
    { "ExecutionTimingChangeOfModuleScripts"_s, SDKAlignedBehavior::ExecutionTimingChangeOfModuleScripts },
    { "GetBoundingClientRectZoomed"_s, SDKAlignedBehavior::GetBoundingClientRectZoomed },
    { "CrashWhenMutatingProcessAssertionsFromBackgroundThread"_s, SDKAlignedBehavior::CrashWhenMutatingProcessAssertionsFromBackgroundThread },
    { "NoFontFaceSetConstructor"_s, SDKAlignedBehavior::NoFontFaceSetConstructor },
    { "NoHTMLEnhancedSelectParsingQuirk"_s, SDKAlignedBehavior::NoHTMLEnhancedSelectParsingQuirk },
    { "DataURLForPastedImages"_s, SDKAlignedBehavior::DataURLForPastedImages },
    { "SuppressKeypressForModifierShortcuts"_s, SDKAlignedBehavior::SuppressKeypressForModifierShortcuts },
    { "ScrollColorExtensionGrowsDuringRubberBanding"_s, SDKAlignedBehavior::ScrollColorExtensionGrowsDuringRubberBanding },
    { "ManagedRefreshControlAppearance"_s, SDKAlignedBehavior::ManagedRefreshControlAppearance },
    { "EnableUserScriptAndUserStyleInterning"_s, SDKAlignedBehavior::EnableUserScriptAndUserStyleInterning },
    { "AllBackForwardItemsWithoutUserGestureInvisibleToUI"_s, SDKAlignedBehavior::AllBackForwardItemsWithoutUserGestureInvisibleToUI },
    { "ExposePartitionFromWKHTTPCookieStoreAPI"_s, SDKAlignedBehavior::ExposePartitionFromWKHTTPCookieStoreAPI },
    { "MediaSessionPauseOnInterruption"_s, SDKAlignedBehavior::MediaSessionPauseOnInterruption },
    { "ScrollPocketInFullscreen"_s, SDKAlignedBehavior::ScrollPocketInFullscreen },
    { "IgnorePageLocationDuringHardPocketEligibilityCheck"_s, SDKAlignedBehavior::IgnorePageLocationDuringHardPocketEligibilityCheck },
    { "AdjustColorExtensionsForHorizontalBannerViewOverlays"_s, SDKAlignedBehavior::AdjustColorExtensionsForHorizontalBannerViewOverlays },
    { "NetworkProcessInheritsNetworkAccessFromUIProcess"_s, SDKAlignedBehavior::NetworkProcessInheritsNetworkAccessFromUIProcess },
    { "BoxPackAccountsForBoxDirection"_s, SDKAlignedBehavior::BoxPackAccountsForBoxDirection },
    { "BlockOrUpgradeMixedContent"_s, SDKAlignedBehavior::BlockOrUpgradeMixedContent },
    { "EmbedAttributeChangeReconstructsRenderers"_s, SDKAlignedBehavior::EmbedAttributeChangeReconstructsRenderers },
    { "KeepEditableSelectionOnMouseFocus"_s, SDKAlignedBehavior::KeepEditableSelectionOnMouseFocus },
};

static consteval bool sdkAlignedBehaviorNamesMatchEnum()
{
    if (std::size(sdkAlignedBehaviorNames) != static_cast<size_t>(SDKAlignedBehavior::NumberOfBehaviors))
        return false;
    for (size_t i = 0; i < std::size(sdkAlignedBehaviorNames); ++i) {
        if (static_cast<size_t>(sdkAlignedBehaviorNames[i].second) != i)
            return false;
    }
    return true;
}
static_assert(sdkAlignedBehaviorNamesMatchEnum(), "sdkAlignedBehaviorNames must list every SDKAlignedBehavior in enum order");

// Info.plist key AquaWebKitSDKAlignedBehaviors: a dictionary from behavior name to a Boolean.
static void applyInfoPlistSDKAlignedBehaviors(SDKAlignedBehaviors& behaviors)
{
    id overrides = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"AquaWebKitSDKAlignedBehaviors"];
    if (!overrides)
        return;
    if (![overrides isKindOfClass:NSDictionary.class]) {
        WTFLogAlways("AquaWebKitSDKAlignedBehaviors: Info.plist value is not a dictionary; ignored");
        return;
    }
    for (NSString *name in overrides) {
        id value = [overrides objectForKey:name];
        if (![name isKindOfClass:NSString.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
            WTFLogAlways("AquaWebKitSDKAlignedBehaviors: entry %@ is not a name with a Boolean; ignored", name);
            continue;
        }
        auto entry = std::ranges::find_if(sdkAlignedBehaviorNames, [&](auto& pair) {
            return String(name) == pair.first;
        });
        if (entry == std::end(sdkAlignedBehaviorNames)) {
            WTFLogAlways("AquaWebKitSDKAlignedBehaviors: unknown behavior %@; ignored", name);
            continue;
        }
        auto index = static_cast<size_t>(entry->second);
        if ([value boolValue])
            behaviors.set(index);
        else
            behaviors.clear(index);
    }
}

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

    applyInfoPlistSDKAlignedBehaviors(behaviors);
}
