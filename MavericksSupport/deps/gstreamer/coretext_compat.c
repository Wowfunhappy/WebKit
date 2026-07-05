// CoreText compatibility shim for the vendored GStreamer (Cerbero 1.26.6, deploy
// target 10.13; see PROVENANCE.txt). The vendored libharfbuzz's CoreText shaper backend imports two
// OpenType-feature dictionary-key constants that postdate 10.9:
//
//   kCTFontOpenTypeFeatureTag    (10.10+)
//   kCTFontOpenTypeFeatureValue  (10.10+)
//
// They are non-lazy data symbols, so dlopen() of any plugin that pulls in libharfbuzz
// (libgstassrender / libgstclosedcaption / libgstpango, i.e. subtitle and text-overlay rendering)
// fails on 10.9 with "Symbol not found: _kCTFontOpenTypeFeatureTag" and the plugin never registers.
//
// This shim REEXPORTS the real CoreText framework (so every CoreText symbol libharfbuzz actually uses
// on 10.9 still resolves) and DEFINES exactly those two gap constants. They are the dictionary keys
// libharfbuzz puts in a kCTFontFeatureSettingsAttribute array to request OpenType features; 10.9's
// CoreText predates that API and simply ignores unrecognized keys, so text still shapes and renders —
// it just falls back from the OpenType-tag feature path to default shaping (fine for caption text).
// The string values match the 10.10+ CoreText constants for forward-correctness. install-safari7.sh
// repoints libharfbuzz's CoreText dependency to @rpath/libcoretext_compat.dylib, so the existing
// two-level bind ordinals resolve on 10.9 with no flat-namespace games — mirroring
// libcoreservices_compat.dylib for CoreServices and libsystem_compat.dylib for libSystem.

#include <CoreFoundation/CoreFoundation.h>

const CFStringRef kCTFontOpenTypeFeatureTag = CFSTR("CTFeatureOpenTypeTag");
const CFStringRef kCTFontOpenTypeFeatureValue = CFSTR("CTFeatureOpenTypeValue");
