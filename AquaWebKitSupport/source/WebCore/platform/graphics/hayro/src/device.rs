//! A hayro_interpret `Device` that replays a PDF page as CoreGraphics drawing.
//!
//! The context's user space is the device space hayro interprets the page into: the CTM stays there
//! between calls, and each draw concatenates its own transform inside a saved graphics state.
//! Function-based and mesh shadings, which CoreGraphics has no shading type for, are rasterized at the
//! context's device resolution; everything else reaches the context as paths, shadings, images,
//! patterns and soft masks.

use crate::cg::*;
use crate::DocumentCore;
use hayro_interpret::color::Color;
use hayro_interpret::color::{AlphaColor, ColorSpace};
use hayro_interpret::font::{Glyph, GlyphRun};
use hayro_interpret::kurbo::{self, Affine, BezPath, PathEl, Rect, Shape};
use hayro_interpret::pattern::{Pattern, ShadingPattern, TilingPattern};
use hayro_interpret::shading::{ShadingFunction, ShadingType};
use hayro_interpret::{
    ActiveTransferFunction, BlendMode, ClipPath, Device, DrawMode, FillRule, Image, ImageData, ImageDrawProps,
    LumaData, MaskType, Paint, SoftMask, StrokeProps, TransferFunction,
};
use hayro_interpret::DrawProps;
use std::ffi::c_void;
use std::marker::PhantomData;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;

/// The tolerance, in device pixels, kurbo flattens a stroke outline to.
const STROKE_TOLERANCE: f64 = 0.1;

enum Saved {
    State,
    Layer,
}

pub(crate) struct CgDevice<'a> {
    context: CGContextRef,
    core: Rc<DocumentCore>,
    srgb: CGColorSpaceRef,
    gray: CGColorSpaceRef,
    page: Rect,
    saved: Vec<Saved>,
    _interpretation: PhantomData<&'a ()>,
}

pub(crate) fn cg_transform(transform: Affine) -> CGAffineTransform {
    let [a, b, c, d, tx, ty] = transform.as_coeffs();
    CGAffineTransform { a, b, c, d, tx, ty }
}

fn affine(transform: CGAffineTransform) -> Affine {
    Affine::new([transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty])
}

pub(crate) fn rect(rect: CGRect) -> Rect {
    Rect::new(rect.origin.x, rect.origin.y, rect.origin.x + rect.size.width, rect.origin.y + rect.size.height)
}

fn cg_rect(rect: Rect) -> CGRect {
    CGRect { origin: CGPoint { x: rect.x0, y: rect.y0 }, size: CGSize { width: rect.width(), height: rect.height() } }
}

fn is_empty(rect: Rect) -> bool {
    !(rect.width() > 0.0 && rect.height() > 0.0)
}

// Only finite geometry reaches CoreGraphics.
fn finite_path(path: &BezPath) -> bool {
    path.elements().iter().all(|element| match *element {
        PathEl::MoveTo(p) | PathEl::LineTo(p) => p.is_finite(),
        PathEl::QuadTo(p1, p2) => p1.is_finite() && p2.is_finite(),
        PathEl::CurveTo(p1, p2, p3) => p1.is_finite() && p2.is_finite() && p3.is_finite(),
        PathEl::ClosePath => true,
    })
}

fn blend_mode(mode: BlendMode) -> i32 {
    match mode {
        BlendMode::Normal => 0,
        BlendMode::Multiply => 1,
        BlendMode::Screen => 2,
        BlendMode::Overlay => 3,
        BlendMode::Darken => 4,
        BlendMode::Lighten => 5,
        BlendMode::ColorDodge => 6,
        BlendMode::ColorBurn => 7,
        BlendMode::SoftLight => 8,
        BlendMode::HardLight => 9,
        BlendMode::Difference => 10,
        BlendMode::Exclusion => 11,
        BlendMode::Hue => 12,
        BlendMode::Saturation => 13,
        BlendMode::Color => 14,
        BlendMode::Luminosity => 15,
    }
}

