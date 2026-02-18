//! pdfzig - PDF manipulation library using PDFium

// Core modules
pub const pdfium = @import("pdfium/pdfium.zig");
pub const metadata = @import("pdf/metadata.zig");
pub const images = @import("pdfcontent/images.zig");
pub const textfmt = @import("pdfcontent/textfmt.zig");
pub const downloader = @import("pdfium/downloader.zig");

// High-level operations
pub const rotate = @import("pdfzig/rotate.zig");
pub const mirror = @import("pdfzig/mirror.zig");
pub const delete = @import("pdfzig/delete.zig");
pub const info = @import("pdfzig/info.zig");
pub const extract_text = @import("pdfzig/extract_text.zig");
pub const render = @import("pdfzig/render.zig");
pub const attach = @import("pdfzig/attach.zig");
