// NSItemProvider and the share-sheet wrapper that carries its artwork (polyfills/classes/): the two
// contracts a caller depends on and WebKit's own callers do not exercise.
//
// A load hands back the REGISTERED ITEM, not the pasteboard representation of it, and it does so on a
// private queue rather than on the caller's thread. Completion semaphores synchronize the result
// reads with the handler's writes.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdio.h>
#import <assert.h>
#import <dispatch/dispatch.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

// Both classes carry availability the 10.9 deployment target predates, and this file is compiled with
// -Werror=unguarded-availability, so they are reached through their class symbols rather than by name.
extern char OBJC_CLASS_$_NSItemProvider;
extern char OBJC_CLASS_$_NSPreviewRepresentingActivityItem;

static id makeProvider(id item, NSString *typeIdentifier)
{
    Class cls = (__bridge Class)(void *)&OBJC_CLASS_$_NSItemProvider;
    return [((id (*)(id, SEL, id, NSString *))objc_msgSend)([cls alloc], sel_getUid("initWithItem:typeIdentifier:"), item, typeIdentifier) autorelease];
}

static void startLoad(id provider, NSString *type, void (^handler)(id, NSError *))
{
    ((void (*)(id, SEL, NSString *, NSDictionary *, void (^)(id, NSError *)))objc_msgSend)(provider,
        sel_getUid("loadItemForTypeIdentifier:options:completionHandler:"), type, nil, handler);
}

static id loadAndWait(id provider, NSString *type, NSError **errorOut)
{
    __block id loaded = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    startLoad(provider, type, ^(id item, NSError *e) {
        loaded = [item retain];
        error = [e retain];
        dispatch_semaphore_signal(completed);
    });
    assert(!dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    dispatch_release(completed);
    if (errorOut)
        *errorOut = [error autorelease];
    else
        [error release];
    return [loaded autorelease];
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];

        NSString *string = @"a registered string";
        id stringProvider = makeProvider(string, @"public.utf8-plain-text");
        check([loadAndWait(stringProvider, @"public.utf8-plain-text", NULL) isEqual:string], "an NSString item loads as the NSString");
        check([((id (*)(id, SEL, NSString *))objc_msgSend)(stringProvider, sel_getUid("pasteboardPropertyListForType:"), @"public.utf8-plain-text") length] > 0, "and still writes to a pasteboard");

        NSURL *url = [NSURL URLWithString:@"https://example.org/page"];
        id urlProvider = makeProvider(url, @"public.url");
        check([loadAndWait(urlProvider, @"public.url", NULL) isEqual:url], "an NSURL item loads as the NSURL");
        check(((id (*)(id, SEL, NSString *))objc_msgSend)(urlProvider, sel_getUid("pasteboardPropertyListForType:"), @"public.url") != nil, "and still writes to a pasteboard");

        NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(8, 8)] autorelease];
        [image lockFocus];
        [[NSColor redColor] set];
        NSRectFill(NSMakeRect(0, 0, 8, 8));
        [image unlockFocus];
        id imageProvider = makeProvider(image, @"public.tiff");
        id loadedImage = loadAndWait(imageProvider, @"public.tiff", NULL);
        check(loadedImage == image, "an image item loads as the registered image");

        NSData *data = [image TIFFRepresentation];
        id dataProvider = makeProvider(data, @"public.tiff");
        check([loadAndWait(dataProvider, @"public.tiff", NULL) isEqual:data], "an NSData item loads as that NSData");
        check([((id (*)(id, SEL))objc_msgSend)(dataProvider, sel_getUid("registeredTypeIdentifiers")) isEqual:[NSArray arrayWithObject:@"public.tiff"]], "and registers exactly its type");

        NSError *mismatch = nil;
        check(!loadAndWait(dataProvider, @"public.png", &mismatch) && [mismatch.domain isEqualToString:@"NSItemProviderErrorDomain"] && mismatch.code == -1000, "an unavailable type has the NSItemProvider error domain and code");

        // Completion executes off the calling thread; it may finish before startLoad returns.
        __block BOOL sameThread = YES;
        pthread_t caller = pthread_self();
        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        startLoad(dataProvider, @"public.tiff", ^(id item, NSError *e) {
            (void)item;
            (void)e;
            sameThread = pthread_equal(pthread_self(), caller) != 0;
            dispatch_semaphore_signal(completed);
        });
        assert(!dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        check(!sameThread, "the handler runs off the calling thread");
        dispatch_release(completed);

        // NSPreviewRepresentingActivityItem carries the artwork it is handed, as the providers it vends.
        Class previewItem = (__bridge Class)(void *)&OBJC_CLASS_$_NSPreviewRepresentingActivityItem;
        id preview = ((id (*)(id, SEL, id, NSString *, NSImage *, NSImage *))objc_msgSend)([previewItem alloc],
            sel_getUid("initWithItem:title:image:icon:"), url, @"Title", image, image);
        check([preview valueForKey:@"item"] == url && [[preview valueForKey:@"title"] isEqualToString:@"Title"], "a preview item keeps its item and title");
        check([preview valueForKey:@"imageProvider"] && [preview valueForKey:@"iconProvider"], "and the image and icon it was handed");
        check([previewItem instancesRespondToSelector:sel_getUid("initWithItem:title:imageProvider:iconProvider:")], "and answers the designated initializer");
        check([((id (*)(id, SEL, id))objc_msgSend)(preview, sel_getUid("writableTypesForPasteboard:"), nil) count] > 0, "and writes the wrapped item to a pasteboard");
        [preview release];

        printf("Foundation-item-provider: %d failure(s)\n", failures);
        return failures ? 1 : 0;
    }
}
