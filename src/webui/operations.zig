//! PDF page modification operations
//! Handles rotate, mirror, delete, and revert operations with state tracking

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const state_mod = @import("state.zig");
const GlobalState = state_mod.GlobalState;
const PageState = state_mod.PageState;
const DocumentState = state_mod.DocumentState;
const page_renderer = @import("page_renderer.zig");

/// Rotate a page by specified degrees (90, 180, 270, or -90)
pub fn rotatePage(
    state: *GlobalState,
    doc_id: u32,
    page_index: u32,
    degrees: i32,
) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    if (page_index >= doc.pages.items.len) return error.PageNotFound;

    const page_state = &doc.pages.items[page_index];

    // Load the page
    var page = try doc.doc.loadPage(page_state.original_index);
    defer page.close();

    // Rotate the page
    if (!page.rotate(degrees)) return error.InvalidRotation;
    if (!page.generateContent()) return error.GenerateContentFailed;

    // Update modification tracking
    page_state.modifications.rotation = @mod(page_state.modifications.rotation + degrees, 360);

    // Increment version for cache busting
    page_state.version +%= 1;

    // Invalidate thumbnail cache (keep original)
    page_renderer.invalidateThumbnailCache(page_state, state.allocator);

    doc.modified = true;
    state.notifyChange();
}

pub const MirrorDirection = enum { updown, leftright };

/// Mirror a page vertically (up-down) or horizontally (left-right)
pub fn mirrorPage(
    state: *GlobalState,
    doc_id: u32,
    page_index: u32,
    direction: MirrorDirection,
) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    if (page_index >= doc.pages.items.len) return error.PageNotFound;

    const page_state = &doc.pages.items[page_index];

    // Load the page
    var page = try doc.doc.loadPage(page_state.original_index);
    defer page.close();

    // Get page dimensions
    const page_width = page.getWidth();
    const page_height = page.getHeight();

    // Mirror all objects on the page
    const object_count = page.getObjectCount();
    var i: u32 = 0;
    while (i < object_count) : (i += 1) {
        if (page.getObject(i)) |obj| {
            switch (direction) {
                .updown => {
                    // Mirror vertically: flip around horizontal axis
                    obj.transform(1, 0, 0, -1, 0, page_height);
                },
                .leftright => {
                    // Mirror horizontally: flip around vertical axis
                    obj.transform(-1, 0, 0, 1, page_width, 0);
                },
            }
        }
    }

    // Generate content to apply transformations
    if (!page.generateContent()) return error.GenerateContentFailed;

    // Update modification tracking (toggle the mirror state)
    switch (direction) {
        .updown => page_state.modifications.mirror_ud = !page_state.modifications.mirror_ud,
        .leftright => page_state.modifications.mirror_lr = !page_state.modifications.mirror_lr,
    }

    // Increment version for cache busting
    page_state.version +%= 1;

    // Invalidate thumbnail cache (keep original)
    page_renderer.invalidateThumbnailCache(page_state, state.allocator);

    doc.modified = true;
    state.notifyChange();
}

/// Mark a page as deleted (soft delete - doesn't actually remove it yet)
pub fn deletePage(
    state: *GlobalState,
    doc_id: u32,
    page_index: u32,
) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    if (page_index >= doc.pages.items.len) return error.PageNotFound;

    const page_state = &doc.pages.items[page_index];

    // Toggle deleted state
    page_state.modifications.deleted = !page_state.modifications.deleted;

    // Increment version for cache busting
    page_state.version +%= 1;

    doc.modified = true;
    state.notifyChange();
}

/// Revert a page to its original state
pub fn revertPage(
    state: *GlobalState,
    doc_id: u32,
    page_index: u32,
) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    if (page_index >= doc.pages.items.len) return error.PageNotFound;

    const page_state = &doc.pages.items[page_index];

    // Reload the document from original bytes
    if (doc.original_bytes == null) return error.NoOriginalData;

    // Close current document
    doc.doc.close();

    // For uploaded documents, write original_bytes to temp file first
    const allocator = state.allocator;
    const temp_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/pdfzig-revert-{d}.pdf",
        .{std.time.milliTimestamp()},
    );
    defer allocator.free(temp_path);

    const file = try std.fs.cwd().createFile(temp_path, .{});
    defer file.close();
    try file.writeAll(doc.original_bytes.?);

    // Reopen from temp file
    doc.doc = try pdfium.Document.open(temp_path);

    // Clean up temp file
    std.fs.cwd().deleteFile(temp_path) catch {};

    // Clear all modifications for this page
    page_state.modifications = .{};

    // Reset version
    page_state.version = 0;

    // Restore thumbnail from original cache if available
    if (page_state.original_thumbnail_cache) |original| {
        // Free current cache if it exists
        if (page_state.thumbnail_cache) |current| {
            state.allocator.free(current);
        }
        // Duplicate the original cache
        page_state.thumbnail_cache = try state.allocator.dupe(u8, original);
    } else {
        // No original cache, invalidate so it re-renders
        page_renderer.invalidateThumbnailCache(page_state, state.allocator);
    }

    // Check if document still has any modifications
    var has_modifications = false;
    for (doc.pages.items) |page| {
        if (!page.modifications.isEmpty()) {
            has_modifications = true;
            break;
        }
    }
    doc.modified = has_modifications;

    state.notifyChange();
}

