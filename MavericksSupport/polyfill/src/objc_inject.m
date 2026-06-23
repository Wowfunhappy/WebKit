// Mavericks ObjC method injection — adds AppKit/Foundation methods the 10.9 runtime lacks, so
// upstream WebKit can call them unguarded instead of carrying a `respondsToSelector:` 10.9 fork at
// each site. The +load runs once (this object is force-loaded ONLY into JavaScriptCore via
// libpolyfill_classes.a), before WebCore/WebKit use these classes.
//
// VALUES: prefer a SEMANTIC 10.9 equivalent (a real NSColor that still exists and adapts) over a
// frozen literal — controlTextColor for labelColor, disabledControlTextColor for secondaryLabelColor,
// etc. Hardcoded sRGB is used only for the system *tint* palette (systemBlue…systemYellow) and the
// fill hierarchy, which have no 10.9 equivalent concept; those constants are Apple's documented
// values. A semantic color has one correct meaning, so injecting it is correct at every caller
// (a drag label, a datalist field, RenderThemeMac's CSS system-color map) — no per-site conflict.
//
// DISCIPLINE: inject ONLY genuine backport divergences (diff-verified vs upstream 83b24ce), and
// only methods absent on 10.9. addInstance/addClass never overwrite a method the class already has,
// so colors that DO exist on 10.9 (headerTextColor, selectedTextColor, gridColor, …) are untouched.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdio.h>

#define SRGB(r, g, b, a) [NSColor colorWithSRGBRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:(a)/255.0]

static void addInstance(Class cls, SEL sel, IMP imp, const char *types)
{
    if (cls && !class_getInstanceMethod(cls, sel))
        class_addMethod(cls, sel, imp, types);
}
static void addClass(Class cls, SEL sel, IMP imp, const char *types)
{
    if (cls && !class_getClassMethod(cls, sel))
        class_addMethod(object_getClass(cls), sel, imp, types);
}

// --- NSColor label hierarchy (10.10+/10.14+): map to the 10.9 control-text semantics. ---
static id mav_labelColor(id s, SEL c)                  { return [NSColor controlTextColor]; }
static id mav_secondaryLabelColor(id s, SEL c)         { return [NSColor disabledControlTextColor]; }
static id mav_tertiaryLabelColor(id s, SEL c)          { return [NSColor disabledControlTextColor]; }
static id mav_quaternaryLabelColor(id s, SEL c)        { return [NSColor gridColor]; }
static id mav_quinaryLabelColor(id s, SEL c)           { return [NSColor gridColor]; }
static id mav_placeholderTextColor(id s, SEL c)        { return [NSColor disabledControlTextColor]; }

// --- NSColor selection/content (10.14+): map to the classic 10.9 selection colors. ---
static id mav_selectedContentBackgroundColor(id s, SEL c)            { return [NSColor alternateSelectedControlColor]; }
static id mav_unemphasizedSelectedTextColor(id s, SEL c)              { return [NSColor textColor]; }
static id mav_unemphasizedSelectedContentBackgroundColor(id s, SEL c) { return [NSColor secondarySelectedControlColor]; }
static id mav_unemphasizedSelectedTextBackgroundColor(id s, SEL c)    { return [NSColor secondarySelectedControlColor]; }

// --- NSColor other semantics (10.10+/10.14+): nearest existing 10.9 color. ---
static id mav_controlAccentColor(id s, SEL c)  { return [NSColor alternateSelectedControlColor]; } // 10.9 system blue
static id mav_separatorColor(id s, SEL c)      { return [NSColor gridColor]; }
static id mav_containerBorderColor(id s, SEL c){ return [NSColor gridColor]; }
static id mav_findHighlightColor(id s, SEL c)  { return [NSColor yellowColor]; }

// --- NSColor system tint palette (10.10+): no 10.9 equivalent — Apple's documented sRGB constants. ---
static id mav_systemBlueColor(id s, SEL c)   { return SRGB(0, 122, 255, 255); }
static id mav_systemBrownColor(id s, SEL c)  { return SRGB(162, 132, 94, 255); }
static id mav_systemGrayColor(id s, SEL c)   { return SRGB(142, 142, 147, 255); }
static id mav_systemGreenColor(id s, SEL c)  { return SRGB(52, 199, 89, 255); }
static id mav_systemOrangeColor(id s, SEL c) { return SRGB(255, 149, 0, 255); }
static id mav_systemPinkColor(id s, SEL c)   { return SRGB(255, 45, 85, 255); }
static id mav_systemPurpleColor(id s, SEL c) { return SRGB(175, 82, 222, 255); }
static id mav_systemRedColor(id s, SEL c)    { return SRGB(255, 59, 48, 255); }
static id mav_systemYellowColor(id s, SEL c) { return SRGB(255, 204, 0, 255); }

