/*
 * Copyright (C) 2011 Apple Inc. All rights reserved.
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
#import "CorrectionPanel.h"

#if USE(AUTOCORRECTION_PANEL)

#import "WebPageProxy.h"
#import "WebPageProxy.h" // MAVERICKS_BACKPORT: this panel is driven by the page (see CorrectionPanel.h).
#import <WebCore/CorrectionIndicator.h>
#import <pal/SessionID.h>
#import <wtf/cocoa/VectorCocoa.h>

namespace WebKit {
using namespace WebCore;

CorrectionPanel::CorrectionPanel()
    : m_wasDismissedExternally(false)
    , m_reasonForDismissing(ReasonForDismissingAlternativeText::Ignored)
{
}

CorrectionPanel::~CorrectionPanel()
{
    dismissInternal(ReasonForDismissingAlternativeText::Ignored, false);
}

void CorrectionPanel::show(NSView *view, WebPageProxy& page, AlternativeTextType type, const FloatRect& boundingBoxOfReplacedString, const String& replacedString, const String& replacementString, const Vector<String>& alternativeReplacementStrings)  // MAVERICKS_BACKPORT: takes the page (see the class comment).
{
    dismissInternal(ReasonForDismissingAlternativeText::Ignored, false);

    if (!view)
        return;

    NSInteger spellCheckerDocumentTag = page.spellDocumentTag(); // MAVERICKS_BACKPORT: was webViewImpl.spellCheckerDocumentTag(), which forwards here.

    RetainPtr replacedStringAsNSString = replacedString.createNSString();
    RetainPtr replacementStringAsNSString = replacementString.createNSString();

    m_view = view;
    m_spellCheckerDocumentTag = spellCheckerDocumentTag;
    NSCorrectionIndicatorType indicatorType = correctionIndicatorType(type);

    RetainPtr<NSArray> alternativeStrings;
    if (!alternativeReplacementStrings.isEmpty())
        alternativeStrings = createNSArray(alternativeReplacementStrings);

    RetainPtr spellChecker = [NSSpellChecker sharedSpellChecker];
    [spellChecker showCorrectionIndicatorOfType:indicatorType primaryString:replacementStringAsNSString.get() alternativeStrings:alternativeStrings.get() forStringInRect:boundingBoxOfReplacedString view:m_view.get() completionHandler:^(NSString* acceptedString) {
        handleAcceptedReplacement(page, acceptedString, replacedStringAsNSString.get(), replacementStringAsNSString.get(), indicatorType);  // MAVERICKS_BACKPORT: takes the page (see the class comment).
    }];
}

String CorrectionPanel::dismiss(ReasonForDismissingAlternativeText reason)
{
    return dismissInternal(reason, true);
}

String CorrectionPanel::dismissInternal(ReasonForDismissingAlternativeText reason, bool dismissingExternally)
{
    if (!isShowing())
        return String();

    m_wasDismissedExternally = dismissingExternally;
    m_reasonForDismissing = reason;
    m_resultForDismissal.clear();
    [[NSSpellChecker sharedSpellChecker] dismissCorrectionIndicatorForView:m_view.get()];
    return m_resultForDismissal.get();
}

void CorrectionPanel::recordAutocorrectionResponse(WebPageProxy& page, NSInteger spellCheckerDocumentTag, NSCorrectionResponse response, const String& replacedString, const String& replacementString)  // MAVERICKS_BACKPORT: takes the page (see the class comment).
{
    if (page.sessionID().isEphemeral()) // MAVERICKS_BACKPORT: was webViewImpl.page().sessionID().
        return;

    [[NSSpellChecker sharedSpellChecker] recordResponse:response toCorrection:replacementString.createNSString().get() forWord:replacedString.createNSString().get() language:nil inSpellDocumentWithTag:spellCheckerDocumentTag];
}

void CorrectionPanel::handleAcceptedReplacement(WebPageProxy& page, NSString* acceptedReplacement, NSString* replaced, NSString* proposedReplacement,  NSCorrectionIndicatorType correctionIndicatorType)  // MAVERICKS_BACKPORT: takes the page (see the class comment).
{
    if (!m_view)
        return;

    switch (correctionIndicatorType) {
    case NSCorrectionIndicatorTypeDefault:
        if (acceptedReplacement)
            recordAutocorrectionResponse(page, m_spellCheckerDocumentTag, NSCorrectionResponseAccepted, replaced, acceptedReplacement);  // MAVERICKS_BACKPORT: takes the page (see the class comment).
        else {
            if (!m_wasDismissedExternally || m_reasonForDismissing == ReasonForDismissingAlternativeText::Cancelled)
                recordAutocorrectionResponse(page, m_spellCheckerDocumentTag, NSCorrectionResponseRejected, replaced, proposedReplacement);
            else
                recordAutocorrectionResponse(page, m_spellCheckerDocumentTag, NSCorrectionResponseIgnored, replaced, proposedReplacement);  // MAVERICKS_BACKPORT: takes the page (see the class comment).
        }
        break;
    case NSCorrectionIndicatorTypeReversion:
        if (acceptedReplacement)
            recordAutocorrectionResponse(page, m_spellCheckerDocumentTag, NSCorrectionResponseReverted, replaced, acceptedReplacement);  // MAVERICKS_BACKPORT: takes the page (see the class comment).
        break;
    case NSCorrectionIndicatorTypeGuesses:
        if (acceptedReplacement)
            recordAutocorrectionResponse(page, m_spellCheckerDocumentTag, NSCorrectionResponseAccepted, replaced, acceptedReplacement);  // MAVERICKS_BACKPORT: takes the page (see the class comment).
        break;
    }

    page.handleAlternativeTextUIResult(acceptedReplacement); // MAVERICKS_BACKPORT: was webViewImpl.handleAcceptedAlternativeText(), which forwards here.
    m_spellCheckerDocumentTag = 0;
    m_view = nullptr;
    if (acceptedReplacement)
        m_resultForDismissal = adoptNS([acceptedReplacement copy]);
}

} // namespace WebKit

#endif // USE(AUTOCORRECTION_PANEL)
