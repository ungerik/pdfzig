//! Mirror - Mirror PDF pages horizontally or vertically (library function)

const pdfium = @import("../pdfium/pdfium.zig");
const shared = @import("shared.zig");

/// Mirror pages in a PDF document.
/// first_page and last_page are 1-based, inclusive.
/// Returns the number of pages mirrored.
pub fn mirrorPages(
    doc: *pdfium.Document,
    leftright: bool,
    updown: bool,
    first_page: usize,
    last_page: usize,
) !usize {
    var count: usize = 0;
    var page_num = first_page;
    while (page_num <= last_page) : (page_num += 1) {
        var page = try shared.loadPage(doc, page_num);
        defer page.close();

        const page_width = page.getWidth();
        const page_height = page.getHeight();

        const obj_count = page.getObjectCount();
        var obj_idx: u32 = 0;
        while (obj_idx < obj_count) : (obj_idx += 1) {
            if (page.getObject(obj_idx)) |obj| {
                if (leftright) {
                    obj.transform(-1, 0, 0, 1, page_width, 0);
                }
                if (updown) {
                    obj.transform(1, 0, 0, -1, 0, page_height);
                }
            }
        }

        try shared.generatePageContent(&page);
        count += 1;
    }

    return count;
}