/// Image rows are stored top first; this maps a w x h image rectangle so CGContextDrawImage lands
/// row 0 at y = 0 of the image's own space.
fn flip(height: f64) -> Affine {
    Affine::new([1.0, 0.0, 0.0, -1.0, 0.0, height])
}

/// A CGImage over a copy of `data`: `channels` 8-bit samples per pixel, rows top first.
unsafe fn make_image(data: &[u8], width: u32, height: u32, channels: usize, space: CGColorSpaceRef, alpha_info: u32, interpolate: bool) -> CGImageRef {
    let bytes = CFDataCreate(std::ptr::null(), data.as_ptr(), data.len() as isize);
    if bytes.is_null() {
        return std::ptr::null_mut();
    }
    let provider = CGDataProviderCreateWithCFData(bytes);
    CFRelease(bytes);
    if provider.is_null() {
        return std::ptr::null_mut();
    }
    let image = CGImageCreate(width as usize, height as usize, 8, 8 * channels, width as usize * channels, space, alpha_info, provider, std::ptr::null(), interpolate, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    image
}

/// What a tiling pattern's CGPattern draws its cell from. The pattern borrows the document `core` keeps
/// alive; it is declared first so it drops first.
struct TileCell {
    pattern: TilingPattern<'static>,
    is_stroke: bool,
    core: Rc<DocumentCore>,
}

unsafe extern "C" fn draw_tile(info: *mut c_void, context: CGContextRef) {
    let cell = &*(info as *const TileCell);
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let bbox = cell.pattern.bbox;
        let mut device = CgDevice::new(context, cell.core.clone(), Rect::new(0.0, 0.0, bbox.width(), bbox.height()));
        cell.pattern.interpret(&mut device, Affine::translate((-bbox.x0, -bbox.y0)), cell.is_stroke);
    }));
}

unsafe extern "C" fn release_tile(info: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(info as *mut TileCell))));
}

static TILE_CALLBACKS: CGPatternCallbacks = CGPatternCallbacks {
    version: 0,
    draw_pattern: Some(draw_tile),
    release_info: Some(release_tile),
};

/// What a soft mask's CGSoftMask draws its group from, in the device space of the draw that set it.
struct MaskCell {
    mask: SoftMask<'static>,
    page: Rect,
    core: Rc<DocumentCore>,
}

unsafe extern "C" fn draw_mask(info: *mut c_void, context: CGContextRef) {
    let cell = &*(info as *const MaskCell);
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let mut device = CgDevice::new(context, cell.core.clone(), cell.page);
        cell.mask.interpret(&mut device);
    }));
}

unsafe extern "C" fn release_mask(info: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(info as *mut MaskCell))));
}

static MASK_CALLBACKS: CGSoftMaskCallbacks = CGSoftMaskCallbacks {
    version: 0,
    draw_soft_mask: Some(draw_mask),
    release_info: Some(release_mask),
};

/// A soft mask's transfer function, sampled as hayro samples it: at 256 levels.
unsafe extern "C" fn evaluate_transfer(info: *mut c_void, input: *const CGFloat, output: *mut CGFloat) {
    let transfer = &*(info as *const TransferFunction);
    let value = *input;
    let mut level = [if value.is_finite() { (value.clamp(0.0, 1.0) * 255.0 + 0.5) as u8 } else { 0 }];
    if catch_unwind(AssertUnwindSafe(|| transfer.apply_to(&mut level))).is_err() {
        level[0] = 0;
    }
    *output = level[0] as CGFloat / 255.0;
}

unsafe extern "C" fn release_transfer(info: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(info as *mut TransferFunction))));
}

static TRANSFER_CALLBACKS: CGFunctionCallbacks = CGFunctionCallbacks {
    version: 0,
    evaluate: Some(evaluate_transfer),
    release_info: Some(release_transfer),
};

/// An axial or radial shading's colour at a value of its function's domain, as hayro's own sampling
/// gives it: the function, the colour space's sRGB, the pattern's opacity, then its transfer function.
struct ShadingRamp {
    function: ShadingFunction,
    color_space: ColorSpace,
    opacity: f32,
    transfer: Option<ActiveTransferFunction>,
}

