// NSURLIsExcludedFromBackupKey marks a file with Time Machine's exclusion attribute, the bytes 10.9's
// CSBackupSetItemExcluded writes, which CSBackupIsItemExcluded reads back; clearing the key removes it.
#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>
#include <unistd.h>

static int failures;

static void check(BOOL condition, const char *what)
{
    if (condition)
        return;
    printf("  FAIL: %s\n", what);
    ++failures;
}

static const char attributeName[] = "com.apple.metadata:com_apple_backup_excludeItem";

int main(void)
{
    @autoreleasepool {
        char directory[] = "/tmp/backup-exclusion.XXXXXX";
        if (!mkdtemp(directory)) {
            printf("  FAIL: mkdtemp\n");
            return 1;
        }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:directory] isDirectory:YES];

        NSError *error = nil;
        check([url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error], "setting the key succeeds");

        static const unsigned char expected[] = {
            0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0x5F, 0x10, 0x11, 0x63, 0x6F, 0x6D, 0x2E, 0x61,
            0x70, 0x70, 0x6C, 0x65, 0x2E, 0x62, 0x61, 0x63, 0x6B, 0x75, 0x70, 0x64, 0x08, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1C,
        };
        unsigned char actual[128];
        ssize_t length = getxattr(directory, attributeName, actual, sizeof(actual), 0, 0);
        check(length == sizeof(expected) && !memcmp(actual, expected, sizeof(expected)), "the attribute holds CSBackupSetItemExcluded's bytes");
        check(CSBackupIsItemExcluded((CFURLRef)url, NULL), "CSBackupIsItemExcluded reads the item as excluded");

        check([url setResourceValue:@NO forKey:NSURLIsExcludedFromBackupKey error:&error], "clearing the key succeeds");
        check(getxattr(directory, attributeName, NULL, 0, 0, 0) < 0, "clearing the key removes the attribute");
        check(!CSBackupIsItemExcluded((CFURLRef)url, NULL), "CSBackupIsItemExcluded reads the item as included");
        check([url setResourceValue:@NO forKey:NSURLIsExcludedFromBackupKey error:&error], "clearing an unmarked item succeeds");

        NSURL *remote = [NSURL URLWithString:@"https://webkit.org/"];
        check(![remote setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error] && error, "a non-file URL reports an error");

        rmdir(directory);
    }
    if (failures)
        return 1;
    printf("  backup exclusion: ok\n");
    return 0;
}
