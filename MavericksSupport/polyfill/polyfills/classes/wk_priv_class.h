// The rules for polyfills/classes/ -- Objective-C classes macOS 10.9 does not have at all (UTType,
// CABackdropLayer, NSVisualEffectView, LSDatabaseContext, ...), one file per owning framework. Each
// stub supplies as much of the class as WebKit's 10.9 code paths actually use.
//
// ONLY absent SYSTEM classes belong here, with no exceptions. A class WebKit itself owns has its source
// in this tree; if it does not build on 10.9, fix that instead of stubbing it here -- a stub of a WebKit
// class is a silent reimplementation with the wrong shape and no methods, so every message the real
// class would answer raises NSInvalidArgumentException instead.
//
// These files are the one polyfill unit built WITHOUT -fvisibility=hidden, into libpolyfill_classes.dylib,
// which is linked into every WebKit framework, so anything they define is process-global in every app
// that embeds WebKit. A category adding a method to a class 10.9 DOES have would therefore be visible to
// the host app, whose version probes would then be answered wrongly -- that is what
// mechanism/wk_selref_scope.m exists to prevent. Method polyfills go in polyfills/methods/.
//
// The dylib links Foundation, AppKit, QuartzCore, CoreServices, Security and CFNetwork, and nothing
// else: a stub's superclass must come from one of those (or be NSObject), because a classref to any
// other framework's class would put that framework on the load commands of a dylib every WebKit binary
// carries -- JavaScriptCore, the NetworkProcess and every host app included. A stub whose superclass
// lives elsewhere is built at first ask with WK_POLYFILL_CLASS_RESOLVED instead (see AVFoundation.m).
//
// These files compile against the 10.9 headers, so the modern SDK's @interface for a stubbed class is
// not in scope ("cannot find interface declaration") and a bare @implementation would produce a
// root class with no superclass. Declare a minimal @interface naming the correct superclass first, so
// the class gets real ObjC metadata.
//
// Each stub is registered in the ObjC runtime under a PRIVATE name (WKMavPolyfillPriv_<Name>) via
// objc_runtime_name, and the real system symbol _OBJC_CLASS_$_<Name> is exported as an ALIAS to it
// (WK_PRIV_CLASS / WK_PRIV_ALIAS below). WebKit's compiled classrefs bind to the aliased symbol, so
// [<Name> ...] still resolves to the stub -- but objc_getClass("<Name>") / NSClassFromString(@"<Name>") /
// objc_allocateClassPair(..., "<Name>", ...) see the system name as FREE. This keeps the stubs visible
// to WebKit while invisible to other apps in the same process: many 10.9-era apps polyfill these very
// classes themselves (e.g. Meta creates its own NSVisualEffectView via objc_allocateClassPair); with
// the stub occupying the global name, objc_allocateClassPair returns nil and objc_registerClassPair(nil)
// crashes the app at launch. For the two classes WebKit probes with NSClassFromString
// (NSVisualEffectView, _NSScrollingMomentumCalculator) the nil result is the correct 10.9 answer:
// WebKit falls back to its pre-class code path instead of using a non-functional stub. Every other stub
// (UTType, CABackdropLayer, NSPresentationIntent, ...) is reached through a compile-time [Name class] /
// _OBJC_CLASS_$_ classref, which binds to the alias, so those ARE used. A stub WebKit soft-links has to
// be findable by NAME as well, which WK_POLYFILL_CLASS (mechanism/wk_polyfill.h) provides.
//
// Two families are deliberately NOT stubbed:
//   - Classes 10.9 DOES have (CATransformLayer, NSColorPopoverController, SFCertificatePanel, ...): an
//     empty stub would shadow the genuine system class (CATransformLayer backs 3D CSS transforms).
//   - NSTouchBar and its item classes: HAVE(TOUCH_BAR) is off for the 10.9 deployment target, so WebKit
//     references none of them, and a 10.9 app that loads this WebKit and feature-detects Touch Bar via
//     NSClassFromString(@"NSTouchBar") would believe it exists and crash invoking the absent
//     -[NSResponder setTouchBar:] (observed: Dash.app aborts on launch when its nib-load path enables a
//     Touch Bar).

#ifndef WK_PRIV_CLASS_H
#define WK_PRIV_CLASS_H

#include "wk_polyfill.h"

// Place before an @interface to register the class under a private runtime name (the @interface name
// stays usable in code, so self-references like [UTType class] still compile).
#define WK_PRIV_CLASS(name) __attribute__((objc_runtime_name("WKMavPolyfillPriv_" #name)))
// Place after the matching @implementation to export the real _OBJC_CLASS_$_<name> (and metaclass)
// symbol as an alias of the privately-named class, so WebKit's classrefs bind to the stub.
#define WK_PRIV_ALIAS(name) __asm__( \
    ".globl _OBJC_CLASS_$_" #name "\n\t.set _OBJC_CLASS_$_" #name ", _OBJC_CLASS_$_WKMavPolyfillPriv_" #name "\n\t" \
    ".globl _OBJC_METACLASS_$_" #name "\n\t.set _OBJC_METACLASS_$_" #name ", _OBJC_METACLASS_$_WKMavPolyfillPriv_" #name)

#endif // WK_PRIV_CLASS_H
