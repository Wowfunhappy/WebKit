// PDFKit: constants modern WebKit references that 10.9's PDFKit does not export.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
#include <float.h>

// ---------------------------------------------------------------------------------------------------
// PDFKit -- the 10.13 annotation-dictionary vocabulary, and the destination sentinel.
//
// 10.13 replaced PDFKit's per-subclass annotation API with one PDFAnnotation class read by PDF
// dictionary key, and named the keys and the values they take as exported constants. This PDFKit
// predates all of them: it models an annotation's subtype as the object's CLASS and answers -type
// with the subtype name. The names still have to exist, because SOFT_LINK_CONSTANT ends in a
// RELEASE_ASSERT -- reading one 10.9 does not export took Safari's UI process down inside
// -[WKPrintingView drawRect:], which asks every annotation for its /Subtype while writing the printed
// PDF's links (Print > Open PDF in Preview).
//
// The values are the PDF specification's own names for these dictionary entries and their values,
// which is what PDFKit's constants hold; -[PDFAnnotation wk_valueForAnnotationKey:] in methods/PDFKit.m
// answers with the same spelling, so the comparisons WebKit makes between the two are the modern
// ones. The leading slash is PDF name syntax, and part of the value.
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationKeySubtype, @"/Subtype");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationKeyWidgetFieldType, @"/FT");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationSubtypeLink, @"/Link");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationSubtypePopup, @"/Popup");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationSubtypeText, @"/Text");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationSubtypeWidget, @"/Widget");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationWidgetSubtypeButton, @"/Btn");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationWidgetSubtypeChoice, @"/Ch");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationWidgetSubtypeSignature, @"/Sig");
WK_POLYFILL_CONST("PDFKit", NSString * const, PDFAnnotationWidgetSubtypeText, @"/Tx");

// "This destination component is unspecified" -- FLT_MAX, in whichever of a PDFDestination's fields
// the destination leaves open. 10.9 has the value, as the #define its PDFDestination.h carries; what
// it does not have is an exported symbol, and soft-linking can only read a symbol.
WK_POLYFILL_CONST("PDFKit", CGFloat, kPDFDestinationUnspecifiedValue, FLT_MAX);
