// The colour spaces CGColorSpaceCreateWithName synthesizes (c/CoreGraphics.c) carry their names, as
// modern macOS's do: CGColorSpaceGetName and CGColorSpaceCopyName answer the name, the property list is
// the name, and a space made from that property list is the named space again -- the Display P3 PQ space
// itself, which WebKit's HDR conversions recognize by identity.
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>

extern CFStringRef CGColorSpaceGetName(CGColorSpaceRef);
extern CFStringRef CGColorSpaceCopyName(CGColorSpaceRef);
extern CFPropertyListRef CGColorSpaceCopyPropertyList(CGColorSpaceRef);
extern CGColorSpaceRef CGColorSpaceCreateWithPropertyList(CFPropertyListRef);
extern bool CGColorSpaceEqualToColorSpace(CGColorSpaceRef, CGColorSpaceRef);

static int failures;
static void check(bool ok, const char *what, CFStringRef name)
{
    char buffer[128] = "";
    CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    printf("  %s %s: %s\n", buffer, what, ok ? "ok" : "FAIL");
    failures += !ok;
}

int main(void)
{
    const CFStringRef names[] = {
        CFSTR("kCGColorSpaceLinearSRGB"), CFSTR("kCGColorSpaceExtendedLinearSRGB"), CFSTR("kCGColorSpaceGenericXYZ"),
        CFSTR("kCGColorSpaceDisplayP3"), CFSTR("kCGColorSpaceDisplayP3_PQ"), CFSTR("kCGColorSpaceExtendedDisplayP3"),
        CFSTR("kCGColorSpaceLinearDisplayP3"), CFSTR("kCGColorSpaceExtendedLinearDisplayP3"), CFSTR("kCGColorSpaceITUR_2020"),
        CFSTR("kCGColorSpaceExtendedITUR_2020"), CFSTR("kCGColorSpaceExtendedRec2020"), CFSTR("kCGColorSpaceROMMRGB"),
        CFSTR("kCGColorSpaceExtendedSRGB"),
    };
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(names[i]);
        check(space != NULL, "is created", names[i]);
        if (!space)
            continue;
        CFStringRef got = CGColorSpaceGetName(space), copied = CGColorSpaceCopyName(space);
        check(got && CFEqual(got, names[i]) && copied && CFEqual(copied, names[i]), "answers its name", names[i]);
        if (copied)
            CFRelease(copied);
        CFPropertyListRef list = CGColorSpaceCopyPropertyList(space);
        check(list && CFEqual(list, names[i]), "has its name as its property list", names[i]);
        CGColorSpaceRef again = list ? CGColorSpaceCreateWithPropertyList(list) : NULL;
        bool pq = CFEqual(names[i], CFSTR("kCGColorSpaceDisplayP3_PQ"));
        check(again && (pq ? again == space : CGColorSpaceEqualToColorSpace(again, space)) && CFEqual(CGColorSpaceGetName(again), names[i]),
            pq ? "round-trips to the same space" : "round-trips to an equal named space", names[i]);
        if (again)
            CGColorSpaceRelease(again);
        if (list)
            CFRelease(list);
        CGColorSpaceRelease(space);
    }
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    check(CFEqual(CGColorSpaceGetName(srgb), kCGColorSpaceSRGB), "keeps 10.9's own name", kCGColorSpaceSRGB);
    CGColorSpaceRelease(srgb);
    printf("CoreGraphics-named-spaces: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