impl ShadingRamp {
    fn color(&self, color: AlphaColor) -> [f32; 4] {
        let mut components = color.components();
        components[3] *= self.opacity;
        match &self.transfer {
            Some(transfer) => transfer.apply(&AlphaColor::new(components)).components(),
            None => components,
        }
    }
}

unsafe extern "C" fn evaluate_ramp(info: *mut c_void, input: *const CGFloat, output: *mut CGFloat) {
    let output = std::slice::from_raw_parts_mut(output, 4);
    output.fill(0.0);
    let ramp = &*(info as *const ShadingRamp);
    let t = *input as f32;
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let mut values = [0.0f32; 32];
        let values = &mut values[..ramp.function.num_outputs().min(32)];
        if ramp.function.eval(&[t], values).is_some() {
            for (out, component) in output.iter_mut().zip(ramp.color(ramp.color_space.to_rgba(values, 1.0))) {
                *out = if component.is_finite() { component as CGFloat } else { 0.0 };
            }
        }
    }));
}

unsafe extern "C" fn release_ramp(info: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(info as *mut ShadingRamp))));
}

static RAMP_CALLBACKS: CGFunctionCallbacks = CGFunctionCallbacks {
    version: 0,
    evaluate: Some(evaluate_ramp),
    release_info: Some(release_ramp),
};

impl<'a> CgDevice<'a> {
    pub(crate) fn new(context: CGContextRef, core: Rc<DocumentCore>, page: Rect) -> Self {
        unsafe {
            Self {
                context,
                core,
                srgb: CGColorSpaceCreateWithName(kCGColorSpaceSRGB),
                gray: CGColorSpaceCreateDeviceGray(),
                page,
                saved: Vec::new(),
                _interpretation: PhantomData,
            }
        }
    }

    fn save(&mut self) {
        unsafe { CGContextSaveGState(self.context) };
        self.saved.push(Saved::State);
    }

    fn restore(&mut self) {
        match self.saved.pop() {
            Some(Saved::State) => unsafe { CGContextRestoreGState(self.context) },
            Some(Saved::Layer) => unsafe {
                CGContextEndTransparencyLayer(self.context);
                CGContextRestoreGState(self.context);
            },
            None => {}
        }
    }

    fn concat(&self, transform: Affine) {
        unsafe { CGContextConcatCTM(self.context, cg_transform(transform)) };
    }

    /// Clips everything out: what follows in the current state draws nothing.
    fn clip_out(&self) {
        unsafe { CGContextClipToRect(self.context, cg_rect(Rect::ZERO)) };
    }

    fn ctm(&self) -> Affine {
        affine(unsafe { CGContextGetCTM(self.context) })
    }

    fn clip_box(&self) -> Rect {
        rect(unsafe { CGContextGetClipBoundingBox(self.context) })
    }

    fn device_scale(&self, transform: Affine) -> f64 {
        (self.ctm() * transform).determinant().abs().sqrt()
    }

    fn add_path(&self, path: &BezPath) {
        let c = self.context;
        unsafe {
            CGContextBeginPath(c);
            for element in path.elements() {
                match *element {
                    PathEl::MoveTo(p) => CGContextMoveToPoint(c, p.x, p.y),
                    PathEl::LineTo(p) => CGContextAddLineToPoint(c, p.x, p.y),
                    PathEl::QuadTo(p1, p2) => CGContextAddQuadCurveToPoint(c, p1.x, p1.y, p2.x, p2.y),
                    PathEl::CurveTo(p1, p2, p3) => CGContextAddCurveToPoint(c, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y),
                    PathEl::ClosePath => CGContextClosePath(c),
                }
            }
        }
    }

    /// Clips to `path`, given in the current user space; an empty path leaves nothing visible.
    fn clip_to_path(&self, path: &BezPath, rule: FillRule) {
        if path.elements().is_empty() {
            self.clip_out();
            return;
        }
        self.add_path(path);
        self.clip_current_path(rule);
    }

