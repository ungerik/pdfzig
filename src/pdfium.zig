//! Zig bindings for PDFium library
//! Provides idiomatic Zig wrappers around the PDFium C API
//! Uses runtime dynamic loading instead of build-time linking

const std = @import("std");
const loader = @import("pdfium_loader.zig");
const downloader = @import("downloader.zig");

// Module-level library state
var lib: ?loader.PdfiumLib = null;
var lib_allocator: ?std.mem.Allocator = null;
var lib_path: ?[]u8 = null;

// Page object types
pub const PageObjectType = enum(c_int) {
    unknown = 0,
    text = 1,
    path = 2,
    image = 3,
    shading = 4,
    form = 5,
};

pub const Error = error{
    Unknown,
    FileNotFound,
    InvalidFormat,
    PasswordRequired,
    UnsupportedSecurity,
    PageNotFound,
    BitmapCreationFailed,
    LibraryNotLoaded,
    LibraryLoadFailed,
};

/// Convert UTF-16LE to UTF-8
fn utf16LeToUtf8(allocator: std.mem.Allocator, utf16: []const u16) ?[]u8 {
    // Calculate required UTF-8 length
    var utf8_len: usize = 0;
    for (utf16) |code_unit| {
        if (code_unit < 0x80) {
            utf8_len += 1;
        } else if (code_unit < 0x800) {
            utf8_len += 2;
        } else {
            utf8_len += 3;
        }
    }

    const utf8_buf = allocator.alloc(u8, utf8_len) catch return null;
    errdefer allocator.free(utf8_buf);

    var i: usize = 0;
    for (utf16) |code_unit| {
        if (code_unit < 0x80) {
            utf8_buf[i] = @intCast(code_unit);
            i += 1;
        } else if (code_unit < 0x800) {
            utf8_buf[i] = @intCast(0xC0 | (code_unit >> 6));
            utf8_buf[i + 1] = @intCast(0x80 | (code_unit & 0x3F));
            i += 2;
        } else {
            utf8_buf[i] = @intCast(0xE0 | (code_unit >> 12));
            utf8_buf[i + 1] = @intCast(0x80 | ((code_unit >> 6) & 0x3F));
            utf8_buf[i + 2] = @intCast(0x80 | (code_unit & 0x3F));
            i += 3;
        }
    }

    return utf8_buf;
}

/// Initialize the PDFium library. Must be called before any other PDFium functions.
/// If no library is found, attempts to download the latest version.
pub fn init() Error!void {
    return initWithAllocator(std.heap.page_allocator);
}

/// Initialize with a specific allocator
pub fn initWithAllocator(allocator: std.mem.Allocator) Error!void {
    if (lib != null) return; // Already initialized

    lib_allocator = allocator;

    // Get the executable directory
    const exe_dir = loader.getExecutableDir(allocator) catch {
        return Error.LibraryLoadFailed;
    };
    defer allocator.free(exe_dir);

    // Try to find an existing PDFium library
    if (loader.findBestPdfiumLibrary(allocator, exe_dir) catch null) |lib_info| {
        lib_path = lib_info.path;
        lib = loader.PdfiumLib.load(lib_info.path) catch {
            allocator.free(lib_info.path);
            lib_path = null;
            return Error.LibraryLoadFailed;
        };
        lib.?.FPDF_InitLibrary();
        return;
    }

    // No library found - try to download
    std.debug.print("PDFium library not found, downloading...\n", .{});
    _ = downloader.downloadPdfium(allocator, null, exe_dir) catch {
        return Error.LibraryLoadFailed;
    };

    // Try again after download
    if (loader.findBestPdfiumLibrary(allocator, exe_dir) catch null) |lib_info| {
        lib_path = lib_info.path;
        lib = loader.PdfiumLib.load(lib_info.path) catch {
            allocator.free(lib_info.path);
            lib_path = null;
            return Error.LibraryLoadFailed;
        };
        lib.?.FPDF_InitLibrary();
        return;
    }

    return Error.LibraryLoadFailed;
}

/// Deinitialize the PDFium library. Should be called when done with PDFium.
pub fn deinit() void {
    if (lib) |*l| {
        l.FPDF_DestroyLibrary();
        l.unload();
        lib = null;
    }
    if (lib_path) |path| {
        if (lib_allocator) |allocator| {
            allocator.free(path);
        }
        lib_path = null;
    }
}

