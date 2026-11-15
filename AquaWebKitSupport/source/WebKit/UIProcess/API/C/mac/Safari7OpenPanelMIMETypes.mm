// Safari 7 (Safari::BrowserPageUIClient::runOpenPanel) builds an open panel's file filter from its accepted MIME types alone.
// It filters the panel by the union of the extensions it finds for them: for a "major/*" type, those Foundation's types.plist
// lists under major/; for any other type, -[NSURLFileTypeMappings extensionsForMIMEType:]. An empty union sets no filter.
// types.plist lists no m4a, mp4 or m4v under audio/ or video/.
//
// Safari is handed the page's types plus, for each extension modern Safari filters by (allowedFileExtensions()), the MIME
// type NSURLFileTypeMappings gives that extension and maps back to it. They are added when Safari's filter over the page's
// types is non-empty, or when the page names only extensions and each maps that way, so the panel offers every file it
// offers without them.

#import "config.h"
#import "Safari7OpenPanelMIMETypes.h"

#if PLATFORM(MAC)

#import "APIArray.h"
#import "APIOpenPanelParameters.h"
#import <pal/spi/cocoa/NSURLFileTypeMappingsSPI.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/ObjCRuntimeExtras.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>

namespace WebKit {

// Safari's own table: "major/*" -> every extension types.plist lists under a MIME type of that major type.
static NSDictionary<NSString *, NSSet<NSString *> *> *wildcardExtensions()
{
    static NeverDestroyed<RetainPtr<NSDictionary>> table = [] {
        RetainPtr table = adoptNS([[NSMutableDictionary alloc] init]);
        RetainPtr<NSString> path = [[NSBundle bundleForClass:[NSURLFileTypeMappings class]] pathForResource:@"types" ofType:@"plist"];
        RetainPtr<NSDictionary> types = path ? [NSDictionary dictionaryWithContentsOfFile:path.get()] : nil;
        [types.get() enumerateKeysAndObjectsUsingBlock:^(id type, id extensions, BOOL *) {
            if (![type isKindOfClass:[NSString class]] || ![extensions isKindOfClass:[NSArray class]])
                return;
            RetainPtr wildcard = [NSString stringWithFormat:@"%@/*", [type componentsSeparatedByString:@"/"].firstObject];
            RetainPtr<NSMutableSet> set = [table.get() objectForKey:wildcard.get()];
            if (!set) {
                set = adoptNS([[NSMutableSet alloc] init]);
                [table.get() setObject:set.get() forKey:wildcard.get()];
            }
            [set.get() addObjectsFromArray:extensions];
        }];
        return RetainPtr<NSDictionary> { table.get() };
    }();
    return table.get().get();
}

// WebKit's sends of these selectors reach the polyfills in polyfill/polyfills/methods/Foundation.m, which add the types
// this OS's LaunchServices lacks; Safari's reach Foundation. Selectors looked up by name here reach Foundation too.
static NSArray<NSString *> *safariExtensionsForMIMEType(NSString *mimeType)
{
    return wtfObjCMsgSend<NSArray<NSString *> *>([NSURLFileTypeMappings sharedMappings], sel_registerName("extensionsForMIMEType:"), mimeType);
}

static NSString *safariMIMETypeForExtension(NSString *extension)
{
    return wtfObjCMsgSend<NSString *>([NSURLFileTypeMappings sharedMappings], sel_registerName("MIMETypeForExtension:"), extension);
}

static bool safariFindsExtensions(const String& mimeType)
{
    RetainPtr type = mimeType.createNSString();
    if ([type.get() hasSuffix:@"*"])
        return [[wildcardExtensions() objectForKey:type.get()] count];
    return [safariExtensionsForMIMEType(type.get()) count];
}

// The MIME type Foundation gives |extension| when Foundation maps that type back to |extension|.
static String mimeTypeMappingBack(const String& extension)
{
    RetainPtr ext = extension.createNSString();
    RetainPtr<NSString> mimeType = safariMIMETypeForExtension(ext.get());
    if (![mimeType.get() length])
        return { };
    for (NSString *candidate in safariExtensionsForMIMEType(mimeType.get())) {
        if ([candidate caseInsensitiveCompare:ext.get()] == NSOrderedSame)
            return mimeType.get();
    }
    return { };
}

Vector<String> safari7OpenPanelMIMETypes(const API::OpenPanelParameters& parameters)
{
    auto mimeTypes = parameters.acceptMIMETypes()->toStringVector();
    bool safariFilters = mimeTypes.containsIf(safariFindsExtensions);

    Vector<String> additions;
    bool everyExtensionMaps = true;
    for (auto& extension : parameters.allowedFileExtensions()->toStringVector()) {
        auto mimeType = mimeTypeMappingBack(extension);
        if (mimeType.isEmpty())
            everyExtensionMaps = false;
        else
            additions.appendIfNotContains(mimeType);
    }

    if (safariFilters || (mimeTypes.isEmpty() && everyExtensionMaps)) {
        for (auto& mimeType : additions)
            mimeTypes.appendIfNotContains(mimeType);
    }
    return mimeTypes;
}

}

#endif