/// Reorder pages within a document or between documents
pub fn reorderPages(
    state: *GlobalState,
    source_page_id: state_mod.PageId,
    target_page_id: state_mod.PageId,
) !void {
    state.lock();
    defer state.unlock();

    // For now, only support reordering within the same document
    if (source_page_id.doc_id != target_page_id.doc_id) {
        return error.CrossDocumentReorderNotSupported;
    }

    const doc = state.getDocument(source_page_id.doc_id) orelse return error.DocumentNotFound;

    if (source_page_id.page_num >= doc.pages.items.len) return error.PageNotFound;
    if (target_page_id.page_num >= doc.pages.items.len) return error.PageNotFound;

    const source_idx = source_page_id.page_num;
    const target_idx = target_page_id.page_num;

    if (source_idx == target_idx) return; // Nothing to do

    // Remove page from source position
    const page = doc.pages.orderedRemove(source_idx);

    // Insert at target position
    try doc.pages.insert(target_idx, page);

    doc.modified = true;
    state.notifyChange();
}

/// Update DPI setting for thumbnail rendering
pub fn updateDPI(
    state: *GlobalState,
    new_dpi: f64,
) !void {
    state.lock();
    defer state.unlock();

    // Clamp DPI to reasonable range
    const clamped_dpi = @max(50.0, @min(150.0, new_dpi));

    if (state.thumbnail_dpi != clamped_dpi) {
        state.thumbnail_dpi = clamped_dpi;

        // Invalidate all thumbnail caches
        for (state.documents.items) |doc| {
            for (doc.pages.items) |*page| {
                page_renderer.invalidateThumbnailCache(page, state.allocator);
            }
        }

        state.notifyChange();
    }
}

/// Reset all documents to original state
pub fn resetAll(state: *GlobalState) !void {
    state.lock();
    defer state.unlock();

    const allocator = state.allocator;

    for (state.documents.items) |doc| {
        // Reload document from original bytes
        if (doc.original_bytes == null) continue;

        doc.doc.close();

        // Write original_bytes to temp file for reopening
        const temp_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/pdfzig-reset-{d}.pdf",
            .{std.time.milliTimestamp()},
        );
        defer allocator.free(temp_path);

        const file = try std.fs.cwd().createFile(temp_path, .{});
        defer file.close();
        try file.writeAll(doc.original_bytes.?);

        // Reopen from temp file
        doc.doc = try pdfium.Document.open(temp_path);

        // Clean up temp file
        std.fs.cwd().deleteFile(temp_path) catch {};

        // Reset all page modifications
        for (doc.pages.items) |*page| {
            page.modifications = .{};
            page.version = 0;

            // Restore thumbnail from original cache if available
            if (page.original_thumbnail_cache) |original| {
                // Free current cache if it exists
                if (page.thumbnail_cache) |current| {
                    allocator.free(current);
                }
                // Duplicate the original cache
                page.thumbnail_cache = allocator.dupe(u8, original) catch null;
            } else {
                // No original cache, invalidate so it re-renders
                page_renderer.invalidateThumbnailCache(page, allocator);
            }
        }

        doc.modified = false;
    }

    state.notifyChange();
}

/// Clear all documents
pub fn clearAll(state: *GlobalState) !void {
    state.lock();
    defer state.unlock();

    // Clear the list first to prevent use-after-free, then free the documents
    // This ensures no one can access the list while we're freeing
    const docs_to_free = try state.allocator.dupe(*DocumentState, state.documents.items);
    defer state.allocator.free(docs_to_free);

    state.documents.clearRetainingCapacity();

    for (docs_to_free) |doc| {
        doc.deinit();
        state.allocator.destroy(doc);
    }

    state.notifyChange();
}
