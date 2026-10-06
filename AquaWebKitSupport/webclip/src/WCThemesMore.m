// The Deckled Edge (scalloped), Pegboard and Torn Edge themes.

#import "WCThemes.h"

// AppKit's tiler: fills `rect` (clipped to it) with `image` repeated from `phase`.
extern void _NSTileImageWithOperation(NSRect rect, NSImage *image, BOOL isFlipped, NSPoint phase, NSCompositingOperation operation, CGFloat fraction);

#pragma mark - Deckled Edge

// One run of edge tiles grown from a corner piece toward the middle of the view.
// Horizontal runs start at corner.size.width - x (left) or x + corner.origin.x (right), at y (right),
// or y + corner.origin.y (left). Vertical runs sit at x and start at offset + corner.origin.y + 1 (top)
// or y + corner.origin.y (bottom).
typedef struct {
    __unsafe_unretained NSImage *image;
    NSRect corner;
    int element;
    int x;
    int y;
    int offset;
} WCScallopTile;

static NSImage *sScallopedUpperLeftCorner;
static NSImage *sScallopedUpperRightCorner;
static NSImage *sScallopedTopRowTile;
static NSImage *sScallopedLeftEdgeTile;
static NSImage *sScallopedRightEdgeTile;
static NSImage *sScallopedBottomLeftCorner;
static NSImage *sScallopedBottomRightCorner;
static NSImage *sScallopedBottomRowTile;

@implementation WCScallopedTheme

+ (void)initialize
{
    sScallopedUpperLeftCorner = [NSImage wc_flippedPNGNamed:@"scalloped_upperleftcorner"];
    sScallopedUpperRightCorner = [NSImage wc_flippedPNGNamed:@"scalloped_upperrightcorner"];
    sScallopedTopRowTile = [NSImage wc_flippedPNGNamed:@"scalloped_toprowtile"];
    sScallopedLeftEdgeTile = [NSImage wc_flippedPNGNamed:@"scalloped_leftedgetile"];
    sScallopedRightEdgeTile = [NSImage wc_flippedPNGNamed:@"scalloped_rightedgetile"];
    sScallopedBottomLeftCorner = [NSImage wc_flippedPNGNamed:@"scalloped_bottomleftcorner"];
    sScallopedBottomRightCorner = [NSImage wc_flippedPNGNamed:@"scalloped_bottomrightcorner"];
    sScallopedBottomRowTile = [NSImage wc_flippedPNGNamed:@"scalloped_bottomrowtile"];
}

+ (int)borderLeft
{
    return 27;
}

+ (int)borderRight
{
    return 27;
}

+ (int)borderTop
{
    return 18;
}

+ (int)borderBottom
{
    return 36;
}

- (int)doneButtonInsetY
{
    return 7;
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
    return 27;
}

- (int)clipInsetBottom
{
    return 36;
}

- (int)clipInsetTop
{
    return 18;
}

- (int)resizerInsetX
{
    return 0;
}

- (int)resizerInsetY
{
    return 15;
}

- (int)resizerImageInsetX
{
    return -13;
}

- (int)resizerImageInsetY
{
    return -10;
}

- (BOOL)isVerticalElement:(int)element
{
    return (unsigned int)element > 3;
}