/// Check if the library is loaded
pub fn isLoaded() bool {
    return lib != null;
}

/// Get the loaded library version (Chrome version number)
pub fn getVersion() ?u32 {
    if (lib) |l| {
        return l.version;
    }
    return null;
}

/// Get the last error code from PDFium
fn getLastError() Error {
    const l = lib orelse return Error.LibraryNotLoaded;
    return switch (l.FPDF_GetLastError()) {
        loader.FPDF_ERR_SUCCESS => Error.Unknown,
        loader.FPDF_ERR_UNKNOWN => Error.Unknown,
        loader.FPDF_ERR_FILE => Error.FileNotFound,
        loader.FPDF_ERR_FORMAT => Error.InvalidFormat,
        loader.FPDF_ERR_PASSWORD => Error.PasswordRequired,
        loader.FPDF_ERR_SECURITY => Error.UnsupportedSecurity,
        loader.FPDF_ERR_PAGE => Error.PageNotFound,
        else => Error.Unknown,
    };
}

/// A PDF document handle
pub const Document = struct {
    handle: loader.FPDF_DOCUMENT,

    /// Open a PDF document from a file path
    pub fn open(path: []const u8) Error!Document {
        const l = lib orelse return Error.LibraryNotLoaded;

        // Create null-terminated path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_buf.len) return Error.FileNotFound;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const handle = l.FPDF_LoadDocument(&path_buf, null);
        if (handle == null) {
            return getLastError();
        }
        return .{ .handle = handle };
    }

    /// Open a password-protected PDF document
    pub fn openWithPassword(path: []const u8, password: []const u8) Error!Document {
        const l = lib orelse return Error.LibraryNotLoaded;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_buf.len) return Error.FileNotFound;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        var pass_buf: [256]u8 = undefined;
        if (password.len >= pass_buf.len) return Error.PasswordRequired;
        @memcpy(pass_buf[0..password.len], password);
        pass_buf[password.len] = 0;

        const handle = l.FPDF_LoadDocument(&path_buf, &pass_buf);
        if (handle == null) {
            return getLastError();
        }
        return .{ .handle = handle };
    }

    /// Close the document and release resources
    pub fn close(self: *Document) void {
        if (self.handle != null) {
            if (lib) |l| {
                l.FPDF_CloseDocument(self.handle);
            }
            self.handle = null;
        }
    }

    /// Get the total number of pages in the document
    pub fn getPageCount(self: Document) u32 {
        const l = lib orelse return 0;
        const count = l.FPDF_GetPageCount(self.handle);
        return if (count < 0) 0 else @intCast(count);
    }

    /// Load a page by index (0-based)
    pub fn loadPage(self: Document, page_index: u32) Error!Page {
        const l = lib orelse return Error.LibraryNotLoaded;
        const handle = l.FPDF_LoadPage(self.handle, @intCast(page_index));
        if (handle == null) {
            return getLastError();
        }
        return .{ .handle = handle };
    }

    /// Get the PDF file version (e.g., 14 for PDF 1.4, 17 for PDF 1.7)
    pub fn getFileVersion(self: Document) ?u32 {
        const l = lib orelse return null;
        var version: c_int = 0;
        if (l.FPDF_GetFileVersion(self.handle, &version) != 0) {
            return @intCast(version);
        }
        return null;
    }

    /// Get document permissions flags
    pub fn getPermissions(self: Document) u32 {
        const l = lib orelse return 0;
        return @intCast(l.FPDF_GetDocPermissions(self.handle));
    }

    /// Get the security handler revision (-1 if not protected)
    pub fn getSecurityHandlerRevision(self: Document) i32 {
        const l = lib orelse return -1;
        return @intCast(l.FPDF_GetSecurityHandlerRevision(self.handle));
    }

    /// Check if the document is encrypted/password-protected
    pub fn isEncrypted(self: Document) bool {
        return self.getSecurityHandlerRevision() >= 0;
    }

    /// Get metadata value by tag name
    /// Valid tags: Title, Author, Subject, Keywords, Creator, Producer, CreationDate, ModDate
    pub fn getMetaText(self: Document, allocator: std.mem.Allocator, tag: []const u8) ?[]u8 {
        const l = lib orelse return null;

        var tag_buf: [64]u8 = undefined;
        if (tag.len >= tag_buf.len) return null;
        @memcpy(tag_buf[0..tag.len], tag);
        tag_buf[tag.len] = 0;

        // First call to get required buffer size
        const required_len = l.FPDF_GetMetaText(self.handle, &tag_buf, null, 0);
        if (required_len <= 2) return null; // Empty string (just null terminator)

        // Allocate buffer for UTF-16LE data
        const utf16_buf = allocator.alloc(u16, required_len / 2) catch return null;
        defer allocator.free(utf16_buf);

        _ = l.FPDF_GetMetaText(self.handle, &tag_buf, utf16_buf.ptr, required_len);

        // Convert UTF-16LE to UTF-8
        return utf16LeToUtf8(allocator, utf16_buf[0 .. utf16_buf.len - 1]); // Exclude null terminator
    }

    /// Document metadata
    pub const Metadata = struct {
        title: ?[]u8 = null,
        author: ?[]u8 = null,
        subject: ?[]u8 = null,
        keywords: ?[]u8 = null,
        creator: ?[]u8 = null,
        producer: ?[]u8 = null,
        creation_date: ?[]u8 = null,
        mod_date: ?[]u8 = null,

        pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
            if (self.title) |t| allocator.free(t);
            if (self.author) |a| allocator.free(a);
            if (self.subject) |s| allocator.free(s);
            if (self.keywords) |k| allocator.free(k);
            if (self.creator) |c_| allocator.free(c_);
            if (self.producer) |p| allocator.free(p);
            if (self.creation_date) |cd| allocator.free(cd);
            if (self.mod_date) |md| allocator.free(md);
            self.* = .{};
        }
    };

    /// Get all metadata at once
    pub fn getMetadata(self: Document, allocator: std.mem.Allocator) Metadata {
        return .{
            .title = self.getMetaText(allocator, "Title"),
            .author = self.getMetaText(allocator, "Author"),
            .subject = self.getMetaText(allocator, "Subject"),
            .keywords = self.getMetaText(allocator, "Keywords"),
            .creator = self.getMetaText(allocator, "Creator"),
            .producer = self.getMetaText(allocator, "Producer"),
            .creation_date = self.getMetaText(allocator, "CreationDate"),
            .mod_date = self.getMetaText(allocator, "ModDate"),
        };
    }

    /// Get the number of embedded file attachments
    pub fn getAttachmentCount(self: Document) u32 {
        const l = lib orelse return 0;
        const count = l.FPDFDoc_GetAttachmentCount(self.handle);
        return if (count < 0) 0 else @intCast(count);
    }

    /// Get an attachment by index (0-based)
    pub fn getAttachment(self: Document, index: u32) ?Attachment {
        const l = lib orelse return null;
        const handle = l.FPDFDoc_GetAttachment(self.handle, @intCast(index));
        if (handle == null) return null;
        return .{ .handle = handle };
    }

    /// Iterator for attachments
    pub fn attachments(self: Document) AttachmentIterator {
        return .{
            .document = self,
            .index = 0,
            .count = self.getAttachmentCount(),
        };
    }
};