    fn clip_current_path(&self, rule: FillRule) {
        unsafe {
            match rule {
                FillRule::NonZero => CGContextClip(self.context),
                FillRule::EvenOdd => CGContextEOClip(self.context),
            }
        }
    }

    fn color(&self, color: &Color) -> CGColorRef {
        let components = color.to_rgba().components().map(|c| if c.is_finite() { c as f64 } else { 0.0 });
        unsafe { CGColorCreate(self.srgb, components.as_ptr()) }
    }

    fn apply_stroke(&self, stroke: &StrokeProps) {
        let c = self.context;
        unsafe {
            CGContextSetLineWidth(c, stroke.line_width as f64);
            CGContextSetLineCap(c, match stroke.line_cap {
                kurbo::Cap::Butt => kCGLineCapButt,
                kurbo::Cap::Round => kCGLineCapRound,
                kurbo::Cap::Square => kCGLineCapSquare,
            });
            CGContextSetLineJoin(c, match stroke.line_join {
                kurbo::Join::Miter => kCGLineJoinMiter,
                kurbo::Join::Round => kCGLineJoinRound,
                kurbo::Join::Bevel => kCGLineJoinBevel,
            });
            CGContextSetMiterLimit(c, stroke.miter_limit as f64);
            let dashes: Vec<f64> = stroke.dash_array.iter().map(|d| *d as f64).collect();
            if dashes.is_empty() {
                CGContextSetLineDash(c, 0.0, std::ptr::null(), 0);
            } else {
                CGContextSetLineDash(c, stroke.dash_offset as f64, dashes.as_ptr(), dashes.len());
            }
        }
    }

    fn kurbo_stroke(stroke: &StrokeProps) -> kurbo::Stroke {
        kurbo::Stroke::new(stroke.line_width as f64)
            .with_caps(stroke.line_cap)
            .with_join(stroke.line_join)
            .with_miter_limit(stroke.miter_limit as f64)
            .with_dashes(stroke.dash_offset as f64, stroke.dash_array.iter().map(|d| *d as f64))
    }

    /// Runs `draw` inside a transparency group when a soft mask or a blend mode applies to it.
    fn with_group(&mut self, mask: Option<&SoftMask<'a>>, mode: BlendMode, draw: impl FnOnce(&mut Self)) {
        let grouped = mask.is_some() || mode != BlendMode::Normal;
        if grouped {
            self.push_group(1.0, mask, mode);
        }
        draw(self);
        if grouped {
            self.restore();
        }
    }

    fn push_group(&mut self, opacity: f32, mask: Option<&SoftMask<'a>>, mode: BlendMode) {
        unsafe { CGContextSaveGState(self.context) };
        if let Some(mask) = mask {
            self.set_soft_mask(mask);
        }
        unsafe {
            CGContextSetAlpha(self.context, if opacity.is_finite() { opacity as f64 } else { 0.0 });
            CGContextSetBlendMode(self.context, blend_mode(mode));
            CGContextBeginTransparencyLayer(self.context, std::ptr::null());
        }
        self.saved.push(Saved::Layer);
    }

    fn paint_path(&mut self, path: &BezPath, paint: &Paint<'a>, transform: Affine, mode: &DrawMode) {
        match mode {
            DrawMode::Fill(rule) => self.fill(path, paint, transform, *rule),
            DrawMode::Stroke(stroke) => self.stroke(path, paint, transform, stroke),
            DrawMode::FillAndStroke(rule, stroke) => {
                self.fill(path, paint, transform, *rule);
                self.stroke(path, paint, transform, stroke);
            }
            DrawMode::Invisible => {}
        }
    }

    fn fill(&mut self, path: &BezPath, paint: &Paint<'a>, transform: Affine, rule: FillRule) {
        match paint {
            Paint::Color(color) => {
                if !transform.is_finite() || !finite_path(path) {
                    return;
                }
                self.save();
                self.concat(transform);
                let color = self.color(color);
                unsafe {
                    CGContextSetFillColorWithColor(self.context, color);
                    CGColorRelease(color);
                }
                self.add_path(path);
                unsafe {
                    match rule {
                        FillRule::NonZero => CGContextFillPath(self.context),
                        FillRule::EvenOdd => CGContextEOFillPath(self.context),
                    }
                }
                self.restore();
            }
            Paint::Pattern(pattern) => {
                let region = transform * path.clone();
                if finite_path(&region) {
                    self.fill_with_pattern(&region, rule, pattern, false);
                }
            }
        }
    }

