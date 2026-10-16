// CoreImage: Objective-C methods on Core Image classes that macOS 10.9 does not have, implemented with the
// APIs 10.9 does have. 10.9's Core Image is QuartzCore's CoreImage subframework: it has every filter
// these name, the CIKernel Language (+[CIKernel kernelsWithString:]) and the filter-based kernel API
// (-[CIFilter apply:arguments:options:] with -[CIKernel setROISelector:]), but none of the typed
// CIFilterBuiltins accessors, no Metal kernels and no render destinations.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import "../classes/wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreImage/CIFilterBuiltins.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

// ---------------------------------------------------------------------------------------------------
// The CIFilterBuiltins class methods (10.15+): each is the named built-in filter, which 10.9 registers
// under the same name, with its inputs at their defaults.
static id wk_builtinFilter(NSString *name)
{
    CIFilter *filter = [CIFilter filterWithName:name];
    [filter setDefaults];
    return filter;
}

WK_POLYFILL_ADD_METHODS(CIFilter)
+ (CIFilter<CICompositeOperation> *)sourceOverCompositingFilter { return wk_builtinFilter(@"CISourceOverCompositing"); }
+ (CIFilter<CICompositeOperation> *)multiplyBlendModeFilter { return wk_builtinFilter(@"CIMultiplyBlendMode"); }
+ (CIFilter<CICompositeOperation> *)screenBlendModeFilter { return wk_builtinFilter(@"CIScreenBlendMode"); }
+ (CIFilter<CICompositeOperation> *)darkenBlendModeFilter { return wk_builtinFilter(@"CIDarkenBlendMode"); }
+ (CIFilter<CICompositeOperation> *)lightenBlendModeFilter { return wk_builtinFilter(@"CILightenBlendMode"); }
+ (CIFilter<CICompositeOperation> *)overlayBlendModeFilter { return wk_builtinFilter(@"CIOverlayBlendMode"); }
+ (CIFilter<CICompositeOperation> *)colorDodgeBlendModeFilter { return wk_builtinFilter(@"CIColorDodgeBlendMode"); }
+ (CIFilter<CICompositeOperation> *)colorBurnBlendModeFilter { return wk_builtinFilter(@"CIColorBurnBlendMode"); }
+ (CIFilter<CICompositeOperation> *)hardLightBlendModeFilter { return wk_builtinFilter(@"CIHardLightBlendMode"); }
+ (CIFilter<CICompositeOperation> *)softLightBlendModeFilter { return wk_builtinFilter(@"CISoftLightBlendMode"); }
+ (CIFilter<CICompositeOperation> *)differenceBlendModeFilter { return wk_builtinFilter(@"CIDifferenceBlendMode"); }
+ (CIFilter<CICompositeOperation> *)exclusionBlendModeFilter { return wk_builtinFilter(@"CIExclusionBlendMode"); }
+ (CIFilter<CICompositeOperation> *)hueBlendModeFilter { return wk_builtinFilter(@"CIHueBlendMode"); }
+ (CIFilter<CICompositeOperation> *)saturationBlendModeFilter { return wk_builtinFilter(@"CISaturationBlendMode"); }
+ (CIFilter<CICompositeOperation> *)colorBlendModeFilter { return wk_builtinFilter(@"CIColorBlendMode"); }
+ (CIFilter<CICompositeOperation> *)luminosityBlendModeFilter { return wk_builtinFilter(@"CILuminosityBlendMode"); }
+ (CIFilter<CIStripesGenerator> *)stripesGeneratorFilter { return wk_builtinFilter(@"CIStripesGenerator"); }

// -[CIFilter outputImage] (10.10+): the filter's kCIOutputImageKey value. 10.9's built-in filters each
// implement -outputImage, and keep their own.
- (CIImage *)outputImage { return [self valueForKey:kCIOutputImageKey]; }

// The CIFilterBuiltins protocols' typed properties (10.15+) set the filter's input keys.
- (void)setWidth:(float)width { [self setValue:@(width) forKey:@"inputWidth"]; }
- (void)setSharpness:(float)sharpness { [self setValue:@(sharpness) forKey:@"inputSharpness"]; }
- (void)setColor0:(CIColor *)color { [self setValue:color forKey:@"inputColor0"]; }
- (void)setColor1:(CIColor *)color { [self setValue:color forKey:@"inputColor1"]; }
@end

