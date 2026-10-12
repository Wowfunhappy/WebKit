#import "config.h"
#import "LegacyExtensionInfoPlist.h"

#import "WebExtensionControllerConfiguration.h"
#import <Foundation/Foundation.h>
#import <wtf/FileSystem.h>
#import <wtf/BlockPtr.h>
#import <wtf/RetainPtr.h>
#import <wtf/RunLoop.h>
#import <wtf/cocoa/SpanCocoa.h>

namespace WebKit::LegacyExtensions {

static WebsiteAccess websiteAccess(NSDictionary *plist)
{
    WebsiteAccess access;
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

// An entry with a WebExtension manifest's keys, as the manifest's JSON.
static RefPtr<JSON::Object> manifestEntry(NSDictionary *plist, NSString *key)
{
    NSDictionary *entry = plist[key];
    if (![entry isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:entry])
        return nullptr;
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    RefPtr value = json ? JSON::Value::parseJSON(String::fromUTF8(span(json))) : nullptr;
    return value ? value->asObject() : nullptr;
}

void loadInfoPlist(const URL& root, CompletionHandler<void(InfoPlist&&)>&& completionHandler)
{
    RetainPtr request = [NSURLRequest requestWithURL:URL(root, "Info.plist"_s).createNSURL().get()];
    RetainPtr task = [NSURLSession.sharedSession dataTaskWithRequest:request.get() completionHandler:makeBlockPtr([completionHandler = WTF::move(completionHandler)](NSData *data, NSURLResponse *, NSError *) mutable {
        RunLoop::mainSingleton().dispatch([completionHandler = WTF::move(completionHandler), data = RetainPtr { data }]() mutable {
            InfoPlist infoPlist;
            NSDictionary *plist = data ? [NSPropertyListSerialization propertyListWithData:data.get() options:NSPropertyListImmutable format:nil error:nil] : nil;
            if ([plist isKindOfClass:NSDictionary.class]) {
                infoPlist.websiteAccess = websiteAccess(plist);
                infoPlist.declarativeNetRequest = manifestEntry(plist, @"declarative_net_request");
                infoPlist.mimeTypesHandler = manifestEntry(plist, @"mime_types_handler");
            }
            completionHandler(WTF::move(infoPlist));
        });
    }).get()];
    [task resume];
}

String storageDirectory(const String& extensionKey)
{
    return FileSystem::pathByAppendingComponent(WebExtensionControllerConfiguration::createDefault()->storageDirectory(), extensionKey);
}

} // namespace WebKit::LegacyExtensions