    fn stroke(&mut self, path: &BezPath, paint: &Paint<'a>, transform: Affine, stroke: &StrokeProps) {
        match paint {
            Paint::Color(color) => {
                if !transform.is_finite() || !finite_path(path) || !stroke.line_width.is_finite() || !stroke.miter_limit.is_finite()
                    || !stroke.dash_offset.is_finite() || !stroke.dash_array.iter().all(|d| d.is_finite()) {
                    return;
                }
                self.save();
                self.concat(transform);
                self.apply_stroke(stroke);
                let color = self.color(color);
                unsafe {
                    CGContextSetStrokeColorWithColor(self.context, color);
                    CGColorRelease(color);
                }
                self.add_path(path);
                unsafe { CGContextStrokePath(self.context) };
                self.restore();
            }
            Paint::Pattern(pattern) => {
                let tolerance = STROKE_TOLERANCE / self.device_scale(transform).max(f64::EPSILON);
                if !transform.is_finite() || !finite_path(path) || !tolerance.is_finite() {
                    return;
                }
                let outline = kurbo::stroke(path.iter(), &Self::kurbo_stroke(stroke), &kurbo::StrokeOpts::default(), tolerance);
                let region = transform * outline;
                if finite_path(&region) {
                    self.fill_with_pattern(&region, FillRule::NonZero, pattern, true);
                }
            }
        }
    }

    /// Fills `region`, given in the device space, with a pattern.
    fn fill_with_pattern(&mut self, region: &BezPath, rule: FillRule, pattern: &Pattern<'a>, is_stroke: bool) {
        self.save();
        self.clip_to_path(region, rule);
        match pattern {
            Pattern::Shading(shading) => self.draw_shading(shading, region.bounding_box()),
            Pattern::Tiling(tiling) => self.draw_tiling(tiling, is_stroke),
        }
        self.restore();
    }

    fn draw_shading(&mut self, pattern: &ShadingPattern, region: Rect) {
        let shading = &pattern.shading;
        if let Some(clip) = &shading.clip_path {
            if !finite_path(clip) {
                return;
            }
            self.clip_to_path(clip, FillRule::NonZero);
        }
        let bbox = self.clip_box().intersect(region);
        if is_empty(bbox) || !bbox.is_finite() {
            return;
        }
        let ShadingType::RadialAxial { coords, domain, function, extend, axial } = shading.shading_type.as_ref() else {
            let scale = self.device_scale(Affine::IDENTITY);
            if !scale.is_finite() {
                return;
            }
            let texture = pattern.encode().render_texture(bbox, scale as f32);
            self.draw_rgba(&texture.data, texture.width, texture.height, kCGImageAlphaLast, texture.transform, true);
            return;
        };
        if !pattern.matrix.is_finite() || !coords.iter().chain(domain.iter()).all(|v| v.is_finite()) {
            return;
        }
        let ramp = ShadingRamp {
            function: function.clone(),
            color_space: shading.color_space.clone(),
            opacity: if pattern.opacity.is_finite() { pattern.opacity } else { 0.0 },
            transfer: pattern.transfer_function.clone(),
        };
        // The background shows wherever the shading does not reach, under it rather than through it, so
        // the two composite opaquely in a layer that the pattern's opacity then applies to.
        let background = shading.background.as_ref().map(|b| shading.color_space.to_rgba(b, 1.0));
        if background.is_some() {
            unsafe { CGContextSaveGState(self.context) };
            unsafe {
                CGContextSetAlpha(self.context, ramp.opacity as f64);
                CGContextBeginTransparencyLayer(self.context, std::ptr::null());
            }
            self.saved.push(Saved::Layer);
        }
        let ramp = ShadingRamp { opacity: if background.is_some() { 1.0 } else { ramp.opacity }, ..ramp };
        if let Some(background) = background {
            let [r, g, b, a] = ramp.color(background);
            let components = [r, g, b, a].map(|c| if c.is_finite() { c as f64 } else { 0.0 });
            unsafe {
                let color = CGColorCreate(self.srgb, components.as_ptr());
                CGContextSetFillColorWithColor(self.context, color);
                CGColorRelease(color);
                CGContextFillRect(self.context, cg_rect(bbox));
            }
        }
        let domain_values = [domain[0] as f64, domain[1] as f64];
        let range = [0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0];
        unsafe {
            let cg_function = CGFunctionCreate(Box::into_raw(Box::new(ramp)) as *mut c_void, 1, domain_values.as_ptr(), 4, range.as_ptr(), &RAMP_CALLBACKS);
            let [x0, y0, a, b, c, d] = coords.map(|v| v as f64);
            let cg_shading = if *axial {
                CGShadingCreateAxial(self.srgb, CGPoint { x: x0, y: y0 }, CGPoint { x: a, y: b }, cg_function, extend[0], extend[1])
            } else {
                CGShadingCreateRadial(self.srgb, CGPoint { x: x0, y: y0 }, a, CGPoint { x: b, y: c }, d, cg_function, extend[0], extend[1])
            };
            self.save();
            self.concat(pattern.matrix);
            CGContextDrawShading(self.context, cg_shading);
            self.restore();
            CGShadingRelease(cg_shading);
            CGFunctionRelease(cg_function);
        }
        if background.is_some() {
            self.restore();
        }
    }

