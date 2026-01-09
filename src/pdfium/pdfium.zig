//! Zig bindings for PDFium library
//! Provides idiomatic Zig wrappers around the PDFium C API
//! Uses runtime dynamic loading instead of build-time linking

const std = @import("std");
const loader = @import("loader.zig");
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

/// Initialize from a specific library path
pub fn initWithPath(path: []const u8) Error!void {
    if (lib != null) return; // Already initialized

    lib = loader.PdfiumLib.load(path) catch {
        return Error.LibraryLoadFailed;
    };
    lib.?.FPDF_InitLibrary();
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
    _ = downloader.downloadPdfiumWithProgress(allocator, null, exe_dir, downloader.displayProgress) catch {
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

/// Get the loaded library version (Chrome version number)
pub fn getVersion() ?u32 {
    if (lib) |l| {
        return l.version;
    }
    return null;
}

/// Get the path to the loaded library
pub fn getLibraryPath() ?[]const u8 {
    return lib_path;
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

    /// Create a new empty PDF document
    pub fn createNew() Error!Document {
        const l = lib orelse return Error.LibraryNotLoaded;
        const handle = l.FPDF_CreateNewDocument();
        if (handle == null) {
            return Error.Unknown;
        }
        return .{ .handle = handle };
    }

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

    /// Import pages from another document
    /// page_indices: array of 0-based page indices to import, or null to import all pages
    /// insert_index: 0-based index where to insert pages in this document
    pub fn importPages(self: *Document, src_doc: *Document, page_indices: ?[]const c_int, insert_index: u32) bool {
        const l = lib orelse return false;
        if (page_indices) |indices| {
            return l.FPDF_ImportPagesByIndex(
                self.handle,
                src_doc.handle,
                indices.ptr,
                @intCast(indices.len),
                @intCast(insert_index),
            ) != 0;
        } else {
            // Import all pages
            return l.FPDF_ImportPages(
                self.handle,
                src_doc.handle,
                null,
                @intCast(insert_index),
            ) != 0;
        }
    }

    /// Import a range of pages from another document using a page range string
    /// page_range: e.g., "1-3,5,7-9" (1-based), or null for all pages
    /// insert_index: 0-based index where to insert pages in this document
    pub fn importPagesRange(self: *Document, src_doc: *Document, page_range: ?[]const u8, insert_index: u32) bool {
        const l = lib orelse return false;
        if (page_range) |range| {
            var range_buf: [256]u8 = undefined;
            if (range.len >= range_buf.len) return false;
            @memcpy(range_buf[0..range.len], range);
            range_buf[range.len] = 0;
            return l.FPDF_ImportPages(
                self.handle,
                src_doc.handle,
                &range_buf,
                @intCast(insert_index),
            ) != 0;
        } else {
            return l.FPDF_ImportPages(
                self.handle,
                src_doc.handle,
                null,
                @intCast(insert_index),
            ) != 0;
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

    /// Add an attachment to the document
    /// The name should be the filename (will be converted to UTF-16LE)
    pub fn addAttachment(self: Document, allocator: std.mem.Allocator, name: []const u8, content: []const u8) Error!void {
        const l = lib orelse return Error.LibraryNotLoaded;

        // Convert name to UTF-16LE with null terminator
        var name_utf16 = std.array_list.Managed(u16).init(allocator);
        defer name_utf16.deinit();

        for (name) |byte| {
            name_utf16.append(@as(u16, byte)) catch return Error.Unknown;
        }
        name_utf16.append(0) catch return Error.Unknown; // Null terminator

        // Add the attachment
        const attachment = l.FPDFDoc_AddAttachment(self.handle, name_utf16.items.ptr);
        if (attachment == null) {
            return Error.Unknown;
        }

        // Set the file content
        if (l.FPDFAttachment_SetFile(attachment, self.handle, content.ptr, @intCast(content.len)) == 0) {
            return Error.Unknown;
        }
    }

    /// Delete an attachment by index (0-indexed)
    pub fn deleteAttachment(self: Document, index: u32) Error!void {
        const l = lib orelse return Error.LibraryNotLoaded;
        const count = self.getAttachmentCount();
        if (index >= count) {
            return Error.Unknown;
        }
        if (l.FPDFDoc_DeleteAttachment(self.handle, @intCast(index)) == 0) {
            return Error.Unknown;
        }
    }

    /// Delete a page from the document (0-indexed)
    pub fn deletePage(self: Document, page_index: u32) Error!void {
        const l = lib orelse return Error.LibraryNotLoaded;
        const page_count = self.getPageCount();
        if (page_index >= page_count) {
            return Error.PageNotFound;
        }
        l.FPDFPage_Delete(self.handle, @intCast(page_index));
    }

    /// Create a new page at the specified index
    /// Returns a Page handle that must be closed when done
    pub fn createPage(self: Document, page_index: u32, width: f64, height: f64) Error!Page {
        const l = lib orelse return Error.LibraryNotLoaded;
        const handle = l.FPDFPage_New(self.handle, @intCast(page_index), width, height);
        if (handle == null) {
            return Error.Unknown;
        }
        return .{ .handle = handle };
    }

    /// Create an image object for this document
    pub fn createImageObject(self: Document) Error!PageObject {
        const l = lib orelse return Error.LibraryNotLoaded;
        const handle = l.FPDFPageObj_NewImageObj(self.handle);
        if (handle == null) {
            return Error.Unknown;
        }
        return .{ .handle = handle };
    }

    /// Create a text object for this document using a standard font
    /// Standard fonts: Courier, Courier-Bold, Courier-BoldOblique, Courier-Oblique,
    /// Helvetica, Helvetica-Bold, Helvetica-BoldOblique, Helvetica-Oblique,
    /// Times-Roman, Times-Bold, Times-BoldItalic, Times-Italic, Symbol, ZapfDingbats
    pub fn createTextObject(self: Document, font_name: []const u8, font_size: f32) Error!PageObject {
        const l = lib orelse return Error.LibraryNotLoaded;
        const handle = l.FPDFPageObj_NewTextObj(self.handle, font_name.ptr, font_size);
        if (handle == null) {
            return Error.Unknown;
        }
        return .{ .handle = handle };
    }

    /// Save the document to a file
    pub fn save(self: Document, path: []const u8) Error!void {
        const l = lib orelse return Error.LibraryNotLoaded;

        // Open file for writing
        const file = std.fs.cwd().createFile(path, .{}) catch return Error.FileNotFound;
        defer file.close();

        // Create file write context with FPDF_FILEWRITE as first field
        const FileWriteContext = struct {
            fw: loader.FPDF_FILEWRITE,
            file: std.fs.File,

            fn writeBlock(pThis: *loader.FPDF_FILEWRITE, pData: ?*const anyopaque, size: c_ulong) callconv(.c) c_int {
                const ctx: *@This() = @fieldParentPtr("fw", pThis);
                const data: [*]const u8 = @ptrCast(pData orelse return 0);
                ctx.file.writeAll(data[0..size]) catch return 0;
                return 1; // Success
            }
        };

        var ctx = FileWriteContext{
            .fw = .{
                .version = 1,
                .WriteBlock = FileWriteContext.writeBlock,
            },
            .file = file,
        };

        if (l.FPDF_SaveAsCopy(self.handle, &ctx.fw, 0) == 0) {
            return Error.Unknown;
        }
    }

    /// Save the document to a file, preserving the original PDF version
    pub fn saveWithVersion(self: Document, path: []const u8, version: ?u32) Error!void {
        const l = lib orelse return Error.LibraryNotLoaded;

        // Get current version if not specified
        const file_version: c_int = if (version) |v| @intCast(v) else @intCast(self.getFileVersion() orelse 17);

        // Open file for writing
        const file = std.fs.cwd().createFile(path, .{}) catch return Error.FileNotFound;
        defer file.close();

        const FileWriteContext = struct {
            fw: loader.FPDF_FILEWRITE,
            file: std.fs.File,

            fn writeBlock(pThis: *loader.FPDF_FILEWRITE, pData: ?*const anyopaque, size: c_ulong) callconv(.c) c_int {
                const ctx: *@This() = @fieldParentPtr("fw", pThis);
                const data: [*]const u8 = @ptrCast(pData orelse return 0);
                ctx.file.writeAll(data[0..size]) catch return 0;
                return 1;
            }
        };

        var ctx = FileWriteContext{
            .fw = .{
                .version = 1,
                .WriteBlock = FileWriteContext.writeBlock,
            },
            .file = file,
        };

        if (l.FPDF_SaveWithVersion(self.handle, &ctx.fw, 0, file_version) == 0) {
            return Error.Unknown;
        }
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

    /// Render page with transformation matrix and clipping rectangle
    /// This is non-destructive - the page is rendered with the matrix applied
    /// but the page itself is not modified
    pub fn renderWithMatrix(
        self: Page,
        bitmap: *Bitmap,
        matrix: loader.FS_MATRIX,
        clipping: loader.FS_RECTF,
        flags: RenderFlags,
    ) void {
        const l = lib orelse return;
        l.FPDF_RenderPageBitmapWithMatrix(
            bitmap.handle,
            self.handle,
            &matrix,
            &clipping,
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

    /// Rotation values: 0=0°, 1=90°, 2=180°, 3=270° (clockwise)
    pub const Rotation = enum(c_int) {
        none = 0,
        cw90 = 1,
        cw180 = 2,
        cw270 = 3,

        /// Convert degrees to rotation enum
        pub fn fromDegrees(degrees: i32) ?Rotation {
            const normalized = @mod(degrees, 360);
            return switch (normalized) {
                0 => .none,
                90, -270 => .cw90,
                180, -180 => .cw180,
                270, -90 => .cw270,
                else => null,
            };
        }

        /// Convert rotation to degrees
        pub fn toDegrees(self: Rotation) i32 {
            return switch (self) {
                .none => 0,
                .cw90 => 90,
                .cw180 => 180,
                .cw270 => 270,
            };
        }

        /// Add rotation (clockwise)
        pub fn add(self: Rotation, other: Rotation) Rotation {
            const sum = @intFromEnum(self) + @intFromEnum(other);
            return @enumFromInt(@mod(sum, 4));
        }
    };

    /// Get current page rotation
    pub fn getRotation(self: Page) Rotation {
        const l = lib orelse return .none;
        const rot = l.FPDFPage_GetRotation(self.handle);
        return if (rot >= 0 and rot <= 3) @enumFromInt(rot) else .none;
    }

    /// Set page rotation (0=0°, 1=90°, 2=180°, 3=270° clockwise)
    pub fn setRotation(self: Page, rotation: Rotation) bool {
        const l = lib orelse return false;
        l.FPDFPage_SetRotation(self.handle, @intFromEnum(rotation));
        return true;
    }

    /// Set page media box (bounding box for page content)
    pub fn setMediaBox(self: Page, left: f64, bottom: f64, right: f64, top: f64) bool {
        const l = lib orelse return false;
        l.FPDFPage_SetMediaBox(
            self.handle,
            @floatCast(left),
            @floatCast(bottom),
            @floatCast(right),
            @floatCast(top),
        );
        return true;
    }

    /// Get page crop box (visible/printable region)
    /// Returns null if crop box is not defined for this page
    pub fn getCropBox(self: Page) ?struct { left: f64, bottom: f64, right: f64, top: f64 } {
        const l = lib orelse return null;
        var left: f32 = 0;
        var bottom: f32 = 0;
        var right: f32 = 0;
        var top: f32 = 0;
        if (l.FPDFPage_GetCropBox(self.handle, &left, &bottom, &right, &top) == 0) {
            return null;
        }
        return .{
            .left = left,
            .bottom = bottom,
            .right = right,
            .top = top,
        };
    }

    /// Set page crop box (visible/printable region)
    pub fn setCropBox(self: Page, left: f64, bottom: f64, right: f64, top: f64) void {
        const l = lib orelse return;
        l.FPDFPage_SetCropBox(
            self.handle,
            @floatCast(left),
            @floatCast(bottom),
            @floatCast(right),
            @floatCast(top),
        );
    }

    /// Rotate page by additional degrees (must be multiple of 90)
    pub fn rotate(self: Page, degrees: i32) bool {
        const delta = Rotation.fromDegrees(degrees) orelse return false;
        const current = self.getRotation();
        return self.setRotation(current.add(delta));
    }

    /// Insert a page object into this page
    /// Note: The page object will be owned by the page after insertion
    pub fn insertObject(self: Page, obj: PageObject) void {
        const l = lib orelse return;
        l.FPDFPage_InsertObject(self.handle, obj.handle);
    }

    /// Generate content - must be called before saving after modifications
    pub fn generateContent(self: Page) bool {
        const l = lib orelse return false;
        return l.FPDFPage_GenerateContent(self.handle) != 0;
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

    /// Set the bitmap for an image object
    pub fn setBitmap(self: PageObject, bitmap: Bitmap) bool {
        const l = lib orelse return false;
        return l.FPDFImageObj_SetBitmap(null, 0, self.handle, bitmap.handle) != 0;
    }

    /// Set the transformation matrix for an image object
    /// Matrix: [a b 0; c d 0; e f 1] where (e, f) is translation
    /// For scaling an image to (width, height) at position (x, y):
    /// a=width, b=0, c=0, d=height, e=x, f=y
    pub fn setImageMatrix(self: PageObject, width: f64, height: f64, x: f64, y: f64) bool {
        const l = lib orelse return false;
        return l.FPDFImageObj_SetMatrix(self.handle, width, 0, 0, height, x, y) != 0;
    }

    /// Transform the page object with a general matrix
    /// Matrix: [a b 0; c d 0; e f 1]
    pub fn transform(self: PageObject, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
        const l = lib orelse return;
        l.FPDFPageObj_Transform(self.handle, a, b, c, d, e, f);
    }

    /// Set text content for a text object (UTF-16LE encoded)
    pub fn setText(self: PageObject, text_utf16: []const u16) bool {
        const l = lib orelse return false;
        return l.FPDFText_SetText(self.handle, text_utf16.ptr) != 0;
    }

    /// Set fill color for a page object (used for text color)
    pub fn setFillColor(self: PageObject, r: u8, g: u8, b: u8, a: u8) bool {
        const l = lib orelse return false;
        return l.FPDFPageObj_SetFillColor(self.handle, r, g, b, a) != 0;
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

    /// Character bounding box in PDF coordinates
    pub const CharBox = struct {
        left: f64,
        right: f64,
        bottom: f64,
        top: f64,
    };

    /// Get the bounding box of a character at index
    pub fn getCharBox(self: TextPage, index: u32) ?CharBox {
        const l = lib orelse return null;
        var left: f64 = 0;
        var right: f64 = 0;
        var bottom: f64 = 0;
        var top: f64 = 0;
        if (l.FPDFText_GetCharBox(self.handle, @intCast(index), &left, &right, &bottom, &top) != 0) {
            return .{ .left = left, .right = right, .bottom = bottom, .top = top };
        }
        return null;
    }

    /// Get the origin (x, y) of a character at index
    pub fn getCharOrigin(self: TextPage, index: u32) ?struct { x: f64, y: f64 } {
        const l = lib orelse return null;
        var x: f64 = 0;
        var y: f64 = 0;
        if (l.FPDFText_GetCharOrigin(self.handle, @intCast(index), &x, &y) != 0) {
            return .{ .x = x, .y = y };
        }
        return null;
    }

    /// Font descriptor flags (from PDF spec)
    pub const FontFlags = struct {
        raw: c_int,

        pub fn isFixedPitch(self: FontFlags) bool {
            return (self.raw & 0x1) != 0;
        }
        pub fn isSerif(self: FontFlags) bool {
            return (self.raw & 0x2) != 0;
        }
        pub fn isSymbolic(self: FontFlags) bool {
            return (self.raw & 0x4) != 0;
        }
        pub fn isScript(self: FontFlags) bool {
            return (self.raw & 0x8) != 0;
        }
        pub fn isItalic(self: FontFlags) bool {
            return (self.raw & 0x40) != 0;
        }
        pub fn isForceBold(self: FontFlags) bool {
            return (self.raw & 0x40000) != 0;
        }
    };

    /// Font information for a character
    pub const FontInfo = struct {
        name: []u8,
        flags: FontFlags,
    };

    /// Get font information for a character at index
    /// Caller owns the returned font name string
    pub fn getCharFontInfo(self: TextPage, allocator: std.mem.Allocator, index: u32) ?FontInfo {
        const l = lib orelse return null;

        // First call to get required buffer size
        var flags: c_int = 0;
        const required_len = l.FPDFText_GetFontInfo(self.handle, @intCast(index), null, 0, &flags);
        if (required_len == 0) return null;

        // Allocate buffer and get font name
        const buffer = allocator.alloc(u8, required_len) catch return null;
        const actual_len = l.FPDFText_GetFontInfo(self.handle, @intCast(index), buffer.ptr, required_len, &flags);
        if (actual_len == 0) {
            allocator.free(buffer);
            return null;
        }

        // Remove null terminator if present
        const name_len = if (actual_len > 0 and buffer[actual_len - 1] == 0) actual_len - 1 else actual_len;

        return .{
            .name = buffer[0..name_len],
            .flags = .{ .raw = flags },
        };
    }

    /// Get font weight of a character (100-900, 400=normal, 700=bold)
    /// Returns -1 on error
    pub fn getCharFontWeight(self: TextPage, index: u32) i32 {
        const l = lib orelse return -1;
        return l.FPDFText_GetFontWeight(self.handle, @intCast(index));
    }

    /// RGBA color
    pub const Color = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    /// Get fill color of a character at index
    pub fn getCharFillColor(self: TextPage, index: u32) ?Color {
        const l = lib orelse return null;
        var r: c_uint = 0;
        var g: c_uint = 0;
        var b: c_uint = 0;
        var a: c_uint = 0;
        if (l.FPDFText_GetFillColor(self.handle, @intCast(index), &r, &g, &b, &a) != 0) {
            return .{
                .r = @intCast(r),
                .g = @intCast(g),
                .b = @intCast(b),
                .a = @intCast(a),
            };
        }
        return null;
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

// ============================================================================
// Tests (functions that don't require PDFium library)
// ============================================================================

test "Page.Rotation.fromDegrees" {
    try std.testing.expectEqual(Page.Rotation.none, Page.Rotation.fromDegrees(0).?);
    try std.testing.expectEqual(Page.Rotation.cw90, Page.Rotation.fromDegrees(90).?);
    try std.testing.expectEqual(Page.Rotation.cw180, Page.Rotation.fromDegrees(180).?);
    try std.testing.expectEqual(Page.Rotation.cw270, Page.Rotation.fromDegrees(270).?);
    try std.testing.expectEqual(Page.Rotation.none, Page.Rotation.fromDegrees(360).?);
    try std.testing.expectEqual(Page.Rotation.cw90, Page.Rotation.fromDegrees(450).?);
    try std.testing.expect(Page.Rotation.fromDegrees(45) == null);
    try std.testing.expect(Page.Rotation.fromDegrees(15) == null);
}

test "Page.Rotation.toDegrees" {
    try std.testing.expectEqual(@as(i32, 0), Page.Rotation.none.toDegrees());
    try std.testing.expectEqual(@as(i32, 90), Page.Rotation.cw90.toDegrees());
    try std.testing.expectEqual(@as(i32, 180), Page.Rotation.cw180.toDegrees());
    try std.testing.expectEqual(@as(i32, 270), Page.Rotation.cw270.toDegrees());
}

test "Page.Rotation.add" {
    try std.testing.expectEqual(Page.Rotation.cw90, Page.Rotation.none.add(.cw90));
    try std.testing.expectEqual(Page.Rotation.cw180, Page.Rotation.cw90.add(.cw90));
    try std.testing.expectEqual(Page.Rotation.cw270, Page.Rotation.cw180.add(.cw90));
    try std.testing.expectEqual(Page.Rotation.none, Page.Rotation.cw270.add(.cw90));
    try std.testing.expectEqual(Page.Rotation.none, Page.Rotation.cw180.add(.cw180));
}

test "RenderFlags.toInt" {
    // Default flags (only annotations enabled)
    const default_flags = RenderFlags{};
    try std.testing.expectEqual(loader.FPDF_ANNOT, default_flags.toInt());

    // No flags
    const no_flags = RenderFlags{ .annotations = false };
    try std.testing.expectEqual(@as(c_int, 0), no_flags.toInt());

    // Multiple flags
    const multi_flags = RenderFlags{
        .annotations = true,
        .lcd_text = true,
        .grayscale = true,
    };
    const expected = loader.FPDF_ANNOT | loader.FPDF_LCD_TEXT | loader.FPDF_GRAYSCALE;
    try std.testing.expectEqual(expected, multi_flags.toInt());

    // Printing flag
    const print_flags = RenderFlags{ .annotations = false, .printing = true };
    try std.testing.expectEqual(loader.FPDF_PRINTING, print_flags.toInt());
}

test "BitmapFormat values" {
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(BitmapFormat.gray));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(BitmapFormat.bgr));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(BitmapFormat.bgrx));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(BitmapFormat.bgra));
}

test "PageObjectType values" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(PageObjectType.unknown));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(PageObjectType.text));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(PageObjectType.path));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(PageObjectType.image));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(PageObjectType.shading));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(PageObjectType.form));
}

