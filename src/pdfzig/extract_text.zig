//! Extract Text - Extract text content from PDF pages (library function)

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");

pub const ExtractResult = struct {
    pages_extracted: usize,
    pages_skipped: usize,
};

/// Extract text content from PDF pages and write to the given writer.
/// first_page and last_page are 1-based, inclusive.
/// Returns counts of pages successfully extracted and pages skipped due to errors.
pub fn extractText(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    writer: *std.Io.Writer,
    first_page: usize,
    last_page: usize,
) !ExtractResult {
    var result = ExtractResult{ .pages_extracted = 0, .pages_skipped = 0 };

    var page_num = first_page;
    while (page_num <= last_page) : (page_num += 1) {
        var page = doc.loadPage(page_num - 1) catch {
            result.pages_skipped += 1;
            continue;
        };
        defer page.close();

        var text_page = page.loadTextPage() orelse {
            result.pages_skipped += 1;
            continue;
        };
        defer text_page.close();

        if (text_page.getText(allocator)) |text| {
            defer allocator.free(text);
            try writer.writeAll(text);
            try writer.writeAll("\n");
            result.pages_extracted += 1;
        } else {
            result.pages_skipped += 1;
        }
    }

    return result;
}
