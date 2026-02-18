//! Render - Render PDF pages to bitmaps (library function)

const pdfium = @import("../pdfium/pdfium.zig");

/// Render a page to a BGRA bitmap at the given DPI.
/// Caller must call bitmap.destroy() when done.
pub fn renderPageToBitmap(page: *pdfium.Page, dpi: f64) !pdfium.Bitmap {
    const dims = page.getDimensionsAtDpi(dpi);
    var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
    bitmap.fillWhite();
    page.render(&bitmap, .{});
    return bitmap;
}
