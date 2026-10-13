// The Plain, Pegboard and Torn Edge themes.

#import "WCThemes.h"

// AppKit's tiler: fills `rect` (clipped to it) with `image` repeated from `phase`.
extern void _NSTileImageWithOperation(NSRect rect, NSImage *image, BOOL isFlipped, NSPoint phase, NSCompositingOperation operation, CGFloat fraction);

#pragma mark - Plain

// Glass's outer corner radius.
static const CGFloat WCPlainCornerRadius = 5;

// Glass's drop shadow, measured from its artwork: black at half opacity, cast 4.5 points down.
static const CGFloat WCPlainShadowOffset = 4.5;
static const CGFloat WCPlainShadowBlur = 6.5;
static const CGFloat WCPlainShadowOpacity = 0.5;

@implementation WCPlainTheme

// The shadow's extent beyond Glass's outer rim; the right border includes the plug-in view's column
// the widget window clips.
+ (int)borderLeft
{
    return 7;
}

+ (int)borderRight
{
    return 8;
}

+ (int)borderTop
{
    return 2;
}

+ (int)borderBottom
{
    return 12;
}

- (int)themeID
{
    return WCThemePlain;
}

- (BOOL)masksPage
{
    return YES;
}

- (int)clipInsetLeft
{
    return 7;
}

- (int)clipInsetTop
{
    return 2;
}

- (int)clipInsetBottom
{
    return 12;
}

// The edit border lines the page's edges.
- (int)innerBezelInsetX
{
    return 7;
}

- (int)innerBezelInsetY
{
    return 2;
}

- (int)innerBezelWidth
{
    return 13;
}

- (int)innerBezelHeight
{
    return 14;
}

// The page's rounded rect in the theme, which the widget window ends one column short of the plug-in view.
- (NSRect)pageRect
{
    NSRect bounds = [self bounds];
    int left = [self clipInsetLeft];
    int top = [self clipInsetTop];
    return NSMakeRect(left, top, NSWidth(bounds) - left - (left - 1), NSHeight(bounds) - top - [self clipInsetBottom]);
}

// Clears the theme outside the page's rounded rect, which leaves the page those corners, and casts the
// page's shadow there. The shape casting it lies a theme's width to the left, with the shadow offset
// back across, so only its shadow lands.
- (void)drawThemeInRect:(NSRect)rect
{
    NSRect bounds = [self bounds];
    NSRect pageRect = [self pageRect];
    NSBezierPath *outside = [NSBezierPath bezierPathWithRect:bounds];
    [outside appendBezierPath:[NSBezierPath bezierPathWithRoundedRect:pageRect xRadius:WCPlainCornerRadius yRadius:WCPlainCornerRadius]];
    [outside setWindingRule:NSEvenOddWindingRule];
    [NSGraphicsContext saveGraphicsState];
    [outside addClip];
    [[NSColor clearColor] set];
    NSRectFillUsingOperation(rect, NSCompositeCopy);

    CGContextRef context = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    CGFloat away = NSWidth(bounds) + 4 * WCPlainShadowBlur;
    CGSize deviceAway = CGContextConvertSizeToDeviceSpace(context, CGSizeMake(away, 0));
    CGSize deviceBlur = CGContextConvertSizeToDeviceSpace(context, CGSizeMake(WCPlainShadowBlur, 0));
    CGColorRef color = CGColorCreateGenericGray(0, WCPlainShadowOpacity);
    CGContextSetShadowWithColor(context, CGSizeMake(hypot(deviceAway.width, deviceAway.height), 0), hypot(deviceBlur.width, deviceBlur.height), color);
    CGColorRelease(color);
    NSRect casterRect = NSOffsetRect(pageRect, -away, [self isFlipped] ? WCPlainShadowOffset : -WCPlainShadowOffset);
    [[NSColor blackColor] set];
    [[NSBezierPath bezierPathWithRoundedRect:casterRect xRadius:WCPlainCornerRadius yRadius:WCPlainCornerRadius] fill];
    [NSGraphicsContext restoreGraphicsState];
}

@end

#pragma mark - Pegboard

static NSImage *sPegboard;
static NSImage *sPegboardTopLeftMask;
static NSImage *sPegboardTopRightMask;
static NSImage *sPegboardBottomLeftMask;
static NSImage *sPegboardBottomRightMask;
static NSImage *sPegboardTopLeftMetal;
static NSImage *sPegboardTopStretchMetal;
static NSImage *sPegboardTopRightMetal;
static NSImage *sPegboardBottomLeftMetal;
static NSImage *sPegboardBottomStretchMetal;
static NSImage *sPegboardBottomRightMetal;
static NSImage *sPegboardLeftStretchMetal;
static NSImage *sPegboardRightStretchMetal;
static NSColor *sPegboardEtchColor;
static NSImage *sPegboardLeftShine;
static NSImage *sPegboardStretchShine;
static NSImage *sPegboardRightShine;

