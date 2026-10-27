// -[NSURLSessionConfiguration _shouldSkipPreferredClientCertificateLookup] is a stored property: NO on a fresh
// default or ephemeral configuration, and the value set survives -copy and +sessionWithConfiguration:. The
// configuration's connection properties keep it, so a task of a session that set it sends the same request,
// over a connection that serves it, as a task of a session that did not.
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

@interface NSURLSessionConfiguration (WKSkipPreferredClientCertificateLookup)
@property BOOL _shouldSkipPreferredClientCertificateLookup;
@end

static int failures;

static void check(BOOL condition, const char *what)
{
    printf("%s %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition)
        ++failures;
}

static int listener;
static uint16_t port;
static NSMutableArray *receivedRequests;

static void startServer(void)
{
    listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = { 0 };
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(listener, (struct sockaddr *)&address, sizeof(address));
    socklen_t length = sizeof(address);
    getsockname(listener, (struct sockaddr *)&address, &length);
    port = ntohs(address.sin_port);
    listen(listener, 8);
    receivedRequests = [NSMutableArray new];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (;;) {
            int connection = accept(listener, NULL, NULL);
            if (connection < 0)
                return;
            char buffer[8192];
            ssize_t total = 0;
            while (total < (ssize_t)sizeof(buffer) - 1) {
                ssize_t count = read(connection, buffer + total, sizeof(buffer) - 1 - total);
                if (count <= 0)
                    break;
                total += count;
                buffer[total] = 0;
                if (strstr(buffer, "\r\n\r\n"))
                    break;
            }
            @synchronized (receivedRequests) {
                [receivedRequests addObject:[[[NSString alloc] initWithBytes:buffer length:total encoding:NSISOLatin1StringEncoding] autorelease]];
            }
            const char *response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
            write(connection, response, strlen(response));
            close(connection);
        }
    });
}

static NSString *runTask(NSURLSessionConfiguration *configuration, NSInteger *status, NSError **error)
{
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/probe", port]];
    __block NSInteger statusCode = 0;
    __block NSError *taskError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSUInteger before = receivedRequests.count;
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
        (void)data;
        statusCode = [(NSHTTPURLResponse *)response statusCode];
        taskError = [e retain];
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    dispatch_release(done);
    [session invalidateAndCancel];
    *status = statusCode;
    *error = [taskError autorelease];
    @synchronized (receivedRequests) {
        return receivedRequests.count > before ? [receivedRequests lastObject] : nil;
    }
}

int main(void)
{
    @autoreleasepool {
        check(![NSURLSessionConfiguration defaultSessionConfiguration]._shouldSkipPreferredClientCertificateLookup, "a default configuration reads NO");
        check(![NSURLSessionConfiguration ephemeralSessionConfiguration]._shouldSkipPreferredClientCertificateLookup, "an ephemeral configuration reads NO");

        for (int value = 1; value >= 0; --value) {
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
            configuration._shouldSkipPreferredClientCertificateLookup = YES;
            configuration._shouldSkipPreferredClientCertificateLookup = value;
            NSURLSessionConfiguration *copy = [[configuration copy] autorelease];
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
            char what[128];
            snprintf(what, sizeof(what), "%s reads back", value ? "YES" : "NO");
            check(configuration._shouldSkipPreferredClientCertificateLookup == value, what);
            snprintf(what, sizeof(what), "%s survives -copy", value ? "YES" : "NO");
            check(copy._shouldSkipPreferredClientCertificateLookup == value, what);
            snprintf(what, sizeof(what), "%s survives +sessionWithConfiguration:", value ? "YES" : "NO");
            check(session.configuration._shouldSkipPreferredClientCertificateLookup == value, what);
            [session invalidateAndCancel];
        }

        startServer();
        NSInteger plainStatus = 0, flaggedStatus = 0;
        NSError *plainError = nil, *flaggedError = nil;
        NSString *plainRequest = runTask([NSURLSessionConfiguration ephemeralSessionConfiguration], &plainStatus, &plainError);
        NSURLSessionConfiguration *flagged = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        flagged._shouldSkipPreferredClientCertificateLookup = YES;
        NSString *flaggedRequest = runTask(flagged, &flaggedStatus, &flaggedError);
        check(!plainError && plainStatus == 200, "a task of a session without the property completes");
        check(!flaggedError && flaggedStatus == 200, "a task of a session with the property completes");
        check(plainRequest && [plainRequest isEqualToString:flaggedRequest], "both sessions send the same request");
        if (plainRequest && ![plainRequest isEqualToString:flaggedRequest])
            printf("  without: %s\n  with:    %s\n", plainRequest.UTF8String, flaggedRequest.UTF8String);
    }
    return failures ? 1 : 0;
}
