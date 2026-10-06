#include "config.h"
#import "WebBackdropLayerAquaWebKit.h"

#import <wtf/RetainPtr.h>

// 10.9 Core Animation applies a layer's backgroundFilters even while the layer is hidden, and reads them through
// this getter when it commits the layer. A hidden layer renders nothing, so it reports no filters until shown.
@implementation WebBackdropLayerAquaWebKit {
    RetainPtr<NSArray> _backgroundFilters;
}

- (instancetype)initWithLayer:(id)layer
{
    if (!(self = [super initWithLayer:layer]))
        return nil;
    if ([layer isKindOfClass:WebBackdropLayerAquaWebKit.class])
        _backgroundFilters = static_cast<WebBackdropLayerAquaWebKit *>(layer)->_backgroundFilters;
    return self;
}

- (NSArray *)backgroundFilters
{
    return self.hidden ? nil : _backgroundFilters.get();
}

- (void)setBackgroundFilters:(NSArray *)backgroundFilters
{
    _backgroundFilters = adoptNS([backgroundFilters copy]);
    [super setBackgroundFilters:self.backgroundFilters];
}

- (void)setHidden:(BOOL)hidden
{
    [super setHidden:hidden];
    [super setBackgroundFilters:self.backgroundFilters];
}

@end