@implementation WCPegboardTheme

+ (void)initialize
{
    sPegboard = [NSImage wc_flippedPNGNamed:@"pegboard"];
    sPegboardTopLeftMask = [NSImage wc_flippedPNGNamed:@"pegboard_topleftmask"];
    sPegboardTopRightMask = [NSImage wc_flippedPNGNamed:@"pegboard_toprightmask"];
    sPegboardBottomLeftMask = [NSImage wc_flippedPNGNamed:@"pegboard_bottomleftmask"];
    sPegboardBottomRightMask = [NSImage wc_flippedPNGNamed:@"pegboard_bottomrightmask"];
    sPegboardTopLeftMetal = [NSImage wc_flippedPNGNamed:@"pegboard_topleftmetal"];
    sPegboardTopStretchMetal = [NSImage wc_flippedPNGNamed:@"pegboard_topstretchmetal"];
    sPegboardTopRightMetal = [NSImage wc_flippedPNGNamed:@"pegboard_toprightmetal"];
    sPegboardBottomLeftMetal = [NSImage wc_flippedPNGNamed:@"pegboard_bottomleftmetal"];
    sPegboardBottomStretchMetal = [NSImage wc_flippedPNGNamed:@"pegboard_bottomstretchmetal"];
    sPegboardBottomRightMetal = [NSImage wc_flippedPNGNamed:@"pegboard_bottomrightmetal"];
    sPegboardLeftStretchMetal = [NSImage wc_flippedPNGNamed:@"pegboard_leftstretchmetal"];
    sPegboardRightStretchMetal = [NSImage wc_flippedPNGNamed:@"pegboard_rightstretchmetal"];
    sPegboardEtchColor = [[NSColor blackColor] colorWithAlphaComponent:0.5];
    sPegboardLeftShine = [NSImage wc_flippedPNGNamed:@"pegboard_leftshine"];
    sPegboardStretchShine = [NSImage wc_flippedPNGNamed:@"pegboard_stretchshine"];
    sPegboardRightShine = [NSImage wc_flippedPNGNamed:@"pegboard_rightshine"];
}

+ (int)borderLeft
{
    return 20;
}

+ (int)borderRight
{
    return 25;
}

+ (int)borderTop
{
    return 14;
}

+ (int)borderBottom
{
    return 26;
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
    return 20;
}

- (int)clipInsetBottom
{
    return 26;
}

- (int)clipInsetTop
{
    return 14;
}

- (int)innerBezelInsetX
{
    return 20;
}

- (int)innerBezelInsetY
{
    return 13;
}

- (int)innerBezelWidth
{
    return 40;
}

