//! Dynamic loader for PDFium library
//! Handles library discovery, version selection, and runtime loading

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ============================================================================
// Opaque Handle Types (replacing @cImport types)
// ============================================================================

pub const FPDF_DOCUMENT = ?*opaque {};
pub const FPDF_PAGE = ?*opaque {};
pub const FPDF_BITMAP = ?*opaque {};
pub const FPDF_TEXTPAGE = ?*opaque {};
pub const FPDF_PAGEOBJECT = ?*opaque {};
pub const FPDF_ATTACHMENT = ?*opaque {};
pub const FPDF_FONT = ?*opaque {};

// ============================================================================
// C Type Aliases
// ============================================================================

pub const FPDF_BOOL = c_int;
pub const FPDF_DWORD = c_ulong;
pub const FPDF_STRING = [*c]const u8;
pub const FPDF_BYTESTRING = [*c]const u8;
pub const FPDF_WIDESTRING = [*c]const u16;

/// File write callback structure for saving PDFs
pub const FPDF_FILEWRITE = extern struct {
    version: c_int = 1,
    WriteBlock: *const fn (pThis: *FPDF_FILEWRITE, pData: ?*const anyopaque, size: c_ulong) callconv(.c) c_int,
};

// ============================================================================
// Error Constants
// ============================================================================

pub const FPDF_ERR_SUCCESS: c_ulong = 0;
pub const FPDF_ERR_UNKNOWN: c_ulong = 1;
pub const FPDF_ERR_FILE: c_ulong = 2;
pub const FPDF_ERR_FORMAT: c_ulong = 3;
pub const FPDF_ERR_PASSWORD: c_ulong = 4;
pub const FPDF_ERR_SECURITY: c_ulong = 5;
pub const FPDF_ERR_PAGE: c_ulong = 6;

// ============================================================================
// Render Flag Constants
// ============================================================================

pub const FPDF_ANNOT: c_int = 0x01;
pub const FPDF_LCD_TEXT: c_int = 0x02;
pub const FPDF_NO_NATIVETEXT: c_int = 0x04;
pub const FPDF_GRAYSCALE: c_int = 0x08;
pub const FPDF_DEBUG_INFO: c_int = 0x80;
pub const FPDF_NO_CATCH: c_int = 0x100;
pub const FPDF_RENDER_LIMITEDIMAGECACHE: c_int = 0x200;
pub const FPDF_RENDER_FORCEHALFTONE: c_int = 0x400;
pub const FPDF_PRINTING: c_int = 0x800;
pub const FPDF_REVERSE_BYTE_ORDER: c_int = 0x10;

// ============================================================================
// Error Types
// ============================================================================

pub const LoadError = error{
    LibraryNotFound,
    LibraryLoadFailed,
    SymbolNotFound,
    OutOfMemory,
};

// ============================================================================
// PDFium Library Handle
// ============================================================================

