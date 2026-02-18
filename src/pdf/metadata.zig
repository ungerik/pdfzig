const std = @import("std");
const xmp = @import("xmp.zig");

pub const MetaData = struct {
    // Standard PDF metadata fields
    title: ?[]u8 = null,
    author: ?[]u8 = null,
    subject: ?[]u8 = null,
    keywords: ?[]u8 = null,
    creator: ?[]u8 = null,
    producer: ?[]u8 = null,
    creation_date: ?[]u8 = null,
    mod_date: ?[]u8 = null,

    // Document properties
    page_count: usize = 0,
    pdf_version: ?[]u8 = null,
    encrypted: bool = false,
    security_handler_revision: ?i32 = null,

    // PDF/A conformance from XMP parsing
    pdfa_conformance: ?PdfAConformance = null,

    pub const PdfAConformance = struct {
        part: u8,
        level: u8,

        pub fn format(
            self: PdfAConformance,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("PDF/A-{d}{c}", .{ self.part, self.level });
        }
    };

    pub fn deinit(self: *MetaData, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.author) |a| allocator.free(a);
        if (self.subject) |s| allocator.free(s);
        if (self.keywords) |k| allocator.free(k);
        if (self.creator) |c| allocator.free(c);
        if (self.producer) |p| allocator.free(p);
        if (self.creation_date) |cd| allocator.free(cd);
        if (self.mod_date) |md| allocator.free(md);
        if (self.pdf_version) |v| allocator.free(v);
        self.* = .{};
    }
};

/// Parse PDF/A conformance from PDF byte stream
pub fn parsePdfA(pdf_bytes: []const u8) ?MetaData.PdfAConformance {
    return xmp.extractPdfAConformance(pdf_bytes);
}
