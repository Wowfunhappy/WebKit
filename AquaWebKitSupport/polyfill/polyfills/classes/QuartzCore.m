// Core Animation classes supplied by the Aqua WebKit compatibility layer.
#import "wk_priv_class.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

@interface CALayer (BackdropRenderSnapshot)
- (id)_initWithReference:(CALayer *)layer;
- (void *)_copyRenderLayer:(void *)context layerFlags:(unsigned)flags commitFlags:(unsigned *)commitFlags;
@end

@interface CAFilter : NSObject <NSCopying>
- (NSString *)type;
- (NSString *)name;
- (BOOL)isEnabled;
@end

@interface CAAnimation (BackdropEvaluation)
- (void)applyForTime:(double)time presentationObject:(id)presentation modelObject:(id)model;
@end

static const double backdropLuma[3] = { .2126, .7152, .0722 };

static double backdropNumber(CAFilter *filter, NSString *key, double fallback)
{
    id value = [filter valueForKey:key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static BOOL backdropDeviceColor(id value, double rgba[4])
{
    if (!value || CFGetTypeID((CFTypeRef)value) != CGColorGetTypeID())
        return NO;
    NSColor *color = [[NSColor colorWithCGColor:(CGColorRef)value] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!color)
        return NO;
    rgba[0] = color.redComponent;
    rgba[1] = color.greenComponent;
    rgba[2] = color.blueComponent;
    rgba[3] = color.alphaComponent;
    return YES;
}

static BOOL backdropMatrix(id value, float matrix[20])
{
    NSUInteger size = 0;
    if (![value isKindOfClass:[NSValue class]])
        return NO;
    NSGetSizeAndAlignment([value objCType], &size, NULL);
    if (size != 20 * sizeof(float))
        return NO;
    [value getValue:matrix];
    return YES;
}

static double backdropPixelLuma(const double pixel[4])
{
    return backdropLuma[0] * pixel[0] + backdropLuma[1] * pixel[1] + backdropLuma[2] * pixel[2];
}

static void backdropApply3x3(double pixel[4], const double m[9])
{
    double r = pixel[0], g = pixel[1], b = pixel[2];
    for (int i = 0; i < 3; ++i)
        pixel[i] = m[i * 3] * r + m[i * 3 + 1] * g + m[i * 3 + 2] * b;
}

// One device-space pixel (unpremultiplied, unclamped between filters) through one filter, as 10.9's compositor
// computes it, including its defaults for unset inputs. A blur of radius r stands in as a move of
// r^2 / (r^2 + 1) of the way to the backdrop's average colour, weighted by how much of the backdrop that colour
// covers, when the caller supplies it, and otherwise as a darkening of 25% * r^2 / (r^2 + 1).
static void backdropApplyFilter(CAFilter *filter, double pixel[4], const double *backdrop)
{
    NSString *type = [filter type];
    double luma = backdropPixelLuma(pixel), color[4];
    if ([type isEqualToString:@"gaussianBlur"]) {
        double radius = fmax(backdropNumber(filter, @"inputRadius", 0), 0);
        double strength = radius * radius / (radius * radius + 1);
        for (int i = 0; i < 3; ++i)
            pixel[i] = backdrop ? pixel[i] + (backdrop[i] - pixel[i]) * strength * backdrop[3] : pixel[i] * (1 - .25 * strength);
    } else if ([type isEqualToString:@"colorMatrix"]) {
        float m[20];
        if (!backdropMatrix([filter valueForKey:@"inputColorMatrix"], m))
            return;
        double input[4] = { pixel[0], pixel[1], pixel[2], pixel[3] };
        for (int i = 0; i < 4; ++i)
            pixel[i] = m[i * 5] * input[0] + m[i * 5 + 1] * input[1] + m[i * 5 + 2] * input[2] + m[i * 5 + 3] * input[3] + m[i * 5 + 4];
    } else if ([type isEqualToString:@"colorBrightness"]) {
        double amount = backdropNumber(filter, @"inputAmount", 1);
        for (int i = 0; i < 3; ++i)
            pixel[i] += amount;
    } else if ([type isEqualToString:@"colorContrast"]) {
        double amount = backdropNumber(filter, @"inputAmount", 1);
        for (int i = 0; i < 3; ++i)
            pixel[i] = (pixel[i] - .5) * amount + .5;
    } else if ([type isEqualToString:@"colorInvert"]) {
        for (int i = 0; i < 3; ++i)
            pixel[i] = 1 - pixel[i];
    } else if ([type isEqualToString:@"colorAdd"] || [type isEqualToString:@"colorSubtract"]) {
        if (!backdropDeviceColor([filter valueForKey:@"inputColor"], color) || pixel[3] <= 0)
            return;
        double sign = [type isEqualToString:@"colorAdd"] ? 1 : -1;
        for (int i = 0; i < 3; ++i)
            pixel[i] += sign * color[i] * color[3] / pixel[3];
    } else if ([type isEqualToString:@"multiplyColor"]) {
        if (!backdropDeviceColor([filter valueForKey:@"inputColor"], color))
            return;
        for (int i = 0; i < 4; ++i)
            pixel[i] *= color[i];
    } else if ([type isEqualToString:@"multiplyGradient"]) {
        // The output colour is the gradient's, at the input's alpha times the gradient's; a uniform fill carries
        // the mean of its two colours.
        double end[4] = { 1, 1, 1, 1 };
        if (!backdropDeviceColor([filter valueForKey:@"inputColor0"], color))
            color[0] = color[1] = color[2] = color[3] = 1;
        backdropDeviceColor([filter valueForKey:@"inputColor1"], end);
        for (int i = 0; i < 3; ++i)
            pixel[i] = (color[i] + end[i]) / 2;
        pixel[3] *= (color[3] + end[3]) / 2;
    } else if ([type isEqualToString:@"colorMonochrome"]) {
        double amount = backdropNumber(filter, @"inputAmount", 0), bias = backdropNumber(filter, @"inputBias", 0);
        if (!backdropDeviceColor([filter valueForKey:@"inputColor"], color))
            color[0] = color[1] = color[2] = 1;
        for (int i = 0; i < 3; ++i)
            pixel[i] = (1 - amount) * pixel[i] + amount * (luma + bias) * color[i];
    } else if ([type isEqualToString:@"colorSaturate"]) {
        double amount = backdropNumber(filter, @"inputAmount", 1);
        for (int i = 0; i < 3; ++i)
            pixel[i] = luma + amount * (pixel[i] - luma);
    } else if ([type isEqualToString:@"colorHueRotate"]) {
        double angle = backdropNumber(filter, @"inputAngle", 0), c = cos(angle), s = sin(angle);
        double m[9] = {
            .213 + c * .787 - s * .213, .715 - c * .715 - s * .715, .072 - c * .072 + s * .928,
            .213 - c * .213 + s * .143, .715 + c * .285 + s * .140, .072 - c * .072 - s * .283,
            .213 - c * .213 - s * .787, .715 - c * .715 + s * .715, .072 + c * .928 + s * .072,
        };
        backdropApply3x3(pixel, m);
    } else if ([type isEqualToString:@"luminanceToAlpha"]) {
        pixel[3] *= luma;
        pixel[0] = pixel[1] = pixel[2] = 0;
    } else if ([type isEqualToString:@"bias"]) {
        double amount = fmin(fmax(backdropNumber(filter, @"inputAmount", 1), .005), .995);
        for (int i = 0; i < 3; ++i)
            pixel[i] = pixel[i] / ((1 / amount - 2) * (1 - pixel[i]) + 1);
    }
}

// The chain's output for a uniform grey backdrop x, composited over that backdrop.
static void backdropChainOutput(NSArray *filters, double x, const double *backdrop, double out[3])
{
    double pixel[4] = { x, x, x, 1 };
    for (CAFilter *filter in filters) {
        if ([filter isKindOfClass:NSClassFromString(@"CAFilter")] && [filter isEnabled])
            backdropApplyFilter(filter, pixel, backdrop);
    }
    double alpha = fmin(fmax(pixel[3], 0), 1);
    for (int i = 0; i < 3; ++i)
        out[i] = fmin(fmax(pixel[i], 0), 1) * alpha + x * (1 - alpha);
}

// A translucent fill maps each channel x to x * (1 - alpha) + color * alpha. When the chain's output on black,
// mid-grey and white is such a map, the fill reproduces it; otherwise the fill matches the chain at mid-grey.
static BOOL backdropFillColor(NSArray *filters, const double *backdrop, double rgba[4])
{
    double black[3], middle[3], white[3];
    backdropChainOutput(filters, 0, backdrop, black);
    backdropChainOutput(filters, .5, backdrop, middle);
    backdropChainOutput(filters, 1, backdrop, white);
    double scale = white[0] - black[0];
    BOOL exact = scale >= 0 && scale <= 1;
    for (int i = 0; i < 3; ++i) {
        exact = exact && fabs(white[i] - black[i] - scale) < 1e-6 && fabs(middle[i] - (black[i] + white[i]) / 2) < 1e-6
            && black[i] >= -1e-6 && black[i] <= 1 - scale + 1e-6;
    }
    if (exact) {
        rgba[3] = 1 - scale;
        for (int i = 0; i < 3; ++i)
            rgba[i] = rgba[3] > 0 ? fmin(fmax(black[i] / rgba[3], 0), 1) : 0;
    } else {
        rgba[3] = 0;
        for (int i = 0; i < 3; ++i)
            rgba[3] = fmax(rgba[3], fabs(middle[i] - .5) / .5);
        for (int i = 0; i < 3; ++i)
            rgba[i] = rgba[3] > 0 ? fmin(fmax((middle[i] - .5 * (1 - rgba[3])) / rgba[3], 0), 1) : 0;
    }
    return rgba[3] > 0;
}

// The backdrop's average colours, in bands along its longer side, as WebKit samples the content beneath it.
// Alpha is how much of the band that content covers; an unknown band has no colour.
enum { backdropMaximumBands = 8 };

typedef struct {
    unsigned count;
    BOOL vertical;
    BOOL known[backdropMaximumBands];
    double rgba[backdropMaximumBands][4];
} BackdropBands;

typedef struct {
    double time;
    double rgba[backdropMaximumBands][4];
} BackdropSample;

// One fill colour per band; without bands, one fill for an unknown backdrop.
static void backdropFillColors(NSArray *filters, const BackdropBands *bands, double rgba[backdropMaximumBands][4])
{
    if (!bands->count) {
        backdropFillColor(filters, NULL, rgba[0]);
        return;
    }
    for (unsigned band = 0; band < bands->count; ++band)
        backdropFillColor(filters, bands->known[band] ? bands->rgba[band] : NULL, rgba[band]);
}

static NSArray *backdropColorArray(const double rgba[backdropMaximumBands][4], unsigned bands)
{
    NSMutableArray *colors = [NSMutableArray arrayWithCapacity:MAX(bands, 2u)];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    for (unsigned band = 0; band < MAX(bands, 2u); ++band) {
        const double *fill = rgba[MIN(band, bands - 1)];
        CGFloat components[4] = { fill[0], fill[1], fill[2], fill[3] };
        CGColorRef color = CGColorCreate(space, components);
        [colors addObject:(id)color];
        CGColorRelease(color);
    }
    CGColorSpaceRelease(space);
    return colors;
}

static NSString * const backdropFillAnimationKey = @"wkBackdropFill";
static NSString * const backdropFillTailKey = @"wkBackdropFillTail";

// Fill samples are placed until linear interpolation between neighbours is within half an 8-bit level, and no
// closer than one millisecond of layer time, below a display frame.
static const double backdropSampleTolerance = .5 / 255;
static const double backdropSampleResolution = .001;

static BOOL backdropSamplesClose(const BackdropSample *expected, const BackdropSample *start, const BackdropSample *end)
{
    double fraction = end->time > start->time ? (expected->time - start->time) / (end->time - start->time) : 0;
    for (unsigned band = 0; band < backdropMaximumBands; ++band) {
        const double *from = start->rgba[band], *to = end->rgba[band], *at = expected->rgba[band];
        for (int i = 0; i < 4; ++i) {
            double a = from[i] * (i < 3 ? from[3] : 1), b = to[i] * (i < 3 ? to[3] : 1);
            if (fabs(a + (b - a) * fraction - at[i] * (i < 3 ? at[3] : 1)) > backdropSampleTolerance)
                return NO;
        }
    }
    return YES;
}

static void backdropRefine(BackdropSample start, BackdropSample end, BackdropSample (^evaluate)(double), NSMutableData *samples)
{
    if (end.time - start.time <= backdropSampleResolution)
        return;
    BackdropSample quarters[3];
    BOOL linear = YES;
    for (int i = 0; i < 3; ++i) {
        quarters[i] = evaluate(start.time + (end.time - start.time) * (i + 1) / 4);
        linear = linear && backdropSamplesClose(&quarters[i], &start, &end);
    }
    if (linear)
        return;
    backdropRefine(start, quarters[1], evaluate, samples);
    [samples appendBytes:&quarters[1] length:sizeof(BackdropSample)];
    backdropRefine(quarters[1], end, evaluate, samples);
}

// Samples [start, end] at the anchors and wherever interpolation between them falls outside the tolerance.
static NSMutableData *backdropSampleSpan(double start, double end, NSArray *(^anchors)(double, double), BackdropSample (^evaluate)(double))
{
    NSMutableArray *times = [NSMutableArray arrayWithObjects:@(start), @(end), nil];
    for (NSNumber *anchor in anchors(start, end)) {
        if (anchor.doubleValue > start && anchor.doubleValue < end)
            [times addObject:anchor];
    }
    [times sortUsingSelector:@selector(compare:)];
    NSMutableData *samples = [NSMutableData data];
    BackdropSample previous = evaluate(start);
    [samples appendBytes:&previous length:sizeof(BackdropSample)];
    for (NSUInteger i = 1; i < times.count; ++i) {
        double time = [times[i] doubleValue];
        if (time <= previous.time)
            continue;
        BackdropSample next = evaluate(time);
        backdropRefine(previous, next, evaluate, samples);
        [samples appendBytes:&next length:sizeof(BackdropSample)];
        previous = next;
    }
    return samples;
}

static BOOL backdropIsFilterAnimation(CAAnimation *animation)
{
    return [animation isKindOfClass:[CAPropertyAnimation class]] && [((CAPropertyAnimation *)animation).keyPath hasPrefix:@"filters."];
}

static double backdropDuration(CAAnimation *animation)
{
    return animation.duration > 0 ? animation.duration : .25;
}

static double backdropPeriod(CAAnimation *animation)
{
    return backdropDuration(animation) * (animation.autoreverses ? 2 : 1) / fabs(animation.speed);
}

static double backdropActiveEnd(CAAnimation *animation)
{
    if (!animation.speed)
        return INFINITY;
    double cycle = backdropDuration(animation) * (animation.autoreverses ? 2 : 1);
    double active = animation.repeatDuration > 0 ? animation.repeatDuration : cycle * (animation.repeatCount > 0 ? animation.repeatCount : 1);
    return animation.beginTime + active / fabs(animation.speed);
}

static BOOL backdropMatrixValued(CAPropertyAnimation *animation)
{
    float matrix[20];
    if ([animation isKindOfClass:[CAKeyframeAnimation class]]) {
        NSArray *values = ((CAKeyframeAnimation *)animation).values;
        return values.count && backdropMatrix(values[0], matrix);
    }
    if (![animation isKindOfClass:[CABasicAnimation class]])
        return NO;
    CABasicAnimation *basic = (CABasicAnimation *)animation;
    return backdropMatrix(basic.fromValue, matrix) || backdropMatrix(basic.toValue, matrix) || backdropMatrix(basic.byValue, matrix);
}

// Brings a keyframe animation's evaluation in line with 10.9's renderer. The renderer paces by the Euclidean distance
// between values, and a matrix-valued animation is evaluated through scalar stand-ins that cannot carry that
// distance, so its paced spacing becomes explicit key times. 10.9's evaluator reads unset cubic key times, tension,
// continuity and bias arrays from uninitialized memory; with every array explicit it matches the renderer.
static void backdropPrepareKeyframes(CAKeyframeAnimation *keyframes, BOOL matrixValued)
{
    NSString *mode = keyframes.calculationMode;
    NSArray *values = keyframes.values;
    NSUInteger count = values.count;
    BOOL paced = [mode isEqualToString:kCAAnimationPaced] || [mode isEqualToString:kCAAnimationCubicPaced];
    BOOL cubic = [mode isEqualToString:kCAAnimationCubic] || [mode isEqualToString:kCAAnimationCubicPaced];
    if (paced && matrixValued && count > 1) {
        double distances[count], total = 0;
        distances[0] = 0;
        for (NSUInteger i = 1; i < count; ++i) {
            float a[20], b[20];
            double sum = 0;
            if (backdropMatrix(values[i - 1], a) && backdropMatrix(values[i], b)) {
                for (int j = 0; j < 20; ++j)
                    sum += (b[j] - a[j]) * (b[j] - a[j]);
            }
            total += sqrt(sum);
            distances[i] = total;
        }
        NSMutableArray *keyTimes = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; ++i)
            [keyTimes addObject:@(total > 0 ? distances[i] / total : (double)i / (count - 1))];
        keyframes.keyTimes = keyTimes;
        keyframes.timingFunctions = nil;
        keyframes.calculationMode = cubic ? kCAAnimationCubic : kCAAnimationLinear;
    }
    if (!cubic || !count)
        return;
    if ([keyframes.calculationMode isEqualToString:kCAAnimationCubic] && keyframes.keyTimes.count != count) {
        NSMutableArray *keyTimes = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; ++i)
            [keyTimes addObject:@(count > 1 ? (double)i / (count - 1) : 0)];
        keyframes.keyTimes = keyTimes;
    }
    NSArray *callers[3] = { keyframes.tensionValues, keyframes.continuityValues, keyframes.biasValues };
    NSMutableArray *explicitValues[3];
    for (int k = 0; k < 3; ++k) {
        explicitValues[k] = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; ++i)
            [explicitValues[k] addObject:i < callers[k].count ? callers[k][i] : @0];
    }
    keyframes.tensionValues = explicitValues[0];
    keyframes.continuityValues = explicitValues[1];
    keyframes.biasValues = explicitValues[2];
}

