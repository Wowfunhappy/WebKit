/*
 * Copyright (C) 2008, 2009 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#import "config.h"
#import "ImageSourceCG.h"

#import "UTIUtilities.h"
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>

#if PLATFORM(IOS_FAMILY)
#import <MobileCoreServices/MobileCoreServices.h>
#endif

namespace WebCore {

String MIMETypeForImageType(const String& uti)
{
    return MIMETypeFromUTI(uti);
}

String preferredExtensionForImageType(const String& uti)
{
    // MAVERICKS_BACKPORT: UTTypeCopyPreferredTagWithClass may go through a registry
    // that's not fully initialized in WebContent, raising unrecognized-selector
    // on UTType class. Hardcoded fallbacks for common image UTIs avoid the crash.
    if (uti == "public.png"_s) return "png"_s;
    if (uti == "public.jpeg"_s) return "jpg"_s;
    if (uti == "public.tiff"_s) return "tiff"_s;
    if (uti == "com.compuserve.gif"_s) return "gif"_s;
    if (uti == "public.heic"_s) return "heic"_s;
    if (uti == "public.heif"_s) return "heif"_s;
    if (uti == "public.webp"_s) return "webp"_s;
    if (uti == "public.svg-image"_s || uti == "public.svg+xml"_s) return "svg"_s;
    if (uti == "com.microsoft.bmp"_s) return "bmp"_s;
    if (uti == "com.microsoft.ico"_s) return "ico"_s;
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    auto cfExt = adoptCF(UTTypeCopyPreferredTagWithClass(uti.createCFString().get(), kUTTagClassFilenameExtension));
ALLOW_DEPRECATED_DECLARATIONS_END
    if (!cfExt)
        return { };
    return String { cfExt.get() };
}

} // namespace WebCore
