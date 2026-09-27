#import "WCSnapper.h"

#include <math.h>

#pragma clang fp contract(off)

enum {
    WCSnapDirectionNone = 0,
    WCSnapDirectionPositiveX = 1,
    WCSnapDirectionNegativeX = 2,
    WCSnapDirectionPositiveY = 3,
    WCSnapDirectionNegativeY = 4,
};

enum {
    WCResizeOperationNone = 0,
    WCResizeOperationWiden = 1,
    WCResizeOperationHeighten = 2,
    WCResizeOperationNarrow = 3,
    WCResizeOperationShorten = 4,
};

@implementation WCSnapNode

- (instancetype)initWithIdentifier:(NSInteger)identifier boundingBox:(NSRect)boundingBox
{
    self = [super init];
    if (!self)
        return nil;
    _identifier = identifier;
    _boundingBox = boundingBox;
    return self;
}

@end

static NSRect boundingBoxOfNode(WCSnapNode *node)
{
    return node ? node.boundingBox : NSZeroRect;
}

@implementation WCSnap

+ (int)holdAmount
{
    return 8;
}

+ (int)jumpAmount
{
    return 4;
}

@end

@implementation WCPositionSnap {
    int _direction;
    WCSnapNode *_node;
    NSPoint _point;
    NSSet *_nodesWithMatchingLeftEdge;
    NSSet *_nodesWithMatchingTopEdge;
}

- (instancetype)initWithNode:(WCSnapNode *)node point:(NSPoint)point direction:(int)direction
{
    self = [super init];
    if (!self)
        return nil;
    _node = node;
    _point = point;
    _direction = direction;
    int jumpAmount = [WCSnap jumpAmount];
    if (_direction == WCSnapDirectionPositiveY)
        _point.y = (double)jumpAmount + _point.y;
    else if (_direction == WCSnapDirectionPositiveX)
        _point.x = (double)jumpAmount + _point.x;
    return self;
}

- (int)direction
{
    return _direction;
}

- (WCSnapNode *)node
{
    return _node;
}

- (NSPoint)point
{
    return _point;
}

- (void)setNodesWithMatchingLeftEdge:(NSSet *)nodes
{
    _nodesWithMatchingLeftEdge = nodes;
}

- (void)setNodesWithMatchingTopEdge:(NSSet *)nodes
{
    _nodesWithMatchingTopEdge = nodes;
}

- (WCSnapNode *)snapNodeForWidth:(float)width
{
    for (WCSnapNode *node in _nodesWithMatchingLeftEdge) {
        NSRect box = boundingBoxOfNode(node);
        float distance = (float)((double)width - (box.origin.x + box.size.width));
        if ((float)[WCSnap holdAmount] >= fabsf(distance))
            return node;
    }
    return nil;
}

- (WCSnapNode *)snapNodeForHeight:(float)height
{
    for (WCSnapNode *node in _nodesWithMatchingTopEdge) {
        NSRect box = boundingBoxOfNode(node);
        float distance = (float)((double)height - (box.origin.y + box.size.height));
        if ((float)[WCSnap holdAmount] >= fabsf(distance))
            return node;
    }
    return nil;
}

@end

@implementation WCResizeSnap {
    float _coordinate;
}

- (instancetype)initWithCoordinate:(float)coordinate resizeOperation:(int)resizeOperation
{
    self = [super init];
    if (!self)
        return nil;
    _coordinate = coordinate;
    int jumpAmount = [WCSnap jumpAmount];
    if (resizeOperation == WCResizeOperationNarrow || resizeOperation == WCResizeOperationShorten)
        _coordinate = _coordinate - (float)jumpAmount;
    else if (resizeOperation == WCResizeOperationWiden || resizeOperation == WCResizeOperationHeighten)
        _coordinate = (float)jumpAmount + _coordinate;
    return self;
}

- (float)coordinate
{
    return _coordinate;
}

@end

