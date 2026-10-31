// Trailing data does not change a WOFF's sanitized font; truncated containers and
// table ranges outside the declared container remain invalid.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern CFDataRef wk_ots_sanitize_font(CFDataRef);

static int failures;

static void check(int ok, const char* message)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", message);
    failures += !ok;
}

static CFDataRef sanitize(const unsigned char* bytes, size_t length)
{
    CFDataRef data = CFDataCreate(NULL, bytes, length);
    CFDataRef result = wk_ots_sanitize_font(data);
    CFRelease(data);
    return result;
}

static void write32(unsigned char* bytes, unsigned value)
{
    bytes[0] = value >> 24;
    bytes[1] = value >> 16;
    bytes[2] = value >> 8;
    bytes[3] = value;
}

int main(int argc, char** argv)
{
    if (argc != 2)
        return 2;
    FILE* file = fopen(argv[1], "rb");
    if (!file)
        return 2;
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    rewind(file);
    if (length < 64 || length > 1024 * 1024)
        return 2;
    size_t paddedLength = length + 800000;
    unsigned char* bytes = calloc(paddedLength, 1);
    if (!bytes || fread(bytes, 1, length, file) != (size_t)length)
        return 2;
    fclose(file);

    CFDataRef original = sanitize(bytes, length);
    check(original != NULL, "original WOFF is valid");
    CFDataRef padded = sanitize(bytes, paddedLength);
    check(original && padded && CFEqual(original, padded), "zero padding preserves the sanitized font");
    if (padded)
        CFRelease(padded);
    memset(bytes + length, 0xA5, paddedLength - length);
    padded = sanitize(bytes, paddedLength);
    check(original && padded && CFEqual(original, padded), "nonzero trailing data preserves the sanitized font");
    if (padded)
        CFRelease(padded);

    CFDataRef invalid = sanitize(bytes, length - 1);
    check(!invalid, "truncated container is rejected");
    if (invalid)
        CFRelease(invalid);
    write32(bytes + 8, 43);
    invalid = sanitize(bytes, paddedLength);
    check(!invalid, "container shorter than its header is rejected");
    if (invalid)
        CFRelease(invalid);
    write32(bytes + 8, length);
    write32(bytes + 48, length); // First table's offset points into trailing data.
    invalid = sanitize(bytes, paddedLength);
    check(!invalid, "table outside the container cannot use trailing data");
    if (invalid)
        CFRelease(invalid);

    if (original)
        CFRelease(original);
    free(bytes);
    return failures ? 1 : 0;
}
