// CoreUI: constants modern WebKit references that 10.9's CoreUI (a private framework, so the provider
// is spelled as a path) does not export. Each value is its own name: a token 10.9 never interprets.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>

WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchBorder, CFSTR("kCUIWidgetSwitchBorder"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchFill, CFSTR("kCUIWidgetSwitchFill"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchFillMask, CFSTR("kCUIWidgetSwitchFillMask"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchKnob, CFSTR("kCUIWidgetSwitchKnob"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchOnOffLabel, CFSTR("kCUIWidgetSwitchOnOffLabel"));
