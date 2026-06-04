/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "WebKit2Initialize.h"

#import <JavaScriptCore/InitializeThreading.h>
#import <WebCore/CommonAtomStrings.h>
#import <WebCore/WebCoreJITOperations.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mutex>
#import <wtf/MainThread.h>
#import <wtf/RefCounted.h>
#import <wtf/WorkQueue.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

#if PLATFORM(IOS_FAMILY)
#import <WebCore/WebCoreThreadSystemInterface.h>
#endif

#if ENABLE(LLVM_PROFILE_GENERATION)
#if PLATFORM(IOS_FAMILY)
#import <wtf/LLVMProfilingUtils.h>
extern "C" char __llvm_profile_filename[] = "%t/WebKitPGO/WebKit_%m_pid%p%c.profraw";
#else
extern "C" char __llvm_profile_filename[] = "/private/tmp/WebKitPGO/WebKit_%m_pid%p%c.profraw";
#endif
#endif

#if USE(GCRYPT)
#include <pal/crypto/gcrypt/Initialization.h>
#endif

namespace WebKit {

static std::once_flag flag;
static BOOL g_didFireAutoLoad = NO;

enum class WebKitProfileTag { };

static void runInitializationCode(void* = nullptr)
{
    // On 10.9, the WebContent XPC service calls this from the XPC event handler
    // thread, which is not the main thread. Skip the assert.
    // RELEASE_ASSERT_WITH_MESSAGE([NSThread isMainThread], "InitializeWebKit2 should be called on the main thread");

    WTF::initializeMainThread();

    // WebKit and JavaScriptCore each have their own statically-linked copy of WTF.
    // The local WTF::initializeMainThread() above only initialises WebKit's copy
    // (sets WebKit's RunLoop::s_mainRunLoop). But many WebKit call sites
    // resolve WTF::RunLoop::mainSingleton() through the dyld stub to the
    // exported JavaScriptCore copy, whose s_mainRunLoop would otherwise stay
    // null. Look up the JSC copy by symbol and call it explicitly so both
    // copies of the global state are in a consistent state.
    {
        if (void* jsc = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore", RTLD_NOLOAD | RTLD_LAZY)) {
            using InitFn = void (*)();
            if (auto fn = reinterpret_cast<InitFn>(dlsym(jsc, "_ZN3WTF20initializeMainThreadEv"))) {
                if (reinterpret_cast<void*>(fn) != reinterpret_cast<void*>(&WTF::initializeMainThread))
                    fn();
            }
        }
    }

    // 10.9 perf: removed debug fopen logging
    JSC::initialize();
    // 10.9 perf: removed debug fopen logging
    WebCore::initializeCommonAtomStrings();
    // 10.9 perf: removed debug fopen logging
#if PLATFORM(IOS_FAMILY)
    InitWebCoreThreadSystemInterface();
#endif

    WTF::RefCountDebuggerBase::enableThreadingChecksGlobally();

    WebCore::populateJITOperations();

#if USE(GCRYPT)
    // 10.9 backport: UIProcess calls wrapSerializedCryptoKey through the
    // libgcrypt path too (see WebPageProxy.cpp / WebProcessProxy.cpp).
    // gcry_check_version must run before any other libgcrypt call.
    PAL::GCrypt::initialize();
#endif

}

void InitializeWebKit2()
{
    // 10.9 perf: removed debug fopen logging
    std::call_once(flag, [] {
        // 10.9 perf: removed debug fopen logging
        runInitializationCode();
        // 10.9 perf: removed debug fopen logging

        // 10.9 backport: Safari launched directly (without LaunchServices) doesn't get the
        // kAEOpenApplication Apple Event, so it never calls applicationOpenUntitledFile: and
        // never opens a window with the home page. After NSApp finishes launching, send
        // openLocation: to NSApp's first responder chain, which makes Safari open a new window.
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"com.apple.Safari"]) {
            FILE *_f=((FILE*)0);
            if(_f){fprintf(_f,"[PID %d] Detected Safari UI process — installing auto-open hook\n",getpid());fclose(_f);}

            [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *) {
                // 10.9 backport: only fire if SAFARI_AUTOOPEN_URL is set in env.
                // Without that env var, skip the auto-load entirely — Safari will
                // either be launched via `open -a Safari URL` (URL passed via AE)
                // or the user will manually navigate via Cmd+L. The auto-load to
                // example.com was a workaround that caused Cmd+A→Cmd+C to navigate
                // the user-loaded page to example.com (notification fires multiple
                // times, e.g. when a 2nd WebContent process spawns).
                if (!getenv("SAFARI_AUTOOPEN_URL"))
                    return;
                if (g_didFireAutoLoad) return;
                g_didFireAutoLoad = YES;
                FILE *_f=((FILE*)0);
                if(_f){fprintf(_f,"[PID %d] Safari did finish launching — scheduling openLocation:\n",getpid());fclose(_f);}
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    FILE *_g=((FILE*)0);
                    if(_g){fprintf(_g,"[PID %d] Triggering newDocument: then loading URL\n",getpid());fclose(_g);}
                    @try {
                        // 10.9 backport: only call newDocument: if Safari has no existing windows yet.
                        // Otherwise we spawn a 2nd WebContent process and the URL load races against an
                        // unwired connection. If session-restored window exists, just navigate it.
                        NSArray *existingWindows = [NSApp orderedWindows];
                        BOOL hasExisting = NO;
                        for (NSWindow *w in existingWindows) {
                            if ([w isVisible]) { hasExisting = YES; break; }
                        }
                        BOOL ok = NO;
                        if (!hasExisting) {
                            ok = [NSApp sendAction:@selector(newDocument:) to:nil from:nil];
                        }
                        FILE *_g2=((FILE*)0);
                        if(_g2){fprintf(_g2,"[PID %d]   hasExisting=%d sendAction:newDocument: = %d\n",getpid(),(int)hasExisting,(int)ok);fclose(_g2);}

                        // Then send the load-URL action via a delayed dispatch so the window's
                        // main controller is fully wired up before we ask it to navigate.
                        // 10.9 backport: only auto-load a URL if SAFARI_AUTOOPEN_URL was set
                        // or we created a new doc (hasExisting=false means no URL was passed).
                        // If Safari was launched via `open -a Safari URL`, LaunchServices will
                        // deliver the URL through the kAEOpenURL event — auto-loading would
                        // cause a race against that navigation, killing the requested page.
                        const char *envURL = getenv("SAFARI_AUTOOPEN_URL");
                        if (!envURL && hasExisting) {
                            FILE *_g4=((FILE*)0);
                            if(_g4){fprintf(_g4,"[PID %d] Skipping auto-open URL — no env, hasExisting (URL likely passed via open)\n",getpid());fclose(_g4);}
                            return;
                        }
                        NSString *url = envURL ? @(envURL) : @"about:blank";
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            FILE *_g3=((FILE*)0);
                            if(_g3){fprintf(_g3,"[PID %d] Loading URL %s into Safari window\n",getpid(),url.UTF8String);fclose(_g3);}
                            @try {
                                // 10.9 backport: prefer the FIRST visible window (the initial one, with a wired-up WebContent)
                                // over the keyWindow (which may be a freshly-spawned 2nd window with no NetworkProcess connection).
                                NSWindow *keyWin = nil;
                                for (NSWindow *w in [NSApp orderedWindows]) {
                                    if ([w isVisible] && w.windowController) { keyWin = w; break; }
                                }
                                if (!keyWin) keyWin = [NSApp keyWindow] ?: [[NSApp orderedWindows] firstObject];
                                id wc = keyWin.windowController;
                                FILE *_glog=((FILE*)0);
                                if(_glog){fprintf(_glog,"[PID %d]   keyWin=%p wc=%p wc class=%s\n",getpid(),keyWin,wc,object_getClassName(wc));fclose(_glog);}

                                // 10.9 backport: navigate the existing WKWebView/WKView directly to avoid
                                // Safari's window-controller logic spawning a new WebContent process.
                                NSURL *nsURL = [NSURL URLWithString:url];

                                // Walk view hierarchy looking for the WKView/WKWebView already wired up.
                                NSView *(^findWebView)(NSView *) = nil;
                                __block NSView *(^findWebViewBlock)(NSView *) = ^NSView *(NSView *v) {
                                    Class wkv = NSClassFromString(@"WKView");
                                    Class wkwv = NSClassFromString(@"WKWebView");
                                    if ((wkv && [v isKindOfClass:wkv]) || (wkwv && [v isKindOfClass:wkwv]))
                                        return v;
                                    for (NSView *sub in v.subviews) {
                                        NSView *r = findWebViewBlock(sub);
                                        if (r) return r;
                                    }
                                    return nil;
                                };
                                findWebView = findWebViewBlock;

                                NSView *webView = findWebView(keyWin.contentView);
                                FILE *_glogwv=((FILE*)0);
                                if(_glogwv){fprintf(_glogwv,"[PID %d]   webView=%p class=%s\n", getpid(), webView, webView ? object_getClassName(webView) : "(null)");fclose(_glogwv);}

                                // Enumerate all methods of wc that contain "URL" or "load" or "navigate" or "goTo".
                                if (wc) {
                                    Class cls = [wc class];
                                    while (cls && cls != [NSResponder class]) {
                                        unsigned int n = 0;
                                        Method *methods = class_copyMethodList(cls, &n);
                                        FILE *_g=((FILE*)0);
                                        if(_g){fprintf(_g,"[PID %d]   wc class=%s has %u methods\n", getpid(), class_getName(cls), n);fclose(_g);}
                                        for (unsigned int i = 0; i < n; i++) {
                                            const char *name = sel_getName(method_getName(methods[i]));
                                            if (strstr(name, "URL") || strstr(name, "oad") || strstr(name, "avigat") || strstr(name, "oTo")) {
                                                FILE *_g2=((FILE*)0);
                                                if(_g2){fprintf(_g2,"[PID %d]     method: %s\n", getpid(), name);fclose(_g2);}
                                            }
                                        }
                                        free(methods);
                                        cls = class_getSuperclass(cls);
                                    }
                                }

                                // First, try setting the unified field (URL bar) and going to it. This typically
                                // navigates the CURRENT tab without spawning a new WKView/WebContent.
                                if (wc) {
                                    SEL setURLSel = NSSelectorFromString(@"setUnifiedFieldText:");
                                    SEL goUnifiedSel = NSSelectorFromString(@"goToUnifiedFieldURL:");
                                    SEL setUF2Sel = NSSelectorFromString(@"safariBrowserWindowUnifiedFieldURLDidChange:");
                                    FILE *_g4=((FILE*)0);
                                    if(_g4){fprintf(_g4,"[PID %d]   wc respondsTo setUnifiedFieldText:=%d goToUnifiedFieldURL:=%d _goToUnifiedFieldURLWithWindowPolicy:=%d\n",getpid(),(int)[wc respondsToSelector:setURLSel],(int)[wc respondsToSelector:goUnifiedSel],(int)[wc respondsToSelector:NSSelectorFromString(@"_goToUnifiedFieldURLWithWindowPolicy:")]);fclose(_g4);}
                                    SEL goWP = NSSelectorFromString(@"_goToUnifiedFieldURLWithWindowPolicy:");
                                    if ([wc respondsToSelector:goWP]) {
                                        // First, set the URL bar to our target (use a sender like nil which is from the URL bar).
                                        // Method signature: void _goToUnifiedFieldURLWithWindowPolicy: takes a windowPolicy.
                                        // We'd need to first put the URL into the unified field. Try goToActivatedCompletionListURL:.
                                        // _tryMultipleURLs:windowPolicy: caused a segfault (wrong arg types?). Skip.
                                    }
                                }

                                // Try _goToURL:windowPolicy:tabPlacementHint: with current-tab policy.
                                if (wc) {
                                    SEL goSel = NSSelectorFromString(@"_goToURL:windowPolicy:tabPlacementHint:");
                                    if ([wc respondsToSelector:goSel]) {
                                        NSMethodSignature *sig = [wc methodSignatureForSelector:goSel];
                                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                                        [inv setSelector:goSel];
                                        [inv setTarget:wc];
                                        [inv setArgument:&nsURL atIndex:2];
                                        // windowPolicy: try 0 (current tab/window).
                                        unsigned long windowPolicy = 0;
                                        unsigned long tabPlacementHint = 0;
                                        [inv setArgument:&windowPolicy atIndex:3];
                                        [inv setArgument:&tabPlacementHint atIndex:4];
                                        @try {
                                            [inv invoke];
                                            FILE *_gd=((FILE*)0);
                                            if(_gd){fprintf(_gd,"[PID %d]   _goToURL:windowPolicy:0:tabPlacementHint:0 invoked\n",getpid());fclose(_gd);}
                                            return;
                                        } @catch (NSException *e) {
                                            FILE *_ge=((FILE*)0);
                                            if(_ge){fprintf(_ge,"[PID %d]   _goToURL:windowPolicy:tabPlacementHint: threw: %s\n",getpid(),[[e description] UTF8String]);fclose(_ge);}
                                        }
                                    } else {
                                        FILE *_gd=((FILE*)0);
                                        if(_gd){fprintf(_gd,"[PID %d]   wc does NOT respond to _goToURL:windowPolicy:tabPlacementHint:\n",getpid());fclose(_gd);}
                                    }
                                }
                                (void)webView;

                                // Fallback to original tryGoToURL: path if direct navigation failed.
                                SEL tryGoSel = NSSelectorFromString(@"tryGoToURL:withTabLabel:");
                                if (wc && [wc respondsToSelector:tryGoSel]) {
                                    NSMethodSignature *sig = [wc methodSignatureForSelector:tryGoSel];
                                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                                    [inv setSelector:tryGoSel];
                                    [inv setTarget:wc];
                                    [inv setArgument:&nsURL atIndex:2];
                                    NSString *label = nil;
                                    [inv setArgument:&label atIndex:3];
                                    @try {
                                        [inv invoke];
                                        FILE *_gd=((FILE*)0);
                                        if(_gd){fprintf(_gd,"[PID %d]   tryGoToURL:withTabLabel: fallback invoked\n",getpid());fclose(_gd);}
                                        return;
                                    } @catch (NSException *e) {
                                        FILE *_ge=((FILE*)0);
                                        if(_ge){fprintf(_ge,"[PID %d]   tryGoToURL: threw: %s\n",getpid(),[[e description] UTF8String]);fclose(_ge);}
                                    }
                                }

                                // Schedule a delayed layer tree dump to see what Safari has.
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                                               dispatch_get_main_queue(), ^{
                                    FILE *_d=((FILE*)0);
                                    if (!_d) return;
                                    fprintf(_d, "=== Safari layer dump PID %d ===\n", getpid());
                                    NSWindow *win = [NSApp keyWindow] ?: [[NSApp orderedWindows] firstObject];
                                    fprintf(_d, "Key window: %s frame=%gx%g\n", [[win description] UTF8String], win.frame.size.width, win.frame.size.height);
                                    void (^dumpLayer)(CALayer *, int);
                                    __block void (^dumpLayerBlock)(CALayer *, int) = ^(CALayer *l, int depth) {
                                        char indent[128] = {0}; for (int i = 0; i < depth*2 && i < 124; ++i) indent[i] = ' ';
                                        const char *cType = "nil";
                                        size_t nz = 0; size_t lw = 0, lh = 0;
                                        if (l.contents) {
                                            CFTypeID t = CFGetTypeID((CFTypeRef)l.contents);
                                            if (t == IOSurfaceGetTypeID()) {
                                                cType = "IOSurface";
                                                IOSurfaceRef s = (__bridge IOSurfaceRef)l.contents;
                                                lw = IOSurfaceGetWidth(s); lh = IOSurfaceGetHeight(s);
                                                IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
                                                uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(s);
                                                size_t bpr = IOSurfaceGetBytesPerRow(s);
                                                for (size_t y = 0; y < lh && y < 100; ++y)
                                                    for (size_t x = 0; x < lw; ++x) {
                                                        uint32_t px = *(uint32_t*)(base + y*bpr + x*4);
                                                        if (px && px != 0xFFFFFFFF) nz++;
                                                    }
                                                IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
                                            } else cType = "other";
                                        }
                                        fprintf(_d, "%s%s bounds=%gx%g pos=(%g,%g) hidden=%d contents=%s%s",
                                            indent, object_getClassName(l), l.bounds.size.width, l.bounds.size.height,
                                            l.position.x, l.position.y, l.hidden, cType,
                                            cType[0]=='I' ? "" : "");
                                        if (cType[0]=='I')
                                            fprintf(_d, " %zux%zu nonZero=%zu", lw, lh, nz);
                                        fprintf(_d, "\n");
                                        if (depth < 10) for (CALayer *c in l.sublayers) dumpLayerBlock(c, depth+1);
                                    };
                                    NSView *cv = (NSView *)win.contentView;
                                    if (cv.layer) dumpLayerBlock(cv.layer, 0);
                                    else fprintf(_d, "no contentView.layer\n");
                                    fclose(_d);
                                });
                            } @catch (NSException *e) {
                                FILE *_h=((FILE*)0);
                                if(_h){fprintf(_h,"[PID %d] goToURL threw: %s\n",getpid(),[[e description] UTF8String]);fclose(_h);}
                            }
                        });
                    } @catch (NSException *e) {
                        FILE *_h=((FILE*)0);
                        if(_h){fprintf(_h,"[PID %d] newDocument: threw: %s\n",getpid(),[[e description] UTF8String]);fclose(_h);}
                    }
                });
            }];
        }
    });
    // 10.9 perf: removed debug fopen logging
}

}