static NSInteger compareNodesByXOrigin(id a, id b, void *context)
{
    double aX = boundingBoxOfNode(a).origin.x;
    double bX = boundingBoxOfNode(b).origin.x;
    if (bX > aX)
        return NSOrderedAscending;
    return aX > bX ? NSOrderedDescending : NSOrderedSame;
}

static NSInteger compareNodesByYOrigin(id a, id b, void *context)
{
    double aY = boundingBoxOfNode(a).origin.y;
    double bY = boundingBoxOfNode(b).origin.y;
    if (bY > aY)
        return NSOrderedAscending;
    return aY > bY ? NSOrderedDescending : NSOrderedSame;
}

static BOOL cropOriginMatchesLeftEdge(NSPoint cropOrigin, NSRect box)
{
    float distance = (float)(box.origin.x - cropOrigin.x);
    return (float)[WCSnap holdAmount] >= fabsf(distance);
}

static BOOL cropOriginMatchesTopEdge(NSPoint cropOrigin, NSRect box)
{
    float distance = (float)(box.origin.y - cropOrigin.y);
    return (float)[WCSnap holdAmount] >= fabsf(distance);
}

@implementation WCSnapper {
    WCPositionSnap *_leftSideOfWidgetSnap;
    WCPositionSnap *_topSideOfWidgetSnap;
    WCResizeSnap *_bottomOfNodeSnap;
    WCResizeSnap *_rightOfNodeSnap;
    NSArray *_nodesSortedByXOrigin;
    NSArray *_nodesSortedByYOrigin;
    NSPoint _lastPoint;
    NSSize _lastSize;
    NSRect _proposedCropRect;
}

- (instancetype)initWithNodes:(NSArray *)nodes
{
    self = [super init];
    if (!self)
        return nil;
    _lastPoint = NSMakePoint(-1, -1);
    _lastSize = NSMakeSize(-1, -1);
    NSMutableArray *snapNodes = [NSMutableArray arrayWithCapacity:nodes.count];
    for (NSDictionary *description in nodes) {
        if (![description isKindOfClass:[NSDictionary class]])
            continue;
        NSRect box = NSMakeRect([description[@"x"] doubleValue], [description[@"y"] doubleValue], [description[@"width"] doubleValue], [description[@"height"] doubleValue]);
        [snapNodes addObject:[[WCSnapNode alloc] initWithIdentifier:[description[@"id"] integerValue] boundingBox:box]];
    }
    [self _sortNodesByOrigin:snapNodes];
    return self;
}

- (void)_sortNodesByOrigin:(NSArray *)nodes
{
    _nodesSortedByXOrigin = [nodes sortedArrayUsingFunction:compareNodesByXOrigin context:NULL];
    _nodesSortedByYOrigin = [nodes sortedArrayUsingFunction:compareNodesByYOrigin context:NULL];
}

- (NSRect)snappedRectFromProposedRect:(NSRect)rect
{
    return rect;
}

- (NSPoint)snappedPointFromPoint:(NSPoint)point proposedCropRect:(NSRect)rect
{
    if (_lastPoint.x == -1.0) {
        _lastPoint = point;
        return point;
    }
    _proposedCropRect = rect;
    int direction = [self _directionOfPoint:point];
    WCSnapNode *node = [self _snappedNodeForCandidatePoint:point direction:direction];
    _lastPoint = point;
    [self _setSnappedNode:node candidatePoint:point direction:direction];
    return [self _snappedPointFromCandidatePoint:point];
}

- (int)_directionOfPoint:(NSPoint)point
{
    float yDistance = fabsf((float)(point.y - _lastPoint.y));
    float xDistance = fabsf((float)(point.x - _lastPoint.x));
    if (xDistance > yDistance) {
        if (point.x > _lastPoint.x)
            return WCSnapDirectionPositiveX;
        if (_lastPoint.x > point.x)
            return WCSnapDirectionNegativeX;
        return WCSnapDirectionNone;
    }
    if (yDistance > xDistance) {
        if (point.y > _lastPoint.y)
            return WCSnapDirectionPositiveY;
        if (_lastPoint.y > point.y)
            return WCSnapDirectionNegativeY;
    }
    return WCSnapDirectionNone;
}

