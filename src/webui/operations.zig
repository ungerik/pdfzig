//! PDF page modification operations
//! Non-destructive transformations using cumulative transformation matrices

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const state_mod = @import("state.zig");
const GlobalState = state_mod.GlobalState;
const PageState = state_mod.PageState;
const DocumentState = state_mod.DocumentState;
const Matrix = state_mod.Matrix;
const page_renderer = @import("page_renderer.zig");

/// Check if all pages in document are in their original state
pub fn checkDocumentModificationStatus(doc: *DocumentState) void {
    var has_modifications = false;

    // Check if any page has modifications (transformations, deletions)
    for (doc.pages.items) |page| {
        if (!page.modifications.isEmpty()) {
            has_modifications = true;
            break;
        }
    }

    // Check if pages are in original order
    if (!has_modifications) {
        for (doc.pages.items, 0..) |page, idx| {
            if (page.original_index != idx) {
                has_modifications = true;
                break;
            }
        }
    }

    doc.modified = has_modifications;
}

/// Rotate a page by specified degrees (90, 180, 270, or -90)
/// Non-destructive: adds rotation operation to version history
pub fn rotatePage(
    state: *GlobalState,
    doc_id: u32,
    page_index: u32,
    degrees: i32,
    operation_desc: []const u8,
) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    if (page_index >= doc.pages.items.len) return error.PageNotFound;

    const page_state = &doc.pages.items[page_index];

    // Get current state
    const current = page_state.modifications.getCurrentState();

    // Get original dimensions for matrix calculation
    var original_page = try doc.doc_original.loadPage(page_state.original_index);
    defer original_page.close();
    const original_width = original_page.getWidth();
    const original_height = original_page.getHeight();

    // Create rotation matrix using current dimensions
    const rotation_matrix = Matrix.rotation(degrees, current.width, current.height);

    // Compose with current matrix
    const new_matrix = current.matrix.multiply(rotation_matrix);

    // Calculate new dimensions
    const dims = new_matrix.transformDimensions(original_width, original_height);

    // Add new version to history
    try page_state.modifications.addVersion(
        operation_desc,
        new_matrix,
        dims.width,
        dims.height,
        current.deleted,
    );

    // Update document modification status
    checkDocumentModificationStatus(doc);

    state.notifyChange();
}

pub const MirrorDirection = enum { updown, leftright };

/// Mirror a page vertically (up-down) or horizontally (left-right)
/// Non-destructive: adds mirror operation to version history
pub fn mirrorPage(
    state: *GlobalState,
    doc_id: u32,
    page_index: u32,
    direction: MirrorDirection,
    operation_desc: []const u8,
) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    if (page_index >= doc.pages.items.len) return error.PageNotFound;

    const page_state = &doc.pages.items[page_index];

    // Get current state
    const current = page_state.modifications.getCurrentState();

    // Get original dimensions for matrix calculation
    var original_page = try doc.doc_original.loadPage(page_state.original_index);
    defer original_page.close();
    const original_width = original_page.getWidth();
    const original_height = original_page.getHeight();

    // Create mirror matrix using current dimensions
    const mirror_matrix = switch (direction) {
        .updown => Matrix.mirrorVertical(current.height),
        .leftright => Matrix.mirrorHorizontal(current.width),
    };

    // Compose with current matrix
    const new_matrix = current.matrix.multiply(mirror_matrix);

    // Calculate new dimensions
    const dims = new_matrix.transformDimensions(original_width, original_height);

    // Add new version to history
    try page_state.modifications.addVersion(
        operation_desc,
        new_matrix,
        dims.width,
        dims.height,
        current.deleted,
    );

    // Update document modification status
    checkDocumentModificationStatus(doc);

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

    // Get current state
    const current = page_state.modifications.getCurrentState();

    // Toggle deleted status and add new version
    const new_deleted = !current.deleted;
    const operation_desc = if (new_deleted) "delete" else "undelete";

    try page_state.modifications.addVersion(
        operation_desc,
        current.matrix,
        current.width,
        current.height,
        new_deleted,
    );

    // Check if all pages are now in original state
    checkDocumentModificationStatus(doc);

    state.notifyChange();
}

/// Revert a page to its original state (version 0)
pub fn revertPage(
    state: *GlobalState,
    doc_id: u32,
    page_index: u32,
) !void {
    return revertPageToVersion(state, doc_id, page_index, 0);
}

/// Revert a page to a specific version
pub fn revertPageToVersion(
    state: *GlobalState,
    doc_id: u32,
    page_index: u32,
    target_version: u32,
) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    if (page_index >= doc.pages.items.len) return error.PageNotFound;

    const page_state = &doc.pages.items[page_index];

    // Revert to specified version
    try page_state.modifications.revertToVersion(target_version);

    // Check if all pages are now in original state
    checkDocumentModificationStatus(doc);

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

    // Check if document is now back in original state
    checkDocumentModificationStatus(doc);
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

    for (state.documents.items) |doc| {
        // Reset all page modifications to version 0
        for (doc.pages.items) |*page| {
            // Reset to version 0 (original state)
            page.modifications.reset();

            // Invalidate thumbnail cache
            page_renderer.invalidateThumbnailCache(page, state.allocator);
        }

        // Check if document is back to original state (accounts for page order)
        checkDocumentModificationStatus(doc);
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