pub const PdfiumLib = struct {
    handle: std.DynLib,
    version: u32,

    // Core functions
    FPDF_InitLibrary: *const fn () callconv(.c) void,
    FPDF_DestroyLibrary: *const fn () callconv(.c) void,
    FPDF_GetLastError: *const fn () callconv(.c) c_ulong,

    // Document functions
    FPDF_LoadDocument: *const fn (file_path: FPDF_STRING, password: FPDF_STRING) callconv(.c) FPDF_DOCUMENT,
    FPDF_CloseDocument: *const fn (document: FPDF_DOCUMENT) callconv(.c) void,
    FPDF_GetPageCount: *const fn (document: FPDF_DOCUMENT) callconv(.c) c_int,
    FPDF_GetFileVersion: *const fn (document: FPDF_DOCUMENT, fileVersion: *c_int) callconv(.c) FPDF_BOOL,
    FPDF_GetDocPermissions: *const fn (document: FPDF_DOCUMENT) callconv(.c) c_ulong,
    FPDF_GetSecurityHandlerRevision: *const fn (document: FPDF_DOCUMENT) callconv(.c) c_int,
    FPDF_GetMetaText: *const fn (document: FPDF_DOCUMENT, tag: FPDF_STRING, buffer: ?*anyopaque, buflen: c_ulong) callconv(.c) c_ulong,

    // Page functions
    FPDF_LoadPage: *const fn (document: FPDF_DOCUMENT, page_index: c_int) callconv(.c) FPDF_PAGE,
    FPDF_ClosePage: *const fn (page: FPDF_PAGE) callconv(.c) void,
    FPDF_GetPageWidth: *const fn (page: FPDF_PAGE) callconv(.c) f64,
    FPDF_GetPageHeight: *const fn (page: FPDF_PAGE) callconv(.c) f64,
    FPDF_RenderPageBitmap: *const fn (bitmap: FPDF_BITMAP, page: FPDF_PAGE, start_x: c_int, start_y: c_int, size_x: c_int, size_y: c_int, rotate: c_int, flags: c_int) callconv(.c) void,

    // Bitmap functions
    FPDFBitmap_CreateEx: *const fn (width: c_int, height: c_int, format: c_int, first_scan: ?*anyopaque, stride: c_int) callconv(.c) FPDF_BITMAP,
    FPDFBitmap_Destroy: *const fn (bitmap: FPDF_BITMAP) callconv(.c) void,
    FPDFBitmap_FillRect: *const fn (bitmap: FPDF_BITMAP, left: c_int, top: c_int, width: c_int, height: c_int, color: FPDF_DWORD) callconv(.c) void,
    FPDFBitmap_GetBuffer: *const fn (bitmap: FPDF_BITMAP) callconv(.c) ?*anyopaque,
    FPDFBitmap_GetWidth: *const fn (bitmap: FPDF_BITMAP) callconv(.c) c_int,
    FPDFBitmap_GetHeight: *const fn (bitmap: FPDF_BITMAP) callconv(.c) c_int,
    FPDFBitmap_GetStride: *const fn (bitmap: FPDF_BITMAP) callconv(.c) c_int,
    FPDFBitmap_GetFormat: *const fn (bitmap: FPDF_BITMAP) callconv(.c) c_int,

    // Text functions
    FPDFText_LoadPage: *const fn (page: FPDF_PAGE) callconv(.c) FPDF_TEXTPAGE,
    FPDFText_ClosePage: *const fn (text_page: FPDF_TEXTPAGE) callconv(.c) void,
    FPDFText_CountChars: *const fn (text_page: FPDF_TEXTPAGE) callconv(.c) c_int,
    FPDFText_GetText: *const fn (text_page: FPDF_TEXTPAGE, start_index: c_int, count: c_int, result: ?*anyopaque) callconv(.c) c_int,
    FPDFText_GetUnicode: *const fn (text_page: FPDF_TEXTPAGE, index: c_int) callconv(.c) c_uint,
    FPDFText_GetFontSize: *const fn (text_page: FPDF_TEXTPAGE, index: c_int) callconv(.c) f64,

    // Page object functions
    FPDFPage_CountObjects: *const fn (page: FPDF_PAGE) callconv(.c) c_int,
    FPDFPage_GetObject: *const fn (page: FPDF_PAGE, index: c_int) callconv(.c) FPDF_PAGEOBJECT,
    FPDFPageObj_GetType: *const fn (page_object: FPDF_PAGEOBJECT) callconv(.c) c_int,

    // Image object functions
    FPDFImageObj_GetImagePixelSize: *const fn (image_object: FPDF_PAGEOBJECT, width: *c_uint, height: *c_uint) callconv(.c) FPDF_BOOL,
    FPDFImageObj_GetRenderedBitmap: *const fn (document: FPDF_DOCUMENT, page: FPDF_PAGE, image_object: FPDF_PAGEOBJECT) callconv(.c) FPDF_BITMAP,
    FPDFImageObj_GetBitmap: *const fn (image_object: FPDF_PAGEOBJECT) callconv(.c) FPDF_BITMAP,

    // Attachment functions
    FPDFDoc_GetAttachmentCount: *const fn (document: FPDF_DOCUMENT) callconv(.c) c_int,
    FPDFDoc_GetAttachment: *const fn (document: FPDF_DOCUMENT, index: c_int) callconv(.c) FPDF_ATTACHMENT,
    FPDFAttachment_GetName: *const fn (attachment: FPDF_ATTACHMENT, buffer: ?*anyopaque, buflen: c_ulong) callconv(.c) c_ulong,
    FPDFAttachment_GetFile: *const fn (attachment: FPDF_ATTACHMENT, buffer: ?*anyopaque, buflen: c_ulong, out_buflen: *c_ulong) callconv(.c) FPDF_BOOL,
    FPDFDoc_AddAttachment: *const fn (document: FPDF_DOCUMENT, name: FPDF_WIDESTRING) callconv(.c) FPDF_ATTACHMENT,
    FPDFAttachment_SetFile: *const fn (attachment: FPDF_ATTACHMENT, document: FPDF_DOCUMENT, contents: ?*const anyopaque, len: c_ulong) callconv(.c) FPDF_BOOL,
    FPDFDoc_DeleteAttachment: *const fn (document: FPDF_DOCUMENT, index: c_int) callconv(.c) FPDF_BOOL,

    // Page rotation functions
    FPDFPage_GetRotation: *const fn (page: FPDF_PAGE) callconv(.c) c_int,
    FPDFPage_SetRotation: *const fn (page: FPDF_PAGE, rotate: c_int) callconv(.c) void,
    FPDFPage_GenerateContent: *const fn (page: FPDF_PAGE) callconv(.c) FPDF_BOOL,

    // Page deletion function
    FPDFPage_Delete: *const fn (document: FPDF_DOCUMENT, page_index: c_int) callconv(.c) void,

    // Document save functions
    FPDF_SaveAsCopy: *const fn (document: FPDF_DOCUMENT, pFileWrite: *FPDF_FILEWRITE, flags: FPDF_DWORD) callconv(.c) FPDF_BOOL,
    FPDF_SaveWithVersion: *const fn (document: FPDF_DOCUMENT, pFileWrite: *FPDF_FILEWRITE, flags: FPDF_DWORD, fileVersion: c_int) callconv(.c) FPDF_BOOL,

    // Page creation and editing functions
    FPDFPage_New: *const fn (document: FPDF_DOCUMENT, page_index: c_int, width: f64, height: f64) callconv(.c) FPDF_PAGE,
    FPDFPage_InsertObject: *const fn (page: FPDF_PAGE, page_object: FPDF_PAGEOBJECT) callconv(.c) void,

    // Image object functions
    FPDFPageObj_NewImageObj: *const fn (document: FPDF_DOCUMENT) callconv(.c) FPDF_PAGEOBJECT,
    FPDFImageObj_SetBitmap: *const fn (pages: ?*FPDF_PAGE, count: c_int, image_object: FPDF_PAGEOBJECT, bitmap: FPDF_BITMAP) callconv(.c) FPDF_BOOL,
    FPDFImageObj_SetMatrix: *const fn (image_object: FPDF_PAGEOBJECT, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) callconv(.c) FPDF_BOOL,

    // Text object functions
    FPDFPageObj_NewTextObj: *const fn (document: FPDF_DOCUMENT, font: FPDF_BYTESTRING, font_size: f32) callconv(.c) FPDF_PAGEOBJECT,
    FPDFText_SetText: *const fn (text_object: FPDF_PAGEOBJECT, text: FPDF_WIDESTRING) callconv(.c) FPDF_BOOL,
    FPDFPageObj_Transform: *const fn (page_object: FPDF_PAGEOBJECT, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) callconv(.c) void,

    // Document creation and page import functions
    FPDF_CreateNewDocument: *const fn () callconv(.c) FPDF_DOCUMENT,
    FPDF_ImportPages: *const fn (dest_doc: FPDF_DOCUMENT, src_doc: FPDF_DOCUMENT, pagerange: FPDF_BYTESTRING, index: c_int) callconv(.c) FPDF_BOOL,
    FPDF_ImportPagesByIndex: *const fn (dest_doc: FPDF_DOCUMENT, src_doc: FPDF_DOCUMENT, page_indices: [*c]const c_int, length: c_ulong, index: c_int) callconv(.c) FPDF_BOOL,

    /// Load PDFium library from a specific path
    pub fn load(path: []const u8) LoadError!PdfiumLib {
        var self: PdfiumLib = undefined;

        self.handle = std.DynLib.open(path) catch {
            return LoadError.LibraryLoadFailed;
        };

        // Extract version from filename (e.g., pdfium_v7606.dylib -> 7606)
        self.version = extractVersionFromPath(path) orelse 0;

        // Load all symbols
        inline for (@typeInfo(PdfiumLib).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "handle") or std.mem.eql(u8, field.name, "version")) {
                continue;
            }
            const symbol = self.handle.lookup(field.type, field.name) orelse {
                self.handle.close();
                return LoadError.SymbolNotFound;
            };
            @field(self, field.name) = symbol;
        }

        return self;
    }

    /// Unload the PDFium library
    pub fn unload(self: *PdfiumLib) void {
        self.handle.close();
    }
};

