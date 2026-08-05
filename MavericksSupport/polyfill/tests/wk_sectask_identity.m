// The SecTaskCopySigningIdentifier / SecTaskGetCodeSignStatus polyfills (polyfills/system-spi.m):
// 10.9 has neither, and WebKit uses them to answer "who is on the other end of this connection?" --
// Shared/Cocoa/CodeSigning.mm, and through it PushClientConnection::create(), which REJECTS a client
// whose identifier comes back empty. A stub returning NULL there is not a degraded answer, it is
// webpushd refusing every connection and the client reconnecting forever.
//
// So this probe demands a real identifier for a real process, obtained the way WebKit obtains it:
// SecTaskCreateWithAuditToken on the target's audit token, then SecTaskCopySigningIdentifier. It
// fails if the answer is NULL, empty, or not the identifier the process actually has.
//
// It uses launchd (pid 1, "com.apple.launchd") as the subject: always running, never restarted, and
// its signing identifier is fixed, so the expected value needs no discovery step that could itself
// be wrong.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <bsm/libbsm.h>
#import <stdio.h>

extern int csops(pid_t, unsigned int ops, void *useraddr, size_t usersize);

// The 26.1 SDK marks this __API_UNAVAILABLE(macos); re-declare it as available so the probe can
// call the polyfill, exactly as polyfills/system-spi.m has to.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
__attribute__((availability(macos, introduced=10.0))) uint32_t SecTaskGetCodeSignStatus(SecTaskRef);
#pragma clang diagnostic pop

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

// WebKit only ever has an audit token; build one naming a pid the way the kernel does.
static audit_token_t auditTokenForPid(pid_t pid)
{
    audit_token_t token;
    memset(&token, 0, sizeof(token));
    token.val[5] = (unsigned int)pid; // audit_token_to_pid() reads val[5]
    return token;
}

static NSString *signingIdentifierForPid(pid_t pid)
{
    SecTaskRef task = SecTaskCreateWithAuditToken(kCFAllocatorDefault, auditTokenForPid(pid));
    if (!task)
        return nil;
    CFStringRef identifier = SecTaskCopySigningIdentifier(task, NULL);
    CFRelease(task);
    return identifier ? [(NSString *)identifier autorelease] : nil;
}

int main(void)
{
    @autoreleasepool {
        // The polyfill recovers the pid a SecTaskRef names by calibrating against synthetic tokens.
        // If that ever stops working every check below fails, which is the point.
        NSString *launchd = signingIdentifierForPid(1);
        printf("  pid 1 -> %s\n", launchd ? [launchd UTF8String] : "(NULL)");
        check(launchd != nil, "SecTaskCopySigningIdentifier returns an identifier, not NULL");
        check([launchd isEqualToString:@"com.apple.launchd"], "the identifier is the one the process actually has");

        // Self, through the same path WebKit uses for its own identity.
        SecTaskRef self = SecTaskCreateFromSelf(kCFAllocatorDefault);
        CFStringRef selfIdentifier = self ? SecTaskCopySigningIdentifier(self, NULL) : NULL;
        printf("  self  -> %s\n", selfIdentifier ? [(NSString *)selfIdentifier UTF8String] : "(NULL)");
        // An unsigned probe binary legitimately has no identifier; only require that asking is safe
        // and that a signed target (above) answers. Crashing or hanging here would be the failure.
        check(true, "SecTaskCreateFromSelf path does not fault");
        if (selfIdentifier)
            CFRelease(selfIdentifier);
        if (self)
            CFRelease(self);

        // SecTaskGetCodeSignStatus must report the kernel's real flags. Compare against csops
        // directly so a stubbed zero cannot pass.
        uint32_t expected = 0;
        bool haveExpected = !csops(1, 0 /* CS_OPS_STATUS */, &expected, sizeof(expected));
        SecTaskRef launchdTask = SecTaskCreateWithAuditToken(kCFAllocatorDefault, auditTokenForPid(1));
        uint32_t reported = launchdTask ? SecTaskGetCodeSignStatus(launchdTask) : 0;
        if (launchdTask)
            CFRelease(launchdTask);
        printf("  pid 1 code sign status: reported 0x%08x, kernel 0x%08x\n", reported, expected);
        check(haveExpected && reported == expected, "SecTaskGetCodeSignStatus matches the kernel");
        check(reported != 0, "the status is a real value, not a stubbed zero");

        if (failures) {
            printf("wk_sectask_identity: %d check(s) FAILED\n", failures);
            return 1;
        }
        printf("wk_sectask_identity: all checks passed\n");
    }
    return 0;
}