// ---------------------------------------------------------------------------------------------------
// +[CIColor clearColor] and +colorWithRed:green:blue:alpha:colorSpace: (10.12+). A colour in a colour
// space is the CGColor of those components, which +colorWithCGColor: (10.4) carries with its space; a
// space that is not RGB has no such colour.
WK_POLYFILL_ADD_METHODS(CIColor)
+ (CIColor *)clearColor { return (id)[CIColor colorWithRed:0 green:0 blue:0 alpha:0]; }

+ (CIColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha colorSpace:(CGColorSpaceRef)colorSpace
{
    if (!colorSpace || CGColorSpaceGetModel(colorSpace) != kCGColorSpaceModelRGB)
        return nil;
    const CGFloat components[4] = { red, green, blue, alpha };
    CGColorRef color = CGColorCreate(colorSpace, components);
    if (!color)
        return nil;
    id result = [CIColor colorWithCGColor:color];
    CGColorRelease(color);
    return result;
}
@end

// ---------------------------------------------------------------------------------------------------
// -[CIKernel applyWithExtent:roiCallback:arguments:] (10.11+) through the filter-based API 10.9 has: a
// kernel is applied by a filter, and asks that filter for each sampler's region of interest through the
// selector -setROISelector: names. Image arguments become samplers, as the kernel language reads them.
@interface WKCoreImageKernelApplier : CIFilter
@property (nonatomic, copy) CIKernelROICallback regionOfInterest;
@end

@implementation WKCoreImageKernelApplier

- (void)dealloc
{
    [_regionOfInterest release];
    [super dealloc];
}

- (CGRect)regionOf:(int)samplerIndex destRect:(CGRect)destRect userInfo:(id)userInfo
{
    return _regionOfInterest ? _regionOfInterest(samplerIndex, destRect) : destRect;
}

@end

static CIImage *wk_applyKernel(CIKernel *kernel, CGRect extent, CIKernelROICallback callback, NSArray *arguments)
{
    if (!kernel || !arguments)
        return nil;
    NSMutableArray *samplers = [NSMutableArray arrayWithCapacity:arguments.count];
    for (id argument in arguments)
        [samplers addObject:[argument isKindOfClass:[CIImage class]] ? [CISampler samplerWithImage:argument] : argument];
    WKCoreImageKernelApplier *applier = [[WKCoreImageKernelApplier alloc] init];
    applier.regionOfInterest = callback;
    [kernel setROISelector:@selector(regionOf:destRect:userInfo:)];
    NSDictionary *options = @{ kCIApplyOptionDefinition: [CIFilterShape shapeWithRect:extent] };
    CIImage *result = [applier apply:kernel arguments:samplers options:options];
    // The image asks the filter for regions of interest whenever it is rendered, so it keeps it.
    if (result)
        objc_setAssociatedObject(result, @selector(regionOf:destRect:userInfo:), applier, OBJC_ASSOCIATION_RETAIN);
    [applier release];
    return result;
}

// +[CIKernel kernelsWithMetalString:error:] (12.0+) compiles Metal Shading Language source. 10.9 has no
// Metal, so no such source compiles here: the answer is nil and an error saying so.
WK_POLYFILL_ADD_METHODS(CIKernel)
+ (NSArray<CIKernel *> *)kernelsWithMetalString:(NSString *)source error:(NSError **)error
{
    if (error) {
        *error = [NSError errorWithDomain:@"CIKernel" code:1
            userInfo:@{ NSLocalizedDescriptionKey: @"Metal kernels cannot be compiled: this system has no Metal." }];
    }
    return nil;
}

- (CIImage *)applyWithExtent:(CGRect)extent roiCallback:(CIKernelROICallback)callback arguments:(NSArray<id> *)args
{
    return wk_applyKernel(self, extent, callback, args);
}
@end

// ---------------------------------------------------------------------------------------------------
// -[CIImage imageByUnpremultiplyingAlpha] (10.12+): the kernel language's unpremultiply() over the image.
static CIKernel *wk_kernelNamed(NSString *source)
{
    NSArray *kernels = [CIKernel kernelsWithString:source];
    return kernels.count ? [kernels[0] retain] : nil;
}

WK_POLYFILL_ADD_METHODS(CIImage)
- (CIImage *)imageByUnpremultiplyingAlpha
{
    static CIKernel *kernel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kernel = wk_kernelNamed(@"kernel vec4 wk_unpremultiply(sampler image) { return unpremultiply(sample(image, samplerCoord(image))); }");
    });
    return wk_applyKernel(kernel, self.extent, ^CGRect(int __unused samplerIndex, CGRect destRect) { return destRect; }, @[ self ]);
}
@end