// ============================================================================
// Version Detection and Library Discovery
// ============================================================================

/// Get the library file extension for the current platform
pub fn getLibraryExtension() []const u8 {
    return switch (builtin.os.tag) {
        .macos => ".dylib",
        .linux => ".so",
        .windows => ".dll",
        else => ".so",
    };
}


/// Extract version number from a library path
/// E.g., "pdfium_v7606.dylib" -> 7606, "libpdfium_v7606.so" -> 7606
pub fn extractVersionFromPath(path: []const u8) ?u32 {
    const basename = std.fs.path.basename(path);

    // Find "_v" in the basename
    const v_pos = std.mem.indexOf(u8, basename, "_v") orelse return null;
    const version_start = v_pos + 2;

    // Find where the version number ends (at the dot before extension)
    var version_end = version_start;
    while (version_end < basename.len and std.ascii.isDigit(basename[version_end])) {
        version_end += 1;
    }

    if (version_end == version_start) return null;

    return std.fmt.parseInt(u32, basename[version_start..version_end], 10) catch null;
}

/// Library info with path and version
pub const LibraryInfo = struct {
    path: []u8,
    version: u32,
};

/// Find the best PDFium library in a directory
/// Returns the library with the highest version number
pub fn findBestPdfiumLibrary(allocator: Allocator, search_dir: []const u8) !?LibraryInfo {
    var dir = std.fs.openDirAbsolute(search_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer dir.close();

    var best_version: u32 = 0;
    var best_path: ?[]u8 = null;

    const ext = getLibraryExtension();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;

        // Check if filename matches pattern: pdfium_v{VERSION}.{ext}
        const name = entry.name;

        // Check if it starts with "pdfium_v"
        if (!std.mem.startsWith(u8, name, "pdfium_v")) continue;

        // Check if it ends with the correct extension
        if (!std.mem.endsWith(u8, name, ext)) continue;

        // Extract version
        const full_path = try std.fs.path.join(allocator, &.{ search_dir, name });
        const version = extractVersionFromPath(full_path) orelse {
            allocator.free(full_path);
            continue;
        };

        if (version > best_version) {
            if (best_path) |old_path| {
                allocator.free(old_path);
            }
            best_version = version;
            best_path = full_path;
        } else {
            allocator.free(full_path);
        }
    }

    if (best_path) |path| {
        return .{ .path = path, .version = best_version };
    }
    return null;
}

