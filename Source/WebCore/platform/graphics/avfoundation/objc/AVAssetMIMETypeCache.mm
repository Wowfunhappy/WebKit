// MAVERICKS_BACKPORT: the upstream AVAssetMIMETypeCache implementation is stubbed out on 10.9 because its
// typeinfo (MIMETypeCache subclass) conflicts with the -fno-rtti compile of MIMETypeCache.cpp in this build.
// Stubbed for 10.9 - typeinfo would conflict with -fno-rtti compile of MIMETypeCache.cpp
#include "config.h"
