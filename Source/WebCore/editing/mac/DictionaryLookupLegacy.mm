/*
 * Copyright (C) 2014-2020 Apple Inc. All rights reserved.
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
#import "DictionaryLookup.h"

// MAVERICKS_BACKPORT: upstream's Lookup.framework DictionaryLookup, built with ENABLE(REVEAL) off.
// Its adaptations to the present interface carry markers of their own.

#if PLATFORM(MAC) && !ENABLE(REVEAL)

#import "Document.h"
#import "DocumentPage.h" // MAVERICKS_BACKPORT: as DictionaryLookup.mm imports.
#import "Editing.h"
#import "EditingInlines.h" // MAVERICKS_BACKPORT: as DictionaryLookup.mm imports.
#import "FocusController.h"
#import "FrameDestructionObserverInlines.h" // MAVERICKS_BACKPORT: as DictionaryLookup.mm imports.
#import "FrameSelection.h"
#import "HitTestResult.h"
#import "LocalFrame.h"
#import "LocalFrameInlines.h" // MAVERICKS_BACKPORT: as DictionaryLookup.mm imports.
#import "Page.h"
#import "Range.h"
#import "RenderObject.h"
#import "TextIterator.h"
#import "VisiblePosition.h"
#import "VisibleSelection.h"
#import "VisibleUnits.h"
#import <Quartz/Quartz.h>
#import <pal/spi/mac/LookupSPI.h>
#import <pal/spi/mac/NSImmediateActionGestureRecognizerSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/RefPtr.h>

namespace WebCore {

static NSRange tokenRange(const String& string, NSRange range, NSDictionary **options)
{
    if (!PAL::getLULookupDefinitionModuleClassSingleton()) // MAVERICKS_BACKPORT: PAL's present accessor name.
        return NSMakeRange(NSNotFound, 0);

    BEGIN_BLOCK_OBJC_EXCEPTIONS

    return [PAL::getLULookupDefinitionModuleClassSingleton() tokenRangeForString:string.createNSString().get() range:range options:options]; // MAVERICKS_BACKPORT: PAL's present accessor name, and String's explicit NSString conversion.

    END_BLOCK_OBJC_EXCEPTIONS

    return NSMakeRange(NSNotFound, 0);
}

static bool selectionContainsPosition(const VisiblePosition& position, const VisibleSelection& selection)
{
    if (!selection.isRange())
        return false;

    auto selectedRange = selection.firstRange();
    return selectedRange && contains<ComposedTree>(*selectedRange, makeBoundaryPoint(position));
}

// std::optional<std::tuple<SimpleRange, NSDictionary *>> DictionaryLookup::rangeForSelection(const VisibleSelection& selection)
std::optional<SimpleRange> DictionaryLookup::rangeForSelection(const VisibleSelection& selection) // MAVERICKS_BACKPORT: no options travel with the result (webkit.org/b/269248).
{
    auto selectedRange = selection.toNormalizedRange();
    if (!selectedRange)
        return std::nullopt;

    // Since we already have the range we want, we just need to grab the returned options.
    auto selectionStart = selection.visibleStart();
    auto selectionEnd = selection.visibleEnd();

    // As context, we are going to use the surrounding paragraphs of text.
    auto paragraphRange = makeSimpleRange(startOfParagraph(selectionStart), endOfParagraph(selectionEnd));
    if (!paragraphRange)
        return std::nullopt;

    auto selectionRange = *makeSimpleRange(selectionStart, selectionEnd);

    NSDictionary *options = nil;
    tokenRange(plainText(*paragraphRange), characterRange(*paragraphRange, selectionRange), &options);

    // return { { *selectedRange, options } };
    return *selectedRange; // MAVERICKS_BACKPORT: as above.
}

// std::optional<std::tuple<SimpleRange, NSDictionary *>> DictionaryLookup::rangeAtHitTestResult(const HitTestResult& hitTestResult)
std::optional<SimpleRange> DictionaryLookup::rangeAtHitTestResult(const HitTestResult& hitTestResult) // MAVERICKS_BACKPORT: as for rangeForSelection.
{
    auto* node = hitTestResult.innerNonSharedNode();
    if (!node || !node->renderer())
        return std::nullopt;

    auto* frame = node->document().frame();
    if (!frame)
        return std::nullopt;

    // Don't do anything if there is no character at the point.
    auto framePoint = hitTestResult.roundedPointInInnerNodeFrame();
    if (!frame->rangeForPoint(framePoint))
        return std::nullopt;

    auto position = frame->visiblePositionForPoint(framePoint);
    if (position.isNull())
        position = firstPositionInOrBeforeNode(node);

    // If we hit the selection, use that instead of letting Lookup decide the range.
    // auto selection = frame->page()->focusController().focusedOrMainFrame().selection().selection();
    // MAVERICKS_BACKPORT: focusedOrMainFrame() returns a pointer, null-checked as DictionaryLookup.mm does.
    RefPtr focusedOrMainFrame = frame->page()->focusController().focusedOrMainFrame();
    if (!focusedOrMainFrame)
        return std::nullopt;
    auto selection = focusedOrMainFrame->selection().selection();
    if (selectionContainsPosition(position, selection))
        return rangeForSelection(selection);

    VisibleSelection selectionAccountingForLineRules { position };
    selectionAccountingForLineRules.expandUsingGranularity(TextGranularity::WordGranularity);
    position = selectionAccountingForLineRules.start();

    // As context, we are going to use 250 characters of text before and after the point.
    auto fullCharacterRange = rangeExpandedAroundPositionByCharacters(position, 250);
    if (!fullCharacterRange)
        return std::nullopt;

    auto rangeToPosition = makeSimpleRange(fullCharacterRange->start, position);
    if (!rangeToPosition)
        return std::nullopt;

    NSRange rangeToPass = NSMakeRange(characterCount(*rangeToPosition), 0);
    NSDictionary *options = nil;
    auto extractedRange = tokenRange(plainText(*fullCharacterRange), rangeToPass, &options);

    // tokenRange sometimes returns {NSNotFound, 0} if it was unable to determine a good string.
    // FIXME (159063): We shouldn't need to check for zero length here.
    if (extractedRange.location == NSNotFound || !extractedRange.length)
        return std::nullopt;

    // return { { resolveCharacterRange(*fullCharacterRange, extractedRange), options } };
    return resolveCharacterRange(*fullCharacterRange, extractedRange); // MAVERICKS_BACKPORT: as above.
}

static void expandSelectionByCharacters(PDFSelection *selection, NSInteger numberOfCharactersToExpand, NSInteger& charactersAddedBeforeStart, NSInteger& charactersAddedAfterEnd)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS

    size_t originalLength = selection.string.length;
    [selection extendSelectionAtStart:numberOfCharactersToExpand];
    
    charactersAddedBeforeStart = selection.string.length - originalLength;
    
    [selection extendSelectionAtEnd:numberOfCharactersToExpand];
    charactersAddedAfterEnd = selection.string.length - originalLength - charactersAddedBeforeStart;

    END_BLOCK_OBJC_EXCEPTIONS
}

// std::tuple<NSString *, NSDictionary *> DictionaryLookup::stringForPDFSelection(PDFSelection *selection)
NSString *DictionaryLookup::stringForPDFSelection(PDFSelection *selection) // MAVERICKS_BACKPORT: as for rangeForSelection.
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS

    // Don't do anything if there is no character at the point.
    if (!selection || !selection.string.length)
        return @""; // MAVERICKS_BACKPORT: as above.

    RetainPtr<PDFSelection> selectionForLookup = adoptNS([selection copy]);

    // As context, we are going to use 250 characters of text before and after the point.
    auto originalLength = [selectionForLookup string].length;
    NSInteger charactersAddedBeforeStart = 0;
    NSInteger charactersAddedAfterEnd = 0;
    expandSelectionByCharacters(selectionForLookup.get(), 250, charactersAddedBeforeStart, charactersAddedAfterEnd);

    auto fullPlainTextString = [selectionForLookup string];
    auto rangeToPass = NSMakeRange(charactersAddedBeforeStart, 0);

    NSDictionary *options = nil;
    auto extractedRange = tokenRange(fullPlainTextString, rangeToPass, &options);

    // This function sometimes returns {NSNotFound, 0} if it was unable to determine a good string.
    if (extractedRange.location == NSNotFound)
        return selection.string; // MAVERICKS_BACKPORT: as above.

    NSInteger lookupAddedBefore = rangeToPass.location - extractedRange.location;
    NSInteger lookupAddedAfter = (extractedRange.location + extractedRange.length) - (rangeToPass.location + originalLength);

    [selection extendSelectionAtStart:lookupAddedBefore];
    [selection extendSelectionAtEnd:lookupAddedAfter];

    ASSERT([selection.string isEqualToString:[fullPlainTextString substringWithRange:extractedRange]]);
    return selection.string; // MAVERICKS_BACKPORT: as above.

    END_BLOCK_OBJC_EXCEPTIONS

    return @""; // MAVERICKS_BACKPORT: as above.
}

// static id <NSImmediateActionAnimationController> showPopupOrCreateAnimationController(bool createAnimationController, const DictionaryPopupInfo& dictionaryPopupInfo, NSView *view, const WTF::Function<void(TextIndicator&)>& textIndicatorInstallationCallback, const WTF::Function<FloatRect(FloatRect)>& rootViewToViewConversionCallback)
static WKRevealController showPopupOrCreateAnimationController(bool createAnimationController, const DictionaryPopupInfo& dictionaryPopupInfo, CocoaView *view, NOESCAPE const WTF::Function<void(TextIndicator&)>& textIndicatorInstallationCallback, NOESCAPE const WTF::Function<FloatRect(FloatRect)>& rootViewToViewConversionCallback) // MAVERICKS_BACKPORT: DictionaryLookup.h's present types.
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS

    if (!PAL::getLULookupDefinitionModuleClassSingleton()) // MAVERICKS_BACKPORT: PAL's present accessor name.
        return nil;

    RetainPtr<NSMutableDictionary> mutableOptions = adoptNS([[NSMutableDictionary alloc] init]);
    // MAVERICKS_BACKPORT: no options travel with the popup info (webkit.org/b/269248).
    // if (NSDictionary *options = dictionaryPopupInfo.platformData.options.get())
    //     [mutableOptions addEntriesFromDictionary:options];

    // MAVERICKS_BACKPORT: the popup info carries the TextIndicator itself, and the term is the
    // font-scaled string DictionaryPopupInfo carries for this panel, which draws it over the page.
    // auto textIndicator = TextIndicator::create(dictionaryPopupInfo.textIndicator);
    RefPtr textIndicator = dictionaryPopupInfo.textIndicator;
    RetainPtr term = dictionaryPopupInfo.attributedString.nsAttributedString();

    // if (PAL::canLoad_Lookup_LUTermOptionDisableSearchTermIndicator() && textIndicator.get().contentImage()) {
    //     textIndicatorInstallationCallback(textIndicator.get());
    if (PAL::canLoad_Lookup_LUTermOptionDisableSearchTermIndicator() && textIndicator && textIndicator->contentImage()) { // MAVERICKS_BACKPORT: as above.
        textIndicatorInstallationCallback(*textIndicator); // MAVERICKS_BACKPORT: as above.
        [mutableOptions setObject:@YES forKey:PAL::get_Lookup_LUTermOptionDisableSearchTermIndicatorSingleton()]; // MAVERICKS_BACKPORT: PAL's present accessor name.

        // FloatRect firstTextRectInViewCoordinates = textIndicator.get().textRectsInBoundingRectCoordinates()[0];
        // FloatRect textBoundingRectInViewCoordinates = textIndicator.get().textBoundingRectInRootViewCoordinates();
        FloatRect firstTextRectInViewCoordinates = textIndicator->textRectsInBoundingRectCoordinates()[0]; // MAVERICKS_BACKPORT: as above.
        FloatRect textBoundingRectInViewCoordinates = textIndicator->textBoundingRectInRootViewCoordinates(); // MAVERICKS_BACKPORT: as above.
        if (rootViewToViewConversionCallback)
            textBoundingRectInViewCoordinates = rootViewToViewConversionCallback(textBoundingRectInViewCoordinates);
        firstTextRectInViewCoordinates.moveBy(textBoundingRectInViewCoordinates.location());
        if (createAnimationController)
            return [PAL::getLULookupDefinitionModuleClassSingleton() lookupAnimationControllerForTerm:term.get() relativeToRect:firstTextRectInViewCoordinates ofView:view options:mutableOptions.get()]; // MAVERICKS_BACKPORT: as above, and PAL's present accessor name.

        [PAL::getLULookupDefinitionModuleClassSingleton() showDefinitionForTerm:term.get() relativeToRect:firstTextRectInViewCoordinates ofView:view options:mutableOptions.get()]; // MAVERICKS_BACKPORT: as above, and PAL's present accessor name.
        return nil;
    }

    NSPoint textBaselineOrigin = dictionaryPopupInfo.origin;

    // Convert to screen coordinates.
    textBaselineOrigin = [view convertPoint:textBaselineOrigin toView:nil];
    textBaselineOrigin = [view.window convertRectToScreen:NSMakeRect(textBaselineOrigin.x, textBaselineOrigin.y, 0, 0)].origin;

    if (createAnimationController)
        return [PAL::getLULookupDefinitionModuleClassSingleton() lookupAnimationControllerForTerm:term.get() atLocation:textBaselineOrigin options:mutableOptions.get()]; // MAVERICKS_BACKPORT: as above, and PAL's present accessor name.

    [PAL::getLULookupDefinitionModuleClassSingleton() showDefinitionForTerm:term.get() atLocation:textBaselineOrigin options:mutableOptions.get()]; // MAVERICKS_BACKPORT: as above, and PAL's present accessor name.
    return nil;

    END_BLOCK_OBJC_EXCEPTIONS
    return nil;
}

// void DictionaryLookup::showPopup(const DictionaryPopupInfo& dictionaryPopupInfo, NSView *view, const WTF::Function<void(TextIndicator&)>& textIndicatorInstallationCallback, const WTF::Function<FloatRect(FloatRect)>& rootViewToViewConversionCallback, WTF::Function<void()>&& clearTextIndicator)
void DictionaryLookup::showPopup(const DictionaryPopupInfo& dictionaryPopupInfo, CocoaView *view, NOESCAPE const WTF::Function<void(TextIndicator&)>& textIndicatorInstallationCallback, NOESCAPE const WTF::Function<FloatRect(FloatRect)>& rootViewToViewConversionCallback, WTF::Function<void()>&& clearTextIndicator) // MAVERICKS_BACKPORT: DictionaryLookup.h's present types.
{
    UNUSED_PARAM(clearTextIndicator);
    
    showPopupOrCreateAnimationController(false, dictionaryPopupInfo, view, textIndicatorInstallationCallback, rootViewToViewConversionCallback);
}

void DictionaryLookup::hidePopup()
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS

    if (!PAL::getLULookupDefinitionModuleClassSingleton()) // MAVERICKS_BACKPORT: PAL's present accessor name.
        return;
    [PAL::getLULookupDefinitionModuleClassSingleton() hideDefinition]; // MAVERICKS_BACKPORT: PAL's present accessor name.

    END_BLOCK_OBJC_EXCEPTIONS
}

// id <NSImmediateActionAnimationController> DictionaryLookup::animationControllerForPopup(const DictionaryPopupInfo& dictionaryPopupInfo, NSView *view, const WTF::Function<void(TextIndicator&)>& textIndicatorInstallationCallback, const WTF::Function<FloatRect(FloatRect)>& rootViewToViewConversionCallback, WTF::Function<void()>&& clearTextIndicator)
WKRevealController DictionaryLookup::animationControllerForPopup(const DictionaryPopupInfo& dictionaryPopupInfo, NSView *view, NOESCAPE const WTF::Function<void(TextIndicator&)>& textIndicatorInstallationCallback, NOESCAPE const WTF::Function<FloatRect(FloatRect)>& rootViewToViewConversionCallback, WTF::Function<void()>&& clearTextIndicator) // MAVERICKS_BACKPORT: DictionaryLookup.h's present types.
{
    UNUSED_PARAM(clearTextIndicator);
    
    return showPopupOrCreateAnimationController(true, dictionaryPopupInfo, view, textIndicatorInstallationCallback, rootViewToViewConversionCallback);
}

} // namespace WebCore

#endif // PLATFORM(MAC) && !ENABLE(REVEAL)
