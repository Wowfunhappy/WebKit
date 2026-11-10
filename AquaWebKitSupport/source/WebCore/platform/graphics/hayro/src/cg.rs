//! The CoreGraphics and CoreFoundation entry points the device draws with, as 10.9 declares them.
//! CGContextGetBaseCTM is CoreGraphics SPI, the one WebCore's GraphicsContextCG reads the base CTM with.
//! CGSoftMaskCreate, CGSoftMaskRelease and CGContextSetSoftMask are the SPI CoreGraphics' own PDF
//! renderer applies a soft mask through, declared as 10.9's CGPDFDrawingContextCreateSoftMask calls them:
//! a NULL background makes an alpha mask, a background colour a luminosity mask over that backdrop.

#![allow(non_upper_case_globals, non_snake_case, dead_code)]

use std::ffi::c_void;

pub type CGFloat = f64;
pub type CGContextRef = *mut c_void;
pub type CGColorRef = *mut c_void;
pub type CGColorSpaceRef = *mut c_void;
pub type CGImageRef = *mut c_void;
pub type CGDataProviderRef = *mut c_void;
pub type CGPatternRef = *mut c_void;
pub type CGFunctionRef = *mut c_void;
pub type CGShadingRef = *mut c_void;
pub type CGSoftMaskRef = *mut c_void;
pub type CFStringRef = *const c_void;
pub type CFDataRef = *const c_void;
pub type CFTypeRef = *const c_void;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CGPoint {
    pub x: CGFloat,
    pub y: CGFloat,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CGSize {
    pub width: CGFloat,
    pub height: CGFloat,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CGRect {
    pub origin: CGPoint,
    pub size: CGSize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CGAffineTransform {
    pub a: CGFloat,
    pub b: CGFloat,
    pub c: CGFloat,
    pub d: CGFloat,
    pub tx: CGFloat,
    pub ty: CGFloat,
}

#[repr(C)]
pub struct CGPatternCallbacks {
    pub version: u32,
    pub draw_pattern: Option<unsafe extern "C" fn(*mut c_void, CGContextRef)>,
    pub release_info: Option<unsafe extern "C" fn(*mut c_void)>,
}

#[repr(C)]
pub struct CGFunctionCallbacks {
    pub version: u32,
    pub evaluate: Option<unsafe extern "C" fn(*mut c_void, *const CGFloat, *mut CGFloat)>,
    pub release_info: Option<unsafe extern "C" fn(*mut c_void)>,
}

#[repr(C)]
pub struct CGSoftMaskCallbacks {
    pub version: u32,
    pub draw_soft_mask: Option<unsafe extern "C" fn(*mut c_void, CGContextRef)>,
    pub release_info: Option<unsafe extern "C" fn(*mut c_void)>,
}

pub const kCGLineCapButt: i32 = 0;
pub const kCGLineCapRound: i32 = 1;
pub const kCGLineCapSquare: i32 = 2;
pub const kCGLineJoinMiter: i32 = 0;
pub const kCGLineJoinRound: i32 = 1;
pub const kCGLineJoinBevel: i32 = 2;
pub const kCGImageAlphaNone: u32 = 0;
pub const kCGImageAlphaLast: u32 = 3;
pub const kCGRenderingIntentDefault: i32 = 0;
pub const kCGPatternTilingConstantSpacing: i32 = 2;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    pub static kCGColorSpaceSRGB: CFStringRef;

    pub fn CGContextSaveGState(c: CGContextRef);
    pub fn CGContextRestoreGState(c: CGContextRef);
    pub fn CGContextConcatCTM(c: CGContextRef, transform: CGAffineTransform);
    pub fn CGContextGetCTM(c: CGContextRef) -> CGAffineTransform;
    pub fn CGContextGetBaseCTM(c: CGContextRef) -> CGAffineTransform;
    pub fn CGContextGetClipBoundingBox(c: CGContextRef) -> CGRect;
    pub fn CGContextBeginPath(c: CGContextRef);
    pub fn CGContextMoveToPoint(c: CGContextRef, x: CGFloat, y: CGFloat);
    pub fn CGContextAddLineToPoint(c: CGContextRef, x: CGFloat, y: CGFloat);
    pub fn CGContextAddQuadCurveToPoint(c: CGContextRef, cpx: CGFloat, cpy: CGFloat, x: CGFloat, y: CGFloat);
    pub fn CGContextAddCurveToPoint(c: CGContextRef, cp1x: CGFloat, cp1y: CGFloat, cp2x: CGFloat, cp2y: CGFloat, x: CGFloat, y: CGFloat);
    pub fn CGContextClosePath(c: CGContextRef);
    pub fn CGContextFillPath(c: CGContextRef);
    pub fn CGContextEOFillPath(c: CGContextRef);
    pub fn CGContextStrokePath(c: CGContextRef);
    pub fn CGContextFillRect(c: CGContextRef, rect: CGRect);
    pub fn CGContextClip(c: CGContextRef);
    pub fn CGContextEOClip(c: CGContextRef);
    pub fn CGContextClipToRect(c: CGContextRef, rect: CGRect);
    pub fn CGContextClipToMask(c: CGContextRef, rect: CGRect, mask: CGImageRef);
    pub fn CGContextSetLineWidth(c: CGContextRef, width: CGFloat);
    pub fn CGContextSetLineCap(c: CGContextRef, cap: i32);
    pub fn CGContextSetLineJoin(c: CGContextRef, join: i32);
    pub fn CGContextSetMiterLimit(c: CGContextRef, limit: CGFloat);
    pub fn CGContextSetLineDash(c: CGContextRef, phase: CGFloat, lengths: *const CGFloat, count: usize);
    pub fn CGContextSetFillColorWithColor(c: CGContextRef, color: CGColorRef);
    pub fn CGContextSetStrokeColorWithColor(c: CGContextRef, color: CGColorRef);
    pub fn CGContextSetFillColorSpace(c: CGContextRef, space: CGColorSpaceRef);
    pub fn CGContextSetFillPattern(c: CGContextRef, pattern: CGPatternRef, components: *const CGFloat);
    pub fn CGContextSetAlpha(c: CGContextRef, alpha: CGFloat);
    pub fn CGContextSetBlendMode(c: CGContextRef, mode: i32);
    pub fn CGContextBeginTransparencyLayer(c: CGContextRef, auxiliaryInfo: CFTypeRef);
    pub fn CGContextEndTransparencyLayer(c: CGContextRef);
    pub fn CGContextDrawImage(c: CGContextRef, rect: CGRect, image: CGImageRef);

    pub fn CGColorSpaceCreateWithName(name: CFStringRef) -> CGColorSpaceRef;
    pub fn CGColorSpaceCreateDeviceGray() -> CGColorSpaceRef;
    pub fn CGColorSpaceCreatePattern(baseSpace: CGColorSpaceRef) -> CGColorSpaceRef;
    pub fn CGColorSpaceRelease(space: CGColorSpaceRef);
    pub fn CGColorCreate(space: CGColorSpaceRef, components: *const CGFloat) -> CGColorRef;
    pub fn CGColorRelease(color: CGColorRef);

    pub fn CGDataProviderCreateWithCFData(data: CFDataRef) -> CGDataProviderRef;
    pub fn CGDataProviderRelease(provider: CGDataProviderRef);
    pub fn CGImageCreate(width: usize, height: usize, bitsPerComponent: usize, bitsPerPixel: usize, bytesPerRow: usize, space: CGColorSpaceRef, bitmapInfo: u32, provider: CGDataProviderRef, decode: *const CGFloat, shouldInterpolate: bool, intent: i32) -> CGImageRef;
    pub fn CGImageRelease(image: CGImageRef);

    pub fn CGPatternCreate(info: *mut c_void, bounds: CGRect, matrix: CGAffineTransform, xStep: CGFloat, yStep: CGFloat, tiling: i32, isColored: bool, callbacks: *const CGPatternCallbacks) -> CGPatternRef;
    pub fn CGPatternRelease(pattern: CGPatternRef);

    pub fn CGFunctionCreate(info: *mut c_void, domainDimension: usize, domain: *const CGFloat, rangeDimension: usize, range: *const CGFloat, callbacks: *const CGFunctionCallbacks) -> CGFunctionRef;
    pub fn CGFunctionRelease(function: CGFunctionRef);
    pub fn CGShadingCreateAxial(space: CGColorSpaceRef, start: CGPoint, end: CGPoint, function: CGFunctionRef, extendStart: bool, extendEnd: bool) -> CGShadingRef;
    pub fn CGShadingCreateRadial(space: CGColorSpaceRef, start: CGPoint, startRadius: CGFloat, end: CGPoint, endRadius: CGFloat, function: CGFunctionRef, extendStart: bool, extendEnd: bool) -> CGShadingRef;
    pub fn CGShadingRelease(shading: CGShadingRef);
    pub fn CGContextDrawShading(c: CGContextRef, shading: CGShadingRef);

    pub fn CGSoftMaskCreate(info: *mut c_void, background: CGColorRef, transfer: CGFunctionRef, callbacks: *const CGSoftMaskCallbacks, bounds: CGRect, matrix: CGAffineTransform) -> CGSoftMaskRef;
    pub fn CGSoftMaskRelease(mask: CGSoftMaskRef);
    pub fn CGContextSetSoftMask(c: CGContextRef, mask: CGSoftMaskRef);
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    pub fn CFDataCreate(allocator: *const c_void, bytes: *const u8, length: isize) -> CFDataRef;
    pub fn CFRelease(cf: CFTypeRef);
}
