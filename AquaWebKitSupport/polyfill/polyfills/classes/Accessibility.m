// Accessibility: stubs of the Accessibility framework classes 10.9 does not have. 10.9 ships no
// Accessibility.framework at all, so every class here is registered with WK_POLYFILL_CLASS and the
// dlopen of the framework path is answered with the layer's absent-provider token.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>

// AXCustomContent (macOS 11+): a label/value pair an assistive client presents alongside an element's
// label, carrying detail the label itself would bury. -[WebAccessibilityObjectWrapperBase
// accessibilityCustomContent] builds one per element that has an extended description
// (aria-description, aria-describedby, a figure caption).
//
// PAL soft-links the class, which resolves through objc_getClass and so needs the WK_POLYFILL_CLASS
// registration below as well as the classref alias. The class is a value object: the label and value
// it is created with plus the importance its creator sets.
WK_PRIV_CLASS(AXCustomContent) @interface AXCustomContent : NSObject {
    NSString *_label;
    NSString *_value;
    NSAttributedString *_attributedLabel;
    NSAttributedString *_attributedValue;
    NSUInteger _importance;
}
+ (instancetype)customContentWithLabel:(NSString *)label value:(NSString *)value;
+ (instancetype)customContentWithAttributedLabel:(NSAttributedString *)label attributedValue:(NSAttributedString *)value;
@property (readonly, copy) NSString *label;
@property (readonly, copy) NSString *value;
@property (readonly, copy) NSAttributedString *attributedLabel;
@property (readonly, copy) NSAttributedString *attributedValue;
@property NSUInteger importance;
@end

@implementation AXCustomContent

// Each factory fills both pairs, so either accessor answers whichever way the item was created. They
// are filled at creation rather than on demand because an item is immutable afterwards and is read
// from the accessibility thread as well as the main one.
+ (instancetype)customContentWithLabel:(NSString *)label value:(NSString *)value
{
    AXCustomContent *content = [[[self alloc] init] autorelease];
    content->_label = [label copy];
    content->_value = [value copy];
    content->_attributedLabel = label ? [[NSAttributedString alloc] initWithString:label] : nil;
    content->_attributedValue = value ? [[NSAttributedString alloc] initWithString:value] : nil;
    return content;
}

+ (instancetype)customContentWithAttributedLabel:(NSAttributedString *)label attributedValue:(NSAttributedString *)value
{
    AXCustomContent *content = [[[self alloc] init] autorelease];
    content->_attributedLabel = [label copy];
    content->_attributedValue = [value copy];
    content->_label = [[label string] copy];
    content->_value = [[value string] copy];
    return content;
}

- (void)dealloc
{
    [_label release];
    [_value release];
    [_attributedLabel release];
    [_attributedValue release];
    [super dealloc];
}

- (NSString *)label { return _label; }
- (NSString *)value { return _value; }
- (NSAttributedString *)attributedLabel { return _attributedLabel; }
- (NSAttributedString *)attributedValue { return _attributedValue; }
- (NSUInteger)importance { return _importance; }
- (void)setImportance:(NSUInteger)importance { _importance = importance; }

@end
WK_PRIV_ALIAS(AXCustomContent);
WK_POLYFILL_CLASS("Accessibility", AXCustomContent);