- (int)_resizeOperationForSize:(NSSize)size
{
    float heightDistance = fabsf((float)(size.height - _lastSize.height));
    float widthDistance = fabsf((float)(size.width - _lastSize.width));
    if (widthDistance > heightDistance) {
        if (_lastSize.width > size.width)
            return WCResizeOperationNarrow;
        if (size.width > _lastSize.width)
            return WCResizeOperationWiden;
        return WCResizeOperationNone;
    }
    if (heightDistance > widthDistance) {
        if (_lastSize.height > size.height)
            return WCResizeOperationShorten;
        if (size.height > _lastSize.height)
            return WCResizeOperationHeighten;
    }
    return WCResizeOperationNone;
}

- (void)_relinquishSnap:(WCPositionSnap *)snap ifCandidatePointExceedsThreshold:(NSPoint)point
{
    NSPoint snapPoint = [snap point];
    if (_leftSideOfWidgetSnap == snap) {
        double distance = snapPoint.x - point.x;
        if (fabs(distance) > (double)[WCSnap holdAmount])
            _leftSideOfWidgetSnap = nil;
    }
    if (_topSideOfWidgetSnap == snap) {
        double distance = snapPoint.y - point.y;
        if (fabs(distance) > (double)[WCSnap holdAmount])
            _topSideOfWidgetSnap = nil;
    }
}

- (void)_relinquishSnap:(WCResizeSnap *)snap ifCandidateSizeExceedsThreshold:(NSSize)size
{
    float coordinate = [snap coordinate];
    if (_rightOfNodeSnap == snap) {
        if (fabs((double)coordinate - size.width) > (double)[WCSnap holdAmount])
            _rightOfNodeSnap = nil;
    }
    if (_bottomOfNodeSnap == snap) {
        if (fabs((double)coordinate - size.height) > (double)[WCSnap holdAmount])
            _bottomOfNodeSnap = nil;
    }
}

- (void)_collectNodesWithTopOrLeftEdgeMatchingSnap:(WCPositionSnap *)snap
{
    NSMutableSet *nodesWithMatchingLeftEdge = [NSMutableSet set];
    NSMutableSet *nodesWithMatchingTopEdge = [NSMutableSet set];
    NSRect snapBox = boundingBoxOfNode([snap node]);
    unsigned count = (unsigned)[_nodesSortedByXOrigin count];
    for (unsigned i = 0; i != count; ++i) {
        WCSnapNode *node = [_nodesSortedByXOrigin objectAtIndex:i];
        NSRect box = boundingBoxOfNode(node);
        if (snapBox.origin.x == box.origin.x)
            [nodesWithMatchingLeftEdge addObject:node];
        if (snapBox.origin.y == box.origin.y)
            [nodesWithMatchingTopEdge addObject:node];
    }
    [snap setNodesWithMatchingLeftEdge:nodesWithMatchingLeftEdge];
    [snap setNodesWithMatchingTopEdge:nodesWithMatchingTopEdge];
}

- (void)_setSnappedNode:(WCSnapNode *)node candidatePoint:(NSPoint)point direction:(int)direction
{
    if (_leftSideOfWidgetSnap)
        [self _relinquishSnap:_leftSideOfWidgetSnap ifCandidatePointExceedsThreshold:point];
    else if (direction == WCSnapDirectionPositiveX && node) {
        _leftSideOfWidgetSnap = [[WCPositionSnap alloc] initWithNode:node point:point direction:WCSnapDirectionPositiveX];
        [self _collectNodesWithTopOrLeftEdgeMatchingSnap:_leftSideOfWidgetSnap];
    }

    if (_topSideOfWidgetSnap)
        [self _relinquishSnap:_topSideOfWidgetSnap ifCandidatePointExceedsThreshold:point];
    else if (direction == WCSnapDirectionPositiveY && node) {
        _topSideOfWidgetSnap = [[WCPositionSnap alloc] initWithNode:node point:point direction:WCSnapDirectionPositiveY];
        [self _collectNodesWithTopOrLeftEdgeMatchingSnap:_topSideOfWidgetSnap];
    }
}

