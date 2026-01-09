//! Page rendering to PNG with caching
//! Non-destructive rendering using transformation matrices

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const loader = @import("../pdfium/loader.zig");
const images = @import("../pdfcontent/images.zig");
const state_mod = @import("state.zig");
const PageState = state_mod.PageState;
const DocumentState = state_mod.DocumentState;
const Matrix = state_mod.Matrix;
const error_page = @import("error_page.zig");

/// Generate an error PNG for when rendering fails
fn generateErrorPng(
    allocator: std.mem.Allocator,
    error_message: []const u8,
    width: f64,
    height: f64,
    dpi: f64,
) ![]u8 {
    // Create appropriate page size for the error message
    const page_size = error_page.PageSize{
        .width = width,
        .height = height,
    };

    return error_page.pdfErrorPagePNG(
        allocator,
        error_message,
        page_size,
        dpi,
    ) catch |err| {
        std.debug.print("Failed to generate error PNG: {}\n", .{err});
        // Return minimal error indication if even error generation fails
        return error.ErrorPageGenerationFailed;
    };
}

/// Render a page thumbnail and cache the result
/// Always renders original untransformed page - client applies CSS transforms
/// Returns an error PNG if rendering fails
pub fn renderThumbnail(
    allocator: std.mem.Allocator,
    page_state: *PageState,
    doc: *DocumentState,
    dpi: f64,
) ![]u8 {
    // Check original thumbnail cache first
    if (page_state.original_thumbnail_cache) |cache| {
        return cache;
    }

    // Try to render the original page, but catch errors and generate error PNG
    const png_bytes = blk: {
        const result = renderOriginalThumbnail(allocator, page_state, doc, dpi) catch |err| {
            std.debug.print("Error rendering page {d}: {}\n", .{ page_state.id.page_num, err });

            // Generate appropriate error message
            const error_message = switch (err) {
                error.OutOfMemory => "Error: Out of Memory",
                error.BufferEmpty => "Error: Render Failed",
                error.PageNotFound => "Error: Page Not Found",
                else => "Error: Rendering Failed",
            };

            // Get original page dimensions for error PNG
            var width: f64 = 600;
            var height: f64 = 600;
            if (doc.doc_original.loadPage(page_state.original_index)) |pg| {
                var page = pg;
                defer page.close();
                width = page.getWidth();
                height = page.getHeight();
            } else |_| {
                // Use fallback dimensions if page can't be loaded
            }

            // Generate error PNG and break from catch to allow caching
            break :blk try generateErrorPng(allocator, error_message, width, height, dpi);
        };
        break :blk result;
    };

    // Cache the original thumbnail
    page_state.original_thumbnail_cache = png_bytes;

    return png_bytes;
}

/// Render original page without transformations (client applies CSS transforms)
fn renderOriginalThumbnail(
    allocator: std.mem.Allocator,
    page_state: *PageState,
    doc: *DocumentState,
    dpi: f64,
) ![]u8 {
    // Load original page (unmodified)
    var page = try doc.doc_original.loadPage(page_state.original_index);
    defer page.close();

    // Get original page dimensions
    const width_points = page.getWidth();
    const height_points = page.getHeight();

    // Calculate pixel dimensions at target DPI
    const width_px: u32 = @intFromFloat(@ceil(width_points * dpi / 72.0));
    const height_px: u32 = @intFromFloat(@ceil(height_points * dpi / 72.0));

    // Create bitmap with original dimensions
    var bitmap = try pdfium.Bitmap.create(width_px, height_px, .bgra);
    defer bitmap.destroy();

    // Fill with white background
    bitmap.fillWhite();

    // Render page with standard rendering (no transformations)
    page.render(&bitmap, .{});

    // Convert to PNG bytes
    return try convertBitmapToPng(allocator, &bitmap);
}

