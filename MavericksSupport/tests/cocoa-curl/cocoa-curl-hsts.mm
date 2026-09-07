// HSTS syntax, lifetime, privacy, and independent-owner coherence against the actual WebCore store.
#include "config.h"
#include <WebCore/HTTPStrictTransportSecurityStore.h>
#include <wtf/FileSystem.h>
#include <wtf/MainThread.h>
#include <wtf/text/MakeString.h>
#include <Foundation/Foundation.h>
#include <cstdio>
using namespace WebCore;
static unsigned checks;
static unsigned failures;
static void check(bool result, const char* name) { ++checks; if (!result) { ++failures; printf("FAIL %s\n", name); } }
int main()
{
    @autoreleasepool {
        WTF::initializeMainThread();
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
        }
        {
            HTTPStrictTransportSecurityStore reopened(directory);
            check(reopened.shouldUpgrade(host), "large expiry survives closing and reopening the store");
            HTTPStrictTransportSecurityStore privateStore;
            check(!privateStore.shouldUpgrade(host), "private HSTS isolated from persistent state");
            privateStore.receiveHeader(URL { "https://private.test/"_s }, "max-age=3600"_s);
            check(!reopened.shouldUpgrade(URL { "https://private.test/"_s }), "private policy not written to persistent state");
        }
        check(FileSystem::deleteNonEmptyDirectory(directory), "remove isolated test database");
        printf("Cocoa curl HSTS: checks=%u FAILED=%u\n", checks, failures);
    }
    return failures ? 1 : 0;
}