// 10.9's model-side evaluation does not interpolate CAColorMatrix values. Outside the paced modes its interpolation
// is linear in the animation's values, so the matrix is each value weighted by what the same animation gives on a
// scalar property with that value set to 1 and the others to 0; the model value carries the remaining weight.
static CAPropertyAnimation *backdropScalarStandIn(CAPropertyAnimation *animation, NSUInteger slot)
{
    CAPropertyAnimation *proxy = [[animation copy] autorelease];
    proxy.keyPath = @"zPosition";
    if ([proxy isKindOfClass:[CAKeyframeAnimation class]]) {
        NSUInteger count = ((CAKeyframeAnimation *)animation).values.count;
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; ++i)
            [values addObject:@(i == slot ? 1 : 0)];
        ((CAKeyframeAnimation *)proxy).values = values;
    } else {
        CABasicAnimation *basic = (CABasicAnimation *)animation, *scalar = (CABasicAnimation *)proxy;
        scalar.fromValue = basic.fromValue ? @(slot == 0 ? 1 : 0) : nil;
        scalar.toValue = basic.toValue ? @(slot == 1 ? 1 : 0) : nil;
        scalar.byValue = basic.byValue ? @(slot == 2 ? 1 : 0) : nil;
    }
    return proxy;
}

static NSArray *backdropMatrixSlots(CAPropertyAnimation *animation)
{
    if ([animation isKindOfClass:[CAKeyframeAnimation class]])
        return ((CAKeyframeAnimation *)animation).values;
    CABasicAnimation *basic = (CABasicAnimation *)animation;
    return @[basic.fromValue ?: [NSNull null], basic.toValue ?: [NSNull null], basic.byValue ?: [NSNull null]];
}

