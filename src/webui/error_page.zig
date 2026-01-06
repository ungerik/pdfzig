//! Error page PDF generation
//!
//! This module provides functions to generate PDF documents and PNG images
//! containing error messages for display in the WebUI when document loading
//! or rendering fails.
//!
//! # Features
//! - Creates single-page PDFs with centered error text
//! - Renders error pages to PNG images at any DPI
//! - Supports multiple page sizes (Letter, A4, Square)
//! - Uses large, bold, red text for visibility
//!
//! # Example Usage
//!
//! ```zig
//! const allocator = std.heap.page_allocator;
//!
//! // Create an error PDF
//! var doc = try pdfErrorPage(
//!     allocator,
//!     "Error: File Not Found",
//!     PageSize.letter,
//! );
//! defer doc.close();
//! try doc.save("/tmp/error.pdf");
//!
//! // Create an error PNG
//! const png_bytes = try pdfErrorPagePNG(
//!     allocator,
//!     "Error: Invalid PDF",
//!     PageSize.a4,
//!     150.0, // 150 DPI
//! );
//! defer allocator.free(png_bytes);
//! ```

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");

/// Page size for error pages
pub const PageSize = struct {
    width: f64,
    height: f64,

    /// US Letter size (8.5" x 11")
    pub const letter = PageSize{ .width = 612, .height = 792 };

    /// A4 size (210mm x 297mm)
    pub const a4 = PageSize{ .width = 595, .height = 842 };

    /// Square page for thumbnails
    pub const square = PageSize{ .width = 600, .height = 600 };
};

/// Convert UTF-8 text to null-terminated UTF-16LE for PDFium
fn encodeUtf8ToUtf16(allocator: std.mem.Allocator, text: []const u8) !std.array_list.Managed(u16) {
    var utf16_buf = std.array_list.Managed(u16).init(allocator);
    errdefer utf16_buf.deinit();

    var utf8_view = std.unicode.Utf8View.init(text) catch {
        // If not valid UTF-8, fall back to Latin-1
        for (text) |byte| {
            try utf16_buf.append(@as(u16, byte));
        }
        try utf16_buf.append(0); // Null terminator
        return utf16_buf;
    };

    var it = utf8_view.iterator();
    while (it.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xFFFF) {
            try utf16_buf.append(@intCast(codepoint));
        } else {
            // Surrogate pair for codepoints > 0xFFFF
            const cp = codepoint - 0x10000;
            try utf16_buf.append(@intCast(0xD800 + (cp >> 10)));
            try utf16_buf.append(@intCast(0xDC00 + (cp & 0x3FF)));
        }
    }
    try utf16_buf.append(0); // Null terminator

    return utf16_buf;
}

/// Create a PDF document with one page containing an error message
/// Returns a PDF document that must be closed by the caller
pub fn pdfErrorPage(
    allocator: std.mem.Allocator,
    error_text: []const u8,
    page_size: PageSize,
) !pdfium.Document {
    // Create new PDF document
    var doc = try pdfium.Document.createNew();
    errdefer doc.close();

    // Create a page with specified size
    var page = try doc.createPage(0, page_size.width, page_size.height);
    defer page.close();

    // Create text object with large font (Helvetica-Bold, 24pt)
    var text_obj = try doc.createTextObject("Helvetica-Bold", 24.0);

    // Convert UTF-8 error text to UTF-16LE
    var utf16_text = try encodeUtf8ToUtf16(allocator, error_text);
    defer utf16_text.deinit();

    // Set the text content
    if (!text_obj.setText(utf16_text.items)) {
        return error.TextSetFailed;
    }

    // Set text color to red (RGB: 200, 0, 0, fully opaque)
    _ = text_obj.setFillColor(200, 0, 0, 255);

    // Position text in the center of the page
    // For a 24pt font, estimate text width as ~14 points per character (rough approximation)
    const estimated_text_width = @as(f64, @floatFromInt(error_text.len)) * 14.0;
    const x_pos = (page_size.width - estimated_text_width) / 2;
    const y_pos = page_size.height / 2;

    // Transform: translate to position (origin is bottom-left)
    text_obj.transform(1, 0, 0, 1, x_pos, y_pos);

    // Insert text object into page
    page.insertObject(text_obj);

    // Generate page content (required before saving)
    if (!page.generateContent()) {
        return error.GenerateContentFailed;
    }

    return doc;
}