// Draws the part-tile that closes the gap between the whole tiles and the middle of the view.
- (void)partialComposite:(NSImage *)image direction:(int)direction fromCorner:(NSRect)corner wholeTileCount:(int)count offset:(int)offset
{
    double boundsWidth = [self bounds].size.width;
    float center;
    int remaining;
    if ([self isVerticalElement:direction]) {
        center = (float)([self bounds].size.height * 0.5);
        remaining = 0;
    } else {
        double halfWidth = [self bounds].size.width * 0.5;
        double tileWidth = [image size].width;
        double run = (double)count * [image size].width;
        center = (float)(tileWidth * -0.5 + halfWidth);
        remaining = (int)((double)center - run - (double)offset);
    }
    float fraction = center - floorf(center);

    NSRect dest = NSZeroRect;
    NSRect source = NSZeroRect;
    switch (direction) {
    case 0: {
        int x = (int)((double)count * [image size].width + corner.size.width - (double)offset);
        int width = remaining - 4 - (fraction == 0.0f ? 1 : 0);
        dest = NSMakeRect((double)x, 4.0, (double)width, [image size].height);
        source = NSMakeRect(0, 0, (double)width, [image size].height);
        break;
    }
    case 1: {
        double end = (double)count * [image size].width + corner.size.width - (double)offset;
        double start = boundsWidth - end;
        int width = remaining - 5;
        int x = (int)start - width;
        dest = NSMakeRect((double)x, 4.0, (double)width, [image size].height);
        source = NSMakeRect([image size].width - (double)width, 0, (double)width, [image size].height);
        break;
    }
    case 2: {
        int x = (int)((double)count * [image size].width + corner.size.width - (double)offset);
        double y = corner.origin.y;
        double height = [image size].height;
        int width = remaining + (fraction != 0.0f ? 1 : 0);
        dest = NSMakeRect((double)x, y + 4.0, (double)width, height);
        source = NSMakeRect(0, 0, (double)width, [image size].height);
        break;
    }
    case 3: {
        double end = (double)count * [image size].width + corner.size.width - (double)offset - 2.0;
        double start = boundsWidth - end;
        double y = corner.origin.y;
        double height = [image size].height;
        int x = (int)start - remaining;
        dest = NSMakeRect((double)x, y + 4.0 + 1.0, (double)remaining, height);
        source = NSMakeRect([image size].width - (double)remaining, 0, (double)remaining, [image size].height);
        break;
    }
    case 4: {
        double run = (double)offset + (double)count * [image size].height;
        int height = (int)((double)center - run - corner.origin.y);
        int y = (int)(center - (float)height);
        dest = NSMakeRect(0, (double)y - corner.origin.y, [image size].width, (double)height);
        source = NSMakeRect(0, 0, [image size].width, (double)height);
        break;
    }
    case 5: {
        double run = (double)(offset + 18) + (double)count * [image size].height;
        double top = (double)center - run + 1.0;
        double fullHeight = [image size].height + 1.0;
        int height = (int)top + (fraction != 0.0f ? 1 : 0);
        int y = (int)(center - 5.0f);
        if ((double)height == fullHeight)
            dest = NSMakeRect(0, (double)(y - 2), [image size].width, (double)(height + 2));
        else
            dest = NSMakeRect(0, (double)y, [image size].width, (double)height);
        source = NSMakeRect(0, [image size].height - (double)height, [image size].width, (double)height);
        break;
    }
    case 6: {
        double top = (double)center - ((double)offset + (double)count * [image size].height);
        double cornerX = corner.origin.x;
        double cornerY = corner.origin.y;
        double width = [image size].width;
        int height = (int)(top - cornerY);
        int y = (int)(center - (float)height);
        dest = NSMakeRect(cornerX + 4.0, (double)y - cornerY, width, (double)height);
        source = NSMakeRect(0, 0, [image size].width, (double)height);
        break;
    }
    case 7: {
        double run = (double)(offset + 18) + (double)count * [image size].height;
        int height = (int)((double)center - run) + (fraction != 0.0f ? 1 : 0);
        float bottom = center - 5.0f;
        double fullHeight = [image size].height + 1.0;
        int y = (int)bottom;
        double x = corner.origin.x + 4.0;
        if ((double)height == fullHeight)
            dest = NSMakeRect(x, (double)(y - 1), [image size].width, (double)(height + 1));
        else
            dest = NSMakeRect(x, (double)y, [image size].width, (double)height);
        source = NSMakeRect(0, [image size].height - (double)height, [image size].width, (double)height);
        break;
    }
    }
    [image drawInRect:dest fromRect:source operation:NSCompositeSourceOver fraction:1.0];
}

