// MAVERICKS_BACKPORT: Stub replacing base 83b24ce's BrowserEngineKit/UIKit alias table.
// Those WKBE* -> BE*/UIWK* defines target iOS 16+ BrowserEngineKit and UIKit types absent on
// 10.9; this Mac build never instantiates them, so the whole mapping is reduced to a no-op.
#pragma once
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport

#if defined(__OBJC__) && __OBJC__
#import <pal/spi/ios/BrowserEngineKitSPI.h>
#endif

#if USE(BROWSERENGINEKIT)
// Scroll view
#define WKBEScrollView                                          BEScrollView
#define WKBEScrollViewDelegate                                  BEScrollViewDelegate
#define WKBEScrollViewScrollUpdate                              BEScrollViewScrollUpdate
#define WKBEScrollViewScrollUpdatePhase                         BEScrollViewScrollUpdatePhase
#define WKBEScrollViewScrollUpdatePhaseBegan                    BEScrollViewScrollUpdatePhaseBegan
#define WKBEScrollViewScrollUpdatePhaseChanged                  BEScrollViewScrollUpdatePhaseChanged
#define WKBEScrollViewScrollUpdatePhaseEnded                    BEScrollViewScrollUpdatePhaseEnded
#define WKBEScrollViewScrollUpdatePhaseCancelled                BEScrollViewScrollUpdatePhaseCancelled
// Editing and keyboards
#define WKBETextSuggestion                                      BETextSuggestion
#define WKBETextDocumentContext                                 BETextDocumentContext
#define WKBETextDocumentRequest                                 BETextDocumentRequest
#define WKBETextDocumentRequestOptions                          BETextDocumentRequestOptions
#define WKBETextDocumentRequestOptionNone                       BETextDocumentOptionNone
#define WKBETextDocumentRequestOptionText                       BETextDocumentOptionText
#define WKBETextDocumentRequestOptionAttributedText             BETextDocumentOptionAttributedText
#define WKBETextDocumentRequestOptionTextRects                  BETextDocumentOptionTextRects
#define WKBETextDocumentRequestOptionMarkedTextRects            BETextDocumentOptionMarkedTextRects
#define WKBETextDocumentRequestOptionAutocorrectedRanges        BETextDocumentOptionAutocorrectedRanges
#define WKBEGestureType                                         BEGestureType
#define WKBEGestureTypeLoupe                                    BEGestureTypeLoupe
#define WKBEGestureTypeOneFingerTap                             BEGestureTypeOneFingerTap
#define WKBEGestureTypeDoubleTapAndHold                         BEGestureTypeDoubleTapAndHold
#define WKBEGestureTypeDoubleTap                                BEGestureTypeDoubleTap
#define WKBEGestureTypeOneFingerDoubleTap                       BEGestureTypeOneFingerDoubleTap
#define WKBEGestureTypeOneFingerTripleTap                       BEGestureTypeOneFingerTripleTap
#define WKBEGestureTypeTwoFingerSingleTap                       BEGestureTypeTwoFingerSingleTap
#define WKBEGestureTypeTwoFingerRangedSelectGesture             BEGestureTypeTwoFingerRangedSelectGesture
#define WKBEGestureTypeIMPhraseBoundaryDrag                     BEGestureTypeIMPhraseBoundaryDrag
#define WKBEGestureTypeForceTouch                               BEGestureTypeForceTouch
#define WKBESelectionTouchPhase                                 BESelectionTouchPhase
#define WKBESelectionTouchPhaseStarted                          BESelectionTouchPhaseStarted
#define WKBESelectionTouchPhaseMoved                            BESelectionTouchPhaseMoved
#define WKBESelectionTouchPhaseEnded                            BESelectionTouchPhaseEnded
#define WKBESelectionTouchPhaseEndedMovingForward               BESelectionTouchPhaseEndedMovingForward
#define WKBESelectionTouchPhaseEndedMovingBackward              BESelectionTouchPhaseEndedMovingBackward
#define WKBESelectionTouchPhaseEndedNotMoving                   BESelectionTouchPhaseEndedNotMoving
#define WKBESelectionFlags                                      BESelectionFlags
#define WKBESelectionFlagsNone                                  BESelectionFlagsNone
#define WKBEWordIsNearTap                                       BEWordIsNearTap
#define WKBESelectionFlipped                                    BESelectionFlipped
#define WKBEPhraseBoundaryChanged                               BEPhraseBoundaryChanged
#else
// Scroll view
#define WKBEScrollView                                          UIScrollView
#define WKBEScrollViewDelegate                                  UIScrollViewDelegate
#define WKBEScrollViewScrollUpdate                              UIScrollEvent
#define WKBEScrollViewScrollUpdatePhase                         UIScrollPhase
#define WKBEScrollViewScrollUpdatePhaseBegan                    UIScrollPhaseBegan
#define WKBEScrollViewScrollUpdatePhaseChanged                  UIScrollPhaseChanged
#define WKBEScrollViewScrollUpdatePhaseEnded                    UIScrollPhaseEnded
#define WKBEScrollViewScrollUpdatePhaseCancelled                UIScrollPhaseCancelled
// Editing and keyboards
#define WKBETextSuggestion                                      UITextSuggestion
#define WKBETextDocumentContext                                 UIWKDocumentContext
#define WKBETextDocumentRequest                                 UIWKDocumentRequest
#define WKBETextDocumentRequestOptions                          UIWKDocumentRequestFlags
#define WKBETextDocumentRequestOptionNone                       UIWKDocumentRequestNone
#define WKBETextDocumentRequestOptionText                       UIWKDocumentRequestText
#define WKBETextDocumentRequestOptionAttributedText             UIWKDocumentRequestAttributed
#define WKBETextDocumentRequestOptionTextRects                  UIWKDocumentRequestRects
#define WKBETextDocumentRequestOptionMarkedTextRects            UIWKDocumentRequestMarkedTextRects
#define WKBETextDocumentRequestOptionAutocorrectedRanges        UIWKDocumentRequestAutocorrectedRanges
#define WKBEGestureType                                         UIWKGestureType
#define WKBEGestureTypeLoupe                                    UIWKGestureLoupe
#define WKBEGestureTypeOneFingerTap                             UIWKGestureOneFingerTap
#define WKBEGestureTypeDoubleTapAndHold                         UIWKGestureTapAndAHalf
#define WKBEGestureTypeDoubleTap                                UIWKGestureDoubleTap
#define WKBEGestureTypeOneFingerDoubleTap                       UIWKGestureOneFingerDoubleTap
#define WKBEGestureTypeOneFingerTripleTap                       UIWKGestureOneFingerTripleTap
#define WKBEGestureTypeTwoFingerSingleTap                       UIWKGestureTwoFingerSingleTap
#define WKBEGestureTypeTwoFingerRangedSelectGesture             UIWKGestureTwoFingerRangedSelectGesture
#define WKBEGestureTypeIMPhraseBoundaryDrag                     UIWKGesturePhraseBoundary
#define WKBESelectionTouchPhase                                 UIWKSelectionTouch
#define WKBESelectionTouchPhaseStarted                          UIWKSelectionTouchStarted
#define WKBESelectionTouchPhaseMoved                            UIWKSelectionTouchMoved
#define WKBESelectionTouchPhaseEnded                            UIWKSelectionTouchEnded
#define WKBESelectionTouchPhaseEndedMovingForward               UIWKSelectionTouchEndedMovingForward
#define WKBESelectionTouchPhaseEndedMovingBackward              UIWKSelectionTouchEndedMovingBackward
#define WKBESelectionTouchPhaseEndedNotMoving                   UIWKSelectionTouchEndedNotMoving
#define WKBESelectionFlags                                      UIWKSelectionFlags
#define WKBESelectionFlagsNone                                  UIWKNone
#define WKBEWordIsNearTap                                       UIWKWordIsNearTap
#define WKBESelectionFlipped                                    UIWKSelectionFlipped
#define WKBEPhraseBoundaryChanged                               UIWKPhraseBoundaryChanged
#endif
MAVERICKS_BACKPORT */