- (int)innerBezelHeight
{
    return 39;
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

// Four 12pt-wide strips of pegboard around the web view.
- (void)_drawPegboardInRect:(NSRect)rect
{
    NSRect bounds = [self bounds];
    double width = bounds.size.width;
    double height = bounds.size.height - 2.0 - 12.0;
    double stripWidth = width - 8.0 - 12.0;
    NSPoint phase = NSZeroPoint;
    _NSTileImageWithOperation(NSMakeRect(8.0, 2.0, stripWidth, 12.0), sPegboard, NO, phase, NSCompositeCopy, 1.0);
    _NSTileImageWithOperation(NSMakeRect(8.0, 2.0, 12.0, height), sPegboard, NO, phase, NSCompositeCopy, 1.0);
    _NSTileImageWithOperation(NSMakeRect(width - 12.0 - 8.0, 2.0, 12.0, height), sPegboard, NO, phase, NSCompositeCopy, 1.0);
    _NSTileImageWithOperation(NSMakeRect(8.0, height - 12.0, stripWidth, 12.0), sPegboard, NO, phase, NSCompositeCopy, 1.0);
}

// Rounds the pegboard's outer corners.
- (void)_drawPegboardMaskInRect:(NSRect)rect
{
    NSRect bounds = [self bounds];
    double width = bounds.size.width;
    double height = bounds.size.height;

    NSSize size = [sPegboardTopLeftMask size];
    [sPegboardTopLeftMask drawInRect:NSMakeRect(8.0, 2.0, size.width, size.height) fromRect:NSZeroRect operation:NSCompositeDestinationOut fraction:1.0];

    size = [sPegboardTopRightMask size];
    [sPegboardTopRightMask drawInRect:NSMakeRect(width - size.width - 8.0, 2.0, size.width, size.height) fromRect:NSZeroRect operation:NSCompositeDestinationOut fraction:1.0];

    size = [sPegboardBottomLeftMask size];
    [sPegboardBottomLeftMask drawInRect:NSMakeRect(8.0, height - size.height - 12.0, size.width, size.height) fromRect:NSZeroRect operation:NSCompositeDestinationOut fraction:1.0];

    size = [sPegboardBottomRightMask size];
    [sPegboardBottomRightMask drawInRect:NSMakeRect(width - size.width - 7.0 - 1.0, height - size.height - 12.0, size.width, size.height) fromRect:NSZeroRect operation:NSCompositeDestinationOut fraction:1.0];
}

- (void)_drawMetalInRect:(NSRect)rect
{
    NSRect bounds = [self bounds];
    double width = bounds.size.width;
    double height = bounds.size.height;

    NSSize size = [sPegboardTopLeftMetal size];
    double topLeftWidth = size.width;
    NSRect topLeftRect = NSMakeRect(0, 0, size.width, size.height);
    [sPegboardTopLeftMetal wc_drawInRect:topLeftRect dirtyRect:rect];

    size = [sPegboardTopRightMetal size];
    double topRightWidth = size.width;
    NSRect topRightRect = NSMakeRect(width - size.width, 0, size.width, size.height);
    [sPegboardTopRightMetal wc_drawInRect:topRightRect dirtyRect:rect];

    double stretchWidth = width - topLeftWidth - topRightWidth;

    size = [sPegboardTopStretchMetal size];
    [sPegboardTopStretchMetal wc_drawInRect:NSMakeRect(topLeftRect.origin.x + topLeftRect.size.width, 0, stretchWidth, size.height) dirtyRect:rect];

    size = [sPegboardBottomLeftMetal size];
    NSRect bottomLeftRect = NSMakeRect(0, height - size.height, size.width, size.height);
    [sPegboardBottomLeftMetal wc_drawInRect:bottomLeftRect dirtyRect:rect];

    size = [sPegboardLeftStretchMetal size];
    [sPegboardLeftStretchMetal wc_drawInRect:NSMakeRect(0, topLeftRect.size.height, size.width, bottomLeftRect.origin.y - 12.0) dirtyRect:rect];

    size = [sPegboardBottomRightMetal size];
    NSRect bottomRightRect = NSMakeRect(width - size.width, height - size.height, size.width, size.height);
    [sPegboardBottomRightMetal wc_drawInRect:bottomRightRect dirtyRect:rect];

    size = [sPegboardRightStretchMetal size];
    [sPegboardRightStretchMetal wc_drawInRect:NSMakeRect(width - 12.0, topRightRect.size.height, size.width, -12.0 + bottomRightRect.origin.y) dirtyRect:rect];

    size = [sPegboardBottomStretchMetal size];
    [sPegboardBottomStretchMetal wc_drawInRect:NSMakeRect(topLeftRect.origin.x + topLeftRect.size.width, height - size.height, stretchWidth, size.height) dirtyRect:rect];
}

- (void)_drawEtchedOutlineAroundWebView
{
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    BOOL shouldAntialias = [context shouldAntialias];
    [context setShouldAntialias:NO];
    NSRect outline = [self innerBezelRect];
    outline.origin.y = outline.origin.y + 2.0;
    outline.size.width = outline.size.width - 1.0;
    outline.size.height = outline.size.height - 2.0;
    [sPegboardEtchColor set];
    [NSBezierPath strokeRect:outline];
    [context setShouldAntialias:shouldAntialias];
}

- (void)_drawShineInRect:(NSRect)rect
{
    double width = [self bounds].size.width - 11.0;
    double height = [sPegboardLeftShine size].height;
    [self wc_drawLeftImage:sPegboardLeftShine middleImage:sPegboardStretchShine rightImage:sPegboardRightShine inRect:NSMakeRect(11.0, 6.0, width, height) dirtRect:rect operation:NSCompositeSourceOver middlePinning:1];
}

- (void)drawThemeInRect:(NSRect)rect
{
    [[NSColor clearColor] set];
    NSRectFillUsingOperation(rect, NSCompositeCopy);
    [self _drawPegboardInRect:rect];
    [self _drawPegboardMaskInRect:rect];
    [self _drawMetalInRect:rect];
    [self _drawEtchedOutlineAroundWebView];
    [self _drawShineInRect:rect];
}

- (void)drawRect:(NSRect)rect
{
    [self drawThemeInRect:rect];
    [super drawRect:rect];
}

- (int)themeID
{
    return WCThemePegboard;
}

- (NSRect)controlRegion
{
    return [self innerBezelRect];
}

- (NSSize)minSize
{
    return NSMakeSize(250.0, 250.0);
}

@end

#pragma mark - Torn Edge

static NSImage *sTornTop;
static NSImage *sTornBottom;
static NSImage *sTornCorner;
static NSImage *sTornPanVerticalLeftStretch;
static NSImage *sTornPanVerticalRightStretch;
static NSImage *sTornPanTopLeft;
static NSImage *sTornPanTopStretch;
static NSImage *sTornPanTopRight;
static NSImage *sTornPanBottomLeft;
static NSImage *sTornBottomStretch;
static NSImage *sTornPanBottomCenter;
static NSImage *sTornPanBottomRight;
static NSImage *sTornResize;

@implementation WCTornEdgeTheme

+ (void)initialize
{
    sTornTop = [NSImage wc_flippedPNGNamed:@"torn_top"];
    sTornBottom = [NSImage wc_flippedPNGNamed:@"torn_bottom"];
    sTornCorner = [NSImage wc_flippedPNGNamed:@"torn_corner"];
    sTornPanVerticalLeftStretch = [NSImage wc_flippedPNGNamed:@"torn_pan_vertical_left_stretch"];
    sTornPanVerticalRightStretch = [NSImage wc_flippedPNGNamed:@"torn_pan_vertical_right_stretch"];
    sTornPanTopLeft = [NSImage wc_flippedPNGNamed:@"torn_pan_top_left"];
    sTornPanTopStretch = [NSImage wc_flippedPNGNamed:@"torn_pan_top_stretch"];
    sTornPanTopRight = [NSImage wc_flippedPNGNamed:@"torn_pan_top_right"];
    sTornPanBottomLeft = [NSImage wc_flippedPNGNamed:@"torn_pan_bottom_left"];
    sTornBottomStretch = [NSImage wc_flippedPNGNamed:@"torn_bottom_stretch"];
    sTornPanBottomCenter = [NSImage wc_flippedPNGNamed:@"torn_pan_bottom_center"];
    sTornPanBottomRight = [NSImage wc_flippedPNGNamed:@"torn_pan_bottom_right"];
    sTornResize = [NSImage wc_flippedPNGNamed:@"resize"];
}

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

- (int)themeID
{
    return WCThemeTornEdge;
}

- (NSPoint)flipperButtonOriginInFrame:(NSRect)frame
{
    return NSMakePoint(frame.size.width - 34.0, frame.origin.y + 16.0);
}

- (NSSize)minSize
{
    return NSMakeSize(160.0, 100.0);
}

- (BOOL)drawsInPlugInView
{
    return YES;
}

- (int)doneButtonInsetY
{
    return 29;
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
    return 0;
}

- (int)clipInsetBottom
{
    return 0;
}

- (int)clipInsetTop
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

- (NSSize)resizerFrameSize
{
    return NSMakeSize(40.0, 40.0);
}

- (int)resizerInsetX
{
    return -45;
}

- (int)resizerInsetY
{
    return -2;
}

- (int)resizerImageInsetX
{
    return 2;
}

- (int)resizerImageInsetY
{
    return 5;
}

// The edit-mode "pan": a frame around the clip with the Done button and resizer set into its bottom edge.
- (void)drawInnerBezelInRect:(NSRect)dirtyRect
{
    double halfWidth = [self bounds].size.width * 0.5;
    NSRect bezel = [self innerBezelRect];

    NSSize bottomLeftSize = [sTornPanBottomLeft size];
    double bottomCenterWidth = [sTornPanBottomCenter size].width;
    NSSize topLeftSize = [sTornPanTopLeft size];
    double topStretchHeight = [sTornPanTopStretch size].height;
    double topRightWidth = [sTornPanTopRight size].width;
    double leftStretchWidth = [sTornPanVerticalLeftStretch size].width;
    double rightStretchWidth = [sTornPanVerticalRightStretch size].width;

    double left = bezel.origin.x;
    double top = bezel.origin.y;
    double right = bezel.size.width + left;

    [sTornPanTopLeft wc_drawAtPoint:NSMakePoint(left, top) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];
    right = right - topRightWidth;
    [sTornPanTopRight wc_drawAtPoint:NSMakePoint(right, top) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];
    [sTornPanTopStretch wc_drawInRect:NSMakeRect(left + topLeftSize.width, top, bezel.size.width - topLeftSize.width - topRightWidth, topStretchHeight) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];

    double sideTop = bezel.origin.y + topLeftSize.height;
    double sideHeight = (double)(int)(bezel.size.height - topLeftSize.height - bottomLeftSize.height);
    [sTornPanVerticalLeftStretch wc_drawInRect:NSMakeRect(bezel.origin.x, sideTop, leftStretchWidth, sideHeight) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];
    [sTornPanVerticalRightStretch wc_drawInRect:NSMakeRect(4.0 + right, sideTop, rightStretchWidth, sideHeight) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];

    double bottomLeftX = bezel.origin.x;
    double bottomY = bezel.size.height + bezel.origin.y - bottomLeftSize.height;
    [sTornPanBottomLeft wc_drawAtPoint:NSMakePoint(bottomLeftX, bottomY) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];
    [sTornPanBottomRight wc_drawAtPoint:NSMakePoint(right, bottomY) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];

    float centerX = floorf((float)(-0.5 * bottomCenterWidth + halfWidth));
    double center = (double)centerX;
    double stretchY = bottomY + 3.0;
    [sTornBottomStretch wc_drawInRect:NSMakeRect(bottomLeftX + bottomLeftSize.width, stretchY, center - bezel.origin.x - bottomLeftSize.width, 30.0) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];
    [sTornPanBottomCenter wc_drawAtPoint:NSMakePoint(center, stretchY) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];

    float doneX = centerX + -2.0f;
    [[self doneButtonImage] wc_drawAtPoint:NSMakePoint((double)doneX, stretchY - 16.0) dirtyRect:dirtyRect];

    double afterCenter = (double)(float)(bottomCenterWidth + center);
    [sTornBottomStretch wc_drawInRect:NSMakeRect(afterCenter, stretchY, right - afterCenter, 30.0) dirtyRect:dirtyRect fraction:_editModeBorderOpacity];

    NSImage *resizer = _resizer;
    int insetX = [self resizerImageInsetX];
    int insetY = [self resizerImageInsetY];
    [resizer wc_drawAtPoint:NSMakePoint(right - (double)insetX, stretchY - (double)insetY) dirtyRect:dirtyRect];
}

- (NSRect)innerBezelFrame
{
    NSRect frame = [self innerBezelRect];
    double topHeight = (double)(float)[sTornPanTopStretch size].height;
    frame.origin.x = frame.origin.x + topHeight;
    frame.origin.y = frame.origin.y + topHeight;
    double leftWidth = [sTornPanVerticalLeftStretch size].width;
    frame.size.width = frame.size.width - (leftWidth + [sTornPanVerticalRightStretch size].width);
    frame.size.height = frame.size.height - ([sTornBottomStretch size].height + topHeight);
    return frame;
}

// Cuts the torn paper edge along the bottom and right of the clip.
- (void)drawThemeInRect:(NSRect)rect
{
    NSRect frame = [self frame];
    double width = frame.size.width;
    double height = frame.size.height;
    NSSize cornerSize = [sTornCorner size];
    double topWidth = [sTornTop size].width;
    double bottomHeight = [sTornBottom size].height;

    NSRect cornerRect = NSMakeRect(width - cornerSize.width, height - cornerSize.height, cornerSize.width, cornerSize.height);
    int bottomWidth = (int)cornerRect.origin.x;
    NSRect topRect = NSMakeRect(cornerRect.origin.x + cornerSize.width - topWidth, 0, topWidth, (double)(int)cornerRect.origin.y);

    double bottomY = height - [sTornBottom size].height;
    NSPoint phase = NSZeroPoint;
    _NSTileImageWithOperation(NSMakeRect(0, bottomY, (double)bottomWidth, bottomHeight), sTornBottom, NO, phase, NSCompositeDestinationIn, 1.0);
    [sTornCorner drawInRect:cornerRect fromRect:NSZeroRect operation:NSCompositeDestinationIn fraction:1.0];
    _NSTileImageWithOperation(topRect, sTornTop, NO, phase, NSCompositeDestinationIn, 1.0);
}

- (NSRect)controlRegion
{
    return NSZeroRect;
}

- (void)drawRect:(NSRect)rect
{
    [super drawRect:rect];
    [self drawThemeInRect:rect];
}

@end
