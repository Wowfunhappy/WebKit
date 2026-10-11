#ifndef WK_ICC_H
#define WK_ICC_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

// The profile as 10.9's ColorSync reads it correctly: each parametric curve of an lutAToB or lutBToA tag
// sampled. The profile itself when it has none; NULL for NULL.
CFDataRef wk_iccProfileForColorSync(CFDataRef profile) CF_RETURNS_RETAINED;

// The bytes a caller built the space from, when ColorSync was given a sampled profile in their place; NULL
// otherwise. The space answers for its profile with these.
CFDataRef wk_iccOriginalProfile(CGColorSpaceRef space);

#endif // WK_ICC_H
