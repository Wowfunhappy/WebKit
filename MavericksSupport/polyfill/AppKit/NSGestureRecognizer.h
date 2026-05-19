#ifndef _NSGESTURERECOGNIZER_H_
#define _NSGESTURERECOGNIZER_H_
#import <AppKit/AppKit.h>
/* NSGestureRecognizer added in 10.10 - stub */
#ifndef NSGestureRecognizerStatePossible
typedef NS_ENUM(NSInteger, NSGestureRecognizerState) {
    NSGestureRecognizerStatePossible,
    NSGestureRecognizerStateBegan,
    NSGestureRecognizerStateChanged,
    NSGestureRecognizerStateEnded,
    NSGestureRecognizerStateCancelled,
    NSGestureRecognizerStateFailed,
};
@interface NSGestureRecognizer : NSObject
@property NSGestureRecognizerState state;
@property (weak) id target;
@property SEL action;
@property (weak) NSView *view;
@property BOOL enabled;
- (void)reset;
- (NSPoint)locationInView:(NSView *)view;
@end
@interface NSClickGestureRecognizer : NSGestureRecognizer
@property NSUInteger numberOfClicksRequired;
@end
@interface NSMagnificationGestureRecognizer : NSGestureRecognizer
@property CGFloat magnification;
@end
#endif
#endif
@protocol NSGestureRecognizerDelegate <NSObject>
@optional
- (BOOL)gestureRecognizerShouldBegin:(NSGestureRecognizer *)gestureRecognizer;
@end
