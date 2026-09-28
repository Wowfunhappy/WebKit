// pasteboard-expiration <pasteboard name> <change count> <deadline, seconds since 1970>
//
// Clears the named pasteboard at the deadline if its change count is still the given one: the expiration
// -[NSPasteboard _setExpirationDate:] promises, kept by the pasteboard server on 11.0. A byte on standard
// input cancels it; the end of standard input, which the caller's exit also brings, leaves it in force.

#import <AppKit/AppKit.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char** argv)
{
    (void)argc;
    const char* name = argv[1];
    long long changeCount = strtoll(argv[2], NULL, 10);
    double deadline = strtod(argv[3], NULL);

    // The caller waits for this process; the expiration continues in a child launchd adopts.
    pid_t child = fork();
    if (child < 0)
        return 71;
    if (child)
        return 0;
    setsid();

    bool watchingInput = true;
    for (;;) {
        double remaining = deadline - (double)time(NULL);
        if (remaining <= 0)
            break;
        // Waits are capped so a wall-clock deadline is noticed after the machine sleeps.
        int timeout = (int)(remaining < 60 ? remaining * 1000 : 60000);
        if (!watchingInput) {
            poll(NULL, 0, timeout);
            continue;
        }
        struct pollfd input = { STDIN_FILENO, POLLIN, 0 };
        int ready = poll(&input, 1, timeout);
        if (ready < 0 && errno != EINTR)
            return 71;
        if (ready <= 0)
            continue;
        char byte;
        ssize_t count = read(STDIN_FILENO, &byte, 1);
        if (count > 0)
            return 0;
        if (count == 0 || errno != EINTR)
            watchingInput = false;
    }

    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:@(name)];
        if ((long long)pasteboard.changeCount == changeCount)
            [pasteboard clearContents];
    }
    return 0;
}
