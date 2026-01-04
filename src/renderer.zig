//! PDF renderer module - coordinates PDF rendering and image output

const std = @import("std");
const pdfium = @import("pdfium.zig");
const image_writer = @import("image_writer.zig");

pub const RenderOptions = struct {
    dpi: f64 = 150.0,
    format: image_writer.Format = .png,
    jpeg_quality: u8 = 90,
    output_template: []const u8 = "page_{num}.{ext}",
    quiet: bool = false,
};

pub const PageRange = struct {
    start: u32,
    end: u32, // inclusive

    pub fn contains(self: PageRange, page: u32) bool {
        return page >= self.start and page <= self.end;
    }
};

pub const RenderError = error{
    InvalidPageRange,
    DocumentOpenFailed,
    PageLoadFailed,
    RenderFailed,
    OutputFailed,
    OutOfMemory,
} || pdfium.Error || image_writer.WriteError || std.mem.Allocator.Error;

/// Parse a page range string like "1-5,8,10-12" into a list of PageRanges
pub fn parsePageRanges(allocator: std.mem.Allocator, range_str: []const u8, max_page: u32) ![]PageRange {
    var ranges: std.ArrayListUnmanaged(PageRange) = .empty;
    errdefer ranges.deinit(allocator);

    var it = std.mem.splitSequence(u8, range_str, ",");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, "-")) |dash_pos| {
            // Range like "1-5"
            const start_str = std.mem.trim(u8, trimmed[0..dash_pos], " ");
            const end_str = std.mem.trim(u8, trimmed[dash_pos + 1 ..], " ");

            const start = std.fmt.parseInt(u32, start_str, 10) catch return RenderError.InvalidPageRange;
            const end = std.fmt.parseInt(u32, end_str, 10) catch return RenderError.InvalidPageRange;

            if (start == 0 or end == 0 or start > end or end > max_page) {
                return RenderError.InvalidPageRange;
            }

            try ranges.append(allocator, .{ .start = start, .end = end });
        } else {
            // Single page like "8"
            const page = std.fmt.parseInt(u32, trimmed, 10) catch return RenderError.InvalidPageRange;
            if (page == 0 or page > max_page) {
                return RenderError.InvalidPageRange;
            }
            try ranges.append(allocator, .{ .start = page, .end = page });
        }
    }

    return ranges.toOwnedSlice(allocator);
}

/// Check if a page number (1-based) is in any of the ranges
pub fn isPageInRanges(page: u32, ranges: []const PageRange) bool {
    for (ranges) |range| {
        if (range.contains(page)) return true;
    }
    return false;
}

/// Progress callback signature
pub const ProgressCallback = *const fn (current: u32, total: u32, page_num: u32) void;

/// Render a PDF document to images
pub fn renderDocument(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    output_dir: []const u8,
    password: ?[]const u8,
    page_ranges: ?[]const PageRange,
    options: RenderOptions,
    progress_callback: ?ProgressCallback,
) RenderError!u32 {
    // Open the document
    var doc = if (password) |pwd|
        pdfium.Document.openWithPassword(pdf_path, pwd) catch return RenderError.DocumentOpenFailed
    else
        pdfium.Document.open(pdf_path) catch return RenderError.DocumentOpenFailed;
    defer doc.close();

    const page_count = doc.getPageCount();
    if (page_count == 0) return 0;

    // Get basename from pdf path
    const basename = getBasename(pdf_path);

    // Count pages to render
    var pages_to_render: u32 = 0;
    for (1..page_count + 1) |page_num| {
        if (page_ranges) |ranges| {
            if (!isPageInRanges(@intCast(page_num), ranges)) continue;
        }
        pages_to_render += 1;
    }

    var rendered_count: u32 = 0;

    // Render each requested page
    for (1..page_count + 1) |i| {
        const page_num: u32 = @intCast(i);

        // Skip if not in requested ranges
        if (page_ranges) |ranges| {
            if (!isPageInRanges(page_num, ranges)) continue;
        }

        // Load the page
        var page = doc.loadPage(page_num - 1) catch return RenderError.PageLoadFailed;
        defer page.close();

        // Calculate dimensions at target DPI
        const dims = page.getDimensionsAtDpi(options.dpi);

        // Create bitmap
        var bitmap = pdfium.Bitmap.create(dims.width, dims.height, .bgra) catch return RenderError.RenderFailed;
        defer bitmap.destroy();

        // Fill with white background
        bitmap.fillWhite();

        // Render the page
        page.render(&bitmap, .{});

        // Generate output filename
        const filename = try image_writer.formatOutputPath(
            allocator,
            options.output_template,
            page_num,
            page_count,
            basename,
            options.format,
        );
        defer allocator.free(filename);

        // Build full output path
        const output_path = try std.fs.path.join(allocator, &.{ output_dir, filename });
        defer allocator.free(output_path);

        // Write the image
        image_writer.writeBitmap(bitmap, output_path, .{
            .format = options.format,
            .jpeg_quality = options.jpeg_quality,
        }) catch return RenderError.OutputFailed;

        rendered_count += 1;

        // Report progress
        if (progress_callback) |callback| {
            callback(rendered_count, pages_to_render, page_num);
        }
    }

    return rendered_count;
}

/// Extract basename (filename without extension) from a path
fn getBasename(path: []const u8) []const u8 {
    // Find the last path separator
    const filename = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |pos|
        path[pos + 1 ..]
    else
        path;

    // Remove extension
    return if (std.mem.lastIndexOfScalar(u8, filename, '.')) |pos|
        filename[0..pos]
    else
        filename;
}

test "parsePageRanges" {
    const allocator = std.testing.allocator;

    {
        const ranges = try parsePageRanges(allocator, "1-5,8,10-12", 20);
        defer allocator.free(ranges);

        try std.testing.expectEqual(@as(usize, 3), ranges.len);
        try std.testing.expectEqual(PageRange{ .start = 1, .end = 5 }, ranges[0]);
        try std.testing.expectEqual(PageRange{ .start = 8, .end = 8 }, ranges[1]);
        try std.testing.expectEqual(PageRange{ .start = 10, .end = 12 }, ranges[2]);
    }
}

test "isPageInRanges" {
    const ranges = [_]PageRange{
        .{ .start = 1, .end = 5 },
        .{ .start = 10, .end = 10 },
    };

    try std.testing.expect(isPageInRanges(1, &ranges));
    try std.testing.expect(isPageInRanges(3, &ranges));
    try std.testing.expect(isPageInRanges(5, &ranges));
    try std.testing.expect(!isPageInRanges(6, &ranges));
    try std.testing.expect(isPageInRanges(10, &ranges));
    try std.testing.expect(!isPageInRanges(11, &ranges));
}

test "getBasename" {
    try std.testing.expectEqualStrings("document", getBasename("/path/to/document.pdf"));
    try std.testing.expectEqualStrings("file", getBasename("file.txt"));
    try std.testing.expectEqualStrings("noext", getBasename("noext"));
}