/// Render a page at full size (no caching)
/// Returns an error PNG if rendering fails
pub fn renderFullSize(
    allocator: std.mem.Allocator,
    doc: pdfium.Document,
    page_index: u32,
    dpi: f64,
) ![]u8 {
    // Try to render the page, but catch errors and generate error PNG
    return renderFullSizeInternal(allocator, doc, page_index, dpi) catch |err| {
        std.debug.print("Error rendering full-size page {d}: {}\n", .{ page_index, err });

        // Generate appropriate error message
        const error_message = switch (err) {
            error.OutOfMemory => "Error: Out of Memory",
            error.BufferEmpty => "Error: Render Failed",
            error.PageNotFound => "Error: Page Not Found",
            else => "Error: Rendering Failed",
        };

        // Try to get page dimensions, fallback to square on error
        var width: f64 = 600;
        var height: f64 = 600;
        if (doc.loadPage(page_index)) |pg| {
            var page = pg;
            defer page.close();
            width = page.getWidth();
            height = page.getHeight();
        } else |_| {
            // If we can't load the page to get dimensions, use fallback
        }

        return generateErrorPng(allocator, error_message, width, height, dpi);
    };
}

/// Internal rendering function that can fail
fn renderFullSizeInternal(
    allocator: std.mem.Allocator,
    doc: pdfium.Document,
    page_index: u32,
    dpi: f64,
) ![]u8 {
    // Load the page
    var page = try doc.loadPage(page_index);
    defer page.close();

    // Calculate dimensions at target DPI
    const width_points = page.getWidth();
    const height_points = page.getHeight();

    const width_px: u32 = @intFromFloat(@ceil(width_points * dpi / 72.0));
    const height_px: u32 = @intFromFloat(@ceil(height_points * dpi / 72.0));

    // Create bitmap
    var bitmap = try pdfium.Bitmap.create(width_px, height_px, .bgra);
    defer bitmap.destroy();

    // Fill with white background
    bitmap.fillWhite();

    // Render the page
    page.render(&bitmap, .{});

    // Convert to PNG bytes (not cached)
    return try convertBitmapToPng(allocator, &bitmap);
}

/// Convert PDFium BGRA bitmap to PNG bytes
fn convertBitmapToPng(
    allocator: std.mem.Allocator,
    bitmap: *pdfium.Bitmap,
) ![]u8 {
    const data = bitmap.getData() orelse return error.BufferEmpty;

    // Convert BGRA to RGBA
    const pixels = try images.convertBgraToRgba(
        allocator,
        data,
        bitmap.width,
        bitmap.height,
        bitmap.stride,
    );
    defer allocator.free(pixels);

    // Create zigimg image structure
    const zigimg = @import("zigimg");
    const pixel_count = bitmap.width * bitmap.height;
    const rgba_pixels: []zigimg.color.Rgba32 =
        @as([*]zigimg.color.Rgba32, @ptrCast(@alignCast(pixels.ptr)))[0..pixel_count];

    const image = zigimg.Image{
        .width = bitmap.width,
        .height = bitmap.height,
        .pixels = .{ .rgba32 = rgba_pixels },
    };

    // Encode to PNG in memory using heap allocation
    // Buffer sized for large pages: A4 at 300 DPI can produce 7-12MB PNGs
    const write_buf = try allocator.alloc(u8, 20 * 1024 * 1024); // 20MB buffer
    errdefer allocator.free(write_buf);

    const png_slice = try image.writeToMemory(allocator, write_buf, .{ .png = .{} });

    // writeToMemory returns a slice into write_buf, so we need to dupe it
    // and free the original buffer
    const png_bytes = try allocator.dupe(u8, png_slice);
    allocator.free(write_buf);

    return png_bytes;
}

/// Invalidate thumbnail cache for a page (used when DPI changes)
pub fn invalidateThumbnailCache(page_state: *PageState, allocator: std.mem.Allocator) void {
    if (page_state.original_thumbnail_cache) |cache| {
        allocator.free(cache);
        page_state.original_thumbnail_cache = null;
    }
    if (page_state.thumbnail_cache) |cache| {
        allocator.free(cache);
        page_state.thumbnail_cache = null;
    }
}