- (void)drawHorizonalLeftTile:(WCScallopTile)tile dirtyRect:(NSRect)dirtyRect
{
    int startX = (int)(tile.corner.size.width - (double)tile.x);
    int y = (int)((double)tile.y + tile.corner.origin.y);
    NSImage *image = tile.image;
    double halfWidth = [self bounds].size.width * 0.5;
    double left = (double)startX;
    int count = (int)((halfWidth - left) / [image size].width);
    if (count > 0) {
        double top = (double)y;
        double index = 0.0;
        for (int n = count; n != 0; n--) {
            double x = [image size].width * index + left;
            double width = [image size].width;
            double height = [image size].height;
            [image wc_drawInRect:NSMakeRect(x, top, width, height) dirtyRect:dirtyRect];
            index += 1.0;
        }
    }
    [self partialComposite:image direction:tile.element fromCorner:tile.corner wholeTileCount:count offset:tile.offset];
}

- (void)drawHorizontalRightTile:(WCScallopTile)tile dirtyRect:(NSRect)dirtyRect
{
    int startX = (int)(tile.corner.size.width - (double)tile.x) + (tile.element == 3 ? -1 : 0);
    NSImage *image = tile.image;
    double halfWidth = [self bounds].size.width * 0.5;
    int count = (int)((halfWidth - (double)startX) / [image size].width);
    if (count > 0) {
        double right = (double)(int)((double)tile.x + tile.corner.origin.x);
        for (int n = count; n > 0; n--) {
            double run = (double)n * [image size].width;
            double x = right - run;
            double width = [image size].width;
            double height = [image size].height;
            [image wc_drawInRect:NSMakeRect(x, (double)tile.y, width, height) dirtyRect:dirtyRect];
        }
    }
    [self partialComposite:image direction:tile.element fromCorner:tile.corner wholeTileCount:count offset:tile.offset];
}

- (void)drawVerticalTopTile:(WCScallopTile)tile dirtyRect:(NSRect)dirtyRect
{
    NSImage *image = tile.image;
    NSSize size = [image size];
    int startY = (int)((double)tile.offset + tile.corner.origin.y + 1.0);
    int tileHeight = (int)size.height;
    double halfHeight = [self bounds].size.height * 0.5;
    double top = (double)startY;
    int count = (int)(halfHeight - top - 5.0) / tileHeight;
    if (count > 0) {
        double index = 0.0;
        for (int n = count; n != 0; n--) {
            double y = [image size].height * index + top;
            double width = [image size].width;
            double height = [image size].height;
            [image wc_drawInRect:NSMakeRect((double)tile.x, y, width, height) dirtyRect:dirtyRect];
            index += 1.0;
        }
    }
    [self partialComposite:image direction:tile.element fromCorner:tile.corner wholeTileCount:count offset:startY];
}

- (void)drawVerticalBottomTile:(WCScallopTile)tile dirtyRect:(NSRect)dirtyRect
{
    NSImage *image = tile.image;
    NSSize size = [image size];
    int startY = (int)((double)tile.y + tile.corner.origin.y);
    int tileHeight = (int)size.height;
    double limit = (double)(startY + 4);
    double halfHeight = [self bounds].size.height * 0.5;
    int count = (int)(limit - halfHeight) / tileHeight;
    if (count > 0) {
        double bottom = (double)startY;
        for (int n = count; n > 0; n--) {
            double y = bottom - (double)n * [image size].height;
            double width = [image size].width;
            double height = [image size].height;
            [image wc_drawInRect:NSMakeRect((double)tile.x, y, width, height) dirtyRect:dirtyRect];
        }
    }
    [self partialComposite:image direction:tile.element fromCorner:tile.corner wholeTileCount:count offset:tile.y];
}

