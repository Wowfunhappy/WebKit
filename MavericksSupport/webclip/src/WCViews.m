#import "WCThemes.h"

#pragma mark - WCRolloverTrackingView

@implementation WCRolloverTrackingView {
    BOOL _mouseOver;
    BOOL _redrawOnMouseEnteredAndExited;
    BOOL _trackingRectUpdatePending;
    NSTrackingRectTag _trackingRectTag;
    __unsafe_unretained id _delegate;
}

- (void)initTrackingRect
{
    [self _updateTrackingRectSoon];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    [self initTrackingRect];
    return self;
}

- (void)setFrameOrigin:(NSPoint)origin
{
    if (NSEqualPoints([self frame].origin, origin))
        return;
    [super setFrameOrigin:origin];
    [self _updateTrackingRectSoon];
}

- (void)setFrameSize:(NSSize)size
{
    if (NSEqualSizes([self frame].size, size))
        return;
    [super setFrameSize:size];
    [self _updateTrackingRectSoon];
}

- (void)setFrameRotation:(CGFloat)rotation
{
    if ([self frameRotation] == rotation)
        return;
    [super setFrameRotation:rotation];
    [self _updateTrackingRectSoon];
}

- (void)setBoundsOrigin:(NSPoint)origin
{
    if (NSEqualPoints([self bounds].origin, origin))
        return;
    [super setBoundsOrigin:origin];
    [self _updateTrackingRectSoon];
}

- (void)setBoundsSize:(NSSize)size
{
    if (NSEqualSizes([self bounds].size, size))
        return;
    [super setBoundsSize:size];
    [self _updateTrackingRectSoon];
}

- (void)setBoundsRotation:(CGFloat)rotation
{
    if ([self boundsRotation] == rotation)
        return;
    [super setBoundsRotation:rotation];
    [self _updateTrackingRectSoon];
}

- (void)awakeFromNib
{
    [self initTrackingRect];
}

- (void)dealloc
{
    if (_trackingRectUpdatePending)
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateTrackingRect) object:nil];
    [self removeTrackingRect];
}

- (BOOL)mouseIsOver
{
    return _mouseOver;
}

- (void)mouseEnteredOrExited:(BOOL)entered
{
}

- (void)setRedrawOnMouseEnteredAndExited:(BOOL)redraw
{
    _redrawOnMouseEnteredAndExited = redraw;
}

- (BOOL)redrawOnMouseEnteredAndExited
{
    return _redrawOnMouseEnteredAndExited;
}

// state: 0 = re-test the mouse position, 1 = a mouseEntered: event, 2 = a mouseExited: event.
- (void)updateMouseIsOver:(int)state
{
    BOOL mouseOver = NO;
    if (![self isHiddenOrHasHiddenAncestor] && state != 2 && _trackingRectTag) {
        NSPoint location = [self convertPoint:[[self window] mouseLocationOutsideOfEventStream] fromView:nil];
        mouseOver = [self mouse:location inRect:[self bounds]];
    }

    if (_mouseOver == mouseOver)
        return;
    _mouseOver = mouseOver;

    if (_redrawOnMouseEnteredAndExited) {
        if ([[self window] firstResponder] == self && [[self window] isKeyWindow])
            [self setKeyboardFocusRingNeedsDisplayInRect:[self bounds]];
        [self setNeedsDisplay:YES];
    }

    [self mouseEnteredOrExited:_mouseOver];
    if ([_delegate respondsToSelector:@selector(rolloverTrackingView:mouseEnteredOrExited:)])
        [_delegate rolloverTrackingView:self mouseEnteredOrExited:_mouseOver];
}

- (void)removeTrackingRect
{
    if (!_trackingRectTag)
        return;
    [self removeTrackingRect:_trackingRectTag];
    _trackingRectTag = 0;
    [self updateMouseIsOver:0];
}

- (void)updateTrackingRect
{
    _trackingRectUpdatePending = NO;
    [self removeTrackingRect];
    if ([self window])
        _trackingRectTag = [self addTrackingRect:[self bounds] owner:self userData:NULL assumeInside:NO];
    [self updateMouseIsOver:0];
}

