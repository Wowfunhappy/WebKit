#include "cmakeconfig.h"

#include <wtf/Platform.h>
#include <JavaScriptCore/JSExportMacros.h>
#include <WebCore/PlatformExportMacros.h>
#include <pal/ExportMacros.h>

#include <WebCore/DatabaseTracker.h>
#include <WebCore/OriginLock.h>
#include <WebCore/SecurityOriginData.h>
#include <wtf/text/WTFString.h>

#import "WCExtensionDatabases.h"
#import "WCSafariStorage.h"

BOOL WCCopyExtensionWebSQLDatabases(NSString *safariDatabaseDirectory, NSString *origin, NSString *clipOrigin)
{
    auto safariOrigin = WebCore::SecurityOriginData::fromDatabaseIdentifier(String(origin));
    auto originInClip = WebCore::SecurityOriginData::fromDatabaseIdentifier(String(clipOrigin));
    if (!safariOrigin || !originInClip)
        return NO;
    auto safariTracker = WebCore::DatabaseTracker::trackerWithDatabasePath(String(safariDatabaseDirectory));
    auto names = safariTracker->databaseNames(*safariOrigin);
    if (names.isEmpty())
        return YES;
    auto& tracker = WebCore::DatabaseTracker::singleton();
    tracker.setQuota(*originInClip, safariTracker->quota(*safariOrigin));
    for (auto& name : names) {
        auto source = safariTracker->fullPathForDatabase(*safariOrigin, name, false);
        auto destination = tracker.fullPathForDatabase(*originInClip, name, true);
        if (source.isEmpty() || destination.isEmpty() || !WCCopySQLiteDatabase(source.createNSString().get(), destination.createNSString().get()))
            return NO;
    }
    return YES;
}

void WCRemoveExtensionWebSQLDatabases(NSString *clipOrigin)
{
    auto originInClip = WebCore::SecurityOriginData::fromDatabaseIdentifier(String(clipOrigin));
    if (originInClip)
        WebCore::DatabaseTracker::singleton().deleteOrigin(*originInClip);
}
