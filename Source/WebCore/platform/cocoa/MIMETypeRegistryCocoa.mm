// MAVERICKS_BACKPORT: real Cocoa MIMETypeRegistry implementations.
//
// The libpolyfill.a stubs for these four functions returned garbage Strings on 10.9 (corrupt
// StringImpl -> SIGSEGV 0x100000004 in commonMimeTypesMap() during YouTube's media load). Provide
// correct implementations using the LaunchServices UTType C APIs (available since 10.3) instead of
// the 11.0+ UTType class. Defining all four here means the linker resolves them from this object
// and never pulls the broken libpolyfill member.
#include "config.h"
#import "MIMETypeRegistry.h"

// MAVERICKS_BACKPORT: include the classic CoreServices UTType C APIs (10.3+) instead of the 11.0+
// UniformTypeIdentifiers / NSURLFileTypeMappings SPI used upstream.
#import <CoreServices/CoreServices.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>
#import <wtf/text/StringView.h>
#import <wtf/text/WTFString.h>

// MAVERICKS_BACKPORT: the classic UTType C APIs are deprecated on the modern SDK; wrap the file.
ALLOW_DEPRECATED_DECLARATIONS_BEGIN

namespace WebCore {

// MAVERICKS_BACKPORT: real implementation replacing the broken libpolyfill stub (see file header).
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

// MAVERICKS_BACKPORT: real implementation replacing the broken libpolyfill stub (see file header).
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

// MAVERICKS_BACKPORT: real implementation replacing the broken libpolyfill stub (see file header).
Vector<String> MIMETypeRegistry::extensionsForMIMEType(const String& type)
{
    Vector<String> extensions;
    // MAVERICKS_BACKPORT: the full tag list (UTTypeCopyAllTagsWithClass) is not used here; the preferred
    // extension is sufficient for WebCore's callers on 10.9.
    String preferred = preferredExtensionForMIMEType(type);
    if (!preferred.isEmpty())
        extensions.append(preferred);
    return extensions;
}

// MAVERICKS_BACKPORT: real implementation replacing the broken libpolyfill stub (see file header).
bool MIMETypeRegistry::isApplicationPluginMIMEType(const String& mimeType)
{
    // MAVERICKS_BACKPORT: "application plug-ins" are user-agent-provided plug-ins (the legacy
    // WebKit-ObjC WebPlugin protocol), as opposed to third-party NPAPI — only these are
    // permitted by SubframeLoader. Safari Web Clips render the clipped page through one such
    // plug-in: application/x-apple-webclip-plug-in (the WebClip.plugin bundled in the
    // Dashboard widget, loaded via WebKitLegacy's WebPluginDatabase). Allow it so the widget's
    // <embed> is treated as a loadable plug-in. (No NPAPI/third-party plug-ins are enabled.)
    return equalLettersIgnoringASCIICase(mimeType, "application/x-apple-webclip-plug-in"_s);
}

/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
bool MIMETypeRegistry::isApplicationPluginMIMEType(const String& MIMEType)
{
#if ENABLE(PDF_PLUGIN)
    // FIXME: This should test if we're actually going to use PDFPlugin,
    // but we only know that in WebKit2 at the moment. This is not a problem
    // in practice because if we don't have PDFPlugin and we go to instantiate the
    // plugin, there won't exist an application plugin supporting these MIME types.
    if (isPDFMIMEType(MIMEType))
        return true;
#else
    UNUSED_PARAM(MIMEType);
#endif

    return false;
MAVERICKS_BACKPORT */
}

// MAVERICKS_BACKPORT: the legacy CoreServices UTType C APIs used above are deprecated on the modern SDK.
ALLOW_DEPRECATED_DECLARATIONS_END
