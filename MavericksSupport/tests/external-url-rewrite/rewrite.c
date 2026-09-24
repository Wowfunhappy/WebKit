// Maps every http(s)://rewrite-source.invalid[:port]/path?query to http://127.0.0.1:18991/path?query.
#include <CoreFoundation/CoreFoundation.h>

CFURLRef WKExternalURLRewrite(CFURLRef url)
{
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