- (NSPoint)_snappedPointFromCandidatePoint:(NSPoint)point
{
    double x = _leftSideOfWidgetSnap ? [_leftSideOfWidgetSnap point].x : point.x;
    double y = _topSideOfWidgetSnap ? [_topSideOfWidgetSnap point].y : point.y;
    return NSMakePoint(x, y);
}

- (BOOL)_didMoveTooFastForSnap:(NSPoint)lastPoint candidatePoint:(NSPoint)point
{
    float yDistance = (float)(lastPoint.y - point.y);
    yDistance = yDistance * yDistance;
    float xDistance = (float)(lastPoint.x - point.x);
    xDistance = xDistance * xDistance;
    return xDistance + yDistance > 9.0f;
}

- (BOOL)_largeEnoughCropRectIntersection:(WCSnapNode *)node
{
    NSRect box = boundingBoxOfNode(node);
    NSRect intersection = NSIntersectionRect(box, _proposedCropRect);
    float coverage = (float)((intersection.size.width * intersection.size.height) / (box.size.width * box.size.height));
    return (double)coverage > 0.3;
}

- (WCSnapNode *)_snappedNodeForCandidatePoint:(NSPoint)point direction:(int)direction
{
    if ([self _didMoveTooFastForSnap:_lastPoint candidatePoint:point])
        return nil;

    NSEnumerator *enumerator = nil;
    BOOL (*cropOriginMatches)(NSPoint, NSRect) = NULL;
    if (direction == WCSnapDirectionPositiveY) {
        enumerator = [_nodesSortedByYOrigin objectEnumerator];
        cropOriginMatches = cropOriginMatchesTopEdge;
    } else if (direction == WCSnapDirectionPositiveX) {
        enumerator = [_nodesSortedByXOrigin objectEnumerator];
        cropOriginMatches = cropOriginMatchesLeftEdge;
    }

    WCSnapNode *node;
    while ((node = [enumerator nextObject])) {
        if (cropOriginMatches(_proposedCropRect.origin, node.boundingBox) && [self _largeEnoughCropRectIntersection:node])
            return node;
    }
    return nil;
}

- (float)_snappedWidthForCandidateRect:(NSRect)rect resizeOperation:(int)resizeOperation
{
    double width = rect.size.width;
    if (!_leftSideOfWidgetSnap)
        return (float)width;
    if (_rightOfNodeSnap)
        [self _relinquishSnap:_rightOfNodeSnap ifCandidateSizeExceedsThreshold:rect.size];
    WCSnapNode *node = [_leftSideOfWidgetSnap snapNodeForWidth:(float)width];
    if (!_rightOfNodeSnap && node) {
        double coordinate = boundingBoxOfNode(node).size.width + rect.origin.x;
        _rightOfNodeSnap = [[WCResizeSnap alloc] initWithCoordinate:(float)coordinate resizeOperation:resizeOperation];
    }
    if (_rightOfNodeSnap)
        return [_rightOfNodeSnap coordinate];
    return (float)width;
}

- (float)_snappedHeightForCandidateRect:(NSRect)rect resizeOperation:(int)resizeOperation
{
    double height = rect.size.height;
    if (!_topSideOfWidgetSnap)
        return (float)height;
    if (_bottomOfNodeSnap)
        [self _relinquishSnap:_bottomOfNodeSnap ifCandidateSizeExceedsThreshold:rect.size];
    WCSnapNode *node = [_topSideOfWidgetSnap snapNodeForHeight:(float)height];
    if (!_bottomOfNodeSnap && node) {
        double coordinate = boundingBoxOfNode(node).size.height + rect.origin.y;
        _bottomOfNodeSnap = [[WCResizeSnap alloc] initWithCoordinate:(float)coordinate resizeOperation:resizeOperation];
    }
    if (_bottomOfNodeSnap)
        return [_bottomOfNodeSnap coordinate];
    return (float)height;
}

@end
