/*
 * MAVERICKS_BACKPORT: WebFeature.h provides the WebFeatureStatus / WebFeatureCategory
 * enums that _WKFeature.h (the experimental/internal feature-flag API) exposes.
 * Upstream generates/ships this header; it was absent from this tree (referenced
 * via <WebKit/WebFeature.h> but never present). The enumerators are not
 * referenced by name anywhere in the build, so this declares the standard set
 * for the API surface only.
 */
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, WebFeatureStatus) {
    WebFeatureStatusEmbedder,
    WebFeatureStatusUnstable,
    WebFeatureStatusInternal,
    WebFeatureStatusDeveloper,
    WebFeatureStatusTestable,
    WebFeatureStatusPreview,
    WebFeatureStatusStable,
    WebFeatureStatusMature,
};

typedef NS_ENUM(NSInteger, WebFeatureCategory) {
    WebFeatureCategoryNone,
    WebFeatureCategoryAnimation,
    WebFeatureCategoryCSS,
    WebFeatureCategoryDOM,
    WebFeatureCategoryExtensions,
    WebFeatureCategoryHTML,
    WebFeatureCategoryJavascript,
    WebFeatureCategoryMedia,
    WebFeatureCategoryNetworking,
    WebFeatureCategoryPrivacy,
    WebFeatureCategorySecurity,
};
