//! Shared library utilities for PDF operations
//! Pure library functions — no process.exit, no stdout/stderr

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const textfmt = @import("../pdfcontent/textfmt.zig");
const images = @import("../pdfcontent/images.zig");

/// Open a PDF document with optional password
pub fn openDocument(
    allocator: std.mem.Allocator,
    path: []const u8,
    password: ?[]const u8,
) !pdfium.Document {
    if (password) |pwd| {
        return pdfium.Document.openWithPassword(allocator, path, pwd);
    } else {
        return pdfium.Document.open(allocator, path);
    }
}

/// Load a page from a document (1-based page number)
pub fn loadPage(doc: *pdfium.Document, page_num: usize) !pdfium.Page {
    return doc.loadPage(page_num - 1);
}

/// Create output directory
pub fn createDirectory(dir_path: []const u8) !void {
    try std.fs.cwd().makePath(dir_path);
}

/// Generate page content (finalize transformations)
pub fn generatePageContent(page: *pdfium.Page) !void {
    if (!page.generateContent()) {
        return error.GenerateContentFailed;
    }
}

/// Get the lowercase file extension from a path, using a stack buffer.
/// Returns the lowered extension slice (e.g., ".pdf", ".json").
pub fn extensionLower(path: []const u8, buf: *[16]u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const len = @min(ext.len, buf.len);
    for (ext[0..len], 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..len];
}

/// Check if a filename has an XML-related extension (case-insensitive).
pub fn hasXmlExtension(name: []const u8) bool {
    var ext_buf: [16]u8 = undefined;
    const ext = extensionLower(name, &ext_buf);
    return std.mem.eql(u8, ext, ".xml") or
        std.mem.eql(u8, ext, ".xmp") or
        std.mem.eql(u8, ext, ".xsd") or
        std.mem.eql(u8, ext, ".xsl") or
        std.mem.eql(u8, ext, ".xslt");
}

/// Add content (image, text, or JSON) to a page based on file extension.
/// Detects file type by extension (case-insensitive) and calls the appropriate
/// content function.
pub fn addFileContentToPage(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    content_path: []const u8,
    page_width: f64,
    page_height: f64,
) !void {
    var ext_buf: [16]u8 = undefined;
    const ext_lower = extensionLower(content_path, &ext_buf);

    if (std.mem.eql(u8, ext_lower, ".json")) {
        try textfmt.addJsonToPage(allocator, doc, page, content_path);
    } else if (std.mem.eql(u8, ext_lower, ".txt") or std.mem.eql(u8, ext_lower, ".text")) {
        try textfmt.addTextToPage(allocator, doc, page, content_path, page_width, page_height);
    } else {
        try images.addImageToPage(allocator, doc, page, content_path, page_width, page_height);
    }
}