- (void)drawThemeInRect:(NSRect)rect
{
    [[NSColor clearColor] set];
    NSRectFillUsingOperation(rect, NSCompositeCopy);

    NSRect bounds = [self bounds];
    double width = bounds.size.width;
    double height = bounds.size.height;
    int rightX = (int)(width - [sScallopedUpperRightCorner size].width);
    double upperLeftWidth = [sScallopedUpperLeftCorner size].width;
    double upperRightWidth = [sScallopedUpperRightCorner size].width;
    NSSize bottomLeftSize = [sScallopedBottomLeftCorner size];
    NSSize bottomRightSize = [sScallopedBottomRightCorner size];
    double right = (double)rightX;
    NSRect upperRightRect = NSMakeRect(right, 5.0, upperRightWidth, [sScallopedUpperRightCorner size].height);
    NSRect upperLeftRect = NSMakeRect(2.0, 5.0, upperLeftWidth, [sScallopedUpperLeftCorner size].height);
    double bottomY = height - bottomLeftSize.height;
    NSRect bottomLeftRect = NSMakeRect(0, 1.0 + bottomY, bottomLeftSize.width, bottomLeftSize.height);
    NSRect bottomRightRect = NSMakeRect(right, bottomY, bottomRightSize.width, bottomRightSize.height);

    WCScallopTile bottomLeftRow = { sScallopedBottomRowTile, bottomLeftRect, 2, 10, 4, 10 };
    WCScallopTile topLeftRow = { sScallopedTopRowTile, upperLeftRect, 0, 7, -1, 7 };
    WCScallopTile topRightRow = { sScallopedTopRowTile, upperRightRect, 1, 7, 4, 7 };
    WCScallopTile bottomRightRow = { sScallopedBottomRowTile, bottomRightRect, 3, 10, (int)(height - [sScallopedBottomRowTile size].height), 10 };
    WCScallopTile leftTopColumn = { sScallopedLeftEdgeTile, upperLeftRect, 4, 0, (int)(height - [sScallopedBottomRowTile size].height), 15 };
    WCScallopTile rightTopColumn = { sScallopedRightEdgeTile, upperRightRect, 6, (int)(width - [sScallopedRightEdgeTile size].width - 4.0), 0, 15 };
    WCScallopTile leftBottomColumn = { sScallopedLeftEdgeTile, bottomLeftRect, 5, 0, 10, 0 };
    WCScallopTile rightBottomColumn = { sScallopedRightEdgeTile, bottomRightRect, 7, (int)(width - [sScallopedRightEdgeTile size].width - 4.0), 10, 19 };

    [self drawHorizonalLeftTile:topLeftRow dirtyRect:rect];
    [self drawHorizontalRightTile:topRightRow dirtyRect:rect];
    [self drawHorizonalLeftTile:bottomLeftRow dirtyRect:rect];
    [self drawHorizontalRightTile:bottomRightRow dirtyRect:rect];
    [self drawVerticalTopTile:leftTopColumn dirtyRect:rect];
    [self drawVerticalTopTile:rightTopColumn dirtyRect:rect];
    [self drawVerticalBottomTile:leftBottomColumn dirtyRect:rect];
    [self drawVerticalBottomTile:rightBottomColumn dirtyRect:rect];

    [sScallopedBottomLeftCorner wc_drawInRect:bottomLeftRect dirtyRect:rect];
    [sScallopedBottomRightCorner wc_drawInRect:bottomRightRect dirtyRect:rect];
    [sScallopedUpperLeftCorner wc_drawInRect:upperLeftRect dirtyRect:rect];
    [sScallopedUpperRightCorner wc_drawInRect:upperRightRect dirtyRect:rect];
}

- (NSRect)innerBezelRect
{
    NSRect bounds = [self bounds];
    return NSMakeRect(28.0, 24.0, bounds.size.width - 55.0, bounds.size.height - 60.0);
}

- (void)drawRect:(NSRect)rect
{
    [self drawThemeInRect:rect];
    [super drawRect:rect];
}

- (int)themeID
{
    return WCThemeDeckled;
}

- (NSRect)controlRegion
{
    return [self innerBezelRect];
}

- (NSSize)minSize
{
    return NSMakeSize(163.0, 150.0);
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
