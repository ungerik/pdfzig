//! State management for the WebUI server
//! Handles documents, pages, modifications, and caching

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");

/// Unique identifier for a page within the global state
pub const PageId = struct {
    doc_id: u32,
    page_num: u32, // 0-based internal index

    /// Encode doc_id and page_num into a single u64 for use in URLs/IDs
    pub fn toGlobalId(self: PageId) u64 {
        return (@as(u64, self.doc_id) << 32) | self.page_num;
    }

    /// Decode a global ID back into doc_id and page_num
    pub fn fromGlobalId(global_id: u64) PageId {
        return .{
            .doc_id = @intCast(global_id >> 32),
            .page_num = @intCast(global_id & 0xFFFFFFFF),
        };
    }

    /// Format as string for URL paths (e.g., "1-0" for doc 1, page 0)
    pub fn format(
        self: PageId,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{d}-{d}", .{ self.doc_id, self.page_num });
    }

    /// Parse from string format "doc_id-page_num"
    pub fn parse(str: []const u8) !PageId {
        var iter = std.mem.splitScalar(u8, str, '-');
        const doc_str = iter.next() orelse return error.InvalidFormat;
        const page_str = iter.next() orelse return error.InvalidFormat;
        if (iter.next() != null) return error.InvalidFormat;

        return .{
            .doc_id = try std.fmt.parseInt(u32, doc_str, 10),
            .page_num = try std.fmt.parseInt(u32, page_str, 10),
        };
    }
};

/// Track cumulative modifications to a page
pub const PageModification = struct {
    rotation: i32 = 0, // cumulative rotation in degrees (0, 90, 180, 270)
    mirror_lr: bool = false, // left-right mirror (horizontal flip)
    mirror_ud: bool = false, // up-down mirror (vertical flip)
    deleted: bool = false, // marked for deletion

    /// Check if page has any modifications
    pub fn isEmpty(self: PageModification) bool {
        return self.rotation == 0 and !self.mirror_lr and !self.mirror_ud and !self.deleted;
    }

    /// Get user-friendly description of modifications
    pub fn describe(self: PageModification, allocator: std.mem.Allocator) ![]const u8 {
        // Use arena allocator for temporary strings
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp_alloc = arena.allocator();

        var parts = std.array_list.Managed([]const u8).init(temp_alloc);

        if (self.rotation != 0) {
            try parts.append(try std.fmt.allocPrint(temp_alloc, "rotated {d}°", .{self.rotation}));
        }
        if (self.mirror_lr) {
            try parts.append("mirrored horizontally");
        }
        if (self.mirror_ud) {
            try parts.append("mirrored vertically");
        }
        if (self.deleted) {
            try parts.append("deleted");
        }

        if (parts.items.len == 0) {
            return try allocator.dupe(u8, "no changes");
        }

        // Join with temp allocator, then dupe with real allocator before arena dies
        const temp_result = try std.mem.join(temp_alloc, ", ", parts.items);
        return try allocator.dupe(u8, temp_result);
    }
};

/// Per-page state including modifications and cache
pub const PageState = struct {
    id: PageId,
    original_index: u32, // original position in document (0-based)
    current_index: u32, // current position after reordering (0-based)
    modifications: PageModification,
    thumbnail_cache: ?[]u8, // PNG bytes, owned by this struct
    width: f64, // page width in PDF points
    height: f64, // page height in PDF points

    pub fn deinit(self: *PageState, allocator: std.mem.Allocator) void {
        if (self.thumbnail_cache) |cache| {
            allocator.free(cache);
            self.thumbnail_cache = null;
        }
    }
};

/// Source of a document (CLI argument or uploaded via web UI)
pub const DocumentSource = enum {
    cli_loaded, // Loaded from CLI arguments (can save to disk)
    uploaded, // Uploaded via UI (in-memory only)
};

/// Per-document state
pub const DocumentState = struct {
    id: u32,
    source: DocumentSource,
    filepath: []const u8, // file path (may be temp file for uploaded PDFs)
    filename: []const u8, // display name
    doc: pdfium.Document, // in-memory PDFium document
    pages: std.array_list.Managed(PageState),
    color: [3]u8, // RGB background color for UI display
    modified: bool = false, // has any modification been made?
    original_bytes: ?[]u8, // original PDF bytes for revert, owned by this struct
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DocumentState) void {
        for (self.pages.items) |*page| {
            page.deinit(self.allocator);
        }
        self.pages.deinit();

        self.doc.close();

        if (self.original_bytes) |bytes| {
            self.allocator.free(bytes);
        }

        self.allocator.free(self.filepath);

        self.allocator.free(self.filename);
    }
};