- (void)_updateTrackingRectSoon
{
    if (_trackingRectUpdatePending)
        return;
    [self performSelector:@selector(updateTrackingRect) withObject:nil afterDelay:0];
    _trackingRectUpdatePending = YES;
}

- (void)viewWillMoveToWindow:(NSWindow *)window
{
    [self removeTrackingRect];
    [super viewWillMoveToWindow:window];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self _updateTrackingRectSoon];
}

- (void)mouseEntered:(NSEvent *)event
{
    if (_trackingRectTag && [event trackingNumber] == _trackingRectTag)
        [self updateMouseIsOver:1];
    [super mouseEntered:event];
}

- (void)mouseExited:(NSEvent *)event
{
    if (_trackingRectTag && [event trackingNumber] == _trackingRectTag)
        [self updateMouseIsOver:2];
    [super mouseExited:event];
}

- (void)rightMouseDown:(NSEvent *)event
{
    [super rightMouseDown:event];
    [self updateMouseIsOver:0];
}

- (void)setDelegate:(id)delegate
{
    _delegate = delegate;
}

- (id)delegate
{
    return _delegate;
}

@end

#pragma mark - WCDoneButton

static NSImage *doneButtonImage;
static NSImage *pressedDoneButtonImage;

@implementation WCDoneButton {
    SEL _buttonClickedAction;
    __unsafe_unretained id _delegateObject;
    BOOL _isPressed;
    __unsafe_unretained id _targetObject;
}

// Renders the localized "Done" title into the button artwork once, and derives the pressed state from it.
+ (void)initialize
{
    doneButtonImage = [NSImage wc_flippedPNGNamed:@"done_move"];

    NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont fontWithName:@"Helvetica" size:14.0], NSFontAttributeName,
        [NSColor whiteColor], NSForegroundColorAttributeName,
        nil];
    NSAttributedString *title = [[NSAttributedString alloc] initWithString:WCLocalizedString("Done") attributes:attributes];

    NSRect titleRect = NSZeroRect;
    NSSize titleSize = [title size];
    titleRect.size = titleSize;
    titleRect.origin.x = ceil(([doneButtonImage size].width - titleSize.width) * 0.5);
    titleRect.origin.y += -3.0;

    [doneButtonImage lockFocus];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:0 yBy:titleSize.height];
    [transform scaleXBy:1.0 yBy:-1.0];
    [transform concat];
    [title drawInRect:titleRect];
    [doneButtonImage unlockFocus];

    pressedDoneButtonImage = [doneButtonImage wc_tintedImageWithColor:[NSColor colorWithCalibratedWhite:0 alpha:0.4] operation:NSCompositingOperationSourceAtop];
}

- (instancetype)init
{
    self = [super init];
    [self setFrameSize:[doneButtonImage size]];
    return self;
}

- (NSImage *)doneButtonImage
{
    return doneButtonImage;
}

- (NSImage *)pressedDoneButtonImage
{
    return pressedDoneButtonImage;
}

- (NSImage *)buttonImage
{
    if (_isPressed)
        return [self pressedDoneButtonImage];
    return [self doneButtonImage];
}

- (void)setIsPressed:(BOOL)pressed
{
    if (_isPressed == pressed)
        return;
    _isPressed = pressed;
    [_delegateObject buttonStateChanged];
}

- (void)setAction:(SEL)action
{
    _buttonClickedAction = action;
}

- (void)setDelegate:(id)delegate
{
    _delegateObject = delegate;
    [delegate buttonStateChanged];
}

- (void)setTarget:(id)target
{
    _targetObject = target;
}

- (void)mouseDown:(NSEvent *)event
{
    [self setIsPressed:YES];
}

- (void)mouseUp:(NSEvent *)event
{
    [self updateTrackingRect];
    if ([self mouseIsOver]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [_targetObject performSelector:_buttonClickedAction];
#pragma clang diagnostic pop
    }
}

