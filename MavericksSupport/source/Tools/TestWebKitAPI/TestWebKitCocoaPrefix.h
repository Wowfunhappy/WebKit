/*
 * Prefix header for TestWebKitCocoa, the Cocoa (WKWebView) half of TestWebKitAPI.
 *
 * Upstream compiles Tests/WebKitCocoa only from Xcode, whose TestWebKitAPI target prefixes every
 * source with TestWebKitAPIPrefix.h and reaches the Objective-C API umbrella through config.h's Xcode
 * branch. config.h's CMake branch has no case for this target, so the umbrella and the export macros
 * arrive here instead.
 */

#pragma once

#import "config.h"

#include <JavaScriptCore/JSExportMacros.h>
#include <WebCore/PlatformExportMacros.h>
#include <pal/ExportMacros.h>
#include <WebKit/WebKit2_C.h>

#if defined(__OBJC__)
#import <WebKit/WebKit.h>
#endif

#import "TestWebKitAPIPrefix.h"
