// HSTS syntax, lifetime, privacy, and independent-owner coherence against the actual WebCore store.
#include "config.h"
#include <WebCore/HTTPStrictTransportSecurityStore.h>
#include <wtf/FileSystem.h>
#include <wtf/MainThread.h>
#include <wtf/text/MakeString.h>
#include <Foundation/Foundation.h>
#include <cstdio>
#include <spawn.h>
#include <sys/wait.h>
using namespace WebCore;
static unsigned checks;
static unsigned failures;
static void check(bool result, const char* name) { ++checks; if (!result) { ++failures; printf("FAIL %s\n", name); } }
static NSDictionary *storedPolicies(const String& directory)
{
    return [NSDictionary dictionaryWithContentsOfFile:FileSystem::pathByAppendingComponent(directory, "HSTS.plist"_s).createNSString().get()];
}
int main(int argc, char** argv)
{
    @autoreleasepool {
        WTF::initializeMainThread();
        // The exit check's child: it receives a policy and exits without flushing.
        if (argc == 3 && !strcmp(argv[1], "--receive-and-exit")) {
            HTTPStrictTransportSecurityStore store(String::fromUTF8(argv[2]));
            store.receiveHeader(URL { "https://exiting.test/"_s }, "max-age=3600"_s);
            exit(0);
        }
        const URL host { "https://policy.test/"_s };
        const URL child { "http://child.policy.test/"_s };
        HTTPStrictTransportSecurityStore memory;
        for (auto field : { "max-age=3600"_s, "MAX-AGE = 3600"_s, "max-age=\"3600\""_s, "max-age=\"3\\600\""_s, ";; max-age=3600 ;;"_s, "extension=\"a;b=c\";max-age=3600"_s, "extension=token;max-age=3600"_s, "extension;max-age=3600"_s, "max-age=18446744073709551616000"_s }) {
            memory.removeHost(host.host().toString());
            memory.receiveHeader(host, field);
            check(memory.shouldUpgrade(host), field.characters());
        }
        for (auto field : { "max-age"_s, "max-age="_s, "max-age=-1"_s, "max-age=1.0"_s, "max-age=3600;MAX-AGE=0"_s, "max-age=3600;extension;EXTENSION"_s, "max-age=3600;includeSubDomains=1"_s, "max-age=3600;extension=\"unterminated"_s, "max-age=3600;extension=\"one\"extra"_s, "max-age=3600, max-age=0"_s, "max-age=3600;extension=a/b"_s, "max-age=\"3 600\""_s, "max-age=3600;extension=\"\r\""_s }) {
            memory.removeHost(host.host().toString());
            memory.receiveHeader(host, field);
            check(!memory.shouldUpgrade(host), field.characters());
        }
        memory.receiveHeader(host, "max-age=3600"_s);
        check(!memory.shouldUpgrade(child), "exact policy does not include children");
        memory.receiveHeader(host, "max-age=3600;includeSubDomains"_s);
        check(memory.shouldUpgrade(child), "subdomain policy");
        check(!memory.shouldUpgrade(URL { "http://notpolicy.test/"_s }), "hostname label boundary");
        memory.receiveHeader(host, "max-age=0"_s);
        check(!memory.shouldUpgrade(host) && !memory.shouldUpgrade(child), "zero deletes policy and subdomain effect");
        memory.receiveHeader(URL { "http://policy.test/"_s }, "max-age=3600"_s);
        memory.receiveHeader(URL { "https://127.0.0.1/"_s }, "max-age=3600"_s);
        memory.receiveHeader(URL { "https://[::1]/"_s }, "max-age=3600"_s);
        check(memory.hosts().isEmpty(), "insecure origin and IP literal headers ignored");
        char temporary[] = "/private/tmp/curl-hsts-tests-XXXXXX";
        RELEASE_ASSERT(mkdtemp(temporary));
        String directory = String::fromUTF8(temporary);
        {
            HTTPStrictTransportSecurityStore writer(directory);
            HTTPStrictTransportSecurityStore anotherWriter(directory);
            HTTPStrictTransportSecurityStore reader(directory, HTTPStrictTransportSecurityStore::Access::ReadOnly);
            writer.receiveHeader(host, "max-age=3600;includeSubDomains"_s);
            check(reader.shouldUpgrade(child), "already-open reader observes another owner's insert");
            anotherWriter.receiveHeader(URL { "https://second.test/"_s }, "max-age=3600"_s);
            check(writer.hosts().size() == 2 && reader.hosts().size() == 2, "independent writers preserve each other's policy");
            reader.removeHost(host.host().toString());
            reader.removeModifiedSince(WallTime::fromRawSeconds(0));
            check(writer.hosts().size() == 2, "read-only owner cannot mutate");
            anotherWriter.removeHost(host.host().toString());
            check(!writer.shouldUpgrade(host) && !reader.shouldUpgrade(child), "all owners observe deletion");
            writer.removeModifiedSince(WallTime::now() + Seconds(3600));
            check(writer.hosts().size() == 1, "modified-since keeps older entries");
            writer.removeModifiedSince(WallTime::fromRawSeconds(0));
            check(reader.hosts().isEmpty(), "modified-since deletion visible to independent reader");
            writer.receiveHeader(host, makeString("max-age="_s, String::fromUTF8(std::string(400, '9').c_str())));
            check(writer.shouldUpgrade(host), "unbounded wire max-age remains valid");
            // The flush writes this policy, so the file the checks below read holds it.
            writer.flush();
            check(storedPolicies(directory)[@"policy.test"] != nil, "flush writes the accepted policy to the file");
        }
        {
            HTTPStrictTransportSecurityStore reopened(directory);
            check(reopened.shouldUpgrade(host), "large expiry survives closing and reopening the store");
            HTTPStrictTransportSecurityStore privateStore;
            check(!privateStore.shouldUpgrade(host), "private HSTS isolated from persistent state");
            privateStore.receiveHeader(URL { "https://private.test/"_s }, "max-age=3600"_s);
            check(!reopened.shouldUpgrade(URL { "https://private.test/"_s }), "private policy not written to persistent state");
        }
        {
            // Nothing may write into the directory after it is removed. The flush persists every
            // mutation the stores above made, so a scheduled pass that runs later has nothing to write
            // and does no I/O.
            HTTPStrictTransportSecurityStore settling(directory);
            settling.flush();
        }
        {
            char batchedTemporary[] = "/private/tmp/curl-hsts-batched-XXXXXX";
            RELEASE_ASSERT(mkdtemp(batchedTemporary));
            String batchedDirectory = String::fromUTF8(batchedTemporary);
            HTTPStrictTransportSecurityStore store(batchedDirectory);
            store.receiveHeader(URL { "https://batched.test/"_s }, "max-age=3600"_s);
            check(store.shouldUpgrade(URL { "http://batched.test/"_s }), "a received policy is answered at once");
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
            check(!storedPolicies(batchedDirectory)[@"batched.test"], "a received policy is written in a later batch");
            store.flush();
            check(storedPolicies(batchedDirectory)[@"batched.test"] != nil, "flush writes the batch");
            check(FileSystem::deleteNonEmptyDirectory(batchedDirectory), "remove batched test directory");
        }
        {
            char expiredTemporary[] = "/private/tmp/curl-hsts-expired-XXXXXX";
            RELEASE_ASSERT(mkdtemp(expiredTemporary));
            String expiredDirectory = String::fromUTF8(expiredTemporary);
            double now = [[NSDate date] timeIntervalSince1970];
            [@{ @"expired.test": @{ @"expires": @(now - 60), @"modified": @(now - 120), @"subdomains": @NO },
                @"current.test": @{ @"expires": @(now + 3600), @"modified": @(now), @"subdomains": @NO } }
                writeToFile:FileSystem::pathByAppendingComponent(expiredDirectory, "HSTS.plist"_s).createNSString().get() atomically:YES];
            HTTPStrictTransportSecurityStore store(expiredDirectory);
            store.receiveHeader(URL { "https://fresh.test/"_s }, "max-age=3600"_s);
            store.flush();
            NSDictionary *stored = storedPolicies(expiredDirectory);
            check(!stored[@"expired.test"] && stored[@"current.test"] && stored[@"fresh.test"], "a write drops expired policies and keeps current ones");
            check(FileSystem::deleteNonEmptyDirectory(expiredDirectory), "remove expired test directory");
        }
        {
            char exitTemporary[] = "/private/tmp/curl-hsts-exit-XXXXXX";
            RELEASE_ASSERT(mkdtemp(exitTemporary));
            char mode[] = "--receive-and-exit";
            char* childArguments[] = { argv[0], mode, exitTemporary, nullptr };
            pid_t pid = 0;
            int status = 0;
            check(!posix_spawn(&pid, argv[0], nullptr, nullptr, childArguments, nullptr) && waitpid(pid, &status, 0) == pid && WIFEXITED(status) && !WEXITSTATUS(status), "exit check child ran");
            check(storedPolicies(String::fromUTF8(exitTemporary))[@"exiting.test"] != nil, "a process that exits without flushing writes the policy it received");
            check(FileSystem::deleteNonEmptyDirectory(String::fromUTF8(exitTemporary)), "remove exit test directory");
        }
        check(FileSystem::deleteNonEmptyDirectory(directory), "remove isolated test database");
        printf("Cocoa curl HSTS: checks=%u FAILED=%u\n", checks, failures);
    }
    return failures ? 1 : 0;
}