/// Get the directory containing the current executable
pub fn getExecutableDir(allocator: Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const dir_path = std.fs.path.dirname(exe_path) orelse ".";
    return allocator.dupe(u8, dir_path);
}

/// Build the expected library filename for a given version
/// Uses the format: pdfium_v{BUILD}.{ext}
pub fn buildLibraryFilename(allocator: Allocator, version: u32) ![]u8 {
    const ext = getLibraryExtension();
    return std.fmt.allocPrint(allocator, "pdfium_v{d}{s}", .{ version, ext });
}

// ============================================================================
// Tests
// ============================================================================

test "extractVersionFromPath" {
    try std.testing.expectEqual(@as(?u32, 7606), extractVersionFromPath("pdfium_v7606.dylib"));
    try std.testing.expectEqual(@as(?u32, 7606), extractVersionFromPath("pdfium_v7606.so"));
    try std.testing.expectEqual(@as(?u32, 7606), extractVersionFromPath("pdfium_v7606.dll"));
    try std.testing.expectEqual(@as(?u32, 7606), extractVersionFromPath("/path/to/pdfium_v7606.dylib"));
    try std.testing.expectEqual(@as(?u32, 123), extractVersionFromPath("pdfium_v123.dll"));
    try std.testing.expectEqual(@as(?u32, null), extractVersionFromPath("pdfium.dylib"));
    try std.testing.expectEqual(@as(?u32, null), extractVersionFromPath("pdfium.dll"));
    try std.testing.expectEqual(@as(?u32, null), extractVersionFromPath("something_else.dylib"));
}

test "getLibraryExtension" {
    const ext = getLibraryExtension();
    try std.testing.expect(ext.len > 0);
    try std.testing.expect(ext[0] == '.');
}

test "buildLibraryFilename" {
    const allocator = std.testing.allocator;
    const filename = try buildLibraryFilename(allocator, 7606);
    defer allocator.free(filename);

    // Should contain version number
    try std.testing.expect(std.mem.indexOf(u8, filename, "7606") != null);
    // Should contain pdfium
    try std.testing.expect(std.mem.indexOf(u8, filename, "pdfium") != null);
}
