// CoreVideo: entry points modern WebKit calls that 10.9's CoreVideo does not export. The colour-space
// constants live in polyfills/shared/cv_colorimetry.c, which the deps builds compile too.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

// CVBufferCopyAttachments (macOS 12) is CVBufferGetAttachments with +1 ownership.
WK_SYSTEM_FN("CoreVideo", CFDictionaryRef, CVBufferGetAttachments, (CVBufferRef, CVAttachmentMode));
WK_POLYFILL_ABSENT("CoreVideo", CFDictionaryRef, CVBufferCopyAttachments, (CVBufferRef buffer, CVAttachmentMode mode))
{
    if (!WK_SYSTEM(CVBufferGetAttachments))
        return NULL;
    CFDictionaryRef attachments = WK_SYSTEM(CVBufferGetAttachments)(buffer, mode);
    return attachments ? CFDictionaryCreateCopy(kCFAllocatorDefault, attachments) : NULL;
}
