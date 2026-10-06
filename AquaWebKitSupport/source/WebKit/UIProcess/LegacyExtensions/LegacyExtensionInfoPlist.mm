#import "config.h"
#import "LegacyExtensionInfoPlist.h"

#import <Foundation/Foundation.h>
#import <wtf/BlockPtr.h>
#import <wtf/RetainPtr.h>
#import <wtf/RunLoop.h>

namespace WebKit::LegacyExtensions {

static WebsiteAccess websiteAccess(NSData *data)
{
    WebsiteAccess access;
    if (!data)
        return access;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![plist isKindOfClass:NSDictionary.class])
        return access;
    NSDictionary *permissions = plist[@"Permissions"];
    NSDictionary *websiteAccess = [permissions isKindOfClass:NSDictionary.class] ? permissions[@"Website Access"] : nil;
    if (![websiteAccess isKindOfClass:NSDictionary.class])
        return access;
    NSString *level = websiteAccess[@"Level"];
    if ([level isEqual:@"All"])
        access.level = WebsiteAccess::Level::All;
    else if ([level isEqual:@"Some"])
        access.level = WebsiteAccess::Level::Some;
    NSArray *domains = websiteAccess[@"Allowed Domains"];
    if ([domains isKindOfClass:NSArray.class]) {
        for (id domain in domains) {
            if ([domain isKindOfClass:NSString.class])
                access.domains.append(String(domain).convertToASCIILowercase());
        }
    }
    NSNumber *includesSecurePages = websiteAccess[@"Include Secure Pages"];
    access.includesSecurePages = [includesSecurePages isKindOfClass:NSNumber.class] && includesSecurePages.boolValue;
    return access;
}

void loadWebsiteAccess(const URL& root, CompletionHandler<void(WebsiteAccess&&)>&& completionHandler)
{
    RetainPtr request = [NSURLRequest requestWithURL:URL(root, "Info.plist"_s).createNSURL().get()];
    RetainPtr task = [NSURLSession.sharedSession dataTaskWithRequest:request.get() completionHandler:makeBlockPtr([completionHandler = WTF::move(completionHandler)](NSData *data, NSURLResponse *, NSError *) mutable {
        RunLoop::mainSingleton().dispatch([completionHandler = WTF::move(completionHandler), data = RetainPtr { data }]() mutable {
            completionHandler(websiteAccess(data.get()));
        });
    }).get()];
    [task resume];
}

} // namespace WebKit::LegacyExtensions
