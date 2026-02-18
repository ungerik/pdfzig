//! Delete - Delete pages from PDF (library function)

const pdfium = @import("../pdfium/pdfium.zig");
const shared = @import("shared.zig");

/// Delete pages from first_page to last_page (1-based, inclusive).
/// Pages are deleted in reverse order to avoid index shifting.
/// Returns the number of pages deleted.
pub fn deletePages(
    doc: *pdfium.Document,
    first_page: usize,
    last_page: usize,
) !usize {
    var page_num = last_page;
    while (page_num >= first_page) {
        try doc.deletePage(page_num - 1);
        if (page_num == first_page) break;
        page_num -= 1;
    }
    return last_page - first_page + 1;
}

/// Replace all pages with a single empty page.
/// Preserves the dimensions of the first page.
/// Returns the number of pages that were removed.
pub fn replaceAllPagesWithEmpty(doc: *pdfium.Document) !usize {
    const page_count = doc.getPageCount();

    var first_page_width: f64 = 612;
    var first_page_height: f64 = 792;
    if (page_count > 0) {
        var first_page = try doc.loadPage(0);
        first_page_width = first_page.getWidth();
        first_page_height = first_page.getHeight();
        first_page.close();
    }

    var p = page_count;
    while (p > 0) : (p -= 1) {
        try doc.deletePage(p - 1);
    }

    var new_page = try doc.createPage(0, first_page_width, first_page_height);
    defer new_page.close();
    try shared.generatePageContent(&new_page);

    return page_count;
}