    fn draw_tiling(&mut self, tiling: &TilingPattern<'a>, is_stroke: bool) {
        let bbox = tiling.bbox;
        // CGPatternCreate's matrix maps the pattern space to the context's base space.
        let base = affine(unsafe { CGContextGetBaseCTM(self.context) });
        let pattern_to_base = base.inverse() * self.ctm() * tiling.matrix * Affine::translate((bbox.x0, bbox.y0));
        if is_empty(bbox) || !bbox.is_finite() || !pattern_to_base.is_finite() || !tiling.x_step.is_finite() || !tiling.y_step.is_finite() {
            return;
        }
        // SAFETY: the cell keeps the document it borrows from alive (TileCell::core), so the borrow
        // outlives every use CoreGraphics makes of the pattern.
        let pattern: TilingPattern<'static> = unsafe { std::mem::transmute(tiling.clone()) };
        let cell = Box::new(TileCell { pattern, is_stroke, core: self.core.clone() });
        let matrix = cg_transform(pattern_to_base);
        let bounds = CGRect { origin: CGPoint { x: 0.0, y: 0.0 }, size: CGSize { width: bbox.width(), height: bbox.height() } };
        unsafe {
            let cg_pattern = CGPatternCreate(Box::into_raw(cell) as *mut c_void, bounds, matrix, tiling.x_step.abs() as f64, tiling.y_step.abs() as f64, kCGPatternTilingConstantSpacing, true, &TILE_CALLBACKS);
            let space = CGColorSpaceCreatePattern(std::ptr::null_mut());
            let alpha = [tiling.opacity as f64];
            CGContextSetFillColorSpace(self.context, space);
            CGContextSetFillPattern(self.context, cg_pattern, alpha.as_ptr());
            CGContextFillRect(self.context, CGContextGetClipBoundingBox(self.context));
            CGColorSpaceRelease(space);
            CGPatternRelease(cg_pattern);
        }
    }

    /// Draws `width` x `height` RGBA pixels (rows top first) whose pixel space `transform` maps to the device space.
    fn draw_rgba(&mut self, data: &[u8], width: u32, height: u32, alpha_info: u32, transform: Affine, interpolate: bool) {
        if width == 0 || height == 0 || !transform.is_finite() {
            return;
        }
        unsafe {
            let image = make_image(data, width, height, 4, self.srgb, alpha_info, interpolate);
            if image.is_null() {
                return;
            }
            self.save();
            self.concat(transform * flip(height as f64));
            CGContextDrawImage(self.context, cg_rect(Rect::new(0.0, 0.0, width as f64, height as f64)), image);
            self.restore();
            CGImageRelease(image);
        }
    }