static double backdropStandInValue(CAPropertyAnimation *proxy, CALayer *model, CALayer *presentation, double time)
{
    presentation.zPosition = model.zPosition;
    [proxy applyForTime:time presentationObject:presentation modelObject:model];
    return presentation.zPosition;
}

// The local time at which an animation's timing function reaches `progress`, from Core Animation's own evaluation.
static double backdropLocalTimeForProgress(CAMediaTimingFunction *function, double progress, CALayer *model, CALayer *presentation)
{
    if (!function)
        return progress;
    CABasicAnimation *proxy = [CABasicAnimation animationWithKeyPath:@"zPosition"];
    proxy.fromValue = @0;
    proxy.toValue = @1;
    proxy.duration = 1;
    proxy.timingFunction = function;
    double low = 0, high = 1;
    for (int i = 0; i < 40; ++i) {
        double middle = (low + high) / 2;
        if (backdropStandInValue(proxy, model, presentation, middle) < progress)
            low = middle;
        else
            high = middle;
    }
    return (low + high) / 2;
}

static NSArray *backdropFillValues(NSData *samples, unsigned bands, NSArray **keyTimes)
{
    const BackdropSample *sampled = samples.bytes;
    NSUInteger count = samples.length / sizeof(BackdropSample);
    double start = sampled[0].time, length = sampled[count - 1].time - start;

    // A sample without fill carries the next filled sample's colour at zero alpha, so alpha fades without a hue swing.
    double carry[backdropMaximumBands][3] = { { 0 } };
    for (unsigned band = 0; band < bands; ++band) {
        for (NSUInteger i = count; i-- > 0;) {
            if (sampled[i].rgba[band][3] > 0) {
                memcpy(carry[band], sampled[i].rgba[band], sizeof(carry[band]));
                break;
            }
        }
    }
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *times = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = count; i-- > 0;) {
        double fills[backdropMaximumBands][4];
        for (unsigned band = 0; band < bands; ++band) {
            if (sampled[i].rgba[band][3] > 0)
                memcpy(carry[band], sampled[i].rgba[band], sizeof(carry[band]));
            memcpy(fills[band], carry[band], sizeof(carry[band]));
            fills[band][3] = sampled[i].rgba[band][3];
        }
        [values insertObject:backdropColorArray(fills, bands) atIndex:0];
        [times insertObject:@(length > 0 ? (sampled[i].time - start) / length : (double)i / (count - 1)) atIndex:0];
    }
    *keyTimes = times;
    return values;
}

