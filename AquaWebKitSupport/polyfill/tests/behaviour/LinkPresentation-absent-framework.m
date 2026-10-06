// A framework 10.9 does not ship AT ALL, whose classes the layer supplies: LinkPresentation.framework
// and the LPLinkMetadata / LPFileMetadata that WKShareSheet describes navigator.share()'s URL and files
// with. PAL soft-links both classes, so the framework open is answered by the absent-provider token and
// the class lookups out of __wk_clsmap in libpolyfill_classes.dylib; this program links both images,
// the topology WebCore forms.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <unistd.h>

@interface LPSpecializationMetadata : NSObject <NSSecureCoding, NSCopying>
@end

@interface LPFileMetadata : LPSpecializationMetadata
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, assign) uint64_t size;
@end

@interface LPLinkMetadata : NSObject <NSSecureCoding, NSCopying>
@property (nonatomic, retain) NSURL *originalURL;
@property (nonatomic, retain) NSURL *URL;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) LPSpecializationMetadata *specialization;
- (void)_setIncomplete:(BOOL)incomplete;
@end

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

int main(void)
{
    @autoreleasepool {
        check(access("/System/Library/Frameworks/LinkPresentation.framework", F_OK) != 0,
            "this system ships no LinkPresentation.framework, so the premise holds");
        void *handle = dlopen("/System/Library/Frameworks/LinkPresentation.framework/LinkPresentation", RTLD_NOW);
        check(handle != NULL, "dlopen of the absent framework answers with a handle");

        Class linkMetadataClass = objc_getClass("LPLinkMetadata");
        Class fileMetadataClass = objc_getClass("LPFileMetadata");
        check(linkMetadataClass != Nil && fileMetadataClass != Nil, "objc_getClass finds both classes across images");
        check([fileMetadataClass isSubclassOfClass:objc_getClass("LPSpecializationMetadata")], "LPFileMetadata is a specialization");

        NSURL *url = [NSURL URLWithString:@"https://webkit.org/"];
        LPLinkMetadata *metadata = [[[linkMetadataClass alloc] init] autorelease];
        [metadata setOriginalURL:url];
        [metadata setURL:url];
        NSMutableString *title = [NSMutableString stringWithString:@"WebKit"];
        [metadata setTitle:title];
        [title appendString:@" changed"];
        [metadata _setIncomplete:YES];
        check([[metadata URL] isEqual:url] && [[metadata originalURL] isEqual:url], "the URLs read back");
        check([[metadata title] isEqualToString:@"WebKit"], "the title is copied on set");

        LPFileMetadata *file = [[[fileMetadataClass alloc] init] autorelease];
        [file setName:@"hello"];
        [file setType:@"public.plain-text"];
        [file setSize:12];
        [metadata setSpecialization:file];
        LPFileMetadata *specialization = (LPFileMetadata *)[metadata specialization];
        check(specialization != file && [[specialization name] isEqualToString:@"hello"] && [[specialization type] isEqualToString:@"public.plain-text"] && [specialization size] == 12,
            "the specialization is copied on set with its file details");

        LPLinkMetadata *copy = [[metadata copy] autorelease];
        check([[copy title] isEqualToString:@"WebKit"] && [[copy URL] isEqual:url] && [(LPFileMetadata *)[copy specialization] size] == 12, "a copy carries every property");

        NSMutableData *data = [NSMutableData data];
        NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:data] autorelease];
        [archiver setRequiresSecureCoding:YES];
        [archiver encodeObject:metadata forKey:NSKeyedArchiveRootObjectKey];
        [archiver finishEncoding];
        NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingWithData:data] autorelease];
        [unarchiver setRequiresSecureCoding:YES];
        LPLinkMetadata *decoded = [unarchiver decodeObjectOfClass:linkMetadataClass forKey:NSKeyedArchiveRootObjectKey];
        LPFileMetadata *decodedFile = (LPFileMetadata *)[decoded specialization];
        check([[decoded title] isEqualToString:@"WebKit"] && [[decoded originalURL] isEqual:url] && [[decodedFile name] isEqualToString:@"hello"] && [decodedFile size] == 12,
            "a secure archive round-trips the metadata and its specialization");
    }
    return failures ? 1 : 0;
}
