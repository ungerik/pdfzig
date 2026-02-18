//! Info - Get PDF metadata and information (library function)

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const pdf = @import("../pdf/metadata.zig");

/// Get PDF metadata information from an already-open document.
/// Extracts metadata from PDFium and parses XMP for PDF/A conformance.
/// Caller must call deinit() on the returned MetaData.
pub fn getInfo(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
) !pdf.MetaData {
    // Build metadata from the open document
    var metadata = pdf.MetaData{
        .page_count = doc.getPageCount(),
        .encrypted = doc.isEncrypted(),
    };
    errdefer metadata.deinit(allocator);

    if (metadata.encrypted) {
        const revision = doc.getSecurityHandlerRevision();
        if (revision >= 0) {
            metadata.security_handler_revision = revision;
        }
    }

    // Extract PDF version
    if (doc.getFileVersion()) |version| {
        metadata.pdf_version = try std.fmt.allocPrint(
            allocator,
            "{d}.{d}",
            .{ version / 10, version % 10 },
        );
    }

    // Extract standard metadata fields
    metadata.title = doc.getMetaText(allocator, "Title");
    metadata.author = doc.getMetaText(allocator, "Author");
    metadata.subject = doc.getMetaText(allocator, "Subject");
    metadata.keywords = doc.getMetaText(allocator, "Keywords");
    metadata.creator = doc.getMetaText(allocator, "Creator");
    metadata.producer = doc.getMetaText(allocator, "Producer");
    metadata.creation_date = doc.getMetaText(allocator, "CreationDate");
    metadata.mod_date = doc.getMetaText(allocator, "ModDate");

    // Parse PDF/A conformance from the document's memory buffer
    if (doc.pdf_buffer) |buf| {
        metadata.pdfa_conformance = pdf.parsePdfA(buf);
    }

    return metadata;
}
