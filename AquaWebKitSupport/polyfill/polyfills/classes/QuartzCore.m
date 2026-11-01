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
// computes it, including its defaults for unset inputs. A blur stands in as a darkening of 25% * r^2 / (r^2 + 1).
static void backdropApplyFilter(CAFilter *filter, double pixel[4])
{
    NSString *type = [filter type];
    double luma = backdropPixelLuma(pixel), color[4];
    if ([type isEqualToString:@"gaussianBlur"]) {
        double radius = fmax(backdropNumber(filter, @"inputRadius", 0), 0);
        double scale = 1 - .25 * radius * radius / (radius * radius + 1);
        for (int i = 0; i < 3; ++i)
            pixel[i] *= scale;
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
static void backdropChainOutput(NSArray *filters, double x, double out[3])
{
    double pixel[4] = { x, x, x, 1 };
    for (CAFilter *filter in filters) {
        if ([filter isKindOfClass:NSClassFromString(@"CAFilter")] && [filter isEnabled])
            backdropApplyFilter(filter, pixel);
    }
    double alpha = fmin(fmax(pixel[3], 0), 1);
    for (int i = 0; i < 3; ++i)
        out[i] = fmin(fmax(pixel[i], 0), 1) * alpha + x * (1 - alpha);
}

// A translucent fill maps each channel x to x * (1 - alpha) + color * alpha. When the chain's output on black,
// mid-grey and white is such a map, the fill reproduces it; otherwise the fill matches the chain at mid-grey.
static BOOL backdropFillColor(NSArray *filters, double rgba[4])
{
    double black[3], middle[3], white[3];
    backdropChainOutput(filters, 0, black);
    backdropChainOutput(filters, .5, middle);
    backdropChainOutput(filters, 1, white);
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

// A layer with filters keeps a colour pair even when it draws nothing, so 10.9 renders `colors` animations on it.
static CGColorRef backdropCreateFill(NSArray *filters)
{
    double rgba[4] = { 0, 0, 0, 0 };
    if (!filters.count)
        return NULL;
    backdropFillColor(filters, rgba);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[4] = { rgba[0], rgba[1], rgba[2], rgba[3] };
    CGColorRef color = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return color;
}

static NSString * const backdropFillAnimationKey = @"wkBackdropFill";
static NSString * const backdropFillTailKey = @"wkBackdropFillTail";

// Fill samples are placed until linear interpolation between neighbours is within half an 8-bit level, and no
// closer than one millisecond of layer time, below a display frame.
static const double backdropSampleTolerance = .5 / 255;
static const double backdropSampleResolution = .001;

typedef struct {
    double time;
    double rgba[4];
} BackdropSample;

static BOOL backdropSamplesClose(const BackdropSample *expected, const BackdropSample *start, const BackdropSample *end)
{
    double fraction = end->time > start->time ? (expected->time - start->time) / (end->time - start->time) : 0;
    for (int i = 0; i < 4; ++i) {
        double a = start->rgba[i] * (i < 3 ? start->rgba[3] : 1), b = end->rgba[i] * (i < 3 ? end->rgba[3] : 1);
        double actual = expected->rgba[i] * (i < 3 ? expected->rgba[3] : 1);
        if (fabs(a + (b - a) * fraction - actual) > backdropSampleTolerance)
            return NO;
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

static NSArray *backdropFillValues(NSData *samples, NSArray **keyTimes)
{
    const BackdropSample *sampled = samples.bytes;
    NSUInteger count = samples.length / sizeof(BackdropSample);
    double start = sampled[0].time, length = sampled[count - 1].time - start;

    // A sample without fill carries the next filled sample's colour at zero alpha, so alpha fades without a hue swing.
    double carry[3] = { 0, 0, 0 };
    for (NSUInteger i = count; i-- > 0;) {
        if (sampled[i].rgba[3] > 0) {
            memcpy(carry, sampled[i].rgba, sizeof(carry));
            break;
        }
    }
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *times = [NSMutableArray arrayWithCapacity:count];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    for (NSUInteger i = count; i-- > 0;) {
        if (sampled[i].rgba[3] > 0)
            memcpy(carry, sampled[i].rgba, sizeof(carry));
        CGFloat components[4] = { carry[0], carry[1], carry[2], sampled[i].rgba[3] };
        CGColorRef color = CGColorCreate(space, components);
        [values insertObject:@[(id)color, (id)color] atIndex:0];
        [times insertObject:@(length > 0 ? (sampled[i].time - start) / length : (double)i / (count - 1)) atIndex:0];
        CGColorRelease(color);
    }
    CGColorSpaceRelease(space);
    *keyTimes = times;
    return values;
}

// The filter chain as 10.9 applies it to WebKit's images of the backdrop. 10.9's blur has no inputNormalizeEdges;
// for an opaque backdrop its inputHardEdges renormalizes the same way.
static NSArray *backdropImageFilters(NSArray *filters)
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:filters.count];
    for (id filter in filters) {
        CAFilter *copy = [[filter copy] autorelease];
        if ([copy isKindOfClass:NSClassFromString(@"CAFilter")] && [[copy type] isEqualToString:@"gaussianBlur"]
            && [[copy valueForKey:@"inputNormalizeEdges"] boolValue])
            [copy setValue:@YES forKey:@"inputHardEdges"];
        [result addObject:copy];
    }
    return result;
}

static NSString * const backdropImagesKey = @"wkBackdropImages";
static NSString * const backdropImageFadeKey = @"wkBackdropImageFade";
static const double backdropImageFadeDuration = .1;

// Once an image has faded in, the images beneath it are covered and leave; once one has faded out, it leaves.
@interface WKPolyfillBackdropImageFade : NSObject {
    CALayer *_image;
    BOOL _fadesOut;
}
@end

@implementation WKPolyfillBackdropImageFade
- (id)initWithImage:(CALayer *)image fadesOut:(BOOL)fadesOut
{
    if ((self = [super init])) {
        _image = [image retain];
        _fadesOut = fadesOut;
    }
    return self;
}

- (void)dealloc
{
    [_image release];
    [super dealloc];
}

- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished
{
    if (!finished)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_fadesOut) {
        [_image removeAllAnimations];
        [_image removeFromSuperlayer];
    } else {
        for (CALayer *covered in [[_image.superlayer.sublayers copy] autorelease]) {
            if (covered == _image)
                break;
            [covered removeAllAnimations];
            [covered removeFromSuperlayer];
        }
    }
    [CATransaction commit];
}
@end

static void backdropFadeImage(CALayer *image, BOOL fadesOut)
{
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    CALayer *presented = image.presentationLayer;
    fade.fromValue = @(fadesOut ? (presented ?: image).opacity : 0);
    fade.toValue = @(fadesOut ? 0 : 1);
    fade.duration = backdropImageFadeDuration;
    fade.delegate = [[[WKPolyfillBackdropImageFade alloc] initWithImage:image fadesOut:fadesOut] autorelease];
    image.opacity = fadesOut ? 0 : 1;
    [image addAnimation:fade forKey:backdropImageFadeKey];
}

// The layer holding a backdrop's images, which its `sublayers` leaves out.
@interface WKPolyfillBackdropImages : CALayer
@end

@implementation WKPolyfillBackdropImages
@end

// The backdrop shows WebKit's images of the content beneath it (aquaWebKitBackdropImage) through the filter
// chain, in a rasterized sublayer at the images' resolution. An image after the backdrop's first fades in over
// the ones before it, and they fade out when WebKit sends none. Where no image covers it, its fill stands in for
// the chain.
WK_PRIV_CLASS(CABackdropLayer) @interface CABackdropLayer : CAGradientLayer {
    NSArray *_backdropFilters;
    WKPolyfillBackdropImages *_images;
    NSMutableArray *_unkeyedFilterAnimations;
    BOOL _fillAnimationNeedsUpdate;
    BOOL _windowServerAware;
    BOOL _showedImage;
}
@property(nonatomic) BOOL windowServerAware;
- (void)setAquaWebKitBackdropImage:(NSDictionary *)image;
@end

@implementation CABackdropLayer
@synthesize windowServerAware = _windowServerAware;

- (id)initWithLayer:(id)layer
{
    if ((self = [super initWithLayer:layer]) && [layer isKindOfClass:[CABackdropLayer class]]) {
        CABackdropLayer *other = layer;
        [CATransaction lock];
        _backdropFilters = [other->_backdropFilters copy];
        [CATransaction unlock];
        _windowServerAware = other->_windowServerAware;
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _images = [[coder decodeObjectForKey:backdropImagesKey] retain];
        if (_images)
            [super insertSublayer:_images atIndex:0];
        _showedImage = _images.sublayers.count > 0;
        self.filters = [coder decodeObjectForKey:@"wkBackdropFilters"];
        _windowServerAware = [coder decodeBoolForKey:@"wkWindowServerAware"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:self.filters forKey:@"wkBackdropFilters"];
    [coder encodeObject:_images forKey:backdropImagesKey];
    [coder encodeBool:_windowServerAware forKey:@"wkWindowServerAware"];
}

- (void)dealloc
{
    [_backdropFilters release];
    for (CALayer *image in _images.sublayers)
        [image removeAllAnimations];
    [_images release];
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

// Filters change under the transaction lock, which also guards initWithLayer:'s read for presentation copies.
- (void)setFilters:(NSArray *)filters
{
    NSArray *copy = [filters copy];
    CGColorRef color = backdropCreateFill(copy);
    [CATransaction lock];
    [_backdropFilters release];
    _backdropFilters = copy;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [super setColors:color ? @[(id)color, (id)color] : nil];
    _images.filters = backdropImageFilters(copy);
    [CATransaction commit];
    [CATransaction unlock];
    if (color)
        CGColorRelease(color);
    [self setNeedsFillAnimation];
}

// { image: CGImage, rect: NSValue of the CGRect it covers in this layer's coordinates }, or nil for none.
- (void)setAquaWebKitBackdropImage:(NSDictionary *)sample
{
    id contents = sample[@"image"];
    CGRect rect;
    [sample[@"rect"] getValue:&rect];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!sample) {
        for (CALayer *image in _images.sublayers) {
            if (image.opacity)
                backdropFadeImage(image, YES);
        }
        [CATransaction commit];
        return;
    }
    if (!_images) {
        _images = [[WKPolyfillBackdropImages alloc] init];
        _images.anchorPoint = CGPointZero;
        _images.bounds = self.bounds;
        _images.position = self.bounds.origin;
        _images.shouldRasterize = YES;
        [CATransaction lock];
        _images.filters = backdropImageFilters(_backdropFilters);
        [CATransaction unlock];
        [super insertSublayer:_images atIndex:0];
        [self setNeedsFillAnimation];
    }
    // Twice the images' density preserves all they hold.
    _images.rasterizationScale = fmin(2 * CGImageGetWidth((CGImageRef)contents) / rect.size.width, fmax(self.contentsScale, 1));
    CALayer *image = [CALayer layer];
    image.anchorPoint = CGPointZero;
    image.frame = rect;
    image.contents = contents;
    [_images addSublayer:image];
    if (_showedImage)
        backdropFadeImage(image, NO);
    _showedImage = YES;
    [CATransaction commit];
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
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _images.bounds = self.bounds;
    _images.position = self.bounds.origin;
    if (_fillAnimationNeedsUpdate) {
        _fillAnimationNeedsUpdate = NO;
        [self updateFillAnimation];
    }
    [CATransaction commit];
}

// The images sit beneath the caller's sublayers, which are all `sublayers` lists, on this layer and its
// presentation copies.
- (BOOL)holdsImages
{
    return [[super sublayers].firstObject isKindOfClass:[WKPolyfillBackdropImages class]];
}

- (NSArray *)sublayers
{
    NSArray *sublayers = [super sublayers];
    if (![self holdsImages])
        return sublayers;
    NSArray *callers = [sublayers subarrayWithRange:NSMakeRange(1, sublayers.count - 1)];
    return callers.count ? callers : nil;
}

- (void)setSublayers:(NSArray *)sublayers
{
    [super setSublayers:sublayers];
    if (_images)
        [super insertSublayer:_images atIndex:0];
}

- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned)index
{
    [super insertSublayer:layer atIndex:index + ([self holdsImages] ? 1 : 0)];
}

- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling
{
    if (sibling)
        [super insertSublayer:layer below:sibling];
    else
        [self insertSublayer:layer atIndex:0];
}

// The images run copies of the filter animations, which their filters carry under the same names. Without
// them, rasterization keeps the blurred result until the images or filters change; 10.9 renders a rasterized
// layer's filter animation late, starting from a frame at its model value.
- (void)updateImageAnimations:(NSArray *)animations now:(double)now
{
    _images.shouldRasterize = !animations.count;
    for (NSString *key in _images.animationKeys)
        [_images removeAnimationForKey:key];
    NSUInteger index = 0;
    for (CAAnimation *source in animations) {
        CAAnimation *animation = [[source copy] autorelease];
        animation.delegate = nil;
        if (!animation.beginTime)
            animation.beginTime = now;
        [_images addAnimation:animation forKey:[NSString stringWithFormat:@"wkBackdropFilter%lu", (unsigned long)index++]];
    }
}

// Mirrors the filter animations into keyframe animations of `colors` over this layer's time: one across their
// finite span, and, while some never end, a repeating tail of their shared period or a held value. Animations
// added in this transaction have no begin time yet; they and the mirrors all begin at its commit.
- (void)updateFillAnimation
{
    [super removeAnimationForKey:backdropFillAnimationKey];
    [super removeAnimationForKey:backdropFillTailKey];
    NSArray *animations = [self filterAnimations];
    BOOL uncommitted = YES;
    for (CAAnimation *animation in animations)
        uncommitted = uncommitted && !animation.beginTime;
    double now = uncommitted ? 0 : [self currentTime];
    [self updateImageAnimations:animations now:now];
    if (!animations.count)
        return;

    CALayer *modelZero = [CALayer layer], *modelOne = [CALayer layer], *standIn = [CALayer layer], *sample = [CALayer layer];
    modelOne.zPosition = 1;
    [CATransaction lock];
    NSArray *modelFilters = [[_backdropFilters retain] autorelease];
    [CATransaction unlock];
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
        BackdropSample result = { time, { 0, 0, 0, 0 } };
        backdropFillColor(sample.filters, result.rgba);
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
        tail.values = backdropFillValues(tailSamples, &keyTimes);
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
    fill.values = backdropFillValues(samples, &keyTimes);
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
