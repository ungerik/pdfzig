const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const loader = @import("loader.zig");
const xmp = @import("xmp.zig");

pub const MetaData = struct {
    // Standard metadata from PDFium
    title: ?[]u8 = null,
    author: ?[]u8 = null,
    subject: ?[]u8 = null,
    keywords: ?[]u8 = null,
    creator: ?[]u8 = null,
    producer: ?[]u8 = null,
    creation_date: ?[]u8 = null,
    mod_date: ?[]u8 = null,

    // Document properties from PDFium
    page_count: u32 = 0,
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

/// Parse all PDF info from a file path
/// Combines PDFium metadata + PDF/A conformance
pub fn parseInfo(
    allocator: std.mem.Allocator,
    path: []const u8,
    password: ?[]const u8,
) !MetaData {
    // Step 1: Load entire PDF into memory
    const pdf_bytes = try loader.loadPdfFile(allocator, path);
    defer allocator.free(pdf_bytes);

    // Step 2: Extract PDFium metadata from buffer
    var pdfium_metadata = try pdfium.extractMetadataFromMemory(allocator, pdf_bytes, password);
    defer pdfium_metadata.deinit(allocator);

    // Step 3: Parse PDF/A conformance from buffer
    const pdfa = parsePdfA(pdf_bytes);

    // Step 4: Combine into generic MetaData struct
    return try combineMetadata(allocator, pdfium_metadata, pdfa);
}

/// Parse PDF/A conformance from PDF byte stream
pub fn parsePdfA(pdf_bytes: []const u8) ?MetaData.PdfAConformance {
    return xmp.extractPdfAConformance(pdf_bytes);
}

/// Combine pdfium.ExtendedMetadata + PDF/A conformance into generic pdf.MetaData
fn combineMetadata(
    allocator: std.mem.Allocator,
    pdfium_meta: pdfium.ExtendedMetadata,
    pdfa: ?MetaData.PdfAConformance,
) !MetaData {
    return MetaData{
        .title = if (pdfium_meta.title) |t| try allocator.dupe(u8, t) else null,
        .author = if (pdfium_meta.author) |a| try allocator.dupe(u8, a) else null,
        .subject = if (pdfium_meta.subject) |s| try allocator.dupe(u8, s) else null,
        .keywords = if (pdfium_meta.keywords) |k| try allocator.dupe(u8, k) else null,
        .creator = if (pdfium_meta.creator) |c| try allocator.dupe(u8, c) else null,
        .producer = if (pdfium_meta.producer) |p| try allocator.dupe(u8, p) else null,
        .creation_date = if (pdfium_meta.creation_date) |cd| try allocator.dupe(u8, cd) else null,
        .mod_date = if (pdfium_meta.mod_date) |md| try allocator.dupe(u8, md) else null,
        .page_count = pdfium_meta.page_count,
        .pdf_version = if (pdfium_meta.pdf_version) |v| try allocator.dupe(u8, v) else null,
        .encrypted = pdfium_meta.encrypted,
        .security_handler_revision = pdfium_meta.security_handler_revision,
        .pdfa_conformance = pdfa,
    };
}
