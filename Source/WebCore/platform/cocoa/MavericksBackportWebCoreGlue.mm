/*
 * MAVERICKS_BACKPORT build glue.
 *
 * WebCore must not ship any UNDEFINED WebCore:: symbol. Safari tolerates a few (two-level namespace +
 * lazy binding never resolves a symbol it never calls), but a WebKit plug-in that is dlopen'd with
 * eager / flat-namespace binding — e.g. Apple Mail's WebContent injected bundle MailUIWebBundle, or
 * Spotlight's Mail.mdimporter — forces every WebCore symbol to resolve at load time, and a single
 * unresolved one aborts the load. When MailUIWebBundle fails to load, Mail's message body never gets
 * processed/revealed and renders blank. (#137)
 *
 * This file provides faithful definitions for the WebCore symbols whose normal implementation TU is
 * excluded from the 10.9 build:
 *   - WebCore::isRegexpMatching: the real impl (ServiceWorkerRoute.mm) needs PALSwift (Swift), which
 *     this toolchain can't build. Reimplemented with NSRegularExpression (also ICU-backed, same
 *     semantics) so service-worker URLPattern regex routing keeps working.
 *   - MockAudioCaptureUnit / MockRealtimeVideoSourceMac mock-capture entry points: the Cocoa
 *     mock-capture backend (MockAudioCaptureUnit.mm / MockRealtimeVideoSourceMac.mm) is excluded
 *     because USE(GSTREAMER_MEDIA_STREAM) is the real capture backend and those TUs would duplicate
 *     MockRealtimeVideoSource::create / MockRealtimeAudioSource::create. MockRealtimeMediaSourceCenter
 *     still references the Cocoa mock symbols under PLATFORM(COCOA); these are only reachable via the
 *     test-only setMockCaptureDevicesEnabled() path (never used by Mail/Safari in production), so the
 *     audio hooks are no-ops and the Cocoa mock display-capturer is unreachable on this backend.
 *     (Proper fix belongs to #96: align the PLATFORM(COCOA) reference guards with the capture backend.)
 */

#include "config.h"

#import <Foundation/Foundation.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>
#import <wtf/text/StringView.h>

#import "ServiceWorkerRoute.h"

namespace WebCore {

bool isRegexpMatching(const String& pattern, StringView value, bool shouldIgnoreCase)
{
    if (pattern.isNull())
        return false;

    NSRegularExpressionOptions options = shouldIgnoreCase ? NSRegularExpressionCaseInsensitive : 0;
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern.createNSString().get() options:options error:&error];
    if (!regex || error)
        return false;

    RetainPtr<NSString> string = value.toString().createNSString();
    NSRange fullRange = NSMakeRange(0, [string length]);
    NSRange matchRange = [regex rangeOfFirstMatchInString:string.get() options:0 range:fullRange];
    // URLPattern component matching is a whole-string match.
    return matchRange.location == 0 && matchRange.length == fullRange.length;
}

} // namespace WebCore

#if ENABLE(MEDIA_STREAM)

#import "MockAudioCaptureUnit.h"
#import "MockRealtimeVideoSourceMac.h"

namespace WebCore {

void MockAudioCaptureUnit::enable()
{
}

void MockAudioCaptureUnit::disable()
{
}

void MockAudioCaptureUnit::increaseBufferSize()
{
}

Ref<MockRealtimeVideoSource> MockRealtimeVideoSourceMac::createForMockDisplayCapturer(String&&, AtomString&&, MediaDeviceHashSalts&&, std::optional<PageIdentifier>)
{
    // Cocoa mock display capture is not the active capture backend on this port (GStreamer is) and is
    // only reachable from the test-only mock-capture path. Never invoked in production.
    RELEASE_ASSERT_NOT_REACHED();
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
