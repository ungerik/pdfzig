//! Image writer module for outputting rendered pages as PNG or JPEG files

const std = @import("std");
const zigimg = @import("zigimg");
const zstbi = @import("zstbi");
const pdfium = @import("pdfium/pdfium.zig");

pub const Format = enum {
    png,
    jpeg,

    pub fn fromString(str: []const u8) ?Format {
        if (std.mem.eql(u8, str, "png")) return .png;
        if (std.mem.eql(u8, str, "jpeg") or std.mem.eql(u8, str, "jpg")) return .jpeg;
        return null;
    }

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpg",
        };
    }
};

pub const WriteOptions = struct {
    format: Format = .png,
    jpeg_quality: u8 = 90, // 1-100, only used for JPEG
};

pub const WriteError = error{
    InvalidBitmapFormat,
    BufferEmpty,
    FileCreateFailed,
    WriteError,
    OutOfMemory,
} || std.fs.File.OpenError || std.fs.File.WriteError;

/// Write a PDFium bitmap to a file
pub fn writeBitmap(
    bitmap: pdfium.Bitmap,
    output_path: []const u8,
    options: WriteOptions,
) WriteError!void {
    const data = bitmap.getData() orelse return WriteError.BufferEmpty;

    // Write to file based on format
    switch (options.format) {
        .png => {
            // Convert BGRA to RGBA for zigimg (PNG supports alpha)
            const pixels = try convertBgraToRgba(data, bitmap.width, bitmap.height, bitmap.stride);
            defer std.heap.page_allocator.free(pixels);

            // Create zigimg image with proper slice type
            const pixel_count = bitmap.width * bitmap.height;
            const rgba_pixels: []zigimg.color.Rgba32 = @as([*]zigimg.color.Rgba32, @ptrCast(@alignCast(pixels.ptr)))[0..pixel_count];

            const image = zigimg.Image{
                .width = bitmap.width,
                .height = bitmap.height,
                .pixels = .{ .rgba32 = rgba_pixels },
            };

            // Write buffer for encoding
            var write_buffer: [4096]u8 = undefined;
            image.writeToFilePath(std.heap.page_allocator, output_path, &write_buffer, .{
                .png = .{ .filter_choice = .heuristic },
            }) catch return WriteError.WriteError;
        },
        .jpeg => {
            // Convert BGRA to RGB for JPEG (no alpha channel support)
            const rgb_data = try convertBgraToRgb(data, bitmap.width, bitmap.height, bitmap.stride);
            defer std.heap.page_allocator.free(rgb_data);

            // Create null-terminated path for zstbi
            const path_z = std.heap.page_allocator.dupeZ(u8, output_path) catch return WriteError.OutOfMemory;
            defer std.heap.page_allocator.free(path_z);

            // Initialize zstbi
            zstbi.init(std.heap.page_allocator);
            defer zstbi.deinit();

            // Create zstbi Image struct
            const img = zstbi.Image{
                .data = rgb_data,
                .width = bitmap.width,
                .height = bitmap.height,
                .num_components = 3,
                .bytes_per_component = 1,
                .bytes_per_row = bitmap.width * 3,
                .is_hdr = false,
            };

            // Write JPEG with quality setting
            img.writeToFile(path_z, .{ .jpg = .{ .quality = options.jpeg_quality } }) catch return WriteError.WriteError;
        },
    }
}

/// Convert BGRA pixel data to RGBA (for PNG with alpha)
fn convertBgraToRgba(
    bgra_data: []const u8,
    width: u32,
    height: u32,
    stride: u32,
) ![]u8 {
    const rgba = try std.heap.page_allocator.alloc(u8, width * height * 4);
    errdefer std.heap.page_allocator.free(rgba);

    var dst_offset: usize = 0;
    for (0..height) |y| {
        const src_row_start = y * stride;
        for (0..width) |x| {
            const src_offset = src_row_start + x * 4;
            // BGRA -> RGBA
            rgba[dst_offset + 0] = bgra_data[src_offset + 2]; // R <- B
            rgba[dst_offset + 1] = bgra_data[src_offset + 1]; // G <- G
            rgba[dst_offset + 2] = bgra_data[src_offset + 0]; // B <- R
            rgba[dst_offset + 3] = bgra_data[src_offset + 3]; // A <- A
            dst_offset += 4;
        }
    }

    return rgba;
}

