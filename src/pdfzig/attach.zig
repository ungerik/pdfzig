//! Attach - Attach files to PDF (library function)

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");

/// Attach content to a PDF document with the given name.
pub fn attachFile(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    name: []const u8,
    content: []const u8,
) !void {
    try doc.addAttachment(allocator, name, content);
}