    /// Clips to `mask`, a `width` x `height` coverage image whose pixel space `transform` maps to the device space.
    fn clip_to_coverage(&self, mask: &[u8], width: u32, height: u32, transform: Affine, interpolate: bool) {
        unsafe {
            let image = make_image(mask, width, height, 1, self.gray, kCGImageAlphaNone, interpolate);
            let placement = transform * flip(height as f64);
            if image.is_null() || !placement.is_finite() || placement.determinant() == 0.0 {
                self.clip_out();
                if !image.is_null() {
                    CGImageRelease(image);
                }
                return;
            }
            self.concat(placement);
            CGContextClipToMask(self.context, cg_rect(Rect::new(0.0, 0.0, width as f64, height as f64)), image);
            self.concat(placement.inverse());
            CGImageRelease(image);
        }
    }

    fn draw_raster(&mut self, data: ImageData, alpha: Option<LumaData>, transform: Affine) {
        let (width, height, interpolate, pixels): (u32, u32, bool, Vec<[u8; 3]>) = match data {
            ImageData::Rgb(rgb) => (rgb.width, rgb.height, rgb.interpolate, rgb.data.chunks_exact(3).map(|p| [p[0], p[1], p[2]]).collect()),
            ImageData::Luma(luma) => (luma.width, luma.height, luma.interpolate, luma.data.iter().map(|g| [*g, *g, *g]).collect()),
        };
        let matching_alpha = alpha.as_ref().is_some_and(|a| a.width == width && a.height == height);
        let mut rgba = Vec::with_capacity(pixels.len() * 4);
        for (index, pixel) in pixels.iter().enumerate() {
            rgba.extend_from_slice(pixel);
            rgba.push(if matching_alpha { alpha.as_ref().unwrap().data[index] } else { 255 });
        }
        match alpha {
            Some(alpha) if !matching_alpha => {
                self.save();
                let alpha_transform = transform * Affine::scale_non_uniform(width as f64 / alpha.width as f64, height as f64 / alpha.height as f64);
                self.clip_to_coverage(&alpha.data, alpha.width, alpha.height, alpha_transform, alpha.interpolate);
                self.draw_rgba(&rgba, width, height, kCGImageAlphaLast, transform, interpolate);
                self.restore();
            }
            _ => self.draw_rgba(&rgba, width, height, kCGImageAlphaLast, transform, interpolate),
        }
    }

    fn draw_stencil(&mut self, stencil: &LumaData, paint: &Paint<'a>, transform: Affine) {
        self.save();
        self.clip_to_coverage(&stencil.data, stencil.width, stencil.height, transform, stencil.interpolate);
        let cell = Rect::new(0.0, 0.0, stencil.width as f64, stencil.height as f64).to_path(0.1);
        self.fill(&cell, paint, transform, FillRule::NonZero);
        self.restore();
    }

    /// Sets `mask` as the graphics state's soft mask. Its group draws in this draw's device space, which
    /// the mask's matrix maps to the context's device space, as CGPDF composes it.
    fn set_soft_mask(&self, mask: &SoftMask<'a>) {
        let matrix = self.ctm();
        // SAFETY: the cell keeps the document the mask borrows from alive (MaskCell::core), so the borrow
        // outlives every use CoreGraphics makes of the mask.
        let mask_static: SoftMask<'static> = unsafe { std::mem::transmute(mask.clone()) };
        let cell = Box::new(MaskCell { mask: mask_static, page: self.page, core: self.core.clone() });
        unsafe {
            let background = match mask.mask_type() {
                MaskType::Luminosity => self.color(&mask.background_color()),
                MaskType::Alpha => std::ptr::null_mut(),
            };
            let unit = [0.0, 1.0];
            let transfer = match mask.transfer_function() {
                Some(transfer) => CGFunctionCreate(Box::into_raw(Box::new(transfer.clone())) as *mut c_void, 1, unit.as_ptr(), 1, unit.as_ptr(), &TRANSFER_CALLBACKS),
                None => std::ptr::null_mut(),
            };
            let soft_mask = CGSoftMaskCreate(Box::into_raw(cell) as *mut c_void, background, transfer, &MASK_CALLBACKS, cg_rect(self.page), cg_transform(matrix));
            CGContextSetSoftMask(self.context, soft_mask);
            CGSoftMaskRelease(soft_mask);
            if !transfer.is_null() {
                CGFunctionRelease(transfer);
            }
            if !background.is_null() {
                CGColorRelease(background);
            }
        }
    }
}

