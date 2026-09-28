#import <AppKit/AppKit.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

@interface NSPasteboard (ExpirationProbe)
- (BOOL)_setExpirationDate:(NSDate *)date;
@end

static BOOL writeString(NSPasteboard *pasteboard, NSString *string, NSTimeInterval lifetime)
{
    [pasteboard declareTypes:@[ NSPasteboardTypeString ] owner:nil];
    BOOL scheduled = lifetime < 0 || [pasteboard _setExpirationDate:[NSDate dateWithTimeIntervalSinceNow:lifetime]];
    [pasteboard setString:string forType:NSPasteboardTypeString];
    return scheduled;
}

static BOOL holds(NSPasteboard *pasteboard, NSString *string)
{
    NSString *contents = [pasteboard stringForType:NSPasteboardTypeString];
    return string ? [contents isEqualToString:string] : !contents;
}

static int failures;
static void expect(BOOL condition, const char* failure)
{
    if (condition)
        return;
    fprintf(stderr, "FAIL %s\n", failure);
    ++failures;
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        // The writer that exits before its contents expire.
        if (argc == 3 && !strcmp(argv[1], "write"))
            return writeString([NSPasteboard pasteboardWithName:@(argv[2])], @"orphaned", 0.5) ? 0 : 1;

        NSPasteboard *expiring = [NSPasteboard pasteboardWithUniqueName];
        NSPasteboard *replaced = [NSPasteboard pasteboardWithUniqueName];
        NSPasteboard *lasting = [NSPasteboard pasteboardWithUniqueName];
        NSPasteboard *postponed = [NSPasteboard pasteboardWithUniqueName];
        NSPasteboard *hastened = [NSPasteboard pasteboardWithUniqueName];
        NSPasteboard *orphaned = [NSPasteboard pasteboardWithUniqueName];

        expect(writeString(expiring, @"expires", 0.5), "the expiration was not scheduled");
        writeString(replaced, @"first", 0.5);
        writeString(replaced, @"second", -1);
        writeString(lasting, @"lasts", 10);
        writeString(postponed, @"postponed", 0.5);
        expect([postponed _setExpirationDate:[NSDate dateWithTimeIntervalSinceNow:10]], "the later expiration was not scheduled");
        writeString(hastened, @"hastened", 10);
        [hastened _setExpirationDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

        pid_t writer;
        char* arguments[] = { argv[0], "write", (char*)orphaned.name.UTF8String, NULL };
        int status = 1;
        if (!posix_spawn(&writer, argv[0], NULL, NULL, arguments, NULL))
            waitpid(writer, &status, 0);
        expect(WIFEXITED(status) && !WEXITSTATUS(status), "the writer process failed");
        expect(holds(orphaned, @"orphaned"), "the exited writer's contents are missing");
        expect(holds(expiring, @"expires"), "contents cleared before their expiration date");

        [NSThread sleepForTimeInterval:2.5];

        expect(holds(expiring, nil), "expired contents remain");
        expect(holds(replaced, @"second"), "an expiration cleared the contents that replaced its own");
        expect(holds(lasting, @"lasts"), "contents cleared before their expiration date");
        expect(holds(postponed, @"postponed"), "an earlier expiration outlived the later one that replaced it");
        expect(holds(hastened, nil), "a later, sooner expiration did not replace the earlier one");
        expect(holds(orphaned, nil), "contents outlived their expiration because the writer exited");

        for (NSPasteboard *pasteboard in @[ expiring, replaced, lasting, postponed, hastened, orphaned ])
            [pasteboard releaseGlobally];
        return failures ? 1 : 0;
    }
}
