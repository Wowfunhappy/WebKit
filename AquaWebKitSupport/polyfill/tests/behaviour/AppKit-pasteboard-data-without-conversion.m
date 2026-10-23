#import <AppKit/AppKit.h>
#include <stdio.h>

@interface NSPasteboard (DataWithoutConversionProbe)
- (NSData *)_dataWithoutConversionForType:(NSString *)type securityScoped:(BOOL)securityScoped;
@end

static int failures;
static void expect(BOOL condition, const char* failure)
{
    if (condition)
        return;
    fprintf(stderr, "FAIL %s\n", failure);
    ++failures;
}

int main(void)
{
    @autoreleasepool {
        NSBitmapImageRep *image = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:4 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
        NSData *png = [image representationUsingType:NSPNGFileType properties:@{ }];
        NSData *tiff = [image TIFFRepresentation];
        NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];

        [pasteboard declareTypes:@[ (NSString *)kUTTypePNG ] owner:nil];
        [pasteboard setData:png forType:(NSString *)kUTTypePNG];
        expect([pasteboard dataForType:NSTIFFPboardType].length > 0, "-dataForType: did not convert PNG to TIFF");
        for (BOOL securityScoped = NO; securityScoped <= YES; ++securityScoped) {
            expect(![pasteboard _dataWithoutConversionForType:NSTIFFPboardType securityScoped:securityScoped], "TIFF was converted from the PNG on the pasteboard");
            expect(![pasteboard _dataWithoutConversionForType:(NSString *)kUTTypeTIFF securityScoped:securityScoped], "public.tiff was converted from the PNG on the pasteboard");
            expect([[pasteboard _dataWithoutConversionForType:(NSString *)kUTTypePNG securityScoped:securityScoped] isEqualToData:png], "the PNG on the pasteboard was not returned as written");
        }

        [pasteboard declareTypes:@[ NSTIFFPboardType ] owner:nil];
        [pasteboard setData:tiff forType:NSTIFFPboardType];
        for (BOOL securityScoped = NO; securityScoped <= YES; ++securityScoped) {
            expect([[pasteboard _dataWithoutConversionForType:NSTIFFPboardType securityScoped:securityScoped] isEqualToData:tiff], "the TIFF on the pasteboard was not returned for its legacy type name");
            expect([[pasteboard _dataWithoutConversionForType:(NSString *)kUTTypeTIFF securityScoped:securityScoped] isEqualToData:tiff], "the TIFF on the pasteboard was not returned for public.tiff");
            expect(![pasteboard _dataWithoutConversionForType:(NSString *)kUTTypePNG securityScoped:securityScoped], "PNG was converted from the TIFF on the pasteboard");
        }

        // This probe is built with a 10.10+ SDK, so a file reference URL becomes its file path URL only
        // when NSPasteboardConvertsFileReferenceURLsToFilePathURLs is YES at the first read. The runner
        // passes "-NSPasteboardConvertsFileReferenceURLsToFilePathURLs YES" for that run.
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL converts = [defaults boolForKey:@"NSPasteboardConvertsFileReferenceURLsToFilePathURLs"];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
        [[NSData data] writeToFile:path atomically:NO];
        NSURL *referenceURL = [NSURL fileURLWithPath:path].fileReferenceURL;
        expect(referenceURL.isFileReferenceURL, "no file reference URL for the probe file");
        NSData *referenceData = [referenceURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSData *pathData = [referenceURL.filePathURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        [pasteboard declareTypes:@[ (NSString *)kUTTypeFileURL ] owner:nil];
        [pasteboard setData:referenceData forType:(NSString *)kUTTypeFileURL];
        for (BOOL securityScoped = NO; securityScoped <= YES; ++securityScoped)
            expect([[pasteboard _dataWithoutConversionForType:(NSString *)kUTTypeFileURL securityScoped:securityScoped] isEqualToData:converts ? pathData : referenceData], converts ? "a file reference URL did not become its file path URL" : "a file reference URL was rewritten with the conversion default unset");

        if (!converts) {
            [defaults setVolatileDomain:@{ @"NSPasteboardConvertsFileReferenceURLsToFilePathURLs": @YES } forName:NSArgumentDomain];
            expect([[pasteboard _dataWithoutConversionForType:(NSString *)kUTTypeFileURL securityScoped:NO] isEqualToData:referenceData], "the conversion default was read again after the first read");
            [defaults removeVolatileDomainForName:NSArgumentDomain];
        }

        [pasteboard declareTypes:@[ (NSString *)kUTTypeFileURL ] owner:nil];
        [pasteboard setData:pathData forType:(NSString *)kUTTypeFileURL];
        expect([[pasteboard _dataWithoutConversionForType:(NSString *)kUTTypeFileURL securityScoped:NO] isEqualToData:pathData], "a file path URL was not returned as written");
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        [pasteboard releaseGlobally];
        return failures ? 1 : 0;
    }
}
