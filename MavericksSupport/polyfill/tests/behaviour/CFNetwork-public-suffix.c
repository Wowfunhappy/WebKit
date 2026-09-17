#include "wk_hosts.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    const struct { const char* name; bool isSuffix; } cases[] = {
        { "com", true }, { "COM", true }, { "co.uk", true },
        { ".com", true }, { "com.", false }, { "com..", false },
        { "..com", false }, { "a..com", false },
        { "blogspot.com", true }, { "github.io", true },
        { "c.kobe.jp", true }, { "city.kobe.jp", false },
        { "栃木.jp", true }, { "test.com", false },
        { "example", true }, { "invalid", true }, { "localhost", true },
        { "åäö", false }, { "xn--4cab6c", false },
        { "", false }, { ".", false }, { "..", false }, { "...", false }, { "....", false },
        { "127.0.0.1", false }, { "[::1]", false },
    };
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        CFStringRef name = CFStringCreateWithCString(NULL, cases[i].name, kCFStringEncodingUTF8);
        assert(name);
        assert(wk_domainIsPublicSuffix(name) == cases[i].isSuffix);
        CFRelease(name);
    }
    puts("PASS explicit public-suffix rules");
    return 0;
}