/// A PDF page handle
pub const Page = struct {
    handle: loader.FPDF_PAGE,

    /// Close the page and release resources
    pub fn close(self: *Page) void {
        if (self.handle != null) {
            if (lib) |l| {
                l.FPDF_ClosePage(self.handle);
            }
            self.handle = null;
        }
    }

    /// Get page width in PDF points (1 point = 1/72 inch)
    pub fn getWidth(self: Page) f64 {
        const l = lib orelse return 0;
        return l.FPDF_GetPageWidth(self.handle);
    }

    /// Get page height in PDF points (1 point = 1/72 inch)
    pub fn getHeight(self: Page) f64 {
        const l = lib orelse return 0;
        return l.FPDF_GetPageHeight(self.handle);
    }

    /// Get page dimensions at a given DPI
    pub fn getDimensionsAtDpi(self: Page, dpi: f64) struct { width: u32, height: u32 } {
        const scale = dpi / 72.0;
        return .{
            .width = @intFromFloat(@ceil(self.getWidth() * scale)),
            .height = @intFromFloat(@ceil(self.getHeight() * scale)),
        };
    }

    /// Render the page to a bitmap
    pub fn render(self: Page, bitmap: *Bitmap, flags: RenderFlags) void {
        const l = lib orelse return;
        l.FPDF_RenderPageBitmap(
            bitmap.handle,
            self.handle,
            0, // start_x
            0, // start_y
            @intCast(bitmap.width),
            @intCast(bitmap.height),
            0, // rotation (0 = no rotation)
            flags.toInt(),
        );
    }

    /// Load text information for this page
    pub fn loadTextPage(self: Page) ?TextPage {
        const l = lib orelse return null;
        const handle = l.FPDFText_LoadPage(self.handle);
        if (handle == null) return null;
        return .{ .handle = handle };
    }

    /// Get the number of objects on this page
    pub fn getObjectCount(self: Page) u32 {
        const l = lib orelse return 0;
        const count = l.FPDFPage_CountObjects(self.handle);
        return if (count < 0) 0 else @intCast(count);
    }

    /// Get a page object by index
    pub fn getObject(self: Page, index: u32) ?PageObject {
        const l = lib orelse return null;
        const handle = l.FPDFPage_GetObject(self.handle, @intCast(index));
        if (handle == null) return null;
        return .{ .handle = handle };
    }

    /// Iterator for image objects on a page
    pub fn imageObjects(self: Page) ImageObjectIterator {
        return .{
            .page = self,
            .index = 0,
            .count = self.getObjectCount(),
        };
    }
};