// ---------------------------------------------------------------------------------------------------
// Filters 10.9 does not register: CIMorphologyRectangleMinimum and CIMorphologyRectangleMaximum (10.13+),
// and CIGaussianBlurXY, the separable Gaussian blur with a standard deviation per axis. Each is built from
// separable kernel-language passes. The kernel language here has no data-dependent loops or branches and
// unrolls at most 129 iterations, so a pass reaches at most 64 pixels each side of a destination pixel,
// through a kernel compiled for the smallest of a few fixed reaches that covers it, and larger reaches take
// several passes: minima and maxima compose across passes exactly, and Gaussians compose by adding their
// variances. Outside an image's extent its samples are clear, as Core Image's are.
static const CGFloat wk_passReach = 64;

typedef enum { WKSeparableMinimum, WKSeparableMaximum, WKSeparableBlur, WKSeparableKindCount } WKSeparableKind;

static CIKernel *wk_separableKernel(WKSeparableKind kind, CGFloat reach)
{
    static const int bounds[] = { 4, 8, 16, 32, 64 };
    enum { boundCount = sizeof(bounds) / sizeof(bounds[0]) };
    static CIKernel *kernels[WKSeparableKindCount][boundCount];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // `body` combines `value` with the pixel `p` at `offset` along the pass's direction; `inside` is 1
        // within the pass's reach and 0 beyond it.
        NSString *names[] = { @"wk_minimum", @"wk_maximum", @"wk_blur" };
        NSString *declarations[] = { @"", @"", @"float total = 0.0;" };
        NSString *bodies[] = {
            @"value = mix(value, min(value, p), inside);",
            @"value = mix(value, max(value, p), inside);",
            @"float w = inside * exp(-(offset * offset) / (2.0 * sigma * sigma)); value += w * p; total += w;",
        };
        NSString *results[] = { @"value + 0.0 * sigma", @"value + 0.0 * sigma", @"value / total" };
        for (int k = 0; k < WKSeparableKindCount; k++) {
            for (int b = 0; b < boundCount; b++) {
                kernels[k][b] = wk_kernelNamed([NSString stringWithFormat:@"kernel vec4 %@%d(sampler image, vec2 direction, float reach, float sigma, vec4 start) {"
                    " vec2 c = destCoord(); vec4 value = start; %@"
                    " for (float offset = -%d.0; offset <= %d.0; offset += 1.0) {"
                    " float inside = abs(offset) <= reach ? 1.0 : 0.0; vec4 p = sample(image, samplerTransform(image, c + offset * direction)); %@ }"
                    " return %@; }", names[k], bounds[b], declarations[k], bounds[b], bounds[b], bodies[k], results[k]]);
            }
        }
    });
    for (int b = 0; b < boundCount; b++) {
        if (reach <= bounds[b])
            return kernels[kind][b];
    }
    return nil;
}

static CIImage *wk_separablePass(WKSeparableKind kind, CIImage *image, CGVector direction, CGFloat reach, CGFloat sigma, CIVector *start, bool grows)
{
    CGFloat dx = direction.dx * reach, dy = direction.dy * reach;
    CGRect extent = grows ? CGRectInset(image.extent, -dx, -dy) : image.extent;
    return wk_applyKernel(wk_separableKernel(kind, reach), extent, ^CGRect(int __unused index, CGRect destRect) { return CGRectInset(destRect, -dx, -dy); },
        @[ image, [CIVector vectorWithX:direction.dx Y:direction.dy], @(reach), @(sigma), start ]);
}

// Passes along one axis whose reaches add up to `reach`.
static CIImage *wk_morphologyAxis(WKSeparableKind kind, CIImage *image, CGVector direction, CGFloat reach, CIVector *start, bool grows)
{
    while (image && reach > 0) {
        CGFloat pass = fmin(reach, wk_passReach);
        image = wk_separablePass(kind, image, direction, pass, 0, start, grows);
        reach -= pass;
    }
    return image;
}

// Passes along one axis whose variances add up to sigma squared, each reaching three of its own deviations.
static CIImage *wk_blurAxis(CIImage *image, CGVector direction, CGFloat sigma)
{
    if (!(sigma > 0))
        return image;
    double passes = ceil(pow(3 * sigma / wk_passReach, 2));
    CGFloat passSigma = sigma / sqrt(passes);
    for (double pass = 0; image && pass < passes; pass++)
        image = wk_separablePass(WKSeparableBlur, image, direction, ceil(3 * passSigma), passSigma, [CIVector vectorWithX:0 Y:0 Z:0 W:0], true);
    return image;
}

