//! Zig bindings for PDFium library
//! Provides idiomatic Zig wrappers around the PDFium C API

const std = @import("std");
const c = @cImport({
    @cInclude("fpdfview.h");
    @cInclude("fpdf_text.h");
    @cInclude("fpdf_doc.h");
    @cInclude("fpdf_edit.h");
});

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
pub fn init() void {
    c.FPDF_InitLibrary();
}

/// Deinitialize the PDFium library. Should be called when done with PDFium.
pub fn deinit() void {
    c.FPDF_DestroyLibrary();
}

/// Get the last error code from PDFium
fn getLastError() Error {
    return switch (c.FPDF_GetLastError()) {
        c.FPDF_ERR_SUCCESS => Error.Unknown,
        c.FPDF_ERR_UNKNOWN => Error.Unknown,
        c.FPDF_ERR_FILE => Error.FileNotFound,
        c.FPDF_ERR_FORMAT => Error.InvalidFormat,
        c.FPDF_ERR_PASSWORD => Error.PasswordRequired,
        c.FPDF_ERR_SECURITY => Error.UnsupportedSecurity,
        c.FPDF_ERR_PAGE => Error.PageNotFound,
        else => Error.Unknown,
    };
}

/// A PDF document handle
pub const Document = struct {
    handle: c.FPDF_DOCUMENT,

    /// Open a PDF document from a file path
    pub fn open(path: []const u8) Error!Document {
        // Create null-terminated path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_buf.len) return Error.FileNotFound;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const handle = c.FPDF_LoadDocument(&path_buf, null);
        if (handle == null) {
            return getLastError();
        }
        return .{ .handle = handle };
    }

    /// Open a password-protected PDF document
    pub fn openWithPassword(path: []const u8, password: []const u8) Error!Document {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_buf.len) return Error.FileNotFound;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        var pass_buf: [256]u8 = undefined;
        if (password.len >= pass_buf.len) return Error.PasswordRequired;
        @memcpy(pass_buf[0..password.len], password);
        pass_buf[password.len] = 0;

        const handle = c.FPDF_LoadDocument(&path_buf, &pass_buf);
        if (handle == null) {
            return getLastError();
        }
        return .{ .handle = handle };
    }

    /// Close the document and release resources
    pub fn close(self: *Document) void {
        if (self.handle != null) {
            c.FPDF_CloseDocument(self.handle);
            self.handle = null;
        }
    }

    /// Get the total number of pages in the document
    pub fn getPageCount(self: Document) u32 {
        const count = c.FPDF_GetPageCount(self.handle);
        return if (count < 0) 0 else @intCast(count);
    }

    /// Load a page by index (0-based)
    pub fn loadPage(self: Document, page_index: u32) Error!Page {
        const handle = c.FPDF_LoadPage(self.handle, @intCast(page_index));
        if (handle == null) {
            return getLastError();
        }
        return .{ .handle = handle };
    }

    /// Get the PDF file version (e.g., 14 for PDF 1.4, 17 for PDF 1.7)
    pub fn getFileVersion(self: Document) ?u32 {
        var version: c_int = 0;
        if (c.FPDF_GetFileVersion(self.handle, &version) != 0) {
            return @intCast(version);
        }
        return null;
    }

    /// Get document permissions flags
    pub fn getPermissions(self: Document) u32 {
        return @intCast(c.FPDF_GetDocPermissions(self.handle));
    }

    /// Get the security handler revision (-1 if not protected)
    pub fn getSecurityHandlerRevision(self: Document) i32 {
        return @intCast(c.FPDF_GetSecurityHandlerRevision(self.handle));
    }

    /// Check if the document is encrypted/password-protected
    pub fn isEncrypted(self: Document) bool {
        return self.getSecurityHandlerRevision() >= 0;
    }

    /// Get metadata value by tag name
    /// Valid tags: Title, Author, Subject, Keywords, Creator, Producer, CreationDate, ModDate
    pub fn getMetaText(self: Document, allocator: std.mem.Allocator, tag: []const u8) ?[]u8 {
        var tag_buf: [64]u8 = undefined;
        if (tag.len >= tag_buf.len) return null;
        @memcpy(tag_buf[0..tag.len], tag);
        tag_buf[tag.len] = 0;

        // First call to get required buffer size
        const required_len = c.FPDF_GetMetaText(self.handle, &tag_buf, null, 0);
        if (required_len <= 2) return null; // Empty string (just null terminator)

        // Allocate buffer for UTF-16LE data
        const utf16_buf = allocator.alloc(u16, required_len / 2) catch return null;
        defer allocator.free(utf16_buf);

        _ = c.FPDF_GetMetaText(self.handle, &tag_buf, utf16_buf.ptr, required_len);

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
};

