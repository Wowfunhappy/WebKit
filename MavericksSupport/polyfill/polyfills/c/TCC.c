// TCC: entry points and constants modern WebKit references that 10.9's TCC (a private framework, so
// the provider is spelled as a path) does not export, or exports with behaviour that has to be
// replaced.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/message.h>
#include <mach/task_info.h>
#include <stdbool.h>
#include <string.h>

// --- TCC (Transparency, Consent and Control) service identifiers ---------
//
// Per-application camera and microphone gating arrived in macOS 10.14 and photo-library and cross-website-tracking gating later
// still, so 10.9's TCC exports none of those four identifiers. Its own set is thirteen:
// Accessibility, AddressBook, All, Calendar, Location, Reminders, Ubiquity and the six
// social-network ones (Facebook, LinkedIn, Liverpool, SinaWeibo, TencentWeibo, Twitter).
//
// A TCC identifier's value IS its own name on every macOS -- read off all thirteen of 10.9's on this
// host -- so these carry the same CFStrings the system framework would, and that same invariant is
// what lets mav_tccImplementsService below turn any service string back into the symbol name that
// would name it.
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/TCC.framework/TCC", CFStringRef, kTCCServiceCamera, CFSTR("kTCCServiceCamera"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/TCC.framework/TCC", CFStringRef, kTCCServiceMicrophone, CFSTR("kTCCServiceMicrophone"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/TCC.framework/TCC", CFStringRef, kTCCServicePhotos, CFSTR("kTCCServicePhotos"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/TCC.framework/TCC", CFStringRef, kTCCServiceWebKitIntelligentTrackingPrevention, CFSTR("kTCCServiceWebKitIntelligentTrackingPrevention"));

// TCCAccessPreflight and its audit-token spelling, whose value-is-their-own-name invariant is what the
// identifiers above answer by.
//
// 10.9 HAS TCCAccessPreflight, and it fails closed: handed a service it does not know it returns
// Denied (measured on this host). There is no per-app camera, microphone, photo-library or
// cross-website-tracking gating on 10.9 at all, so "denied" is not an answer the system ever meant
// to give for those: it is the absence of the question. UserMediaPermissionRequestManagerProxy
// compares against kTCCAccessPreflightGranted, so left alone this silently disables getUserMedia.
//
// What separates a service 10.9 gates from one it merely does not recognise is not a list kept here:
// 10.9's TCC implements exactly the services whose identifier constants it exports. So ask its
// export table, and answer Granted only where the question does not exist on this OS.

// Mirrors TCCAccessPreflightResult and its enumerators in <TCC/TCC.h>, as PAL's TCCSPI.h declares
// them for WebKit's side of the same call.
typedef int TCCAccessPreflightResult;
enum {
    kTCCAccessPreflightGranted = 0,
    kTCCAccessPreflightDenied = 1,
    kTCCAccessPreflightUnknown = 2,
};

// Does 10.9's TCC implement this service, i.e. does it export the service's identifier constant?
//
// No service is named here, and none is answered for from this file. A service identifier's VALUE is
// its own name (the invariant the constants above rest on, measured across all thirteen identifiers
// 10.9's TCC exports), so the string a caller hands in is also the symbol name that would name it in
// TCC's export table. Asking that table is the whole of the test, which is what makes the answer
// right for a service nobody here anticipated -- AddressBook, Calendar, Location, Reminders and
// Ubiquity are gated on 10.9 and reach TCC's own verdict by exactly the same route Camera and
// Microphone take to Granted.
//
// The lookup goes through wk_polyfill_system_symbol rather than dlsym on purpose: this layer answers
// dlsym for a polyfilled name with OUR storage, so that WebKit's soft-linking sees what the linker
// sees -- which would make every identifier this file polyfills look present. wk_polyfill_system_symbol
// reaches the real one.
//
// Which way an unrecognised string falls matters, so it falls the safe way: a string that cannot BE
// a symbol name is reported unimplemented (there is no gate, so the answer is Granted), while a
// string that happens to name some other TCC export is reported implemented and gets TCC's own
// verdict, which for a service it does not know is Denied. Only "no such export" can produce
// Granted, and that is exactly the case where 10.9 has no gate to consult.
static bool mav_tccImplementsService(CFStringRef service)
{
    if (!service)
        return false;

    // A symbol name is ASCII and fixed-length, so a conversion that fits and whose result is as long
    // as the string rules out both non-ASCII and an embedded NUL -- the latter would otherwise
    // truncate to a shorter name that may well exist.
    char name[128];
    if (!CFStringGetCString(service, name, sizeof name, kCFStringEncodingASCII))
        return false;
    if ((CFIndex)strlen(name) != CFStringGetLength(service))
        return false;
    for (const char *c = name; *c; c++) {
        bool identifierCharacter = (*c >= 'A' && *c <= 'Z') || (*c >= 'a' && *c <= 'z')
            || (*c >= '0' && *c <= '9') || *c == '_';
        if (!identifierCharacter)
            return false;
    }

    // The name is the caller's, so there is no fixed slot to cache it in and the lookup is made per
    // call. A preflight runs when something asks for a capability, not in a loop.
    void *cache = NULL;
    return wk_polyfill_system_symbol("/System/Library/PrivateFrameworks/TCC.framework/TCC",
                                     name, &cache) != NULL;
}