// Samples archive as device-space components, NSNull for an unknown band; CGColor does not archive.
static NSDictionary *backdropSamplesArchive(NSDictionary *samples)
{
    if (!samples)
        return nil;
    NSMutableArray *bands = [NSMutableArray array];
    for (id color in samples[@"colors"]) {
        double rgba[4];
        if (backdropDeviceColor(color, rgba))
            [bands addObject:@[@(rgba[0]), @(rgba[1]), @(rgba[2]), @(rgba[3])]];
        else
            [bands addObject:NSNull.null];
    }
    return @{ @"bands": bands, @"vertical": @([samples[@"vertical"] boolValue]) };
}

static NSDictionary *backdropSamplesFromArchive(NSDictionary *archive)
{
    if (!archive)
        return nil;
    NSMutableArray *colors = [NSMutableArray array];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    for (id band in archive[@"bands"]) {
        if (band == NSNull.null) {
            [colors addObject:band];
            continue;
        }
        CGFloat components[4] = { [band[0] doubleValue], [band[1] doubleValue], [band[2] doubleValue], [band[3] doubleValue] };
        CGColorRef color = CGColorCreate(space, components);
        [colors addObject:(id)color];
        CGColorRelease(color);
    }
    CGColorSpaceRelease(space);
    return @{ @"colors": colors, @"vertical": archive[@"vertical"] };
}

