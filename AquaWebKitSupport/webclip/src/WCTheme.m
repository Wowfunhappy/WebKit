#import "WCThemes.h"

@interface WCTheme ()
- (void)_setEditModeBorderOpacity:(float)opacity;
@end

// Fades the edit border in with a cosine ease, redisplaying the theme at every frame.
@interface WCEditModeBorderFade : NSAnimation
@property (nonatomic, weak) WCTheme *theme;
@end

@implementation WCEditModeBorderFade

- (void)setCurrentProgress:(NSAnimationProgress)progress
{
    [super setCurrentProgress:progress];
    WCTheme *theme = self.theme;
    [theme _setEditModeBorderOpacity:(float)(0.5 - cos(progress * M_PI) * 0.5) * [theme innerBezelOpacity]];
}

@end

#pragma mark - WCTheme

@implementation WCTheme

+ (int)borderLeft
{
    return 0;
}

+ (int)borderRight
{
    return 0;
}

+ (int)borderTop
{
    return 0;
}

+ (int)borderBottom
{
    return 0;
}

- (float)innerBezelOpacity
{
    return 1.0f;
}

- (instancetype)init
{
    self = [super init];
    [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _editModeBorderOpacity = [self innerBezelOpacity];
    return self;
}

- (void)setDashboardWebView:(id)dashboardWebView
{
    _widgetObject = [(id<WCDashboardWebView>)dashboardWebView widget];
}

- (void)setDoneButton:(WCDoneButton *)doneButton
{
    _doneButton = doneButton;
    [doneButton setDelegate:self];
}

// The inner bezel rect inset by the edit border's thickness on every side.
- (NSRect)innerBezelFrame
{
    NSRect frame = [self innerBezelRect];
    float thickness = [_topEditStretch size].height;
    frame.origin.x += thickness;
    frame.origin.y += thickness;
    frame.size.width -= thickness + thickness;
    frame.size.height -= thickness + thickness;
    return frame;
}

- (void)buttonStateChanged
{
    [self display];
}

- (NSPoint)flipperButtonOriginInFrame:(NSRect)frame
{
    return NSMakePoint(frame.origin.x + frame.size.width + -22.0, frame.origin.y + 5.0);
}

// Centers the Done button horizontally in the frame, at doneButtonInsetY below the frame's top.
- (NSPoint)doneButtonOriginInFrame:(NSRect)frame
{
    float width = (double)([self clipInsetLeft] * 2) + frame.size.width;
    NSSize buttonSize = [[self doneButtonImage] size];
    CGFloat x = floorf(width - buttonSize.width) * 0.5f;
    CGFloat y = (double)[self doneButtonInsetY] + frame.origin.y;
    return NSMakePoint(x, y);
}

- (int)resizerImageInsetX
{
    return 0;
}

- (int)resizerImageInsetY
{
    return 0;
}

- (int)resizerInsetX
{
    return 0;
}

- (int)resizerInsetY
{
    return 0;
}

// Draws the edit-mode border around the inner bezel: corners, stretched edges, the notch under the
// Done button, the Done button itself, and the resize grip in the bottom-right corner.
- (void)drawInnerBezelInRect:(NSRect)rect
{
    CGFloat halfWidth = [self bounds].size.width;
    NSRect bezel = [self innerBezelRect];
    NSRect displacement = [self displacementRect];
    halfWidth = halfWidth * 0.5;
    int displacementX = displacement.origin.x;

    CGFloat sideStretchWidth = [_rightEditStretch size].width;
    NSSize topLeftSize = [_topLeftEditCorner size];
    CGFloat topStretchHeight = [_topEditStretch size].height;
    CGFloat topRightWidth = [_topRightEditCorner size].width;
    NSSize bottomLeftSize = [_bottomLeftEditCorner size];
    CGFloat underDoneWidth = [_underDoneButton size].width;

    CGFloat bezelX = bezel.origin.x;
    CGFloat bezelY = bezel.origin.y;
    CGFloat rightX = bezel.size.width + bezelX;
    [_topLeftEditCorner wc_drawAtPoint:NSMakePoint(bezelX, bezelY) dirtyRect:rect fraction:_editModeBorderOpacity];

    rightX = rightX - topRightWidth;
    [_topRightEditCorner wc_drawAtPoint:NSMakePoint(rightX, bezelY) dirtyRect:rect fraction:_editModeBorderOpacity];

    NSRect topStretchRect = NSMakeRect(bezelX + topLeftSize.width, bezelY, bezel.size.width - topLeftSize.width - topRightWidth, topStretchHeight);
    [_topEditStretch wc_drawInRect:topStretchRect dirtyRect:rect fraction:_editModeBorderOpacity];

    CGFloat sideHeight = (int)(bezel.size.height - topLeftSize.height - bottomLeftSize.height);
    NSRect leftSideRect = NSMakeRect(bezel.origin.x, bezel.origin.y + topLeftSize.height, sideStretchWidth, sideHeight);
    [_rightEditStretch wc_drawInRect:leftSideRect dirtyRect:rect fraction:_editModeBorderOpacity];

    NSRect rightSideRect = NSMakeRect(rightX + 4.0, leftSideRect.origin.y, sideStretchWidth, sideHeight);
    [_rightEditStretch wc_drawInRect:rightSideRect dirtyRect:rect fraction:_editModeBorderOpacity];

    CGFloat bottomLeftX = bezel.origin.x;
    CGFloat bottomY = (bezel.size.height + bezel.origin.y) - bottomLeftSize.height;
    [_bottomLeftEditCorner wc_drawAtPoint:NSMakePoint(bottomLeftX, bottomY) dirtyRect:rect fraction:_editModeBorderOpacity];
    [_bottomRightEditCorner wc_drawAtPoint:NSMakePoint(rightX, bottomY) dirtyRect:rect fraction:_editModeBorderOpacity];

    float underDoneX = floorf(-0.5 * underDoneWidth + halfWidth);
    CGFloat displacementXDouble = displacementX;
    CGFloat underDoneXDouble = underDoneX;
    CGFloat bottomStretchY = bottomY + 4.0;
    NSRect bottomLeftStretchRect = NSMakeRect(bottomLeftX + bottomLeftSize.width, bottomStretchY, underDoneXDouble - bezel.origin.x - bottomLeftSize.width - displacementXDouble, 12.0);
    [_bottomEditStretch wc_drawInRect:bottomLeftStretchRect dirtyRect:rect fraction:_editModeBorderOpacity];

    float displacementXFloat = displacementX;
    [_underDoneButton wc_drawAtPoint:NSMakePoint(underDoneX - displacementXFloat, bottomStretchY + 1.0) dirtyRect:rect fraction:_editModeBorderOpacity];

    [[self doneButtonImage] wc_drawAtPoint:NSMakePoint((underDoneX + -2.0f) - displacementXFloat, bottomStretchY + -18.0) dirtyRect:rect];

    float bottomRightStretchX = underDoneWidth + underDoneXDouble;
    NSRect bottomRightStretchRect = NSMakeRect(bottomRightStretchX - displacementXFloat, bottomStretchY, rightX - (double)bottomRightStretchX + displacementXDouble, 12.0);
    [_bottomEditStretch wc_drawInRect:bottomRightStretchRect dirtyRect:rect fraction:_editModeBorderOpacity];

    NSImage *resizer = _resizer;
    int resizerImageInsetX = [self resizerImageInsetX];
    int resizerImageInsetY = [self resizerImageInsetY];
    [resizer wc_drawAtPoint:NSMakePoint(rightX - resizerImageInsetX, bottomStretchY - resizerImageInsetY) dirtyRect:rect];
}

- (void)loadBezelImages
{
    _topLeftEditCorner = [NSImage wc_flippedPNGNamed:@"pan_topleft"];
    _topEditStretch = [NSImage wc_flippedPNGNamed:@"pan_horizstretch_top"];
    _topRightEditCorner = [NSImage wc_flippedPNGNamed:@"pan_toprt"];
    _rightEditStretch = [NSImage wc_flippedPNGNamed:@"pan_vertstretch"];
    _rightEditStretch = [NSImage wc_flippedPNGNamed:@"pan_vertstretch"];
    _bottomLeftEditCorner = [NSImage wc_flippedPNGNamed:@"pan_bottomlt"];
    _bottomEditStretch = [NSImage wc_flippedPNGNamed:@"pan_bottomhorizstretch"];
    _underDoneButton = [NSImage wc_flippedPNGNamed:@"pan_mid_done"];
    _bottomRightEditCorner = [NSImage wc_flippedPNGNamed:@"pan_bottomrt"];
    _resizer = [NSImage wc_flippedPNGNamed:@"resize"];
}

- (void)deallocBezelImages
{
    _topLeftEditCorner = nil;
    _topEditStretch = nil;
    _topRightEditCorner = nil;
    _leftEditStretch = nil;
    _rightEditStretch = nil;
    _bottomLeftEditCorner = nil;
    _bottomEditStretch = nil;
    _underDoneButton = nil;
    _bottomRightEditCorner = nil;
    _resizer = nil;
}

- (NSImage *)doneButtonImage
{
    return [_doneButton buttonImage];
}

- (NSImage *)resizerImage
{
    return _resizer;
}

- (void)drawRect:(NSRect)rect
{
    if (_drawsInnerBezel)
        [self drawInnerBezelInRect:rect];
}

- (BOOL)drawsInPlugInView
{
    return NO;
}

- (void)setEventRegion:(NSRect)rect
{
    NSRect region = rect;
    [(id<WCDashboardWidget>)_widgetObject setEventRegionWithRects:&region count:1];
}

- (NSSize)resizerFrameSize
{
    return [[NSImage wc_flippedPNGNamed:@"resize"] size];
}

- (NSRect)controlRegion
{
    return NSZeroRect;
}

- (NSRect)displacementRect
{
    return NSZeroRect;
}

- (int)themeID
{
    return 0;
}

- (int)clipInsetLeft
{
    return 0;
}

- (int)clipInsetTop
{
    return 0;
}

- (int)clipInsetBottom
{
    return 0;
}

- (NSSize)minSize
{
    return NSZeroSize;
}

- (void)shouldLoadImages:(BOOL)shouldLoad
{
    if (shouldLoad)
        [self loadBezelImages];
    else
        [self deallocBezelImages];
}

- (void)setDrawsInnerBezel:(BOOL)drawsInnerBezel
{
    if (_drawsInnerBezel == drawsInnerBezel)
        return;
    [self shouldLoadImages:drawsInnerBezel];
    _drawsInnerBezel = drawsInnerBezel;
    [self setNeedsDisplay:YES];
}

- (void)_setEditModeBorderOpacity:(float)opacity
{
    if (_editModeBorderOpacity == opacity)
        return;
    _editModeBorderOpacity = opacity;
    [self display];
}

- (void)showEditModeBorder
{
    [_editModeBorderFade stopAnimation];
    WCEditModeBorderFade *fade = [[WCEditModeBorderFade alloc] initWithDuration:0.18 animationCurve:NSAnimationLinear];
    fade.theme = self;
    [fade setAnimationBlockingMode:NSAnimationNonblocking];
    _editModeBorderFade = fade;
    [fade startAnimation];
}

- (void)hideEditModeBorder
{
    [_editModeBorderFade stopAnimation];
    _editModeBorderFade = nil;
    [self _setEditModeBorderOpacity:0];
}

- (NSPoint)resizerOrigin:(NSRect)frame
{
    CGFloat x = (double)[self resizerInsetX] + (frame.origin.x + frame.size.width);
    CGFloat y = frame.origin.y - (double)[self resizerInsetY];
    return NSMakePoint(x, y);
}

- (NSRect)innerBezelRect
{
    NSRect bounds = [self bounds];
    int insetX = [self innerBezelInsetX];
    int insetY = [self innerBezelInsetY];
    int width = [self innerBezelWidth];
    int height = [self innerBezelHeight];
    return NSMakeRect(insetX, insetY, bounds.size.width - width, bounds.size.height - height);
}

- (int)doneButtonInsetY
{
    return 0;
}

- (int)innerBezelInsetX
{
    return 0;
}

- (int)innerBezelInsetY
{
    return 0;
}

- (int)innerBezelWidth
{
    return 0;
}

- (int)innerBezelHeight
{
    return 0;
}

@end

#pragma mark - WCGlassTheme

static NSImage *glassTopLeft;
static NSImage *glassTopMiddle;
static NSImage *glassTopRight;
static NSImage *glassMiddleLeft;
static NSImage *glassMiddleMiddle;
static NSImage *glassMiddleRight;
static NSImage *glassBottomLeft;
static NSImage *glassBottomRight;
static NSImage *glassBottomMiddle;

@implementation WCGlassTheme

+ (void)initialize
{
    glassTopLeft = [NSImage wc_flippedPNGNamed:@"top_left"];
    glassTopMiddle = [NSImage wc_flippedPNGNamed:@"top_mid"];
    glassTopRight = [NSImage wc_flippedPNGNamed:@"top_right"];
    glassMiddleLeft = [NSImage wc_flippedPNGNamed:@"mid_left"];
    glassMiddleMiddle = [NSImage wc_flippedPNGNamed:@"mid_mid"];
    glassMiddleRight = [NSImage wc_flippedPNGNamed:@"mid_right"];
    glassBottomLeft = [NSImage wc_flippedPNGNamed:@"bottom_left"];
    glassBottomRight = [NSImage wc_flippedPNGNamed:@"bottom_right"];
    glassBottomMiddle = [NSImage wc_flippedPNGNamed:@"bottom_mid"];
}

- (float)innerBezelOpacity
{
    return 0.5f;
}

+ (int)borderLeft
{
    return 11;
}

+ (int)borderRight
{
    return 12;
}

+ (int)borderTop
{
    return 6;
}

+ (int)borderBottom
{
    return 16;
}

- (BOOL)isOpaque
{
    return NO;
}

- (BOOL)isFlipped
{
    return YES;
}

- (int)clipInsetLeft
{
    return 11;
}

- (int)clipInsetTop
{
    return 6;
}

- (int)clipInsetBottom
{
    return 16;
}

- (int)themeID
{
    return WCThemeGlass;
}

- (NSSize)resizerFrameSize
{
    return NSMakeSize(20.0, 20.0);
}

// Same layout as WCTheme's edit border, with a wider right edge offset, a taller bottom strip,
// and no displacement.
- (void)drawInnerBezelInRect:(NSRect)rect
{
    CGFloat halfWidth = [self bounds].size.width;
    NSRect bezel = [self innerBezelRect];
    halfWidth = halfWidth * 0.5;

    CGFloat sideStretchWidth = [_rightEditStretch size].width;
    NSSize topLeftSize = [_topLeftEditCorner size];
    CGFloat topStretchHeight = [_topEditStretch size].height;
    CGFloat topRightWidth = [_topRightEditCorner size].width;
    NSSize bottomLeftSize = [_bottomLeftEditCorner size];
    CGFloat underDoneWidth = [_underDoneButton size].width;

    CGFloat bezelX = bezel.origin.x;
    CGFloat bezelY = bezel.origin.y;
    CGFloat rightX = bezel.size.width + bezelX;
    [_topLeftEditCorner wc_drawAtPoint:NSMakePoint(bezelX, bezelY) dirtyRect:rect fraction:_editModeBorderOpacity];

    rightX = rightX - topRightWidth;
    [_topRightEditCorner wc_drawAtPoint:NSMakePoint(rightX, bezelY) dirtyRect:rect fraction:_editModeBorderOpacity];

    NSRect topStretchRect = NSMakeRect(bezelX + topLeftSize.width, bezelY, bezel.size.width - topLeftSize.width - topRightWidth, topStretchHeight);
    [_topEditStretch wc_drawInRect:topStretchRect dirtyRect:rect fraction:_editModeBorderOpacity];

    CGFloat sideHeight = (int)(bezel.size.height - topLeftSize.height - bottomLeftSize.height);
    NSRect leftSideRect = NSMakeRect(bezel.origin.x, bezel.origin.y + topLeftSize.height, sideStretchWidth, sideHeight);
    [_rightEditStretch wc_drawInRect:leftSideRect dirtyRect:rect fraction:_editModeBorderOpacity];

    NSRect rightSideRect = NSMakeRect(rightX + 10.0, leftSideRect.origin.y, sideStretchWidth, sideHeight);
    [_rightEditStretch wc_drawInRect:rightSideRect dirtyRect:rect fraction:_editModeBorderOpacity];

    CGFloat bottomLeftX = bezel.origin.x;
    CGFloat bottomY = (bezel.size.height + bezel.origin.y) - bottomLeftSize.height;
    [_bottomLeftEditCorner wc_drawAtPoint:NSMakePoint(bottomLeftX, bottomY) dirtyRect:rect fraction:_editModeBorderOpacity];
    [_bottomRightEditCorner wc_drawAtPoint:NSMakePoint(rightX, bottomY) dirtyRect:rect fraction:_editModeBorderOpacity];

    float underDoneX = floorf(-0.5 * underDoneWidth + halfWidth);
    CGFloat underDoneXDouble = underDoneX;
    CGFloat bottomStretchY = bottomY + 10.0;
    NSRect bottomLeftStretchRect = NSMakeRect(bottomLeftX + bottomLeftSize.width, bottomStretchY, underDoneXDouble - bezel.origin.x - bottomLeftSize.width, 15.0);
    [_bottomEditStretch wc_drawInRect:bottomLeftStretchRect dirtyRect:rect fraction:_editModeBorderOpacity];

    [_underDoneButton wc_drawAtPoint:NSMakePoint(underDoneXDouble, bottomStretchY) dirtyRect:rect fraction:_editModeBorderOpacity];

    [[self doneButtonImage] wc_drawAtPoint:NSMakePoint(underDoneXDouble, bottomStretchY + -18.0) dirtyRect:rect];

    float bottomRightStretchX = underDoneWidth + underDoneXDouble;
    CGFloat bottomRightStretchXDouble = bottomRightStretchX;
    NSRect bottomRightStretchRect = NSMakeRect(bottomRightStretchXDouble, bottomStretchY, rightX - bottomRightStretchXDouble, 15.0);
    [_bottomEditStretch wc_drawInRect:bottomRightStretchRect dirtyRect:rect fraction:_editModeBorderOpacity];

    NSImage *resizer = _resizer;
    int resizerImageInsetX = [self resizerImageInsetX];
    int resizerImageInsetY = [self resizerImageInsetY];
    [resizer wc_drawAtPoint:NSMakePoint(rightX - resizerImageInsetX, bottomStretchY - resizerImageInsetY) dirtyRect:rect];
}

// Nine-slice glass frame: top and bottom strips at their natural heights, the middle strip filling
// the space between them when it is at least 20 points tall.
- (void)drawThemeInRect:(NSRect)rect
{
    [[NSColor clearColor] set];
    NSRectFillUsingOperation(rect, NSCompositingOperationCopy);

    NSRect bounds = [self bounds];
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

    NSSize topLeftSize = [glassTopLeft size];
    NSRect topRect = NSMakeRect(0, 0, width, topLeftSize.height);
    [self wc_drawLeftImage:glassTopLeft middleImage:glassTopMiddle rightImage:glassTopRight inRect:topRect dirtRect:rect operation:NSCompositingOperationCopy middlePinning:1];

    NSSize bottomLeftSize = [glassBottomLeft size];
    NSRect bottomRect = NSMakeRect(0, height - bottomLeftSize.height, width, bottomLeftSize.height);
    [self wc_drawLeftImage:glassBottomLeft middleImage:glassBottomMiddle rightImage:glassBottomRight inRect:bottomRect dirtRect:rect operation:NSCompositingOperationCopy middlePinning:1];

    CGFloat middleY = topRect.origin.y + topRect.size.height;
    float middleHeight = bottomRect.origin.y - middleY;
    if (middleHeight >= 20.0f) {
        NSRect middleRect = NSMakeRect(0, middleY, width, middleHeight);
        [self wc_drawLeftImage:glassMiddleLeft middleImage:glassMiddleMiddle rightImage:glassMiddleRight inRect:middleRect dirtRect:rect operation:NSCompositingOperationCopy middlePinning:2];
    }
}

- (NSPoint)resizerOrigin:(NSRect)frame
{
    return NSMakePoint(frame.origin.x + frame.size.width + -20.0, 0.0 + frame.origin.y);
}

- (int)doneButtonInsetY
{
    return 8;
}

- (void)drawRect:(NSRect)rect
{
    [self drawThemeInRect:rect];
    [super drawRect:rect];
}

- (NSSize)minSize
{
    NSSize topLeftSize = [glassTopLeft size];
    NSSize bottomLeftSize = [glassBottomLeft size];
    float leftWidth = bottomLeftSize.width > topLeftSize.width ? bottomLeftSize.width : topLeftSize.width;
    CGFloat height = bottomLeftSize.height + topLeftSize.height + 20.0;
    CGFloat topRightWidth = [glassTopRight size].width;
    CGFloat bottomRightWidth = [glassBottomRight size].width;
    float rightWidth = bottomRightWidth > topRightWidth ? bottomRightWidth : topRightWidth;
    float width = rightWidth + leftWidth + 30.0f;
    return NSMakeSize(width, height);
}

- (NSRect)innerBezelFrame
{
    NSRect frame = [self innerBezelRect];
    float thickness = [_topEditStretch size].height;
    frame.origin.x += thickness;
    frame.origin.y += thickness;
    frame.size.width -= thickness + thickness;
    frame.size.height -= thickness + thickness;
    return frame;
}

- (NSRect)controlRegion
{
    NSRect bezel = [self innerBezelRect];
    return NSMakeRect(15.0 + bezel.origin.x, bezel.origin.y + 15.0, -30.0 + bezel.size.width, bezel.size.height + -30.0);
}

- (void)loadBezelImages
{
    _topLeftEditCorner = [NSImage wc_flippedPNGNamed:@"top_left_inner"];
    _topEditStretch = [NSImage wc_flippedPNGNamed:@"top_mid_inner"];
    _topRightEditCorner = [NSImage wc_flippedPNGNamed:@"top_right_inner"];
    _leftEditStretch = [NSImage wc_flippedPNGNamed:@"mid_left_inner"];
    _rightEditStretch = [NSImage wc_flippedPNGNamed:@"mid_right_inner"];
    _bottomLeftEditCorner = [NSImage wc_flippedPNGNamed:@"bottom_left_inner"];
    _bottomEditStretch = [NSImage wc_flippedPNGNamed:@"bottom_mid_inner"];
    _underDoneButton = [NSImage wc_flippedPNGNamed:@"bottom_mid_mid_inner"];
    _bottomRightEditCorner = [NSImage wc_flippedPNGNamed:@"bottom_right_inner"];
    _resizer = [NSImage wc_flippedPNGNamed:@"resize"];
}

- (void)deallocBezelImages
{
    _topLeftEditCorner = nil;
    _topEditStretch = nil;
    _topRightEditCorner = nil;
    _leftEditStretch = nil;
    _rightEditStretch = nil;
    _bottomLeftEditCorner = nil;
    _bottomEditStretch = nil;
    _underDoneButton = nil;
    _bottomRightEditCorner = nil;
    _resizer = nil;
}

- (int)innerBezelInsetX
{
    return 10;
}

- (int)innerBezelInsetY
{
    return 5;
}

- (int)innerBezelWidth
{
    return 21;
}

- (int)innerBezelHeight
{
    return 20;
}

- (int)resizerImageInsetX
{
    return -2;
}

- (int)resizerImageInsetY
{
    return 5;
}

@end

#pragma mark - WCBlackEdgeTheme

static NSImage *blackEdgeTopLeft;
static NSImage *blackEdgeTopMiddle;
static NSImage *blackEdgeTopRight;
static NSImage *blackEdgeMiddleLeft;
static NSImage *blackEdgeMiddleMiddle;
static NSImage *blackEdgeMiddleRight;
static NSImage *blackEdgeBottomLeft;
static NSImage *blackEdgeBottomMiddle;
static NSImage *blackEdgeBottomRight;

@implementation WCBlackEdgeTheme

+ (void)initialize
{
    blackEdgeTopLeft = [NSImage wc_flippedPNGNamed:@"blackedge_top_left"];
    blackEdgeTopMiddle = [NSImage wc_flippedPNGNamed:@"blackedge_top_mid"];
    blackEdgeTopRight = [NSImage wc_flippedPNGNamed:@"blackedge_top_right"];
    blackEdgeMiddleLeft = [NSImage wc_flippedPNGNamed:@"blackedge_mid_left"];
    blackEdgeMiddleMiddle = [NSImage wc_flippedPNGNamed:@"blackedge_mid_mid"];
    blackEdgeMiddleRight = [NSImage wc_flippedPNGNamed:@"blackedge_mid_right"];
    blackEdgeBottomLeft = [NSImage wc_flippedPNGNamed:@"blackedge_bottom_left"];
    blackEdgeBottomMiddle = [NSImage wc_flippedPNGNamed:@"blackedge_bottom_mid"];
    blackEdgeBottomRight = [NSImage wc_flippedPNGNamed:@"blackedge_bottom_right"];
}

+ (int)borderLeft
{
    return 18;
}

+ (int)borderRight
{
    return 18;
}

+ (int)borderTop
{
    return 12;
}

+ (int)borderBottom
{
    return 22;
}

- (int)doneButtonInsetY
{
    return 9;
}

- (BOOL)isOpaque
{
    return NO;
}

- (BOOL)isFlipped
{
    return YES;
}

- (int)clipInsetLeft
{
    return 18;
}

- (int)clipInsetBottom
{
    return 22;
}

- (int)clipInsetTop
{
    return 12;
}

- (int)innerBezelInsetX
{
    return 18;
}

- (int)innerBezelInsetY
{
    return 12;
}

- (int)innerBezelWidth
{
    return 36;
}

- (int)innerBezelHeight
{
    return 34;
}

- (NSSize)resizerFrameSize
{
    return NSMakeSize(30.0, 30.0);
}

- (int)resizerInsetX
{
    return -18;
}

- (int)resizerInsetY
{
    return 10;
}

- (int)resizerImageInsetX
{
    return 2;
}

- (int)resizerImageInsetY
{
    return 5;
}

// Nine-slice frame: the top strip's middle pinned to its top, the bottom strip's to its bottom,
// and the middle strip filling everything between them.
- (void)drawThemeInRect:(NSRect)rect
{
    [[NSColor clearColor] set];
    NSRectFillUsingOperation(rect, NSCompositingOperationCopy);

    NSRect bounds = [self bounds];
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

    [blackEdgeTopLeft size];
    CGFloat topHeight = [blackEdgeTopLeft size].height;
    CGFloat bottomHeight = [blackEdgeBottomLeft size].height;
    NSRect topRect = NSMakeRect(0, 0, width, [blackEdgeTopLeft size].height);
    [self wc_drawLeftImage:blackEdgeTopLeft middleImage:blackEdgeTopMiddle rightImage:blackEdgeTopRight inRect:topRect dirtRect:rect operation:NSCompositingOperationCopy middlePinning:0];

    CGFloat middleY = 0.0 + topHeight;
    CGFloat bottomY = height - bottomHeight;
    float middleHeight = bottomY - middleY;
    NSRect middleRect = NSMakeRect(0, middleY, width, middleHeight);
    [self wc_drawLeftImage:blackEdgeMiddleLeft middleImage:blackEdgeMiddleMiddle rightImage:blackEdgeMiddleRight inRect:middleRect dirtRect:rect operation:NSCompositingOperationCopy middlePinning:2];

    NSRect bottomRect = NSMakeRect(0, bottomY, width, bottomHeight);
    [self wc_drawLeftImage:blackEdgeBottomLeft middleImage:blackEdgeBottomMiddle rightImage:blackEdgeBottomRight inRect:bottomRect dirtRect:rect operation:NSCompositingOperationCopy middlePinning:1];
}

- (void)drawRect:(NSRect)rect
{
    [self drawThemeInRect:rect];
    [super drawRect:rect];
}

- (int)themeID
{
    return WCThemeBlackEdge;
}

- (NSRect)controlRegion
{
    return [self innerBezelRect];
}

- (NSSize)minSize
{
    NSSize topLeftSize = [blackEdgeTopLeft size];
    NSSize bottomLeftSize = [blackEdgeBottomLeft size];
    float leftWidth = bottomLeftSize.width > topLeftSize.width ? bottomLeftSize.width : topLeftSize.width;
    CGFloat height = bottomLeftSize.height + topLeftSize.height + 34.0;
    CGFloat topRightWidth = [blackEdgeTopRight size].width;
    CGFloat bottomRightWidth = [blackEdgeBottomRight size].width;
    float rightWidth = bottomRightWidth > topRightWidth ? bottomRightWidth : topRightWidth;
    float width = (rightWidth > leftWidth ? rightWidth : leftWidth) + 36.0f;
    return NSMakeSize(width, height);
}

@end

#pragma mark - WCVintageCornersTheme

static NSImage *vintageTopLeft;
static NSImage *vintageTopStretch;
static NSImage *vintageTopRight;
static NSImage *vintageLeftStretch;
static NSImage *vintageRightStretch;
static NSImage *vintageBottomLeft;
static NSImage *vintageBottomStretch;
static NSImage *vintageBottomRight;

@implementation WCVintageCornersTheme

+ (void)initialize
{
    vintageTopLeft = [NSImage wc_flippedPNGNamed:@"vintagecorners_topleft"];
    vintageTopStretch = [NSImage wc_flippedPNGNamed:@"vintagecorners_topstretch"];
    vintageTopRight = [NSImage wc_flippedPNGNamed:@"vintagecorners_topright"];
    vintageLeftStretch = [NSImage wc_flippedPNGNamed:@"vintagecorners_leftstretch"];
    vintageRightStretch = [NSImage wc_flippedPNGNamed:@"vintagecorners_rightstretch"];
    vintageBottomLeft = [NSImage wc_flippedPNGNamed:@"vintagecorners_bottomleft"];
    vintageBottomStretch = [NSImage wc_flippedPNGNamed:@"vintagecorners_bottomstretch"];
    vintageBottomRight = [NSImage wc_flippedPNGNamed:@"vintagecorners_bottomright"];
}

+ (int)borderLeft
{
    return 30;
}

+ (int)borderRight
{
    return 30;
}

+ (int)borderTop
{
    return 30;
}

+ (int)borderBottom
{
    return 30;
}

- (int)doneButtonInsetY
{
    return 9;
}

- (BOOL)isOpaque
{
    return NO;
}

- (BOOL)isFlipped
{
    return YES;
}

- (int)clipInsetLeft
{
    return 30;
}

- (int)clipInsetBottom
{
    return 30;
}

- (int)clipInsetTop
{
    return 30;
}

- (int)innerBezelInsetX
{
    return 30;
}

- (int)innerBezelInsetY
{
    return 30;
}

- (int)innerBezelWidth
{
    return 62;
}

- (int)innerBezelHeight
{
    return 62;
}

- (NSSize)resizerFrameSize
{
    return NSMakeSize(45.0, 45.0);
}

- (int)resizerInsetX
{
    return -5;
}

- (int)resizerInsetY
{
    return 30;
}

- (int)resizerImageInsetX
{
    return -15;
}

- (int)resizerImageInsetY
{
    return -10;
}

// Four photo-corner images with stretched edges between them. The bottom-right corner is placed
// using the bottom-left corner's size.
- (void)drawThemeInRect:(NSRect)rect
{
    [[NSColor clearColor] set];
    NSRectFillUsingOperation(rect, NSCompositingOperationCopy);

    NSRect bounds = [self bounds];
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

    CGFloat topRightWidth = [vintageTopRight size].width;
    CGFloat topLeftWidth = [vintageTopLeft size].width;
    NSSize topLeftSize = [vintageTopLeft size];
    NSRect topLeftRect = NSMakeRect(0, 0, topLeftWidth, topLeftSize.height);
    CGFloat topRightX = (int)(width - topRightWidth);

    CGFloat topRightRectWidth = [vintageTopRight size].width;
    NSSize topRightSize = [vintageTopRight size];
    NSRect topRightRect = NSMakeRect(topRightX, 0, topRightRectWidth, topRightSize.height);

    CGFloat topStretchX = [vintageTopLeft size].width + -1.0;
    CGFloat topStretchInset = [vintageTopRight size].width;
    NSSize topStretchSize = [vintageTopStretch size];
    NSRect topStretchRect = NSMakeRect(topStretchX, 10.0, topStretchInset * -2.0 + width + 1.0, topStretchSize.height);

    NSSize bottomLeftSize = [vintageBottomLeft size];
    CGFloat bottomLeftY = height - bottomLeftSize.height;
    NSRect bottomLeftRect = NSMakeRect(0, bottomLeftY, bottomLeftSize.width, bottomLeftSize.height);
    NSSize bottomCornerSize = [vintageBottomLeft size];

    [vintageTopLeft wc_drawInRect:topLeftRect dirtyRect:rect];
    [vintageTopStretch wc_drawInRect:topStretchRect dirtyRect:rect];
    [vintageTopRight wc_drawInRect:topRightRect dirtyRect:rect];

    CGFloat sideY = topLeftRect.origin.y + topLeftRect.size.height;
    float sideHeight = bottomLeftY - sideY;
    NSRect sideRect = NSMakeRect(10.0, -2.0 + sideY, -10.0 + width, sideHeight + 4.0f);
    [self wc_drawLeftImage:vintageLeftStretch middleImage:nil rightImage:vintageRightStretch inRect:sideRect dirtRect:rect operation:NSCompositingOperationCopy middlePinning:2];

    [vintageBottomLeft wc_drawInRect:bottomLeftRect dirtyRect:rect];

    CGFloat bottomStretchX = [vintageTopLeft size].width;
    CGFloat bottomStretchHeight = [vintageBottomStretch size].height;
    CGFloat bottomRightY = height - bottomCornerSize.height;
    CGFloat bottomRightX = width - bottomCornerSize.width;
    bottomStretchX = bottomStretchX + -4.0;
    CGFloat bottomStretchInset = [vintageTopRight size].width;
    NSSize bottomStretchSize = [vintageBottomStretch size];
    NSRect bottomStretchRect = NSMakeRect(bottomStretchX, height - bottomStretchHeight + -8.0, width - (bottomStretchInset + bottomStretchInset) + 8.0, bottomStretchSize.height);
    NSRect bottomRightRect = NSMakeRect(bottomRightX, bottomRightY, bottomCornerSize.width, bottomCornerSize.height);
    [vintageBottomStretch wc_drawInRect:bottomStretchRect dirtyRect:rect];
    [vintageBottomRight wc_drawInRect:bottomRightRect dirtyRect:rect];
}

- (void)drawRect:(NSRect)rect
{
    [self drawThemeInRect:rect];
    [super drawRect:rect];
}

- (int)themeID
{
    return WCThemeVintageCorners;
}

- (NSRect)controlRegion
{
    return [self innerBezelRect];
}

- (NSPoint)flipperButtonOriginInFrame:(NSRect)frame
{
    return NSMakePoint(frame.origin.x + frame.size.width + -24.0, frame.origin.y + 8.0);
}

- (NSSize)minSize
{
    NSSize topLeftSize = [vintageTopLeft size];
    NSSize bottomLeftSize = [vintageBottomLeft size];
    float leftWidth = bottomLeftSize.width > topLeftSize.width ? bottomLeftSize.width : topLeftSize.width;
    CGFloat height = bottomLeftSize.height + topLeftSize.height + 62.0;
    leftWidth = leftWidth + 62.0f;
    CGFloat topRightWidth = [vintageTopRight size].width;
    CGFloat bottomRightWidth = [vintageBottomRight size].width;
    float rightWidth = bottomRightWidth > topRightWidth ? bottomRightWidth : topRightWidth;
    float width = rightWidth + leftWidth;
    return NSMakeSize(width, height);
}

@end