/// Create a PNG image of an error page
/// Returns PNG bytes that must be freed by the caller
pub fn pdfErrorPagePNG(
    allocator: std.mem.Allocator,
    error_text: []const u8,
    page_size: PageSize,
    dpi: ?f64,
) ![]u8 {
    const actual_dpi = dpi orelse 72.0;

    // Create error PDF
    var doc = try pdfErrorPage(allocator, error_text, page_size);
    defer doc.close();

    // Load the page for rendering
    var page = try doc.loadPage(0);
    defer page.close();

    // Calculate dimensions at target DPI
    const width_px: u32 = @intFromFloat(@ceil(page_size.width * actual_dpi / 72.0));
    const height_px: u32 = @intFromFloat(@ceil(page_size.height * actual_dpi / 72.0));

    // Create bitmap for rendering
    var bitmap = try pdfium.Bitmap.create(width_px, height_px, .bgra);
    defer bitmap.destroy();

    // Fill with white background
    bitmap.fillWhite();

    // Render the page
    page.render(&bitmap, .{});

    // Convert to PNG
    const images = @import("../pdfcontent/images.zig");
    const data = bitmap.getData() orelse return error.BufferEmpty;

    // Convert BGRA to RGBA
    const pixels = try images.convertBgraToRgba(
        allocator,
        data,
        bitmap.width,
        bitmap.height,
        bitmap.stride,
    );
    defer allocator.free(pixels);

    // Create zigimg image structure
    const zigimg = @import("zigimg");
    const pixel_count = bitmap.width * bitmap.height;
    const rgba_pixels: []zigimg.color.Rgba32 =
        @as([*]zigimg.color.Rgba32, @ptrCast(@alignCast(pixels.ptr)))[0..pixel_count];

    const image = zigimg.Image{
        .width = bitmap.width,
        .height = bitmap.height,
        .pixels = .{ .rgba32 = rgba_pixels },
    };

    // Encode to PNG in memory
    const write_buf = try allocator.alloc(u8, 5 * 1024 * 1024); // 5MB buffer for error pages
    defer allocator.free(write_buf);

    return try image.writeToMemory(allocator, write_buf, .{ .png = .{} });
}

test "create error PDF" {
    const allocator = std.testing.allocator;

    // Initialize PDFium
    try pdfium.initLibrary();
    defer pdfium.deinitLibrary();

    // Create error PDF
    var doc = try pdfErrorPage(
        allocator,
        "File Not Found",
        PageSize.letter,
    );
    defer doc.close();

    // Save to temp file for manual inspection
    const temp_path = "/tmp/error_page_test.pdf";
    try doc.save(temp_path);

    // Verify file exists
    const file = try std.fs.cwd().openFile(temp_path, .{});
    file.close();

    // Clean up
    try std.fs.cwd().deleteFile(temp_path);
}

test "create error PNG" {
    const allocator = std.testing.allocator;

    // Initialize PDFium
    try pdfium.initLibrary();
    defer pdfium.deinitLibrary();

    // Create error PNG
    const png_bytes = try pdfErrorPagePNG(
        allocator,
        "Error: Document Failed to Load",
        PageSize.a4,
        150.0, // 150 DPI
    );
    defer allocator.free(png_bytes);

    // Verify we got PNG data
    try std.testing.expect(png_bytes.len > 0);

    // PNG should start with magic bytes
    try std.testing.expect(png_bytes[0] == 0x89);
    try std.testing.expect(png_bytes[1] == 0x50); // 'P'
    try std.testing.expect(png_bytes[2] == 0x4E); // 'N'
    try std.testing.expect(png_bytes[3] == 0x47); // 'G'

    // Save for manual inspection
    const temp_path = "/tmp/error_page_test.png";
    const file = try std.fs.cwd().createFile(temp_path, .{});
    defer file.close();
    try file.writeAll(png_bytes);

    std.debug.print("Error PNG saved to {s} ({d} bytes)\n", .{ temp_path, png_bytes.len });
}
