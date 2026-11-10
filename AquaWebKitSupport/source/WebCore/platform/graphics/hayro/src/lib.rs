//! wk_pdf: the C interface WebCore's PDFDocumentImage draws PDF images through (wk_pdf.h). hayro parses
//! the document and interprets its first page; `device::CgDevice` replays the page as CoreGraphics
//! drawing in the context WebCore passes. Every entry point stops a panic at the boundary and reports
//! failure instead.

mod cg;
mod device;

use device::{rect, CgDevice};
use hayro_interpret::hayro_syntax::page::{Page, Rotation};
use hayro_interpret::hayro_syntax::Pdf;
use hayro_interpret::kurbo::{Affine, Rect};
use hayro_interpret::{interpret_page, Context, InterpreterCache, InterpreterSettings, RectExt};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;

/// A parsed document and the interpreter cache its pages draw through. The cache holds data borrowed
/// from `pdf`; it is declared first so it drops first, and `pdf` is boxed so that data stays put.
pub(crate) struct DocumentCore {
    cache: InterpreterCache<'static>,
    pdf: Box<Pdf>,
}

pub struct WKPDFDocument {
    core: Rc<DocumentCore>,
}

#[repr(C)]
pub struct WKPDFPageBounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    rotation: i32,
}

fn guarded<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// The page's crop box (intersected with its media box), or its media box where that is empty, and
/// its /Rotate in degrees.
fn page_box(page: &Page<'_>) -> (Rect, i32) {
    let crop_box = page.intersected_crop_box().to_kurbo();
    let page_box = if crop_box.width() > 0.0 && crop_box.height() > 0.0 { crop_box } else { page.media_box().to_kurbo() };
    let rotation = match page.rotation() {
        Rotation::None => 0,
        Rotation::Horizontal => 90,
        Rotation::Flipped => 180,
        Rotation::FlippedHorizontal => 270,
    };
    (page_box, rotation)
}

/// The transform from PDF user space to the page as displayed -- `page_box` at the origin, turned
/// clockwise by `rotation`, y up -- and the displayed width and height.
fn page_placement(page_box: Rect, rotation: i32) -> (Affine, f64, f64) {
    let (width, height) = (page_box.width(), page_box.height());
    let local = Affine::translate((-page_box.x0, -page_box.y0));
    match rotation {
        90 => (Affine::new([0.0, -1.0, 1.0, 0.0, 0.0, width]) * local, height, width),
        180 => (Affine::new([-1.0, 0.0, 0.0, -1.0, width, height]) * local, width, height),
        270 => (Affine::new([0.0, 1.0, -1.0, 0.0, height, 0.0]) * local, height, width),
        _ => (local, width, height),
    }
}

/// # Safety
/// `data` points to `length` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn wk_pdf_document_create(data: *const u8, length: usize) -> *mut WKPDFDocument {
    if data.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = std::slice::from_raw_parts(data, length).to_vec();
    guarded(std::ptr::null_mut(), || match Pdf::new(bytes) {
        Ok(pdf) => Box::into_raw(Box::new(WKPDFDocument {
            core: Rc::new(DocumentCore { cache: InterpreterCache::new(), pdf: Box::new(pdf) }),
        })),
        Err(_) => std::ptr::null_mut(),
    })
}

/// # Safety
/// `document` is NULL or came from `wk_pdf_document_create` and is not used again.
#[no_mangle]
pub unsafe extern "C" fn wk_pdf_document_destroy(document: *mut WKPDFDocument) {
    if !document.is_null() {
        guarded((), || drop(Box::from_raw(document)));
    }
}

/// # Safety
/// `document` is NULL or a live document.
#[no_mangle]
pub unsafe extern "C" fn wk_pdf_document_page_count(document: *const WKPDFDocument) -> usize {
    match document.as_ref() {
        Some(document) => guarded(0, || document.core.pdf.pages().len()),
        None => 0,
    }
}

/// # Safety
/// `document` is NULL or a live document; `bounds` is NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn wk_pdf_document_first_page_bounds(document: *const WKPDFDocument, bounds: *mut WKPDFPageBounds) -> bool {
    let (Some(document), Some(bounds)) = (document.as_ref(), bounds.as_mut()) else {
        return false;
    };
    guarded(false, || {
        let Some(page) = document.core.pdf.pages().first() else {
            return false;
        };
        let (page_box, rotation) = page_box(page);
        *bounds = WKPDFPageBounds { x: page_box.x0, y: page_box.y0, width: page_box.width(), height: page_box.height(), rotation };
        true
    })
}

fn draw_first_page(core: &Rc<DocumentCore>, context: cg::CGContextRef) -> bool {
    let Some(page) = core.pdf.pages().first() else {
        return false;
    };
    let (page_box, rotation) = page_box(page);
    let (placement, width, height) = page_placement(page_box, rotation);
    let page_rect = Rect::new(0.0, 0.0, width, height);
    let visible = rect(unsafe { cg::CGContextGetClipBoundingBox(context) }).intersect(page_rect);
    if !(visible.width() > 0.0 && visible.height() > 0.0) {
        return true;
    }
    // SAFETY: the cache only ever holds data borrowed from `core.pdf`, which outlives it (see DocumentCore).
    let cache: &InterpreterCache<'_> = unsafe { &*(&core.cache as *const InterpreterCache<'static> as *const InterpreterCache<'_>) };
    let mut state = Context::new(placement, visible, cache, page.xref(), InterpreterSettings::default());
    unsafe { cg::CGContextClipToRect(context, cg::CGRect { origin: cg::CGPoint { x: 0.0, y: 0.0 }, size: cg::CGSize { width, height } }) };
    let mut device = CgDevice::new(context, core.clone(), page_rect);
    interpret_page(page, &mut state, &mut device);
    true
}

/// # Safety
/// `document` is NULL or a live document; `context` is NULL or a CGContextRef whose user space is the
/// first page as displayed: its rotated crop box at the origin, y up, one unit per point.
#[no_mangle]
pub unsafe extern "C" fn wk_pdf_document_draw_first_page(document: *const WKPDFDocument, context: *mut c_void) -> bool {
    let Some(document) = document.as_ref() else {
        return false;
    };
    if context.is_null() {
        return false;
    }
    cg::CGContextSaveGState(context);
    let drawn = guarded(false, || draw_first_page(&document.core, context));
    cg::CGContextRestoreGState(context);
    drawn
}