WK_PRIV_CLASS(CABackdropLayer) @interface CABackdropLayer : CAGradientLayer {
    NSArray *_backdropFilters;
    NSDictionary *_backdropSamples;
    BackdropBands _bands;
    NSMutableArray *_unkeyedFilterAnimations;
    BOOL _fillAnimationNeedsUpdate;
    BOOL _windowServerAware;
}
@property(nonatomic) BOOL windowServerAware;
@property(nonatomic, copy) NSDictionary *aquaWebKitBackdropSamples;
@end

@implementation CABackdropLayer
@synthesize windowServerAware = _windowServerAware;

- (id)initWithLayer:(id)layer
{
    if ((self = [super initWithLayer:layer]) && [layer isKindOfClass:[CABackdropLayer class]]) {
        CABackdropLayer *other = layer;
        [CATransaction lock];
        _backdropFilters = [other->_backdropFilters copy];
        _backdropSamples = [other->_backdropSamples copy];
        _bands = other->_bands;
        [CATransaction unlock];
        _windowServerAware = other->_windowServerAware;
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        self.aquaWebKitBackdropSamples = backdropSamplesFromArchive([coder decodeObjectForKey:@"wkBackdropSamples"]);
        self.filters = [coder decodeObjectForKey:@"wkBackdropFilters"];
        _windowServerAware = [coder decodeBoolForKey:@"wkWindowServerAware"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:self.filters forKey:@"wkBackdropFilters"];
    [coder encodeObject:backdropSamplesArchive(self.aquaWebKitBackdropSamples) forKey:@"wkBackdropSamples"];
    [coder encodeBool:_windowServerAware forKey:@"wkWindowServerAware"];
}

- (void)dealloc
{
    [_backdropFilters release];
    [_backdropSamples release];
    [_unkeyedFilterAnimations release];
    [super dealloc];
}

- (NSArray *)filters
{
    [CATransaction lock];
    NSArray *filters = [[_backdropFilters retain] autorelease];
    [CATransaction unlock];
    return filters;
}

// Every filters, samples and fill change happens under the transaction lock, which also guards
// initWithLayer:'s reads for presentation copies.
- (void)setFilters:(NSArray *)filters
{
    NSArray *copy = [filters copy];
    [CATransaction lock];
    [_backdropFilters release];
    _backdropFilters = copy;
    [self updateFill];
    [CATransaction unlock];
}

// WebKit's samples of the content beneath the backdrop: { colors: [CGColor or NSNull], vertical: BOOL }.
- (NSDictionary *)aquaWebKitBackdropSamples
{
    [CATransaction lock];
    NSDictionary *samples = [[_backdropSamples retain] autorelease];
    [CATransaction unlock];
    return samples;
}

- (void)setAquaWebKitBackdropSamples:(NSDictionary *)samples
{
    BackdropBands bands = { 0, [samples[@"vertical"] boolValue], { NO }, { { 0 } } };
    for (id color in samples[@"colors"]) {
        if (bands.count == backdropMaximumBands)
            break;
        bands.known[bands.count] = backdropDeviceColor(color, bands.rgba[bands.count]);
        ++bands.count;
    }
    NSDictionary *copy = [samples copy];
    [CATransaction lock];
    [_backdropSamples release];
    _backdropSamples = copy;
    _bands = bands;
    [self updateFill];
    [CATransaction unlock];
}

// A layer with filters keeps its colours even when it draws nothing, so 10.9 renders `colors` animations on it.
// Called with the transaction lock held.
- (void)updateFill
{
    unsigned bands = MAX(_bands.count, 1u);
    double fills[backdropMaximumBands][4] = { { 0 } };
    backdropFillColors(_backdropFilters, &_bands, fills);
    NSMutableArray *locations = nil;
    if (bands > 1) {
        locations = [NSMutableArray arrayWithCapacity:bands];
        for (unsigned band = 0; band < bands; ++band)
            [locations addObject:@((band + .5) / bands)];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [super setColors:_backdropFilters.count ? backdropColorArray(fills, bands) : nil];
    [super setLocations:locations];
    [super setStartPoint:_bands.vertical ? CGPointMake(.5, 0) : CGPointMake(0, .5)];
    [super setEndPoint:_bands.vertical ? CGPointMake(.5, 1) : CGPointMake(1, .5)];
    [CATransaction commit];
    [self setNeedsFillAnimation];
}

- (double)currentTime
{
    return [self convertTime:CACurrentMediaTime() fromLayer:nil];
}

// Filter animations in the order Core Animation applies them; unkeyed ones carry the time they were added.
- (NSArray *)filterAnimations
{
    NSMutableArray *animations = [NSMutableArray array];
    for (NSString *key in [super animationKeys]) {
        CAAnimation *animation = [self animationForKey:key];
        if (![key isEqualToString:backdropFillAnimationKey] && ![key isEqualToString:backdropFillTailKey] && backdropIsFilterAnimation(animation))
            [animations addObject:animation];
    }
    double now = [self currentTime];
    for (CAAnimation *animation in [[_unkeyedFilterAnimations copy] autorelease]) {
        if (animation.removedOnCompletion && backdropActiveEnd(animation) < now)
            [_unkeyedFilterAnimations removeObjectIdenticalTo:animation];
        else
            [animations addObject:animation];
    }
    return animations;
}

- (void)setNeedsFillAnimation
{
    _fillAnimationNeedsUpdate = YES;
    [self setNeedsLayout];
}

- (void)layoutSublayers
{
    [super layoutSublayers];
    if (!_fillAnimationNeedsUpdate)
        return;
    _fillAnimationNeedsUpdate = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self updateFillAnimation];
    [CATransaction commit];
}

// Mirrors the filter animations into keyframe animations of `colors` over this layer's time: one across their
// finite span, and, while some never end, a repeating tail of their shared period or a held value. Animations
// added in this transaction have no begin time yet; they and the mirrors all begin at its commit.
- (void)updateFillAnimation
{
    [super removeAnimationForKey:backdropFillAnimationKey];
    [super removeAnimationForKey:backdropFillTailKey];
    NSArray *animations = [self filterAnimations];
    if (!animations.count)
        return;
    BOOL uncommitted = YES;
    for (CAAnimation *animation in animations)
        uncommitted = uncommitted && !animation.beginTime;
    double now = uncommitted ? 0 : [self currentTime];

    CALayer *modelZero = [CALayer layer], *modelOne = [CALayer layer], *standIn = [CALayer layer], *sample = [CALayer layer];
    modelOne.zPosition = 1;
    [CATransaction lock];
    NSArray *modelFilters = [[_backdropFilters retain] autorelease];
    BackdropBands bands = _bands;
    [CATransaction unlock];
    unsigned bandCount = MAX(bands.count, 1u);
    NSMutableArray *pristine = [NSMutableArray arrayWithCapacity:modelFilters.count];
    for (id filter in modelFilters)
        [pristine addObject:[[filter copy] autorelease]];

    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:animations.count];
    NSMutableArray *fixedAnchors = [NSMutableArray array], *keyframeTimings = [NSMutableArray array];
    double start = INFINITY, finiteEnd = -INFINITY, period = 0;
    BOOL infinite = NO, repeating = NO, commensurate = YES, cumulative = NO, backwards = NO, forwards = NO, removed = YES;
    for (CAPropertyAnimation *source in animations) {
        CAPropertyAnimation *animation = [[source copy] autorelease];
        if (!animation.beginTime)
            animation.beginTime = now;
        animation.additive = NO;
        BOOL matrixValued = backdropMatrixValued(animation);
        if ([animation isKindOfClass:[CAKeyframeAnimation class]])
            backdropPrepareKeyframes((CAKeyframeAnimation *)animation, matrixValued);

        // A paused animation shows its timeOffset forever; the evaluator gives that only at a running copy's local time.
        CAPropertyAnimation *evaluated = animation;
        id fixedTime = [NSNull null];
        if (!animation.speed) {
            evaluated = [[animation copy] autorelease];
            evaluated.beginTime = 0;
            evaluated.speed = 1;
            evaluated.timeOffset = 0;
            fixedTime = @(animation.timeOffset);
        }
        NSMutableArray *standIns = nil;
        if (matrixValued) {
            NSArray *slots = backdropMatrixSlots(evaluated);
            standIns = [NSMutableArray arrayWithCapacity:slots.count + 1];
            for (NSUInteger i = 0; i < slots.count; ++i)
                [standIns addObject:backdropScalarStandIn(evaluated, i)];
            [standIns addObject:backdropScalarStandIn(evaluated, NSNotFound)];
        }
        NSArray *path = [animation.keyPath componentsSeparatedByString:@"."];
        [entries addObject:@[evaluated, standIns ?: [NSNull null], path.count == 3 ? path[1] : @"", path.count == 3 ? path[2] : @"", fixedTime]];

        double end = backdropActiveEnd(animation);
        start = fmin(start, animation.beginTime);
        [fixedAnchors addObject:@(animation.beginTime)];
        if (isfinite(end)) {
            finiteEnd = fmax(finiteEnd, end);
            [fixedAnchors addObject:@(end)];
        } else {
            infinite = YES;
            if (animation.speed) {
                double cycle = backdropPeriod(animation);
                commensurate = commensurate && (!repeating || fabs(cycle - period) <= 1e-9 * period);
                period = cycle;
                repeating = YES;
                cumulative = cumulative || animation.cumulative;
            }
        }
        forwards = forwards || [animation.fillMode isEqualToString:kCAFillModeForwards] || [animation.fillMode isEqualToString:kCAFillModeBoth];
        backwards = backwards || [animation.fillMode isEqualToString:kCAFillModeBackwards] || [animation.fillMode isEqualToString:kCAFillModeBoth];
        removed = removed && animation.removedOnCompletion;

        if ([animation isKindOfClass:[CAKeyframeAnimation class]] && animation.speed) {
            NSMutableArray *locals = [NSMutableArray array];
            for (NSNumber *keyTime in ((CAKeyframeAnimation *)animation).keyTimes)
                [locals addObject:@(backdropLocalTimeForProgress(animation.timingFunction, fmin(fmax(keyTime.doubleValue, 0), 1), modelZero, standIn) * backdropDuration(animation))];
            [keyframeTimings addObject:@[animation, locals, @(end)]];
        }
    }
    if (!isfinite(finiteEnd))
        finiteEnd = start;

    // Keyframe boundaries in this layer's time within [from, to], for every cycle the window covers.
    NSArray *(^anchors)(double, double) = ^(double from, double to) {
        NSMutableArray *result = [NSMutableArray arrayWithArray:fixedAnchors];
        for (NSArray *timing in keyframeTimings) {
            CAPropertyAnimation *animation = timing[0];
            double duration = backdropDuration(animation), cycle = duration * (animation.autoreverses ? 2 : 1);
            double lower = fmax(from, animation.beginTime), upper = fmin(to, [timing[2] doubleValue]);
            if (upper < lower)
                continue;
            double localA = (lower - animation.beginTime) * animation.speed + animation.timeOffset;
            double localB = (upper - animation.beginTime) * animation.speed + animation.timeOffset;
            double localLow = fmin(localA, localB), localHigh = fmax(localA, localB);
            for (double base = floor(localLow / cycle) * cycle; base <= localHigh; base += cycle) {
                for (NSNumber *local in timing[1]) {
                    double points[2] = { base + local.doubleValue, base + 2 * duration - local.doubleValue };
                    for (int k = 0; k < (animation.autoreverses ? 2 : 1); ++k) {
                        if (points[k] >= localLow && points[k] <= localHigh)
                            [result addObject:@(animation.beginTime + (points[k] - animation.timeOffset) / animation.speed)];
                    }
                }
            }
        }
        return result;
    };

    BackdropSample (^evaluate)(double) = ^(double time) {
        sample.filters = pristine;
        for (NSArray *entry in entries) {
            CAPropertyAnimation *animation = entry[0];
            double at = entry[4] == [NSNull null] ? time : [entry[4] doubleValue];
            if (entry[1] == [NSNull null]) {
                [animation applyForTime:at presentationObject:sample modelObject:self];
                continue;
            }
            NSArray *standIns = entry[1], *slots = backdropMatrixSlots(animation);
            NSMutableArray *filters = [[sample.filters mutableCopy] autorelease];
            for (NSUInteger i = 0; i < filters.count; ++i) {
                CAFilter *filter = filters[i];
                if (![filter isKindOfClass:NSClassFromString(@"CAFilter")] || ![[filter name] isEqualToString:entry[2]])
                    continue;
                float result[20] = { 0 }, matrix[20];
                const char *type = NULL;
                if (backdropMatrix([filter valueForKey:entry[3]], matrix)) {
                    double weight = backdropStandInValue(standIns.lastObject, modelOne, standIn, at);
                    for (int j = 0; j < 20; ++j)
                        result[j] += weight * matrix[j];
                }
                for (NSUInteger k = 0; k < slots.count; ++k) {
                    if (!backdropMatrix(slots[k], matrix))
                        continue;
                    type = [slots[k] objCType];
                    double weight = backdropStandInValue(standIns[k], modelZero, standIn, at);
                    for (int j = 0; j < 20; ++j)
                        result[j] += weight * matrix[j];
                }
                CAFilter *animated = [[filter copy] autorelease];
                [animated setValue:[NSValue value:result withObjCType:type] forKey:entry[3]];
                filters[i] = animated;
            }
            sample.filters = filters;
        }
        BackdropSample result = { time, { { 0 } } };
        backdropFillColors(sample.filters, &bands, result.rgba);
        return result;
    };

    // A cumulative repeat changes each iteration; the tail starts at the first iteration that a later one repeats,
    // and spans the iterations up to that repeat. With no repeat within 64 periods the fill holds.
    double tailStart = finiteEnd, tailLength = period;
    BOOL periodicTail = repeating && commensurate;
    if (periodicTail && cumulative) {
        NSData *grid = backdropSampleSpan(tailStart, tailStart + period, anchors, evaluate);
        const BackdropSample *phases = grid.bytes;
        NSUInteger count = grid.length / sizeof(BackdropSample);
        NSMutableArray *windows = [NSMutableArray arrayWithObject:grid];
        BOOL found = NO;
        for (NSUInteger k = 1; k < 64 && !found; ++k) {
            NSMutableData *window = [NSMutableData dataWithLength:grid.length];
            BackdropSample *sampled = window.mutableBytes;
            for (NSUInteger i = 0; i < count; ++i) {
                sampled[i] = evaluate(phases[i].time + k * period);
                sampled[i].time = phases[i].time;
            }
            for (NSUInteger j = 0; j < k && !found; ++j) {
                const BackdropSample *earlier = [windows[j] bytes];
                BOOL same = YES;
                for (NSUInteger i = 0; i < count && same; ++i)
                    same = backdropSamplesClose(&sampled[i], &earlier[i], &earlier[i]);
                if (same) {
                    found = YES;
                    tailStart += j * period;
                    tailLength = (k - j) * period;
                }
            }
            [windows addObject:window];
        }
        if (!found)
            tailStart += 64 * period;
        periodicTail = found;
    }

    NSArray *keyTimes = nil;
    if (periodicTail) {
        NSData *tailSamples = backdropSampleSpan(tailStart, tailStart + tailLength, anchors, evaluate);
        CAKeyframeAnimation *tail = [CAKeyframeAnimation animationWithKeyPath:@"colors"];
        tail.values = backdropFillValues(tailSamples, bandCount, &keyTimes);
        tail.keyTimes = keyTimes;
        tail.beginTime = uncommitted ? 0 : tailStart;
        tail.timeOffset = uncommitted ? fmod(tailLength - fmod(tailStart, tailLength), tailLength) : 0;
        tail.duration = tailLength;
        tail.repeatCount = HUGE_VALF;
        [super addAnimation:tail forKey:backdropFillTailKey];
    }
    double end = fmax(tailStart, start + backdropSampleResolution);
    NSData *samples = backdropSampleSpan(start, end, anchors, evaluate);
    CAKeyframeAnimation *fill = [CAKeyframeAnimation animationWithKeyPath:@"colors"];
    fill.values = backdropFillValues(samples, bandCount, &keyTimes);
    fill.keyTimes = keyTimes;
    fill.beginTime = uncommitted ? 0 : start;
    fill.duration = end - start;
    BOOL hold = infinite && !periodicTail;
    forwards = (forwards || hold) && !periodicTail;
    fill.fillMode = forwards && backwards ? kCAFillModeBoth : forwards ? kCAFillModeForwards : backwards ? kCAFillModeBackwards : kCAFillModeRemoved;
    fill.removedOnCompletion = removed && !hold;
    [super addAnimation:fill forKey:backdropFillAnimationKey];
}

- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key
{
    [super addAnimation:animation forKey:key];
    if (!backdropIsFilterAnimation(animation))
        return;
    if (!key) {
        CAAnimation *unkeyed = [[animation copy] autorelease];
        if (!unkeyed.beginTime)
            unkeyed.beginTime = [self currentTime];
        if (!_unkeyedFilterAnimations)
            _unkeyedFilterAnimations = [[NSMutableArray alloc] init];
        [_unkeyedFilterAnimations addObject:unkeyed];
    }
    [self setNeedsFillAnimation];
}

- (void)removeAnimationForKey:(NSString *)key
{
    BOOL filterAnimation = backdropIsFilterAnimation([self animationForKey:key]);
    [super removeAnimationForKey:key];
    if (filterAnimation)
        [self setNeedsFillAnimation];
}

- (void)removeAllAnimations
{
    [_unkeyedFilterAnimations removeAllObjects];
    [super removeAllAnimations];
}

- (NSArray *)animationKeys
{
    NSMutableArray *keys = [[[super animationKeys] mutableCopy] autorelease];
    [keys removeObject:backdropFillAnimationKey];
    [keys removeObject:backdropFillTailKey];
    return keys.count ? keys : nil;
}

// The immutable reference exposes native render properties independently of the logical filters getter.
- (void *)_copyRenderLayer:(void *)context layerFlags:(unsigned)flags commitFlags:(unsigned *)commitFlags
{
    CAGradientLayer *snapshot = [[CAGradientLayer alloc] _initWithReference:self];
    void *result = [snapshot _copyRenderLayer:context layerFlags:flags commitFlags:commitFlags];
    [snapshot release];
    return result;
}
@end
WK_PRIV_ALIAS(CABackdropLayer);

WK_PRIV_CLASS(CAPresentationModifier) @interface CAPresentationModifier : NSObject @end
@implementation CAPresentationModifier @end
WK_PRIV_ALIAS(CAPresentationModifier);