@interface WKCIMorphologyRectangle : CIFilter
@property (nonatomic, retain) CIImage *inputImage;
@property (nonatomic, copy) NSNumber *inputWidth;
@property (nonatomic, copy) NSNumber *inputHeight;
@end

@implementation WKCIMorphologyRectangle
- (void)dealloc
{
    [_inputImage release];
    [_inputWidth release];
    [_inputHeight release];
    [super dealloc];
}

- (bool)isMaximum { return false; }

- (CIImage *)outputImage
{
    bool isMaximum = [self isMaximum];
    WKSeparableKind kind = isMaximum ? WKSeparableMaximum : WKSeparableMinimum;
    CIVector *start = isMaximum ? [CIVector vectorWithX:0 Y:0 Z:0 W:0] : [CIVector vectorWithX:1 Y:1 Z:1 W:1];
    CGFloat reachX = floor(fmax(_inputWidth ? _inputWidth.doubleValue : 1, 1) / 2);
    CGFloat reachY = floor(fmax(_inputHeight ? _inputHeight.doubleValue : 1, 1) / 2);
    CIImage *image = wk_morphologyAxis(kind, _inputImage, CGVectorMake(1, 0), reachX, start, isMaximum);
    return wk_morphologyAxis(kind, image, CGVectorMake(0, 1), reachY, start, isMaximum);
}
@end

@interface WKCIMorphologyRectangleMaximum : WKCIMorphologyRectangle
@end

@implementation WKCIMorphologyRectangleMaximum
- (bool)isMaximum { return true; }
@end

@interface WKCIGaussianBlurXY : CIFilter
@property (nonatomic, retain) CIImage *inputImage;
@property (nonatomic, copy) NSNumber *inputSigmaX;
@property (nonatomic, copy) NSNumber *inputSigmaY;
@end

@implementation WKCIGaussianBlurXY
- (void)dealloc
{
    [_inputImage release];
    [_inputSigmaX release];
    [_inputSigmaY release];
    [super dealloc];
}

- (CIImage *)outputImage
{
    CIImage *image = wk_blurAxis(_inputImage, CGVectorMake(1, 0), _inputSigmaX.doubleValue);
    return wk_blurAxis(image, CGVectorMake(0, 1), _inputSigmaY.doubleValue);
}
@end

// +[CIFilter filterWithName:] answers those names with the filters above.
WK_POLYFILL_REPLACE_METHODS(CIFilter)
+ (CIFilter *)filterWithName:(NSString *)name
{
    CIFilter *filter = WK_ORIGINAL_METHOD(CIFilter *, (NSString *), name);
    if (filter)
        return filter;
    Class polyfill = nil;
    if ([name isEqualToString:@"CIMorphologyRectangleMinimum"])
        polyfill = [WKCIMorphologyRectangle class];
    else if ([name isEqualToString:@"CIMorphologyRectangleMaximum"])
        polyfill = [WKCIMorphologyRectangleMaximum class];
    else if ([name isEqualToString:@"CIGaussianBlurXY"])
        polyfill = [WKCIGaussianBlurXY class];
    return polyfill ? [[[polyfill alloc] init] autorelease] : nil;
}
@end

// ---------------------------------------------------------------------------------------------------
// The classes 10.13 added and 10.9 lacks entirely, privately named and bound under their system names by
// WebCore alone (the aliases are private to the image).
#define WK_CORE_IMAGE_ALIAS(name, implementation) __asm__( \
    ".globl _OBJC_CLASS_$_" #name "\n\t.private_extern _OBJC_CLASS_$_" #name "\n\t" \
    ".set _OBJC_CLASS_$_" #name ", _OBJC_CLASS_$_" #implementation "\n\t" \
    ".globl _OBJC_METACLASS_$_" #name "\n\t.private_extern _OBJC_METACLASS_$_" #name "\n\t" \
    ".set _OBJC_METACLASS_$_" #name ", _OBJC_METACLASS_$_" #implementation)

// CIBlendKernel: the Porter-Duff operators on premultiplied colours, each a kernel-language kernel over
// the foreground and the background, applied over the union of their extents (outside an image's extent
// its samples are clear).
WK_PRIV_CLASS(CIBlendKernel) __attribute__((visibility("hidden")))
@interface WKCIBlendKernel : NSObject {
    CIKernel *_kernel;
}
@end

@implementation WKCIBlendKernel