/// Iterator for image objects on a page
pub const ImageObjectIterator = struct {
    page: Page,
    index: u32,
    count: u32,

    pub fn next(self: *ImageObjectIterator) ?ImageObject {
        while (self.index < self.count) {
            const obj = self.page.getObject(self.index);
            self.index += 1;
            if (obj) |o| {
                if (o.getType() == .image) {
                    return .{ .handle = o.handle, .page = self.page };
                }
            }
        }
        return null;
    }
};

/// A page object handle
pub const PageObject = struct {
    handle: loader.FPDF_PAGEOBJECT,

    /// Get the type of this page object
    pub fn getType(self: PageObject) PageObjectType {
        const l = lib orelse return .unknown;
        const obj_type = l.FPDFPageObj_GetType(self.handle);
        return @enumFromInt(obj_type);
    }
};

/// An image object on a page
pub const ImageObject = struct {
    handle: loader.FPDF_PAGEOBJECT,
    page: Page,

    /// Get the pixel dimensions of the image
    pub fn getPixelSize(self: ImageObject) ?struct { width: u32, height: u32 } {
        const l = lib orelse return null;
        var width: c_uint = 0;
        var height: c_uint = 0;
        if (l.FPDFImageObj_GetImagePixelSize(self.handle, &width, &height) != 0) {
            return .{ .width = width, .height = height };
        }
        return null;
    }

    /// Get the rendered bitmap of this image (includes masks and transforms)
    pub fn getRenderedBitmap(self: ImageObject, document: Document) ?Bitmap {
        const l = lib orelse return null;
        const bmp_handle = l.FPDFImageObj_GetRenderedBitmap(
            document.handle,
            self.page.handle,
            self.handle,
        );
        if (bmp_handle == null) return null;

        const width: u32 = @intCast(l.FPDFBitmap_GetWidth(bmp_handle));
        const height: u32 = @intCast(l.FPDFBitmap_GetHeight(bmp_handle));
        const stride: u32 = @intCast(l.FPDFBitmap_GetStride(bmp_handle));
        const format_int = l.FPDFBitmap_GetFormat(bmp_handle);

        return .{
            .handle = bmp_handle,
            .width = width,
            .height = height,
            .stride = stride,
            .format = @enumFromInt(format_int),
        };
    }

    /// Get the raw bitmap of this image (no masks or transforms)
    pub fn getBitmap(self: ImageObject) ?Bitmap {
        const l = lib orelse return null;
        const bmp_handle = l.FPDFImageObj_GetBitmap(self.handle);
        if (bmp_handle == null) return null;

        const width: u32 = @intCast(l.FPDFBitmap_GetWidth(bmp_handle));
        const height: u32 = @intCast(l.FPDFBitmap_GetHeight(bmp_handle));
        const stride: u32 = @intCast(l.FPDFBitmap_GetStride(bmp_handle));
        const format_int = l.FPDFBitmap_GetFormat(bmp_handle);

        return .{
            .handle = bmp_handle,
            .width = width,
            .height = height,
            .stride = stride,
            .format = @enumFromInt(format_int),
        };
    }
};

