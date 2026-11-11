// PassKitCore: the functions and constants WebKit reaches through PAL's PassKitCore soft link, from a
// private framework 10.9 does not ship. Its classes are in classes/PassKitCore.m.
#include "wk_polyfill.h"

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <PassKit/PKConstants.h>

#define WK_PASSKITCORE "/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore"

typedef void (^WKPKCanMakePaymentsCompletion)(BOOL canMakePayments, NSError *error);

// No payment card can be provisioned on this system, so no merchant has an active one. The answer
// arrives asynchronously, as PassKit's does.
static void answerNoActiveCard(WKPKCanMakePaymentsCompletion completion)
{
    if (!completion)
        return;
    WKPKCanMakePaymentsCompletion reply = [[completion copy] autorelease];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        reply(NO, nil);
    });
}

WK_POLYFILL_ABSENT(WK_PASSKITCORE, void, PKCanMakePaymentsWithMerchantIdentifierAndDomain,
    (NSString *identifier, NSString *domain, WKPKCanMakePaymentsCompletion completion))
{
    (void)identifier;
    (void)domain;
    answerNoActiveCard(completion);
}

WK_POLYFILL_ABSENT(WK_PASSKITCORE, void, PKCanMakePaymentsWithMerchantIdentifierDomainAndSourceApplication,
    (NSString *identifier, NSString *domain, NSString *sourceApplicationSecondaryIdentifier, WKPKCanMakePaymentsCompletion completion))
{
    (void)identifier;
    (void)domain;
    (void)sourceApplicationSecondaryIdentifier;
    answerNoActiveCard(completion);
}

WK_POLYFILL_CONST(WK_PASSKITCORE, CGFloat, PKApplePayButtonDefaultCornerRadius, 4.0);

// PKPaymentButtonType and PKPaymentButtonStyle are the SDK's names for the values WebKit passes; naming
// them at this deployment target is what the availability warning describes.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

// The button's label, with U+F8FF standing for the Apple logo. Labels are English.
static NSString *buttonLabel(PKPaymentButtonType type)
{
    switch (type) {
    case PKPaymentButtonTypePlain: return @" Pay";
    case PKPaymentButtonTypeBuy: return @"Buy with  Pay";
    case PKPaymentButtonTypeSetUp: return @"Set up  Pay";
    case PKPaymentButtonTypeInStore: return @"Pay with  Pay";
    case PKPaymentButtonTypeDonate: return @"Donate with  Pay";
    case PKPaymentButtonTypeCheckout: return @"Check out with  Pay";
    case PKPaymentButtonTypeBook: return @"Book with  Pay";
    case PKPaymentButtonTypeSubscribe: return @"Subscribe with  Pay";
    case PKPaymentButtonTypeReload: return @"Reload with  Pay";
    case PKPaymentButtonTypeAddMoney: return @"Add Money with  Pay";
    case PKPaymentButtonTypeTopUp: return @"Top Up with  Pay";
    case PKPaymentButtonTypeOrder: return @"Order with  Pay";
    case PKPaymentButtonTypeRent: return @"Rent with  Pay";
    case PKPaymentButtonTypeSupport: return @"Support with  Pay";
    case PKPaymentButtonTypeContribute: return @"Contribute with  Pay";
    case PKPaymentButtonTypeTip: return @"Tip with  Pay";
    case PKPaymentButtonTypeContinue: return @"Continue with  Pay";
    }
    return @" Pay";
}

static CTLineRef createLabelLine(NSString *label, CGFloat fontSize)
{
    CTFontRef font = CTFontCreateWithName(CFSTR("HelveticaNeue-Medium"), fontSize, NULL);
    NSDictionary *attributes = @{
        (id)kCTFontAttributeName : (id)font,
        (id)kCTForegroundColorFromContextAttributeName : @YES,
    };
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:label attributes:attributes];
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)string);
    [string release];
    CFRelease(font);
    return line;
}

// Draws into a context whose y axis points up: a rounded rectangle in the style's colour, and the
// type's label centred in it, sized to the button's height and narrowed to fit its width.
WK_POLYFILL_ABSENT(WK_PASSKITCORE, void, PKDrawApplePayButtonWithCornerRadius,
    (CGContextRef context, CGRect drawRect, CGFloat scale, CGFloat cornerRadius, PKPaymentButtonType type, PKPaymentButtonStyle style, NSString *languageCode))
{
    (void)languageCode;
    CGFloat width = CGRectGetWidth(drawRect);
    CGFloat height = CGRectGetHeight(drawRect);
    if (width <= 0 || height <= 0)
        return;

    CGFloat radius = MAX(0, MIN(cornerRadius, MIN(width, height) / 2));
    BOOL dark = style != PKPaymentButtonStyleWhite && style != PKPaymentButtonStyleWhiteOutline;

    CGContextSaveGState(context);

    CGPathRef shape = CGPathCreateWithRoundedRect(drawRect, radius, radius, NULL);
    CGContextAddPath(context, shape);
    CGContextSetGrayFillColor(context, dark ? 0 : 1, 1);
    CGContextFillPath(context);
    CGPathRelease(shape);

    if (style == PKPaymentButtonStyleWhiteOutline) {
        CGFloat lineWidth = 1 / (scale > 0 ? scale : 1);
        CGRect outlineRect = CGRectInset(drawRect, lineWidth / 2, lineWidth / 2);
        CGFloat outlineRadius = MAX(0, MIN(radius - lineWidth / 2, MIN(CGRectGetWidth(outlineRect), CGRectGetHeight(outlineRect)) / 2));
        CGPathRef outline = CGPathCreateWithRoundedRect(outlineRect, outlineRadius, outlineRadius, NULL);
        CGContextAddPath(context, outline);
        CGContextSetGrayStrokeColor(context, 0, 1);
        CGContextSetLineWidth(context, lineWidth);
        CGContextStrokePath(context);
        CGPathRelease(outline);
    }

    NSString *label = buttonLabel(type);
    CGFloat fontSize = height * 0.45;
    CGFloat availableWidth = width - height * 0.5;
    CTLineRef line = createLabelLine(label, fontSize);
    double lineWidth = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    if (lineWidth > availableWidth && availableWidth > 0) {
        CFRelease(line);
        fontSize *= availableWidth / lineWidth;
        line = createLabelLine(label, fontSize);
        lineWidth = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    }

    CGFloat ascent = 0;
    CGFloat descent = 0;
    CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    CGContextSetGrayFillColor(context, dark ? 1 : 0, 1);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetTextPosition(context, CGRectGetMidX(drawRect) - lineWidth / 2, CGRectGetMidY(drawRect) - (ascent - descent) / 2);
    CTLineDraw(line, context);
    CFRelease(line);

    CGContextRestoreGState(context);
}

#pragma clang diagnostic pop