- (void)mouseDragged:(NSEvent *)event
{
    NSPoint location = [self convertPoint:[[self window] mouseLocationOutsideOfEventStream] fromView:nil];
    [self setIsPressed:[self mouse:location inRect:[self bounds]] ? YES : NO];
}

- (void)mouseEnteredOrExited:(BOOL)entered
{
    if (!entered)
        [self setIsPressed:NO];
}

@end

#pragma mark - WCErrorView

@implementation WCErrorView {
    NSTextView *_messageView;
}

- (BOOL)isFlipped
{
    return YES;
}

// Offset that vertically centers the laid-out message within the view.
- (float)_verticalOffsetForCenteredMessage
{
    NSRect frame = [self frame];
    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(frame.size.width, FLT_MAX)];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    [layoutManager addTextContainer:textContainer];
    NSTextStorage *textStorage = [_messageView textStorage];
    [textStorage addLayoutManager:layoutManager];
    [layoutManager glyphRangeForTextContainer:textContainer];
    CGFloat usedHeight = [layoutManager usedRectForTextContainer:textContainer].size.height;
    [textStorage removeLayoutManager:layoutManager];
    return floorf((frame.size.height - usedHeight) * 0.5);
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    _messageView = [[NSTextView alloc] init];
    [_messageView setDrawsBackground:NO];
    [_messageView setEditable:NO];
    [_messageView setSelectable:NO];
    [_messageView setAlignment:NSTextAlignmentCenter];
    [self addSubview:_messageView];
    return self;
}

// A bold "Web Clip Not Available" title line followed by the message, white with a dark drop shadow.
- (void)setMessage:(NSString *)message
{
    NSShadow *shadow = [[NSShadow alloc] init];
    [shadow setShadowOffset:NSMakeSize(2.0, -2.0)];
    [shadow setShadowBlurRadius:2.0];
    [shadow setShadowColor:[NSColor colorWithDeviceWhite:0 alpha:1.0]];

    NSMutableString *string = [[NSMutableString alloc] initWithString:WCLocalizedString("Web Clip Not Available")];
    unsigned int titleLength = (unsigned int)[string length];
    [string appendString:@"\n"];
    [string appendString:message];

    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:string];
    NSDictionary *titleAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont fontWithName:@"Helvetica Neue Bold" size:18.0], NSFontAttributeName,
        shadow, NSShadowAttributeName,
        [NSColor whiteColor], NSForegroundColorAttributeName,
        nil];
    [attributedString addAttributes:titleAttributes range:NSMakeRange(0, titleLength)];
    NSDictionary *messageAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont fontWithName:@"Helvetica Neue" size:18.0], NSFontAttributeName,
        shadow, NSShadowAttributeName,
        [NSColor whiteColor], NSForegroundColorAttributeName,
        nil];
    [attributedString addAttributes:messageAttributes range:NSMakeRange(titleLength, [string length] - titleLength)];
    [[_messageView textStorage] setAttributedString:attributedString];

    NSRect messageFrame = [self frame];
    messageFrame.origin.x = 0;
    messageFrame.origin.y = [self _verticalOffsetForCenteredMessage];
    [_messageView setFrame:messageFrame];
}

- (void)drawRect:(NSRect)rect
{
    [[NSColor colorWithCalibratedRed:0.173 green:0.173 blue:0.173 alpha:1.0] set];
    NSRectFill(rect);
}

@end

#pragma mark - WCVoidView

@implementation WCVoidView {
    BOOL _isBlack;
}

- (void)drawRect:(NSRect)rect
{
    [_isBlack ? [NSColor blackColor] : [NSColor whiteColor] set];
    NSRectFill(rect);
}

// The void is the clip view's 20000-point document; as a layer it is a background color rather
// than a bitmap of that size.
- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    self.layer.backgroundColor = _isBlack ? CGColorGetConstantColor(kCGColorBlack) : CGColorGetConstantColor(kCGColorWhite);
}

- (void)setIsBlack:(BOOL)isBlack
{
    _isBlack = isBlack;
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped
{
    return YES;
}

@end