// --- NSColor fill hierarchy (10.14+, HAVE_NSCOLOR_FILL_COLOR_HIERARCHY): documented light-mode fills. ---
static id mav_systemFillColor(id s, SEL c)          { return SRGB(0, 0, 0, 26); }
static id mav_secondarySystemFillColor(id s, SEL c) { return SRGB(0, 0, 0, 20); }
static id mav_tertiarySystemFillColor(id s, SEL c)  { return SRGB(0, 0, 0, 13); }

// --- NSWorkspace: accessibility-display prefs (10.10/10.12). 10.9 has none, so NO. ---
static BOOL mav_increaseContrast(id s, SEL c)          { return NO; }
static BOOL mav_differentiateWithoutColor(id s, SEL c) { return NO; }
static BOOL mav_reduceMotion(id s, SEL c)              { return NO; }
static BOOL mav_shouldInvertColors(id s, SEL c)        { return NO; }

// --- NSScreen: wide-gamut capability (-canRepresentDisplayGamut:, 10.11+). 10.9 displays are sRGB,
// so report NO. Lets upstream PlatformScreenMac call it unguarded (collectScreenProperties / screenSupportsExtendedColor). ---
static BOOL mav_canRepresentDisplayGamut(id s, SEL c, NSInteger gamut) { (void)gamut; return NO; }

// --- NSAppearance: -tintColor (11.0+). 10.9 has no per-appearance tint; map to the 10.9 accent color. ---
// NOTE: +currentDrawingAppearance is deliberately NOT injected. Injecting it would make every
// `[NSAppearance respondsToSelector:@selector(currentDrawingAppearance)]` bypass guard in WebKit's
// control drawing pass on 10.9 (LocalDefaultSystemAppearance, ScrollbarTrackCornerSystemImageMac,
// ControlMac, Switch*, ProgressBarMac, ...), which then sends the 10.14+ -_drawInRect:context:options: /
// 11.0+ -appearanceByApplyingTintColor: to the resulting appearance and crashes. With it absent, those
// guards correctly take the nil branch (controls draw via the non-appearance path / stay blank, no crash).
// _usesMetricsAppearance is likewise not injected — supportsLargeFormControls short-circuits on the
// (now NO) currentDrawingAppearance respondsToSelector and never reaches it.
static id mav_appearanceTintColor(id s, SEL c) { return [NSColor controlAccentColor]; }

// --- NSEvent: -stage (Force Touch click stage, 10.10.3+). 10.9 has no Force Touch hardware, so report 0.
// Lets the upstream pressure-event code (PlatformEventFactoryMac) read event.stage unguarded. ---
static NSInteger mav_eventStage(id s, SEL c) { return 0; }

// --- NSWindow: -performWindowDragWithEvent: (10.11+). 10.9 has no native window drag from web content,
// so WebViewImpl::startWindowDrag() (e.g. the Web Inspector's unified toolbar, which hosts the web view
// over the native titlebar, or any -webkit-app-region:drag region) never moved the window. Provide the
// classic pre-10.11 manual drag loop: follow the mouse with -setFrameOrigin: until mouse-up. Injecting it
// lets WebViewImpl call -performWindowDragWithEvent: unguarded, exactly as upstream does. ---
static void mav_performWindowDragWithEvent(id self, SEL c, NSEvent *event)
{
    (void)event;
    NSWindow *win = (NSWindow *)self;
    NSPoint startMouse = [NSEvent mouseLocation];
    NSRect startFrame = [win frame];
    while (YES) {
        @autoreleasepool {
            NSEvent *e = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
                                            untilDate:[NSDate distantFuture]
                                               inMode:NSEventTrackingRunLoopMode
                                              dequeue:YES];
            if (!e || e.type == NSEventTypeLeftMouseUp)
                break;
            NSPoint now = [NSEvent mouseLocation];
            [win setFrameOrigin:NSMakePoint(startFrame.origin.x + (now.x - startMouse.x), startFrame.origin.y + (now.y - startMouse.y))];
        }
    }
}