/// A text page handle for text extraction
pub const TextPage = struct {
    handle: loader.FPDF_TEXTPAGE,

    /// Close the text page and release resources
    pub fn close(self: *TextPage) void {
        if (self.handle != null) {
            if (lib) |l| {
                l.FPDFText_ClosePage(self.handle);
            }
            self.handle = null;
        }
    }

    /// Get the number of characters in the page
    pub fn getCharCount(self: TextPage) u32 {
        const l = lib orelse return 0;
        const count = l.FPDFText_CountChars(self.handle);
        return if (count < 0) 0 else @intCast(count);
    }

    /// Extract all text from the page as UTF-8
    pub fn getText(self: TextPage, allocator: std.mem.Allocator) ?[]u8 {
        const l = lib orelse return null;

        const char_count = self.getCharCount();
        if (char_count == 0) return null;

        // Allocate buffer for UTF-16LE data (char_count + 1 for null terminator)
        const utf16_buf = allocator.alloc(u16, char_count + 1) catch return null;
        defer allocator.free(utf16_buf);

        const written = l.FPDFText_GetText(self.handle, 0, @intCast(char_count), utf16_buf.ptr);
        if (written <= 0) return null;

        // Convert UTF-16LE to UTF-8 (exclude null terminator)
        const actual_len: usize = @intCast(written - 1);
        return utf16LeToUtf8(allocator, utf16_buf[0..actual_len]);
    }

    /// Get Unicode value of a character at index
    pub fn getCharUnicode(self: TextPage, index: u32) u32 {
        const l = lib orelse return 0;
        return l.FPDFText_GetUnicode(self.handle, @intCast(index));
    }

    /// Get font size of a character at index (in points)
    pub fn getCharFontSize(self: TextPage, index: u32) f64 {
        const l = lib orelse return 0;
        return l.FPDFText_GetFontSize(self.handle, @intCast(index));
    }
};

/// An embedded file attachment in a PDF
pub const Attachment = struct {
    handle: loader.FPDF_ATTACHMENT,

    /// Get the filename of the attachment
    pub fn getName(self: Attachment, allocator: std.mem.Allocator) ?[]u8 {
        const l = lib orelse return null;

        // First call to get required buffer size
        const required_len = l.FPDFAttachment_GetName(self.handle, null, 0);
        if (required_len <= 2) return null; // Empty or just null terminator

        // Allocate buffer for UTF-16LE data
        const utf16_buf = allocator.alloc(u16, required_len / 2) catch return null;
        defer allocator.free(utf16_buf);

        _ = l.FPDFAttachment_GetName(self.handle, utf16_buf.ptr, required_len);

        // Convert UTF-16LE to UTF-8 (exclude null terminator)
        return utf16LeToUtf8(allocator, utf16_buf[0 .. utf16_buf.len - 1]);
    }

    /// Get the file data of the attachment
    pub fn getData(self: Attachment, allocator: std.mem.Allocator) ?[]u8 {
        const l = lib orelse return null;

        // First call to get required buffer size
        var out_buflen: c_ulong = 0;
        if (l.FPDFAttachment_GetFile(self.handle, null, 0, &out_buflen) == 0) {
            return null;
        }
        if (out_buflen == 0) return null;

        // Allocate buffer and get data
        const buffer = allocator.alloc(u8, out_buflen) catch return null;
        errdefer allocator.free(buffer);

        var actual_len: c_ulong = 0;
        if (l.FPDFAttachment_GetFile(self.handle, buffer.ptr, out_buflen, &actual_len) == 0) {
            allocator.free(buffer);
            return null;
        }

        return buffer[0..actual_len];
    }

    /// Check if this attachment is an XML file (by extension)
    pub fn isXml(self: Attachment, allocator: std.mem.Allocator) bool {
        const name = self.getName(allocator) orelse return false;
        defer allocator.free(name);

        const lower_name = allocator.alloc(u8, name.len) catch return false;
        defer allocator.free(lower_name);

        for (name, 0..) |char, i| {
            lower_name[i] = std.ascii.toLower(char);
        }

        return std.mem.endsWith(u8, lower_name, ".xml") or
            std.mem.endsWith(u8, lower_name, ".xmp") or
            std.mem.endsWith(u8, lower_name, ".xsd") or
            std.mem.endsWith(u8, lower_name, ".xsl") or
            std.mem.endsWith(u8, lower_name, ".xslt");
    }
};

/// Iterator for document attachments
pub const AttachmentIterator = struct {
    document: Document,
    index: u32,
    count: u32,

    pub fn next(self: *AttachmentIterator) ?Attachment {
        if (self.index >= self.count) return null;
        const attachment = self.document.getAttachment(self.index);
        self.index += 1;
        return attachment;
    }

    pub fn reset(self: *AttachmentIterator) void {
        self.index = 0;
    }
};