/// Global application state
pub const GlobalState = struct {
    allocator: std.mem.Allocator,
    documents: std.array_list.Managed(*DocumentState),
    next_doc_id: u32 = 0,
    thumbnail_dpi: f64 = 72.0, // updated dynamically from client
    mutex: std.Thread.Mutex = .{}, // protects state from concurrent browser windows
    change_version: u64 = 0, // incremented on every mutation for SSE notifications

    pub fn init(allocator: std.mem.Allocator) !*GlobalState {
        const state = try allocator.create(GlobalState);
        state.* = .{
            .allocator = allocator,
            .documents = std.array_list.Managed(*DocumentState).init(allocator),
        };
        return state;
    }

    pub fn deinit(self: *GlobalState) void {
        for (self.documents.items) |doc| {
            doc.deinit();
            self.allocator.destroy(doc);
        }
        self.documents.deinit();
        self.allocator.destroy(self);
    }

    /// Lock state for mutation (acquire before any modifications)
    pub fn lock(self: *GlobalState) void {
        self.mutex.lock();
    }

    /// Unlock state after mutation
    pub fn unlock(self: *GlobalState) void {
        self.mutex.unlock();
    }

    /// Increment change version to notify other browser windows
    pub fn notifyChange(self: *GlobalState) void {
        _ = @atomicRmw(u64, &self.change_version, .Add, 1, .seq_cst);
    }

    /// Add a new document from file path
    pub fn addDocument(
        self: *GlobalState,
        source: DocumentSource,
        filepath: []const u8,
        filename: []const u8,
    ) !*DocumentState {
        self.lock();
        defer self.unlock();

        // Open PDF from file
        var doc = try pdfium.Document.open(filepath);
        errdefer doc.close();

        // Read original bytes for revert functionality
        const file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();
        const original_bytes = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024);
        errdefer self.allocator.free(original_bytes);

        // Create document state
        const doc_state = try self.allocator.create(DocumentState);
        errdefer self.allocator.destroy(doc_state);

        const doc_id = self.next_doc_id;
        self.next_doc_id += 1;

        // Allocate strings before struct initialization to avoid partial initialization leaks
        const filepath_copy = try self.allocator.dupe(u8, filepath);
        errdefer self.allocator.free(filepath_copy);
        const filename_copy = try self.allocator.dupe(u8, filename);
        errdefer self.allocator.free(filename_copy);

        doc_state.* = .{
            .id = doc_id,
            .source = source,
            .filepath = filepath_copy,
            .filename = filename_copy,
            .doc = doc,
            .pages = std.array_list.Managed(PageState).init(self.allocator),
            .color = generateDocumentColor(doc_id),
            .original_bytes = original_bytes,
            .allocator = self.allocator,
        };
        errdefer doc_state.deinit();

        // Initialize page states
        const page_count = doc.getPageCount();
        try doc_state.pages.ensureTotalCapacity(page_count);

        for (0..page_count) |i| {
            const page_index: u32 = @intCast(i);
            var page = try doc.loadPage(page_index);
            defer page.close();

            const page_state = PageState{
                .id = .{ .doc_id = doc_id, .page_num = page_index },
                .original_index = page_index,
                .current_index = page_index,
                .modifications = .{},
                .thumbnail_cache = null,
                .width = page.getWidth(),
                .height = page.getHeight(),
            };
            doc_state.pages.appendAssumeCapacity(page_state);
        }

        try self.documents.append(doc_state);
        self.notifyChange();

        return doc_state;
    }

    /// Get document by ID
    pub fn getDocument(self: *GlobalState, doc_id: u32) ?*DocumentState {
        for (self.documents.items) |doc| {
            if (doc.id == doc_id) {
                return doc;
            }
        }
        return null;
    }

    /// Get page by PageId
    pub fn getPage(self: *GlobalState, page_id: PageId) ?*PageState {
        const doc = self.getDocument(page_id.doc_id) orelse return null;
        if (page_id.page_num >= doc.pages.items.len) return null;
        return &doc.pages.items[page_id.page_num];
    }
};

/// Generate a harmonizing dark color for document background
fn generateDocumentColor(doc_id: u32) [3]u8 {
    // Color palette of harmonizing brighter colors for better contrast
    const palette = [_][3]u8{
        .{ 70, 100, 140 }, // bright blue
        .{ 120, 80, 140 }, // bright purple
        .{ 140, 70, 70 }, // bright red
        .{ 60, 130, 110 }, // bright teal
        .{ 140, 110, 60 }, // bright orange
        .{ 60, 120, 140 }, // bright cyan
        .{ 130, 70, 120 }, // bright magenta
        .{ 80, 130, 80 }, // bright green
    };

    return palette[doc_id % palette.len];
}
