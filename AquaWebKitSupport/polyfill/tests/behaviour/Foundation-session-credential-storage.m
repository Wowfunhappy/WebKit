// A configuration on the default storage session answers +[NSURLCredentialStorage sharedCredentialStorage]
// itself, through a session's own copy of the configuration too. An ephemeral configuration keeps its own
// storage, a storage set on a configuration is answered as set, and a host app's own call gets 10.9's answer.
#import <Foundation/Foundation.h>
#import <objc/message.h>

#include <stdio.h>

static int failures;

static void check(bool condition, const char *what)
{
    if (condition)
        return;
    fprintf(stderr, "FAIL %s\n", what);
    ++failures;
}

int main(void)
{
    @autoreleasepool {
        NSURLCredentialStorage *shared = [NSURLCredentialStorage sharedCredentialStorage];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        check(configuration.URLCredentialStorage == shared, "default configuration answers the shared storage");

        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
        check(session.configuration.URLCredentialStorage == shared, "a session's configuration answers the shared storage");
        [session invalidateAndCancel];

        NSURLCredentialStorage *ephemeral = [NSURLSessionConfiguration ephemeralSessionConfiguration].URLCredentialStorage;
        check(ephemeral && ephemeral != shared, "an ephemeral configuration keeps its own storage");

        NSURLSessionConfiguration *configured = [NSURLSessionConfiguration defaultSessionConfiguration];
        configured.URLCredentialStorage = ephemeral;
        check(configured.URLCredentialStorage == ephemeral, "a storage set on a configuration is answered as set");

        NSURLCredentialStorage *hostAnswer = ((id (*)(id, SEL))objc_msgSend)(configuration, sel_registerName("URLCredentialStorage"));
        check(hostAnswer && hostAnswer != shared, "a host app's own call gets 10.9's answer");
    }
    if (failures)
        return 1;
    printf("session credential storage: all cases match\n");
    return 0;
}
