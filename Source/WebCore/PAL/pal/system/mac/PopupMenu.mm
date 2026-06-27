/*
 * Copyright (C) 2017-2024 Apple Inc. All rights reserved.
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
#import "PopupMenu.h"

#if PLATFORM(MAC)

#import "NSMenuSPI.h"
#import <wtf/RetainPtr.h>

@interface NSMenu (WebPrivate)
- (id)_menuImpl;
@end

@interface NSObject (WebPrivate)
- (void)popUpMenu:(NSMenu*)menu atLocation:(NSPoint)location width:(CGFloat)width forView:(NSView*)view withSelectedItem:(NSInteger)selectedItem withFont:(NSFont*)font withFlags:(NSPopUpMenuFlags)flags withOptions:(NSDictionary *)options;
@end

namespace PAL {

void popUpMenu(NSMenu *menu, NSPoint location, float width, NSView *view, int selectedItem, NSFont *font, NSControlSize controlSize, bool usesCustomAppearance)
{
    // MAVERICKS_BACKPORT: On macOS 10.9 -[NSMenu _menuImpl] is an NSCarbonMenuImpl whose private
    // -popUpMenu:atLocation:width:forView:… runs a nested menu-tracking loop that never enters when the
    // owning window is a non-key, non-activating overlay — e.g. a Dashboard widget window in the Dashboard
    // layer — so the pop-up button menu silently fails to appear. For such windows fall back to the public
    // AppKit -popUpMenuPositioningItem:atLocation:inView:, which tracks correctly from a non-key window. Key
    // windows (Safari, Mail, desktop widgets that became key) keep the native pop-up-button presentation.
    NSWindow *ownerWindow = [view window];
    if (ownerWindow && ![ownerWindow isKeyWindow]) {
        NSMenuItem *selectedMenuItem = (selectedItem >= 0 && selectedItem < [menu numberOfItems]) ? [menu itemAtIndex:selectedItem] : nil;
        [menu popUpMenuPositioningItem:selectedMenuItem atLocation:location inView:view];
        return;
    }

    NSRect adjustedPopupBounds = [view.window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
    if (controlSize != NSControlSizeMini) {
        adjustedPopupBounds.origin.x -= 3;
        adjustedPopupBounds.origin.y -= 1;
        adjustedPopupBounds.size.width += 6;
    }

    // These numbers were extracted from visual inspection as the menu animates shut.
    NSSize labelOffset = NSMakeSize(11, 1);
    // MAVERICKS_BACKPORT: -[NSMenu userInterfaceLayoutDirection] is 10.11+ and absent on 10.9, so the RTL
    // label-offset branch is hard-disabled (always the LTR offset) instead of calling the unavailable selector.
    /* userInterfaceLayoutDirection added in macOS 10.11 */
    if (NO)
        labelOffset = NSMakeSize(24, 1);

    auto options = adoptNS([@{
        NSPopUpMenuPopupButtonBounds : [NSValue valueWithRect:adjustedPopupBounds],
        NSPopUpMenuPopupButtonLabelOffset : [NSValue valueWithSize:labelOffset],
        NSPopUpMenuPopupButtonSize : @(controlSize)
    } mutableCopy]);

    if (usesCustomAppearance)
        [options setObject:@"" forKey:NSPopUpMenuPopupButtonWidget];

    [[menu _menuImpl] popUpMenu:menu atLocation:location width:width forView:view withSelectedItem:selectedItem withFont:font withFlags:(usesCustomAppearance ? 0 : NSPopUpMenuIsPopupButton) withOptions:options.get()];
}

} // namespace PAL

#endif // PLATFORM(MAC)