/// Rendering flags for page rendering
pub const RenderFlags = struct {
    annotations: bool = true,
    lcd_text: bool = false,
    no_native_text: bool = false,
    grayscale: bool = false,
    debug_info: bool = false,
    no_catch: bool = false,
    render_limited_image_cache: bool = false,
    render_force_halftone: bool = false,
    printing: bool = false,
    reverse_byte_order: bool = false,

    pub fn toInt(self: RenderFlags) c_int {
        var flags: c_int = 0;
        if (self.annotations) flags |= loader.FPDF_ANNOT;
        if (self.lcd_text) flags |= loader.FPDF_LCD_TEXT;
        if (self.no_native_text) flags |= loader.FPDF_NO_NATIVETEXT;
        if (self.grayscale) flags |= loader.FPDF_GRAYSCALE;
        if (self.debug_info) flags |= loader.FPDF_DEBUG_INFO;
        if (self.no_catch) flags |= loader.FPDF_NO_CATCH;
        if (self.render_limited_image_cache) flags |= loader.FPDF_RENDER_LIMITEDIMAGECACHE;
        if (self.render_force_halftone) flags |= loader.FPDF_RENDER_FORCEHALFTONE;
        if (self.printing) flags |= loader.FPDF_PRINTING;
        if (self.reverse_byte_order) flags |= loader.FPDF_REVERSE_BYTE_ORDER;
        return flags;
    }
};

/// Bitmap format
pub const BitmapFormat = enum(c_int) {
    gray = 1, // 8bpp grayscale
    bgr = 2, // 24bpp BGR
    bgrx = 3, // 32bpp BGRX (X is unused)
    bgra = 4, // 32bpp BGRA
};

/// A bitmap for rendering PDF pages
pub const Bitmap = struct {
    handle: loader.FPDF_BITMAP,
    width: u32,
    height: u32,
    stride: u32,
    format: BitmapFormat,

    /// Create a new bitmap
    pub fn create(width: u32, height: u32, format: BitmapFormat) Error!Bitmap {
        const l = lib orelse return Error.LibraryNotLoaded;

        const handle = l.FPDFBitmap_CreateEx(
            @intCast(width),
            @intCast(height),
            @intFromEnum(format),
            null, // external buffer - let PDFium allocate
            0, // stride - auto-calculate
        );
        if (handle == null) {
            return Error.BitmapCreationFailed;
        }

        return .{
            .handle = handle,
            .width = width,
            .height = height,
            .stride = @intCast(l.FPDFBitmap_GetStride(handle)),
            .format = format,
        };
    }

    /// Destroy the bitmap and release resources
    pub fn destroy(self: *Bitmap) void {
        if (self.handle != null) {
            if (lib) |l| {
                l.FPDFBitmap_Destroy(self.handle);
            }
            self.handle = null;
        }
    }

    /// Fill a rectangle with a color (ARGB format: 0xAARRGGBB)
    pub fn fillRect(self: *Bitmap, left: u32, top: u32, width: u32, height: u32, color: u32) void {
        const l = lib orelse return;
        _ = l.FPDFBitmap_FillRect(
            self.handle,
            @intCast(left),
            @intCast(top),
            @intCast(width),
            @intCast(height),
            @as(loader.FPDF_DWORD, color),
        );
    }

    /// Fill the entire bitmap with white
    pub fn fillWhite(self: *Bitmap) void {
        self.fillRect(0, 0, self.width, self.height, 0xFFFFFFFF);
    }

    /// Get a pointer to the raw bitmap buffer
    pub fn getBuffer(self: Bitmap) ?[*]u8 {
        const l = lib orelse return null;
        const ptr = l.FPDFBitmap_GetBuffer(self.handle);
        if (ptr == null) return null;
        return @ptrCast(ptr);
    }

    /// Get the bitmap data as a slice
    pub fn getData(self: Bitmap) ?[]u8 {
        const buffer = self.getBuffer() orelse return null;
        const total_size = self.stride * self.height;
        return buffer[0..total_size];
    }

    /// Get bytes per pixel for this bitmap format
    pub fn getBytesPerPixel(self: Bitmap) u32 {
        return switch (self.format) {
            .gray => 1,
            .bgr => 3,
            .bgrx, .bgra => 4,
        };
    }
};