@interface MavericksObjCInjection : NSObject @end
@implementation MavericksObjCInjection
+ (void)load
{
    @autoreleasepool {
        // Type encodings: @encode(return) + self(id) + _cmd(SEL). snprintf because adjacent @encode()
        // expressions don't concatenate like bare string literals.
        char retId[8], retBool[8];
        snprintf(retId,   sizeof retId,   "%s%s%s", @encode(id),   @encode(id), @encode(SEL));
        snprintf(retBool, sizeof retBool, "%s%s%s", @encode(BOOL), @encode(id), @encode(SEL));

        Class color = [NSColor class];
        addClass(color, @selector(labelColor), (IMP)mav_labelColor, retId);
        addClass(color, @selector(secondaryLabelColor), (IMP)mav_secondaryLabelColor, retId);
        addClass(color, @selector(tertiaryLabelColor), (IMP)mav_tertiaryLabelColor, retId);
        addClass(color, @selector(quaternaryLabelColor), (IMP)mav_quaternaryLabelColor, retId);
        addClass(color, @selector(quinaryLabelColor), (IMP)mav_quinaryLabelColor, retId);
        addClass(color, @selector(placeholderTextColor), (IMP)mav_placeholderTextColor, retId);
        addClass(color, @selector(selectedContentBackgroundColor), (IMP)mav_selectedContentBackgroundColor, retId);
        addClass(color, @selector(unemphasizedSelectedTextColor), (IMP)mav_unemphasizedSelectedTextColor, retId);
        addClass(color, @selector(unemphasizedSelectedContentBackgroundColor), (IMP)mav_unemphasizedSelectedContentBackgroundColor, retId);
        addClass(color, @selector(unemphasizedSelectedTextBackgroundColor), (IMP)mav_unemphasizedSelectedTextBackgroundColor, retId);
        addClass(color, @selector(controlAccentColor), (IMP)mav_controlAccentColor, retId);
        addClass(color, @selector(separatorColor), (IMP)mav_separatorColor, retId);
        addClass(color, @selector(containerBorderColor), (IMP)mav_containerBorderColor, retId);
        addClass(color, @selector(findHighlightColor), (IMP)mav_findHighlightColor, retId);
        addClass(color, @selector(systemBlueColor), (IMP)mav_systemBlueColor, retId);
        addClass(color, @selector(systemBrownColor), (IMP)mav_systemBrownColor, retId);
        addClass(color, @selector(systemGrayColor), (IMP)mav_systemGrayColor, retId);
        addClass(color, @selector(systemGreenColor), (IMP)mav_systemGreenColor, retId);
        addClass(color, @selector(systemOrangeColor), (IMP)mav_systemOrangeColor, retId);
        addClass(color, @selector(systemPinkColor), (IMP)mav_systemPinkColor, retId);
        addClass(color, @selector(systemPurpleColor), (IMP)mav_systemPurpleColor, retId);
        addClass(color, @selector(systemRedColor), (IMP)mav_systemRedColor, retId);
        addClass(color, @selector(systemYellowColor), (IMP)mav_systemYellowColor, retId);
        addClass(color, @selector(systemFillColor), (IMP)mav_systemFillColor, retId);
        addClass(color, @selector(secondarySystemFillColor), (IMP)mav_secondarySystemFillColor, retId);
        addClass(color, @selector(tertiarySystemFillColor), (IMP)mav_tertiarySystemFillColor, retId);

        Class workspace = [NSWorkspace class];
        addInstance(workspace, @selector(accessibilityDisplayShouldIncreaseContrast), (IMP)mav_increaseContrast, retBool);
        addInstance(workspace, @selector(accessibilityDisplayShouldDifferentiateWithoutColor), (IMP)mav_differentiateWithoutColor, retBool);
        addInstance(workspace, @selector(accessibilityDisplayShouldReduceMotion), (IMP)mav_reduceMotion, retBool);
        addInstance(workspace, @selector(accessibilityDisplayShouldInvertColors), (IMP)mav_shouldInvertColors, retBool);

        // -[NSScreen canRepresentDisplayGamut:] (10.11+): BOOL return + NSInteger arg.
        char retBoolGamut[12];
        snprintf(retBoolGamut, sizeof retBoolGamut, "%s%s%s%s", @encode(BOOL), @encode(id), @encode(SEL), @encode(NSInteger));
        addInstance([NSScreen class], @selector(canRepresentDisplayGamut:), (IMP)mav_canRepresentDisplayGamut, retBoolGamut);

        Class appearance = [NSAppearance class];
        addInstance(appearance, @selector(tintColor), (IMP)mav_appearanceTintColor, retId);

        // -[NSEvent stage] (Force Touch, 10.10.3+): NSInteger return.
        char retInteger[8];
        snprintf(retInteger, sizeof retInteger, "%s%s%s", @encode(NSInteger), @encode(id), @encode(SEL));
        addInstance([NSEvent class], @selector(stage), (IMP)mav_eventStage, retInteger);

        // -[NSWindow performWindowDragWithEvent:] (10.11+): void return, NSEvent* arg.
        char retVoidEvent[12];
        snprintf(retVoidEvent, sizeof retVoidEvent, "%s%s%s%s", @encode(void), @encode(id), @encode(SEL), @encode(id));
        addInstance([NSWindow class], @selector(performWindowDragWithEvent:), (IMP)mav_performWindowDragWithEvent, retVoidEvent);
    }
}
@end
