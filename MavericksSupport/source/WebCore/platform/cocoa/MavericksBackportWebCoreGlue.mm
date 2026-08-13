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
 */

#include "config.h"

#import <Foundation/Foundation.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>
#import <wtf/text/StringView.h>

#import "ServiceWorkerRoute.h"
// MAVERICKS_BACKPORT (#137): GPUCanvasContext::create() for Cocoa. WebGPU is off on this port
// (ENABLE_WEBGPU / GPU_PROCESS off), so html/canvas/GPUCanvasContextCocoa.mm — the WebGPU backend that
// normally defines this — is withheld from the build and kept byte-upstream. GPUCanvasContext.cpp only
// defines create() for !PLATFORM(COCOA), so without this the symbol is undefined: Safari binds it lazily
// and never notices, but a flat-namespace/eager dlopen of a WebKit plug-in (Mail's MailUIWebBundle,
// Spotlight's Mail.mdimporter) fails to load and renders blank. Same nullptr the non-Cocoa fallback returns.
#import "GPUCanvasContext.h"

namespace WebCore {

std::unique_ptr<GPUCanvasContext> GPUCanvasContext::create(CanvasBase&, GPU&, Document*)
{
    return nullptr;
}

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
