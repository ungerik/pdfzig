//! Rotate - Rotate PDF pages (library function)

const pdfium = @import("../pdfium/pdfium.zig");
const shared = @import("shared.zig");

/// Rotate pages in a PDF document.
/// rotation must be a multiple of 90 degrees.
/// first_page and last_page are 1-based, inclusive.
/// Returns the number of pages rotated.
pub fn rotatePages(
    doc: *pdfium.Document,
    rotation: i32,
    first_page: usize,
    last_page: usize,
) !usize {
    if (@mod(rotation, 90) != 0) {
        return error.InvalidRotation;
    }

    var count: usize = 0;
    var page_num = first_page;
    while (page_num <= last_page) : (page_num += 1) {
        var page = try shared.loadPage(doc, page_num);
        defer page.close();

        if (!page.rotate(rotation)) {
            return error.InvalidRotation;
        }

        try shared.generatePageContent(&page);
        count += 1;
    }

    return count;
}
