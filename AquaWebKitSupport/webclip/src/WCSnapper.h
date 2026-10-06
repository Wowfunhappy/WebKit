// Snapping for the Web Clip camera. While the user drags the clip, the crop origin sticks to
// the left and top edges of page elements it passes over slowly.
//
// The snappable elements come from the page agent's snapNodes(): an array of dictionaries
// with numeric "id", "x", "y", "width" and "height" in document coordinates, in document
// order. Points and rects passed to the snapper are in the same coordinates.

#import <Foundation/Foundation.h>

@interface WCSnapNode : NSObject
- (instancetype)initWithIdentifier:(NSInteger)identifier boundingBox:(NSRect)boundingBox;
@property (nonatomic, readonly) NSInteger identifier;
@property (nonatomic, readonly) NSRect boundingBox;
@end

@interface WCSnap : NSObject
+ (int)jumpAmount;
+ (int)holdAmount;
@end

@interface WCPositionSnap : WCSnap
- (instancetype)initWithNode:(WCSnapNode *)node point:(NSPoint)point direction:(int)direction;
- (int)direction;
- (WCSnapNode *)node;
- (NSPoint)point;
- (void)setNodesWithMatchingLeftEdge:(NSSet *)nodes;
- (void)setNodesWithMatchingTopEdge:(NSSet *)nodes;
- (WCSnapNode *)snapNodeForWidth:(float)width;
- (WCSnapNode *)snapNodeForHeight:(float)height;
@end

@interface WCResizeSnap : WCSnap
- (instancetype)initWithCoordinate:(float)coordinate resizeOperation:(int)resizeOperation;
- (float)coordinate;
@end

@interface WCSnapper : NSObject
- (instancetype)initWithNodes:(NSArray *)nodes;
- (NSRect)snappedRectFromProposedRect:(NSRect)rect;
- (NSPoint)snappedPointFromPoint:(NSPoint)point proposedCropRect:(NSRect)rect;
@end
