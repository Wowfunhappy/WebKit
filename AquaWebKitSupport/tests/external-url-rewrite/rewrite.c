// Maps every http(s)://rewrite-source.invalid[:port]/path?query to http://127.0.0.1:18991/path?query. For
// every load it adds X-Rewrite-Test, appends " ExternalURLRewrite/1" to User-Agent (naming it in another case)
// and removes X-Page-Header.
#include <CoreFoundation/CoreFoundation.h>

static void rewriteHeaders(CFMutableDictionaryRef headers)
{
    CFDictionarySetValue(headers, CFSTR("X-Rewrite-Test"), CFSTR("added"));
    CFDictionaryRemoveValue(headers, CFSTR("x-page-header"));
    CFStringRef userAgent = CFDictionaryGetValue(headers, CFSTR("user-agent"));
    if (userAgent) {
        CFStringRef appended = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ ExternalURLRewrite/1"), userAgent);
        CFDictionarySetValue(headers, CFSTR("user-agent"), appended);
        CFRelease(appended);
    }
}

CFURLRef WKExternalURLRewrite(CFURLRef url, CFMutableDictionaryRef headers)
{
    rewriteHeaders(headers);
    CFStringRef host = CFURLCopyHostName(url);
    if (!host)
        return NULL;
    bool matches = CFEqual(host, CFSTR("rewrite-source.invalid"));
    CFRelease(host);
    if (!matches)
        return NULL;
    CFStringRef path = CFURLCopyPath(url);
    CFStringRef query = CFURLCopyQueryString(url, NULL);
    CFStringRef string = CFStringCreateWithFormat(NULL, NULL, CFSTR("http://127.0.0.1:18991%@%s%@"), path, query ? "?" : "", query ? query : CFSTR(""));
    CFURLRef result = CFURLCreateWithString(NULL, string, NULL);
    CFRelease(string);
    CFRelease(path);
    if (query)
        CFRelease(query);
    return result;
}
