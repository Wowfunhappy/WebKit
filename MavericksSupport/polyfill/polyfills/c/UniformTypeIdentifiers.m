// UniformTypeIdentifiers: constants modern WebKit references from a framework 10.9 does not ship at all.
// The UTType class itself is stubbed in classes/UniformTypeIdentifiers.m.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>

typedef NSString *PolyNSStringConst;

// --- UniformTypeIdentifiers tag-class names (11.0+) ----------------------------------------
// The modern framework's UTTagClass* object constants carry the same string values the classic
// LaunchServices kUTTagClass* CFStringRefs (present on 10.9) have carried since 10.3 — so the classic
// C API accepts these values directly, which is how the UTType stub in classes/UniformTypeIdentifiers.m consumes them.
// Upstream references the constant directly (WebCoreURLResponse's typeWithTag:tagClass:, MIMETypeRegistry's
// tags dictionary lookup); without a definition the reference is a weak dynamic lookup that silently
// resolves to nil on this OS, turning those lookups into nil-keyed no-ops.
WK_POLYFILL_CONST("UniformTypeIdentifiers", PolyNSStringConst, UTTagClassFilenameExtension, @"public.filename-extension");