test "TextPage.FontFlags methods" {
    // Test individual flag bits
    const fixed_pitch = TextPage.FontFlags{ .raw = 0x1 };
    try std.testing.expect(fixed_pitch.isFixedPitch());
    try std.testing.expect(!fixed_pitch.isSerif());

    const serif = TextPage.FontFlags{ .raw = 0x2 };
    try std.testing.expect(serif.isSerif());
    try std.testing.expect(!serif.isFixedPitch());

    const symbolic = TextPage.FontFlags{ .raw = 0x4 };
    try std.testing.expect(symbolic.isSymbolic());

    const script = TextPage.FontFlags{ .raw = 0x8 };
    try std.testing.expect(script.isScript());

    const italic = TextPage.FontFlags{ .raw = 0x40 };
    try std.testing.expect(italic.isItalic());
    try std.testing.expect(!italic.isForceBold());

    const force_bold = TextPage.FontFlags{ .raw = 0x40000 };
    try std.testing.expect(force_bold.isForceBold());
    try std.testing.expect(!force_bold.isItalic());

    // Test combined flags
    const combined = TextPage.FontFlags{ .raw = 0x43 }; // fixed pitch + serif + italic
    try std.testing.expect(combined.isFixedPitch());
    try std.testing.expect(combined.isSerif());
    try std.testing.expect(combined.isItalic());
    try std.testing.expect(!combined.isSymbolic());

    // Test zero flags
    const none = TextPage.FontFlags{ .raw = 0 };
    try std.testing.expect(!none.isFixedPitch());
    try std.testing.expect(!none.isSerif());
    try std.testing.expect(!none.isSymbolic());
    try std.testing.expect(!none.isScript());
    try std.testing.expect(!none.isItalic());
    try std.testing.expect(!none.isForceBold());
}
