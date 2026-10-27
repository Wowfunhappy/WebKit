/* What these headers need from an SDK and compiler older than the ones they are written for: the
   macros and types the macOS 10.9 and 10.10 SDKs lack, and WK_ macros for the syntax the compilers
   Xcode ships with those SDKs cannot parse. */
#ifndef WK_LEGACY_SDK_COMPATIBILITY
#define WK_LEGACY_SDK_COMPATIBILITY

#include <Availability.h>
#ifdef __OBJC__
#import <Foundation/NSObjCRuntime.h>
#endif

#if __has_feature(nullability)
#define WK_ASSUME_NONNULL_BEGIN _Pragma("clang assume_nonnull begin")
#define WK_ASSUME_NONNULL_END _Pragma("clang assume_nonnull end")
#define WK_NULLABLE nullable
#define WK_NONNULL nonnull
#define WK_NULL_UNSPECIFIED null_unspecified
#define WK_NULLABLE_PROPERTY nullable,
#define WK_NONNULL_PROPERTY nonnull,
#define WK_NULL_UNSPECIFIED_PROPERTY null_unspecified,
#define WK_NULL_RESETTABLE_PROPERTY null_resettable,
#else
#define _Nullable
#define _Nonnull
#define _Null_unspecified
#define WK_ASSUME_NONNULL_BEGIN
#define WK_ASSUME_NONNULL_END
#define WK_NULLABLE
#define WK_NONNULL
#define WK_NULL_UNSPECIFIED
#define WK_NULLABLE_PROPERTY
#define WK_NONNULL_PROPERTY
#define WK_NULL_UNSPECIFIED_PROPERTY
#define WK_NULL_RESETTABLE_PROPERTY
#endif

/* Foundation's collections take type arguments from the 10.11 SDK on. */
#if __has_feature(objc_generics) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 101100
#define WK_ARRAY(...) NSArray<__VA_ARGS__>
#define WK_DICTIONARY(...) NSDictionary<__VA_ARGS__>
#define WK_SET(...) NSSet<__VA_ARGS__>
#else
#define WK_ARRAY(...) NSArray
#define WK_DICTIONARY(...) NSDictionary
#define WK_SET(...) NSSet
#endif

/* The legacy API's availability, with the releases it names in the dotted form every clang reads. */
#define WK_MAC_VERSION_10_0 10.0
#define WK_MAC_VERSION_10_1 10.1
#define WK_MAC_VERSION_10_2 10.2
#define WK_MAC_VERSION_10_3 10.3
#define WK_MAC_VERSION_10_4 10.4
#define WK_MAC_VERSION_10_5 10.5
#define WK_MAC_VERSION_10_6 10.6
#define WK_MAC_VERSION_10_7 10.7
#define WK_MAC_VERSION_10_8 10.8
#define WK_MAC_VERSION_10_9 10.9
#define WK_MAC_VERSION_10_10 10.10
#define WK_MAC_VERSION_10_11 10.11
#define WK_MAC_VERSION_10_12 10.12
#define WK_MAC_VERSION_10_13 10.13
#define WK_MAC_VERSION_10_14 10.14
#define WK_MAC_VERSION_10_15 10.15
#define WK_DEPRECATED_MAC(_introduced, _deprecated, ...) __attribute__((availability(macosx, introduced=WK_MAC_VERSION_##_introduced, deprecated=WK_MAC_VERSION_##_deprecated, message="" __VA_ARGS__)))
#define WK_ENUM_DEPRECATED_MAC(...) WK_DEPRECATED_MAC(__VA_ARGS__)
#define WK_CLASS_DEPRECATED_MAC(...) __attribute__((visibility("default"))) WK_DEPRECATED_MAC(__VA_ARGS__)

#ifdef __OBJC__

#ifndef NS_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_BEGIN WK_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_END WK_ASSUME_NONNULL_END
#endif
#ifndef NS_HEADER_AUDIT_BEGIN
#define NS_HEADER_AUDIT_BEGIN(...) NS_ASSUME_NONNULL_BEGIN
#define NS_HEADER_AUDIT_END(...) NS_ASSUME_NONNULL_END
#endif
#ifndef NS_DESIGNATED_INITIALIZER
#if __has_attribute(objc_designated_initializer)
#define NS_DESIGNATED_INITIALIZER __attribute__((objc_designated_initializer))
#else
#define NS_DESIGNATED_INITIALIZER
#endif
#endif
#ifndef NS_UNAVAILABLE
#define NS_UNAVAILABLE __attribute__((unavailable))
#endif
#ifndef NS_ERROR_ENUM
#define NS_ERROR_ENUM(_domain, _name) NS_ENUM(NSInteger, _name)
#endif
#ifndef NS_TYPED_ENUM
#define NS_TYPED_ENUM
#endif
#ifndef NS_TYPED_EXTENSIBLE_ENUM
#define NS_TYPED_EXTENSIBLE_ENUM
#endif
#ifndef NS_SWIFT_NAME
#define NS_SWIFT_NAME(_name)
#endif
#ifndef NS_REFINED_FOR_SWIFT
#define NS_REFINED_FOR_SWIFT
#endif
#ifndef NS_SWIFT_NONISOLATED
#define NS_SWIFT_NONISOLATED
#endif
#ifndef NS_SWIFT_SENDABLE
#define NS_SWIFT_SENDABLE
#endif
#ifndef NS_SWIFT_UI_ACTOR
#define NS_SWIFT_UI_ACTOR
#endif
#ifndef NS_SWIFT_ASYNC
#define NS_SWIFT_ASYNC(...)
#endif
#ifndef NS_SWIFT_ASYNC_NAME
#define NS_SWIFT_ASYNC_NAME(...)
#endif
#ifndef NS_SWIFT_ASYNC_THROWS_ON_FALSE
#define NS_SWIFT_ASYNC_THROWS_ON_FALSE(...)
#endif
#ifndef API_AVAILABLE
#define API_AVAILABLE(...)
#endif
#ifndef API_UNAVAILABLE
#define API_UNAVAILABLE(...)
#endif
#ifndef API_DEPRECATED
#define API_DEPRECATED(...)
#endif
#ifndef API_DEPRECATED_WITH_REPLACEMENT
#define API_DEPRECATED_WITH_REPLACEMENT(...)
#endif

@class NSString;
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101000
typedef NSUInteger NSEventModifierFlags;
#endif
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101100
#import <Foundation/NSProgress.h>
@protocol NSProgressReporting <NSObject>
@property (readonly) NSProgress *progress;
@end
#endif
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101200
typedef NSString *NSErrorDomain;
typedef NSString *NSNotificationName;
#endif
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101300
typedef NSString *NSAttributedStringDocumentAttributeKey;
typedef NSString *NSAttributedStringDocumentReadingOptionKey;
#endif

#endif /* __OBJC__ */

#endif /* WK_LEGACY_SDK_COMPATIBILITY */
