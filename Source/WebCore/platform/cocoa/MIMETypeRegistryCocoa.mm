// macOS 10.9 backport: real Cocoa MIMETypeRegistry implementations.
//
// The libpolyfill.a stubs for these four functions returned garbage Strings on 10.9 (corrupt
// StringImpl -> SIGSEGV 0x100000004 in commonMimeTypesMap() during YouTube's media load). Provide
// correct implementations using the LaunchServices UTType C APIs (available since 10.3) instead of
// the 11.0+ UTType class. Defining all four here means the linker resolves them from this object
// and never pulls the broken libpolyfill member.
#include "config.h"
#import "MIMETypeRegistry.h"

#import <CoreServices/CoreServices.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>
#import <wtf/text/StringView.h>
#import <wtf/text/WTFString.h>

ALLOW_DEPRECATED_DECLARATIONS_BEGIN

namespace WebCore {

String MIMETypeRegistry::mimeTypeForExtension(StringView extension)
{
    if (extension.isEmpty())
        return String();
    RetainPtr<CFStringRef> ext = extension.toString().createCFString();
    if (!ext)
        return String();
    RetainPtr<CFStringRef> uti = adoptCF(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext.get(), nullptr));
    if (!uti)
        return String();
    RetainPtr<CFStringRef> mimeType = adoptCF(UTTypeCopyPreferredTagWithClass(uti.get(), kUTTagClassMIMEType));
    return mimeType ? String(mimeType.get()) : String();
}

String MIMETypeRegistry::preferredExtensionForMIMEType(const String& type)
{
    if (type.isEmpty())
        return String();
    RetainPtr<CFStringRef> mime = type.createCFString();
    if (!mime)
        return String();
    RetainPtr<CFStringRef> uti = adoptCF(UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mime.get(), nullptr));
    if (!uti)
        return String();
    RetainPtr<CFStringRef> extension = adoptCF(UTTypeCopyPreferredTagWithClass(uti.get(), kUTTagClassFilenameExtension));
    return extension ? String(extension.get()) : String();
}

Vector<String> MIMETypeRegistry::extensionsForMIMEType(const String& type)
{
    // The full tag list (UTTypeCopyAllTagsWithClass) is not used here; the preferred extension is
    // sufficient for WebCore's callers on 10.9.
    Vector<String> extensions;
    String preferred = preferredExtensionForMIMEType(type);
    if (!preferred.isEmpty())
        extensions.append(preferred);
    return extensions;
}

bool MIMETypeRegistry::isApplicationPluginMIMEType(const String&)
{
    // No application plug-ins on this 10.9 backport.
    return false;
}

}

ALLOW_DEPRECATED_DECLARATIONS_END