/// Convert BGRA pixel data to RGB (for JPEG without alpha)
fn convertBgraToRgb(
    bgra_data: []const u8,
    width: u32,
    height: u32,
    stride: u32,
) ![]u8 {
    const rgb = try std.heap.page_allocator.alloc(u8, width * height * 3);
    errdefer std.heap.page_allocator.free(rgb);

    var dst_offset: usize = 0;
    for (0..height) |y| {
        const src_row_start = y * stride;
        for (0..width) |x| {
            const src_offset = src_row_start + x * 4;
            // BGRA -> RGB (discard alpha)
            rgb[dst_offset + 0] = bgra_data[src_offset + 2]; // R <- B
            rgb[dst_offset + 1] = bgra_data[src_offset + 1]; // G <- G
            rgb[dst_offset + 2] = bgra_data[src_offset + 0]; // B <- R
            dst_offset += 3;
        }
    }

    return rgb;
}

/// Format an output filename from a template
pub fn formatOutputPath(
    allocator: std.mem.Allocator,
    template: []const u8,
    page_num: u32,
    total_pages: u32,
    basename: []const u8,
    format: Format,
) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    // Calculate padding width for zero-padded numbers
    const padding_width = std.math.log10(total_pages) + 1;

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            // Find closing brace
            const end = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                try result.append(allocator, template[i]);
                i += 1;
                continue;
            };

            const var_name = template[i + 1 .. end];

            if (std.mem.eql(u8, var_name, "num")) {
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d}", .{page_num}) catch unreachable;
                try result.appendSlice(allocator, num_str);
            } else if (std.mem.eql(u8, var_name, "num0")) {
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d:0>[1]}", .{ page_num, padding_width }) catch unreachable;
                try result.appendSlice(allocator, num_str);
            } else if (std.mem.eql(u8, var_name, "basename")) {
                try result.appendSlice(allocator, basename);
            } else if (std.mem.eql(u8, var_name, "ext")) {
                try result.appendSlice(allocator, format.extension());
            } else {
                // Unknown variable, keep as-is
                try result.appendSlice(allocator, template[i .. end + 1]);
            }

            i = end + 1;
        } else {
            try result.append(allocator, template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

test "formatOutputPath" {
    const allocator = std.testing.allocator;

    {
        const path = try formatOutputPath(allocator, "page_{num}.{ext}", 5, 100, "test", .png);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("page_5.png", path);
    }

    {
        const path = try formatOutputPath(allocator, "{basename}_{num0}.{ext}", 5, 100, "document", .jpeg);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("document_005.jpg", path);
    }
}

test "Format.fromString" {
    try std.testing.expectEqual(Format.png, Format.fromString("png").?);
    try std.testing.expectEqual(Format.jpeg, Format.fromString("jpeg").?);
    try std.testing.expectEqual(Format.jpeg, Format.fromString("jpg").?);
    try std.testing.expect(Format.fromString("gif") == null);
    try std.testing.expect(Format.fromString("") == null);
    try std.testing.expect(Format.fromString("PNG") == null); // case sensitive
}

test "Format.extension" {
    try std.testing.expectEqualStrings("png", Format.png.extension());
    try std.testing.expectEqualStrings("jpg", Format.jpeg.extension());
}

test "formatOutputPath with unknown variable" {
    const allocator = std.testing.allocator;
    const path = try formatOutputPath(allocator, "page_{unknown}.{ext}", 1, 10, "test", .png);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("page_{unknown}.png", path);
}

test "formatOutputPath zero padding" {
    const allocator = std.testing.allocator;

    // Single digit total pages - no padding needed
    {
        const path = try formatOutputPath(allocator, "{num0}.png", 1, 9, "test", .png);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("1.png", path);
    }

    // Two digit total pages
    {
        const path = try formatOutputPath(allocator, "{num0}.png", 1, 99, "test", .png);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("01.png", path);
    }

    // Three digit total pages
    {
        const path = try formatOutputPath(allocator, "{num0}.png", 1, 100, "test", .png);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("001.png", path);
    }
}