/// A PDF page handle
pub const Page = struct {
    handle: c.FPDF_PAGE,

    /// Close the page and release resources
    pub fn close(self: *Page) void {
        if (self.handle != null) {
            c.FPDF_ClosePage(self.handle);
            self.handle = null;
        }
    }

    /// Get page width in PDF points (1 point = 1/72 inch)
    pub fn getWidth(self: Page) f64 {
        return c.FPDF_GetPageWidth(self.handle);
    }

    /// Get page height in PDF points (1 point = 1/72 inch)
    pub fn getHeight(self: Page) f64 {
        return c.FPDF_GetPageHeight(self.handle);
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
        c.FPDF_RenderPageBitmap(
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
        const handle = c.FPDFText_LoadPage(self.handle);
        if (handle == null) return null;
        return .{ .handle = handle };
    }

    /// Get the number of objects on this page
    pub fn getObjectCount(self: Page) u32 {
        const count = c.FPDFPage_CountObjects(self.handle);
        return if (count < 0) 0 else @intCast(count);
    }

    /// Get a page object by index
    pub fn getObject(self: Page, index: u32) ?PageObject {
        const handle = c.FPDFPage_GetObject(self.handle, @intCast(index));
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
    handle: c.FPDF_PAGEOBJECT,

    /// Get the type of this page object
    pub fn getType(self: PageObject) PageObjectType {
        const obj_type = c.FPDFPageObj_GetType(self.handle);
        return @enumFromInt(obj_type);
    }
};

/// An image object on a page
pub const ImageObject = struct {
    handle: c.FPDF_PAGEOBJECT,
    page: Page,

    /// Get the pixel dimensions of the image
    pub fn getPixelSize(self: ImageObject) ?struct { width: u32, height: u32 } {
        var width: c_uint = 0;
        var height: c_uint = 0;
        if (c.FPDFImageObj_GetImagePixelSize(self.handle, &width, &height) != 0) {
            return .{ .width = width, .height = height };
        }
        return null;
    }

    /// Get the rendered bitmap of this image (includes masks and transforms)
    pub fn getRenderedBitmap(self: ImageObject, document: Document) ?Bitmap {
        const bmp_handle = c.FPDFImageObj_GetRenderedBitmap(
            document.handle,
            self.page.handle,
            self.handle,
        );
        if (bmp_handle == null) return null;

        const width: u32 = @intCast(c.FPDFBitmap_GetWidth(bmp_handle));
        const height: u32 = @intCast(c.FPDFBitmap_GetHeight(bmp_handle));
        const stride: u32 = @intCast(c.FPDFBitmap_GetStride(bmp_handle));
        const format_int = c.FPDFBitmap_GetFormat(bmp_handle);

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
        const bmp_handle = c.FPDFImageObj_GetBitmap(self.handle);
        if (bmp_handle == null) return null;

        const width: u32 = @intCast(c.FPDFBitmap_GetWidth(bmp_handle));
        const height: u32 = @intCast(c.FPDFBitmap_GetHeight(bmp_handle));
        const stride: u32 = @intCast(c.FPDFBitmap_GetStride(bmp_handle));
        const format_int = c.FPDFBitmap_GetFormat(bmp_handle);

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
    handle: c.FPDF_TEXTPAGE,

    /// Close the text page and release resources
    pub fn close(self: *TextPage) void {
        if (self.handle != null) {
            c.FPDFText_ClosePage(self.handle);
            self.handle = null;
        }
    }

    /// Get the number of characters in the page
    pub fn getCharCount(self: TextPage) u32 {
        const count = c.FPDFText_CountChars(self.handle);
        return if (count < 0) 0 else @intCast(count);
    }

    /// Extract all text from the page as UTF-8
    pub fn getText(self: TextPage, allocator: std.mem.Allocator) ?[]u8 {
        const char_count = self.getCharCount();
        if (char_count == 0) return null;

        // Allocate buffer for UTF-16LE data (char_count + 1 for null terminator)
        const utf16_buf = allocator.alloc(u16, char_count + 1) catch return null;
        defer allocator.free(utf16_buf);

        const written = c.FPDFText_GetText(self.handle, 0, @intCast(char_count), utf16_buf.ptr);
        if (written <= 0) return null;

        // Convert UTF-16LE to UTF-8 (exclude null terminator)
        const actual_len: usize = @intCast(written - 1);
        return utf16LeToUtf8(allocator, utf16_buf[0..actual_len]);
    }

    /// Get Unicode value of a character at index
    pub fn getCharUnicode(self: TextPage, index: u32) u32 {
        return c.FPDFText_GetUnicode(self.handle, @intCast(index));
    }

    /// Get font size of a character at index (in points)
    pub fn getCharFontSize(self: TextPage, index: u32) f64 {
        return c.FPDFText_GetFontSize(self.handle, @intCast(index));
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
        if (self.annotations) flags |= c.FPDF_ANNOT;
        if (self.lcd_text) flags |= c.FPDF_LCD_TEXT;
        if (self.no_native_text) flags |= c.FPDF_NO_NATIVETEXT;
        if (self.grayscale) flags |= c.FPDF_GRAYSCALE;
        if (self.debug_info) flags |= c.FPDF_DEBUG_INFO;
        if (self.no_catch) flags |= c.FPDF_NO_CATCH;
        if (self.render_limited_image_cache) flags |= c.FPDF_RENDER_LIMITEDIMAGECACHE;
        if (self.render_force_halftone) flags |= c.FPDF_RENDER_FORCEHALFTONE;
        if (self.printing) flags |= c.FPDF_PRINTING;
        if (self.reverse_byte_order) flags |= c.FPDF_REVERSE_BYTE_ORDER;
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
    handle: c.FPDF_BITMAP,
    width: u32,
    height: u32,
    stride: u32,
    format: BitmapFormat,

    /// Create a new bitmap
    pub fn create(width: u32, height: u32, format: BitmapFormat) Error!Bitmap {
        const alpha: c_int = if (format == .bgra) 1 else 0;
        const handle = c.FPDFBitmap_CreateEx(
            @intCast(width),
            @intCast(height),
            @intFromEnum(format),
            null, // external buffer - let PDFium allocate
            0, // stride - auto-calculate
        );
        if (handle == null) {
            return Error.BitmapCreationFailed;
        }

        _ = alpha;

        return .{
            .handle = handle,
            .width = width,
            .height = height,
            .stride = @intCast(c.FPDFBitmap_GetStride(handle)),
            .format = format,
        };
    }

    /// Destroy the bitmap and release resources
    pub fn destroy(self: *Bitmap) void {
        if (self.handle != null) {
            c.FPDFBitmap_Destroy(self.handle);
            self.handle = null;
        }
    }

    /// Fill a rectangle with a color (ARGB format: 0xAARRGGBB)
    pub fn fillRect(self: *Bitmap, left: u32, top: u32, width: u32, height: u32, color: u32) void {
        _ = c.FPDFBitmap_FillRect(
            self.handle,
            @intCast(left),
            @intCast(top),
            @intCast(width),
            @intCast(height),
            @as(c.FPDF_DWORD, color),
        );
    }

    /// Fill the entire bitmap with white
    pub fn fillWhite(self: *Bitmap) void {
        self.fillRect(0, 0, self.width, self.height, 0xFFFFFFFF);
    }

    /// Get a pointer to the raw bitmap buffer
    pub fn getBuffer(self: Bitmap) ?[*]u8 {
        const ptr = c.FPDFBitmap_GetBuffer(self.handle);
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
