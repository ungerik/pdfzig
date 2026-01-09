//! State management for the WebUI server
//! Handles documents, pages, modifications, and caching

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const matrix_mod = @import("matrix.zig");

// Re-export Matrix for use by other modules
pub const Matrix = matrix_mod.Matrix;

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

/// Single version state in page history
pub const PageVersionState = struct {
    version: u32,
    operation: []const u8, // Owned by this struct
    matrix: Matrix,
    width: f64,
    height: f64,
    deleted: bool,

    pub fn deinit(self: *PageVersionState, allocator: std.mem.Allocator) void {
        allocator.free(self.operation);
    }

    pub fn clone(self: PageVersionState, allocator: std.mem.Allocator) !PageVersionState {
        return .{
            .version = self.version,
            .operation = try allocator.dupe(u8, self.operation),
            .matrix = self.matrix,
            .width = self.width,
            .height = self.height,
            .deleted = self.deleted,
        };
    }
};

/// Track version history for a page (full operation history)
pub const PageModification = struct {
    history: std.array_list.Managed(PageVersionState),
    current_version: u32, // Index into history array
    allocator: std.mem.Allocator,

    /// Create initial state (version 0 with identity matrix)
    pub fn init(allocator: std.mem.Allocator, original_width: f64, original_height: f64) !PageModification {
        var history = std.array_list.Managed(PageVersionState).init(allocator);
        try history.append(.{
            .version = 0,
            .operation = try allocator.dupe(u8, "original"),
            .matrix = Matrix.identity,
            .width = original_width,
            .height = original_height,
            .deleted = false,
        });
        return .{
            .history = history,
            .current_version = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PageModification) void {
        for (self.history.items) |*version_state| {
            version_state.deinit(self.allocator);
        }
        self.history.deinit();
    }

    /// Get current state
    pub fn getCurrentState(self: PageModification) *PageVersionState {
        return &self.history.items[self.current_version];
    }

    /// Get current state (const version)
    pub fn getCurrentStateConst(self: *const PageModification) *const PageVersionState {
        return &self.history.items[self.current_version];
    }

    /// Add new version state
    pub fn addVersion(self: *PageModification, operation: []const u8, matrix: Matrix, width: f64, height: f64, deleted: bool) !void {
        try self.history.append(.{
            .version = @intCast(self.history.items.len),
            .operation = try self.allocator.dupe(u8, operation),
            .matrix = matrix,
            .width = width,
            .height = height,
            .deleted = deleted,
        });
        self.current_version = @intCast(self.history.items.len - 1);
    }

    /// Check if page is in original state
    pub fn isEmpty(self: *const PageModification) bool {
        return self.current_version == 0;
    }

    /// Check if transformation is identity (returns to original state)
    pub fn isIdentity(self: *const PageModification) bool {
        return self.current_version == 0;
    }

    /// Check if page has transformations that need to be baked
    /// Returns true if matrix is not identity (requires transformation)
    pub fn needsTransformation(self: *const PageModification) bool {
        return !self.getCurrentStateConst().matrix.isIdentity();
    }

    /// Reset to original state (version 0)
    pub fn reset(self: *PageModification) void {
        self.current_version = 0;
    }

    /// Describe the current modifications
    pub fn describe(self: *const PageModification, allocator: std.mem.Allocator) ![]const u8 {
        if (self.isEmpty()) {
            return try allocator.dupe(u8, "no changes");
        }

        const current_state = self.getCurrentStateConst();
        if (current_state.deleted) {
            return try allocator.dupe(u8, "deleted");
        }

        // Build description from operation history (skip version 0 which is "original")
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp_alloc = arena.allocator();

        var parts = std.array_list.Managed([]const u8).init(temp_alloc);

        for (self.history.items[1 .. self.current_version + 1]) |version_state| {
            try parts.append(version_state.operation);
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
    thumbnail_cache: ?[]u8, // PNG bytes for current state, owned by this struct
    original_thumbnail_cache: ?[]u8, // PNG bytes for original unmodified state, owned by this struct

    // Width and height are now in modifications.getCurrentState()

    pub fn deinit(self: *PageState, allocator: std.mem.Allocator) void {
        self.modifications.deinit();
        if (self.thumbnail_cache) |cache| {
            allocator.free(cache);
            self.thumbnail_cache = null;
        }
        if (self.original_thumbnail_cache) |cache| {
            allocator.free(cache);
            self.original_thumbnail_cache = null;
        }
    }
};

/// Source of a document (CLI argument or uploaded via web UI)
pub const DocumentSource = enum {
    cli_loaded, // Loaded from CLI arguments (can save to disk)
    uploaded, // Uploaded via UI (in-memory only, download-only)
};

// IMPORTANT: We keep two copies of each PDF document in memory:
//
// 1. doc_original: The original, unmodified PDF (immutable)
//    - Used to revert pages back to original state
//    - Used to generate original thumbnail cache
//    - Never modified, only read
//
// 2. doc: The working copy with transformations applied
//    - All page transformations are applied to this copy
//    - Used to render current state thumbnails
//    - Used to generate download/save output
//
// Source tracking (DocumentSource enum):
//    - cli_loaded: Loaded from filesystem, can save back to source path
//    - uploaded: Uploaded via web interface, download-only (no local path)
//
// Memory implications:
//    - Each document uses ~2× PDF file size in memory
//    - Trade-off for instant revert and original thumbnail caching
//    - Acceptable for typical WebUI usage (1-5 documents)

/// Per-document state
pub const DocumentState = struct {
    id: u32,
    source: DocumentSource,
    filepath: []const u8, // file path (may be temp file for uploaded PDFs)
    filename: []const u8, // display name
    doc: pdfium.Document, // MODIFIED document (current state with transformations)
    doc_original: pdfium.Document, // ORIGINAL document (immutable, for revert)
    pages: std.array_list.Managed(PageState),
    color: [3]u8, // RGB background color for UI display
    modified: bool = false, // has any modification been made?
    original_bytes: ?[]u8, // original PDF bytes for additional backup, owned by this struct
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DocumentState) void {
        for (self.pages.items) |*page| {
            page.deinit(self.allocator);
        }
        self.pages.deinit();

        // Close both document copies
        self.doc.close();
        self.doc_original.close();

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

    /// Notify of state change (placeholder for future SSE/WebSocket support)
    pub fn notifyChange(_: *GlobalState) void {
        // No-op for now, previously used for SSE notifications
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

        // Open original PDF (immutable copy)
        var doc_original = try pdfium.Document.open(filepath);
        errdefer doc_original.close();

        // Open working PDF copy (for modifications)
        var doc = try pdfium.Document.open(filepath);
        errdefer doc.close();

        // Read original bytes for additional backup/revert functionality
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
            .doc_original = doc_original,
            .pages = std.array_list.Managed(PageState).init(self.allocator),
            .color = generateDocumentColor(doc_id),
            .original_bytes = original_bytes,
            .allocator = self.allocator,
        };
        errdefer doc_state.deinit();

        // Initialize page states using the working copy (doc)
        const page_count = doc.getPageCount();
        try doc_state.pages.ensureTotalCapacity(page_count);

        for (0..page_count) |i| {
            const page_index: u32 = @intCast(i);
            var page = try doc.loadPage(page_index);
            defer page.close();

            const page_width = page.getWidth();
            const page_height = page.getHeight();

            const page_state = PageState{
                .id = .{ .doc_id = doc_id, .page_num = page_index },
                .original_index = page_index,
                .current_index = page_index,
                .modifications = try PageModification.init(self.allocator, page_width, page_height),
                .thumbnail_cache = null,
                .original_thumbnail_cache = null,
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
