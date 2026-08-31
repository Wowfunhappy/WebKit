/*
 * Copyright (C) 2024-2025 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT: Objective-C implementation of the WKTextExtractionItem family.
//
// Upstream implements these classes in UIProcess/API/Cocoa/_WKTextExtraction.swift, using
// `@objc @implementation extension`, which requires Swift 6; Swift cannot target this port's
// deployment target, so that file is not built here. Everything the classes need is already
// declared in Objective-C by _WKTextExtractionInternal.h — they are immutable data holders — so
// this file is a direct transcription of the Swift file's stored properties and initializers, with
// no behavioral difference. WKTextExtractionUtilities.mm's WebKit::createItem instantiates them and
// -[WKWebView _requestTextExtraction:completionHandler:] hands the resulting tree to its caller.
//
// When Swift becomes buildable on this port, delete this file (and its SourcesCocoa.txt entry) and
// build _WKTextExtraction.swift instead.

#import "config.h"
#import "_WKTextExtractionInternal.h"

#import <wtf/RetainPtr.h>

@interface WKTextExtractionItem ()
- (instancetype)initWithRectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier;
@end

@implementation WKTextExtractionLink {
    RetainPtr<NSURL> _url;
}

@synthesize range = _range;

- (instancetype)initWithURL:(NSURL *)url range:(NSRange)range
{
    if (!(self = [super init]))
        return nil;

    _url = url;
    _range = range;
    return self;
}

- (NSURL *)url
{
    return _url.get();
}

@end

@implementation WKTextExtractionEditable {
    RetainPtr<NSString> _label;
    RetainPtr<NSString> _placeholder;
}

@synthesize secure = _secure;
@synthesize focused = _focused;

- (instancetype)initWithLabel:(NSString *)label placeholder:(NSString *)placeholder isSecure:(BOOL)isSecure isFocused:(BOOL)isFocused
{
    if (!(self = [super init]))
        return nil;

    _label = label;
    _placeholder = placeholder;
    _secure = isSecure;
    _focused = isFocused;
    return self;
}

- (NSString *)label
{
    return _label.get();
}

- (NSString *)placeholder
{
    return _placeholder.get();
}

@end

@implementation WKTextExtractionItem {
    RetainPtr<NSArray<WKTextExtractionItem *>> _children;
    RetainPtr<NSDictionary<NSString *, NSString *>> _ariaAttributes;
    RetainPtr<NSString> _accessibilityRole;
    RetainPtr<NSString> _nodeIdentifier;
}

@synthesize rectInWebView = _rectInWebView;
@synthesize eventListeners = _eventListeners;

- (instancetype)initWithRectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super init]))
        return nil;

    _rectInWebView = rectInWebView;
    _children = children;
    _eventListeners = eventListeners;
    _ariaAttributes = ariaAttributes;
    _accessibilityRole = accessibilityRole;
    _nodeIdentifier = nodeIdentifier;
    return self;
}

- (NSArray<WKTextExtractionItem *> *)children
{
    return _children.get();
}

- (NSDictionary<NSString *, NSString *> *)ariaAttributes
{
    return _ariaAttributes.get();
}

- (NSString *)accessibilityRole
{
    return _accessibilityRole.get();
}

- (NSString *)nodeIdentifier
{
    return _nodeIdentifier.get();
}

@end

@implementation WKTextExtractionContainerItem

@synthesize container = _container;

- (instancetype)initWithContainer:(WKTextExtractionContainer)container rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _container = container;
    return self;
}

@end

@implementation WKTextExtractionFormItem {
    RetainPtr<NSString> _autocomplete;
    RetainPtr<NSString> _name;
}

- (instancetype)initWithAutocomplete:(NSString *)autocomplete name:(NSString *)name rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _autocomplete = autocomplete;
    _name = name;
    return self;
}

- (NSString *)autocomplete
{
    return _autocomplete.get();
}

- (NSString *)name
{
    return _name.get();
}

@end

@implementation WKTextExtractionLinkItem {
    RetainPtr<NSString> _target;
    RetainPtr<NSURL> _url;
}

- (instancetype)initWithTarget:(NSString *)target url:(NSURL *)url rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _target = target;
    _url = url;
    return self;
}

- (NSString *)target
{
    return _target.get();
}

- (NSURL *)url
{
    return _url.get();
}

@end

@implementation WKTextExtractionIFrameItem {
    RetainPtr<NSString> _origin;
}

- (instancetype)initWithOrigin:(NSString *)origin rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _origin = origin;
    return self;
}

- (NSString *)origin
{
    return _origin.get();
}

@end

@implementation WKTextExtractionContentEditableItem

@synthesize contentEditableType = _contentEditableType;
@synthesize focused = _focused;

- (instancetype)initWithContentEditableType:(WKTextExtractionEditableType)contentEditableType isFocused:(BOOL)isFocused rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _contentEditableType = contentEditableType;
    _focused = isFocused;
    return self;
}

@end

@implementation WKTextExtractionTextFormControlItem {
    RetainPtr<WKTextExtractionEditable> _editable;
    RetainPtr<NSString> _controlType;
    RetainPtr<NSString> _autocomplete;
}

@synthesize readonly = _readonly;
@synthesize disabled = _disabled;
@synthesize checked = _checked;

- (instancetype)initWithEditable:(WKTextExtractionEditable *)editable controlType:(NSString *)controlType autocomplete:(NSString *)autocomplete isReadonly:(BOOL)isReadonly isDisabled:(BOOL)isDisabled isChecked:(BOOL)isChecked rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _editable = editable;
    _controlType = controlType;
    _autocomplete = autocomplete;
    _readonly = isReadonly;
    _disabled = isDisabled;
    _checked = isChecked;
    return self;
}

- (NSString *)label
{
    return [_editable label];
}

- (NSString *)placeholder
{
    return [_editable placeholder];
}

- (BOOL)isSecure
{
    return [_editable isSecure];
}

- (BOOL)isFocused
{
    return [_editable isFocused];
}

- (NSString *)controlType
{
    return _controlType.get();
}

- (NSString *)autocomplete
{
    return _autocomplete.get();
}

@end

@implementation WKTextExtractionTextItem {
    RetainPtr<NSString> _content;
    RetainPtr<NSArray<WKTextExtractionLink *>> _links;
    RetainPtr<WKTextExtractionEditable> _editable;
}

@synthesize selectedRange = _selectedRange;

- (instancetype)initWithContent:(NSString *)content selectedRange:(NSRange)selectedRange links:(NSArray<WKTextExtractionLink *> *)links editable:(WKTextExtractionEditable *)editable rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _content = content;
    _selectedRange = selectedRange;
    _links = links;
    _editable = editable;
    return self;
}

- (NSArray<WKTextExtractionLink *> *)links
{
    return _links.get();
}

- (WKTextExtractionEditable *)editable
{
    return _editable.get();
}

- (NSString *)content
{
    return _content.get();
}

- (void)setContent:(NSString *)content
{
    _content = adoptNS(content.copy);
}

@end

@implementation WKTextExtractionScrollableItem

@synthesize contentSize = _contentSize;

- (instancetype)initWithContentSize:(CGSize)contentSize rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _contentSize = contentSize;
    return self;
}

@end

@implementation WKTextExtractionSelectItem {
    RetainPtr<NSArray<NSString *>> _selectedValues;
}

@synthesize supportsMultiple = _supportsMultiple;

- (instancetype)initWithSelectedValues:(NSArray<NSString *> *)selectedValues supportsMultiple:(BOOL)supportsMultiple rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _selectedValues = selectedValues;
    _supportsMultiple = supportsMultiple;
    return self;
}

- (NSArray<NSString *> *)selectedValues
{
    return _selectedValues.get();
}

@end

@implementation WKTextExtractionImageItem {
    RetainPtr<NSString> _name;
    RetainPtr<NSString> _altText;
}

- (instancetype)initWithName:(NSString *)name altText:(NSString *)altText rectInWebView:(CGRect)rectInWebView children:(NSArray<WKTextExtractionItem *> *)children eventListeners:(WKTextExtractionEventListenerTypes)eventListeners ariaAttributes:(NSDictionary<NSString *, NSString *> *)ariaAttributes accessibilityRole:(NSString *)accessibilityRole nodeIdentifier:(NSString *)nodeIdentifier
{
    if (!(self = [super initWithRectInWebView:rectInWebView children:children eventListeners:eventListeners ariaAttributes:ariaAttributes accessibilityRole:accessibilityRole nodeIdentifier:nodeIdentifier]))
        return nil;

    _name = name;
    _altText = altText;
    return self;
}

- (NSString *)name
{
    return _name.get();
}

- (NSString *)altText
{
    return _altText.get();
}

@end
