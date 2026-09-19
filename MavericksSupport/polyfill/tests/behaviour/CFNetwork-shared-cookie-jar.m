// The account-wide cookie jar, which is shared storage rather than per-process state.
//
// +[NSHTTPCookieStorage sharedHTTPCookieStorage] is backed by cookied, so every CFNetwork client on the
// machine reads and writes the one jar: what the NetworkProcess stores, WebKitLegacy inside the browser's
// own process and the browser itself see too. This gate holds that boundary by writing from a second
// process and reading the value back here.
//
// The cookie must carry an expiry. 10.9 keeps a cookie with none in the process that wrote it and never
// hands it to the daemon, so a session cookie proves nothing about the jar -- a reader would find it
// absent whether or not the storage is shared. Both halves are asserted so the expiry cannot be dropped
// without the gate going red.
//
// The jar under test is the shared one by name, never a private session: a private session's storage is
// memory-backed and process-local by design, and asserting sharing against it would assert nothing.

#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;

static int failures;

static void check(bool condition, const char *what)
{
    if (condition)
        return;
    printf("  FAIL: %s\n", what);
    ++failures;
}

static NSString *const wk_gateDomain = @"shared-jar.test";
static NSString *const wk_gateName = @"shared";

static NSURL *wk_gateURL(void)
{
    return [NSURL URLWithString:@"http://shared-jar.test/gate"];
}

// The write a second process performs. The jar's accept policy is the account's own and is left alone;
// a request URL that is its own main-document URL satisfies every policy the account can carry.
static int wk_writeGateCookie(const char *value, BOOL persistent)
{
    NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSMutableDictionary *properties = [@{ NSHTTPCookieName: wk_gateName,
        NSHTTPCookieValue: [NSString stringWithUTF8String:value],
        NSHTTPCookieDomain: wk_gateDomain, NSHTTPCookiePath: @"/" } mutableCopy];
    if (persistent)
        properties[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSinceNow:3600];
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
    [properties release];
    if (!cookie)
        return 1;
    [jar setCookies:@[cookie] forURL:wk_gateURL() mainDocumentURL:wk_gateURL()];
    return 0;
}

static BOOL wk_writeFromSecondProcess(const char *mode, const char *value)
{
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size))
        return NO;
    char *arguments[] = { executable, (char *)mode, (char *)value, NULL };
    pid_t child = 0;
    if (posix_spawn(&child, executable, NULL, NULL, arguments, environ))
        return NO;
    int status = 0;
    if (waitpid(child, &status, 0) != child)
        return NO;
    return WIFEXITED(status) && !WEXITSTATUS(status);
}

static NSString *wk_gateCookieValue(void)
{
    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:wk_gateURL()]) {
        if ([[cookie name] isEqualToString:wk_gateName])
            return [cookie value];
    }
    return nil;
}

static void wk_forgetGateCookies(void)
{
    NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [[[jar cookies] copy] autorelease]) {
        if ([[cookie domain] rangeOfString:wk_gateDomain].location != NSNotFound)
            [jar deleteCookie:cookie];
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc > 2 && !strcmp(argv[1], "write-persistent"))
            return wk_writeGateCookie(argv[2], YES);
        if (argc > 2 && !strcmp(argv[1], "write-session"))
            return wk_writeGateCookie(argv[2], NO);

        printf("The shared cookie jar across processes:\n");
        wk_forgetGateCookies();
        check(!wk_gateCookieValue(), "the jar holds none of this gate's cookies to begin with");

        check(wk_writeFromSecondProcess("write-persistent", "carried"),
            "a second process writes a persistent cookie to the shared jar");
        NSString *carried = wk_gateCookieValue();
        check([carried isEqualToString:@"carried"],
            [[NSString stringWithFormat:@"and this process reads that cookie back (got %@)", carried] UTF8String]);
        wk_forgetGateCookies();

        // The same write without an expiry stays in the process that made it, which is what makes the
        // expiry above load-bearing rather than decorative.
        check(wk_writeFromSecondProcess("write-session", "not-carried"),
            "a second process writes a session cookie to the shared jar");
        NSString *sessionValue = wk_gateCookieValue();
        check(!sessionValue,
            [[NSString stringWithFormat:@"and a session cookie does not leave the process that wrote it (got %@)", sessionValue] UTF8String]);
        wk_forgetGateCookies();

        printf(failures ? "  %d FAILED\n" : "  ok\n", failures);
        return failures ? 1 : 0;
    }
}