// This process's own audit token. Two tokens name the same process exactly when they are equal: a
// token carries auid, euid, egid, ruid, rgid, pid, session id and pid version, all fixed for the
// life of the process.
static bool mav_ownAuditToken(audit_token_t *out)
{
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    return task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)out, &count) == KERN_SUCCESS
        && count == TASK_AUDIT_TOKEN_COUNT;
}

WK_POLYFILL_REPLACES("/System/Library/PrivateFrameworks/TCC.framework/TCC", TCCAccessPreflightResult, TCCAccessPreflight,
                     (CFStringRef service, CFDictionaryRef options))
{
    if (mav_tccImplementsService(service) && WK_ORIGINAL(TCCAccessPreflight))
        return WK_ORIGINAL(TCCAccessPreflight)(service, options);
    // A capability this OS does not gate. The honest answer to "may I" where there is no gate is yes.
    return kTCCAccessPreflightGranted;
}

// The same question asked about another process, by audit token. 10.9's TCC predates this spelling
// and exports nothing for it, and TCCSoftLink.mm declares it with the non-optional
// SOFT_LINK_FUNCTION_FOR_SOURCE, whose initializer ends in RELEASE_ASSERT_WITH_MESSAGE(function,
// dlerror()) -- so without this the first call kills the process. That call is real and reachable:
// doesParentProcessHaveTrackingPreventionEnabled() (Shared/Cocoa/DefaultWebBrowserChecks.mm) asks it
// about the parent's audit token from inside a static initializer in every child process.
//
// Whether the token can change the answer depends on the service, so the token is consulted exactly
// where it matters:
//
//  * A service this OS does not gate has no gate for any process at all, so no token can change the
//    answer and it is Granted. Every service WebKit asks about is in this case.
//  * A service it does gate is gated PER BUNDLE -- 10.9 holds Accessibility and AddressBook grants in
//    the TCC database against the requesting application -- so the token does change the answer. When
//    it is this process's own token the question is literally the one TCCAccessPreflight above
//    answers, and it is forwarded there so the two spellings cannot disagree.
//  * For a gated service and somebody else's token, the answer is kTCCAccessPreflightUnknown: 10.9
//    cannot be asked. Its only by-token entry point is TCCAccessCheckAuditToken, the CHECK spelling,
//    which takes kTCCAccessCheckOptionPrompt and so may put a dialog in front of the user -- which a
//    preflight must never do -- and which answers a bare granted/not-granted that cannot carry the
//    undetermined state (measured on this host: TCCAccessPreflight answers Unknown for AddressBook,
//    Calendar, Location and Reminders, where the check answers not-granted). Unknown is a verdict
//    10.9's own TCCAccessPreflight returns, so it asks nothing of callers that they do not already
//    handle, and it is never mistaken for permission.
//
// The sibling TCCAccessCheckAuditToken needs nothing here: 10.9 does export it (dlsym on the TCC
// handle answers, and it returns the real per-process Accessibility verdict), and its argument
// layout matches the declaration in TCCSoftLink.h -- service in the first integer register, options
// in the second, the 32-byte audit token in memory either way.
WK_POLYFILL_ABSENT("/System/Library/PrivateFrameworks/TCC.framework/TCC", TCCAccessPreflightResult,
                   TCCAccessPreflightWithAuditToken,
                   (CFStringRef service, audit_token_t token, CFDictionaryRef options))
{
    if (!mav_tccImplementsService(service))
        return kTCCAccessPreflightGranted;
    audit_token_t self;
    if (mav_ownAuditToken(&self) && !memcmp(&self, &token, sizeof self))
        return TCCAccessPreflight(service, options);
    return kTCCAccessPreflightUnknown;
}