impl Drop for CgDevice<'_> {
    fn drop(&mut self) {
        while !self.saved.is_empty() {
            self.restore();
        }
        unsafe {
            CGColorSpaceRelease(self.srgb);
            CGColorSpaceRelease(self.gray);
        }
    }
}

impl<'a> Device<'a> for CgDevice<'a> {
    fn draw_path(&mut self, path: &BezPath, props: DrawProps<'a>, draw_mode: &DrawMode) {
        self.with_group(props.soft_mask.as_ref(), props.blend_mode, |device| {
            device.paint_path(path, &props.paint, props.transform, draw_mode);
        });
    }

    fn push_clip_path(&mut self, clip_path: &ClipPath) {
        self.save();
        if finite_path(&clip_path.path) {
            self.clip_to_path(&clip_path.path, clip_path.fill);
        } else {
            self.clip_out();
        }
    }

    fn push_clip_rect(&mut self, clip_rect: &Rect) {
        self.save();
        if clip_rect.is_finite() {
            unsafe { CGContextClipToRect(self.context, cg_rect(*clip_rect)) };
        } else {
            self.clip_out();
        }
    }

    fn push_transparency_group(&mut self, opacity: f32, mask: Option<SoftMask<'a>>, blend_mode: BlendMode) {
        self.push_group(opacity, mask.as_ref(), blend_mode);
    }

    fn draw_glyph_run(&mut self, glyph_run: &GlyphRun<'_, 'a>, props: DrawProps<'a>, draw_mode: &DrawMode) {
        self.with_group(props.soft_mask.as_ref(), props.blend_mode, |device| {
            for positioned in glyph_run.glyphs() {
                let glyph_transform = positioned.transform();
                let glyph: &Glyph<'a> = positioned;
                match glyph {
                    Glyph::Outline(outline) => {
                        let path = outline.outline();
                        match draw_mode {
                            DrawMode::Fill(_) => device.paint_path(&path, &props.paint, props.transform * glyph_transform, draw_mode),
                            DrawMode::Stroke(_) | DrawMode::FillAndStroke(_, _) => device.paint_path(&(glyph_transform * path), &props.paint, props.transform, draw_mode),
                            DrawMode::Invisible => {}
                        }
                    }
                    Glyph::Type3(type3) => type3.interpret(device, props.transform, glyph_transform, &props.paint),
                }
            }
        });
    }

    fn draw_image(&mut self, image: Image<'a, '_>, props: ImageDrawProps<'a>) {
        self.with_group(props.soft_mask.as_ref(), props.blend_mode, |device| match image {
            Image::Stencil(stencil) => stencil.with_stencil(
                |luma, paint| {
                    let transform = props.transform * Affine::scale_non_uniform(luma.scale_factors.0 as f64, luma.scale_factors.1 as f64);
                    device.draw_stencil(&luma, paint, transform);
                },
                None,
            ),
            Image::Raster(raster) => raster.with_rgba(
                |data, alpha| {
                    let (sx, sy) = data.scale_factors();
                    let transform = props.transform * Affine::scale_non_uniform(sx as f64, sy as f64);
                    device.draw_raster(data, alpha, transform);
                },
                None,
            ),
        });
    }

    fn pop_clip(&mut self) {
        self.restore();
    }

    fn pop_transparency_group(&mut self) {
        self.restore();
    }
}