- (instancetype)initWithResult:(NSString *)result name:(NSString *)name
{
    if (!(self = [super init]))
        return nil;
    NSString *source = [NSString stringWithFormat:@"kernel vec4 %@(sampler foreground, sampler background) {"
        " vec4 s = sample(foreground, samplerCoord(foreground)); vec4 d = sample(background, samplerCoord(background));"
        " return %@; }", name, result];
    _kernel = wk_kernelNamed(source);
    if (!_kernel) {
        [self release];
        return nil;
    }
    return self;
}

- (void)dealloc
{
    [_kernel release];
    [super dealloc];
}

#define WK_BLEND_KERNEL(selectorName, result) \
    + (instancetype)selectorName \
    { \
        static WKCIBlendKernel *kernel; \
        static dispatch_once_t once; \
        dispatch_once(&once, ^{ kernel = [[WKCIBlendKernel alloc] initWithResult:@result name:@"wk_" #selectorName]; }); \
        return kernel; \
    }

WK_BLEND_KERNEL(sourceOver, "s + d * (1.0 - s.a)")
WK_BLEND_KERNEL(sourceIn, "s * d.a")
WK_BLEND_KERNEL(sourceOut, "s * (1.0 - d.a)")
WK_BLEND_KERNEL(sourceAtop, "s * d.a + d * (1.0 - s.a)")
WK_BLEND_KERNEL(exclusiveOr, "s * (1.0 - d.a) + d * (1.0 - s.a)")
WK_BLEND_KERNEL(componentAdd, "s + d")

- (CIImage *)applyWithForeground:(CIImage *)foreground background:(CIImage *)background
{
    if (!foreground || !background)
        return nil;
    return wk_applyKernel(_kernel, CGRectUnion(foreground.extent, background.extent), ^CGRect(int __unused samplerIndex, CGRect destRect) { return destRect; },
        @[ foreground, background ]);
}

@end
WK_CORE_IMAGE_ALIAS(CIBlendKernel, WKPolyfillPriv_CIBlendKernel);

// CIRenderDestination for an IOSurface, and the CIRenderTask a render answers with.
WK_PRIV_CLASS(CIRenderDestination) __attribute__((visibility("hidden")))
@interface WKCIRenderDestination : NSObject {
    IOSurfaceRef _surface;
    CGColorSpaceRef _colorSpace;
}
@end

@implementation WKCIRenderDestination

- (instancetype)initWithIOSurface:(id)surface
{
    if (!(self = [super init]))
        return nil;
    if (!surface) {
        [self release];
        return nil;
    }
    _surface = (IOSurfaceRef)CFRetain((CFTypeRef)surface);
    _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return self;
}

- (void)dealloc
{
    if (_surface)
        CFRelease(_surface);
    CGColorSpaceRelease(_colorSpace);
    [super dealloc];
}

- (IOSurfaceRef)wk_surface { return _surface; }
- (NSUInteger)width { return IOSurfaceGetWidth(_surface); }
- (NSUInteger)height { return IOSurfaceGetHeight(_surface); }
- (CGColorSpaceRef)colorSpace { return _colorSpace; }

- (void)setColorSpace:(CGColorSpaceRef)colorSpace
{
    CGColorSpaceRetain(colorSpace);
    CGColorSpaceRelease(_colorSpace);
    _colorSpace = colorSpace;
}

@end
WK_CORE_IMAGE_ALIAS(CIRenderDestination, WKPolyfillPriv_CIRenderDestination);

// The render a task describes: its wall time and the pixels it wrote.
WK_PRIV_CLASS(CIRenderInfo) __attribute__((visibility("hidden")))
@interface WKCIRenderInfo : NSObject {
    NSTimeInterval _kernelExecutionTime;
    NSInteger _pixelsProcessed;
}
- (instancetype)initWithExecutionTime:(NSTimeInterval)executionTime pixelsProcessed:(NSInteger)pixelsProcessed;
@end

@implementation WKCIRenderInfo
- (instancetype)initWithExecutionTime:(NSTimeInterval)executionTime pixelsProcessed:(NSInteger)pixelsProcessed
{
    if ((self = [super init])) {
        _kernelExecutionTime = executionTime;
        _pixelsProcessed = pixelsProcessed;
    }
    return self;
}
- (NSTimeInterval)kernelExecutionTime { return _kernelExecutionTime; }
- (NSInteger)pixelsProcessed { return _pixelsProcessed; }
@end
WK_CORE_IMAGE_ALIAS(CIRenderInfo, WKPolyfillPriv_CIRenderInfo);

WK_PRIV_CLASS(CIRenderTask) __attribute__((visibility("hidden")))
@interface WKCIRenderTask : NSObject {
    WKCIRenderInfo *_info;
}
- (instancetype)initWithInfo:(WKCIRenderInfo *)info;
@end

@implementation WKCIRenderTask
- (instancetype)initWithInfo:(WKCIRenderInfo *)info
{
    if ((self = [super init]))
        _info = [info retain];
    return self;
}

- (void)dealloc
{
    [_info release];
    [super dealloc];
}

- (CIRenderInfo *)waitUntilCompletedAndReturnError:(NSError **)error
{
    return (CIRenderInfo *)[[_info retain] autorelease];
}
@end
WK_CORE_IMAGE_ALIAS(CIRenderTask, WKPolyfillPriv_CIRenderTask);

// -[CIContext startTaskToRender:fromRect:toDestination:atPoint:error:] (10.13+) renders `fromRect` of the
// image with its origin at `atPoint` of the destination, whose coordinates run up from its bottom row, and
// leaves the rest of the destination as it was. 10.9's -render:toBitmap:rowBytes:bounds:format:colorSpace:
// renders a rect of an image into memory, so the part of that placement inside the surface is rendered
// into the locked surface's own rows. The render completes before the task is returned.
static bool wk_coreImageFormat(OSType pixelFormat, CIFormat *format, size_t *pixelBytes)
{
    switch (pixelFormat) {
    case 'BGRA': *format = kCIFormatBGRA8; *pixelBytes = 4; return true;
    case 'RGBA': *format = kCIFormatRGBA8; *pixelBytes = 4; return true;
    case 'RGhA': *format = kCIFormatRGBAh; *pixelBytes = 8; return true;
    case 'RGfA': *format = kCIFormatRGBAf; *pixelBytes = 16; return true;
    default: return false;
    }
}

WK_POLYFILL_ADD_METHODS(CIContext)
- (CIRenderTask *)startTaskToRender:(CIImage *)image fromRect:(CGRect)fromRect toDestination:(CIRenderDestination *)destination
    atPoint:(CGPoint)atPoint error:(NSError **)error
{
    WKCIRenderDestination *ioSurfaceDestination = (WKCIRenderDestination *)destination;
    IOSurfaceRef surface = [ioSurfaceDestination isKindOfClass:[WKCIRenderDestination class]] ? [ioSurfaceDestination wk_surface] : NULL;
    CIFormat format;
    size_t pixelBytes;
    if (!image || !surface || !wk_coreImageFormat(IOSurfaceGetPixelFormat(surface), &format, &pixelBytes)) {
        if (error)
            *error = [NSError errorWithDomain:@"CIContext" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"The destination is not a renderable IOSurface." }];
        return nil;
    }
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
    CGRect placed = CGRectMake(atPoint.x, atPoint.y, fromRect.size.width, fromRect.size.height);
    CGRect drawn = CGRectIntegral(CGRectIntersection(placed, CGRectMake(0, 0, width, height)));
    NSInteger pixels = 0;
    uint64_t start = mach_absolute_time();
    if (!CGRectIsNull(drawn) && !CGRectIsEmpty(drawn)) {
        pixels = (NSInteger)(drawn.size.width * drawn.size.height);
        CGRect source = CGRectOffset(drawn, fromRect.origin.x - atPoint.x, fromRect.origin.y - atPoint.y);
        IOSurfaceLock(surface, 0, NULL);
        size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
        size_t topRow = height - (size_t)CGRectGetMaxY(drawn);
        uint8_t *origin = (uint8_t *)IOSurfaceGetBaseAddress(surface) + topRow * rowBytes + (size_t)drawn.origin.x * pixelBytes;
        [self render:image toBitmap:origin rowBytes:rowBytes bounds:source format:format colorSpace:[ioSurfaceDestination colorSpace]];
        IOSurfaceUnlock(surface, 0, NULL);
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    NSTimeInterval seconds = (double)(mach_absolute_time() - start) * timebase.numer / timebase.denom / 1e9;
    WKCIRenderInfo *info = [[WKCIRenderInfo alloc] initWithExecutionTime:seconds pixelsProcessed:pixels];
    WKCIRenderTask *task = [[WKCIRenderTask alloc] initWithInfo:info];
    [info release];
    return (CIRenderTask *)[task autorelease];
}
@end

#pragma clang diagnostic pop
