//! Image writer module for outputting rendered pages as PNG or JPEG files

const std = @import("std");
const zigimg = @import("zigimg");
const zstbi = @import("zstbi");
const pdfium = @import("../pdfium/pdfium.zig");

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

pub fn addImageToPage(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    image_path: []const u8,
    page_width: f64,
    page_height: f64,
    stderr: *std.Io.Writer,
) !void {
    // Load image using zigimg
    var read_buffer: [1024 * 1024]u8 = undefined;
    var img = zigimg.Image.fromFilePath(allocator, image_path, &read_buffer) catch {
        try stderr.print("Error loading image: {s}\n", .{image_path});
        try stderr.flush();
        std.process.exit(1);
    };
    defer img.deinit(allocator);

    const img_width: f64 = @floatFromInt(img.width);
    const img_height: f64 = @floatFromInt(img.height);

    // Calculate scale to fit page while maintaining aspect ratio
    const scale_x = page_width / img_width;
    const scale_y = page_height / img_height;
    const scale = @min(scale_x, scale_y);

    const scaled_width = img_width * scale;
    const scaled_height = img_height * scale;

    // Center on page
    const x_offset = (page_width - scaled_width) / 2;
    const y_offset = (page_height - scaled_height) / 2;

    // Create bitmap in BGRA format for PDFium
    var bitmap = pdfium.Bitmap.create(@intFromFloat(img_width), @intFromFloat(img_height), .bgra) catch {
        try stderr.writeAll("Error creating bitmap\n");
        try stderr.flush();
        std.process.exit(1);
    };
    defer bitmap.destroy();

    // Copy image data to bitmap (convert to BGRA)
    const buffer = bitmap.getBuffer() orelse {
        try stderr.writeAll("Error getting bitmap buffer\n");
        try stderr.flush();
        std.process.exit(1);
    };

    // Convert image pixels to BGRA
    const width: usize = @intCast(img.width);
    const height: usize = @intCast(img.height);
    const stride: usize = @intCast(bitmap.stride);

    // Handle different pixel formats using zigimg's PixelStorage union
    switch (img.pixels) {
        .rgba32 => |pixels| {
            for (0..height) |y| {
                for (0..width) |x| {
                    const pix = pixels[y * width + x];
                    const dst_idx = y * stride + x * 4;
                    buffer[dst_idx + 0] = pix.b;
                    buffer[dst_idx + 1] = pix.g;
                    buffer[dst_idx + 2] = pix.r;
                    buffer[dst_idx + 3] = pix.a;
                }
            }
        },
        .rgb24 => |pixels| {
            for (0..height) |y| {
                for (0..width) |x| {
                    const pix = pixels[y * width + x];
                    const dst_idx = y * stride + x * 4;
                    buffer[dst_idx + 0] = pix.b;
                    buffer[dst_idx + 1] = pix.g;
                    buffer[dst_idx + 2] = pix.r;
                    buffer[dst_idx + 3] = 255;
                }
            }
        },
        .bgra32 => |pixels| {
            // Already BGRA, just copy
            for (0..height) |y| {
                for (0..width) |x| {
                    const pix = pixels[y * width + x];
                    const dst_idx = y * stride + x * 4;
                    buffer[dst_idx + 0] = pix.b;
                    buffer[dst_idx + 1] = pix.g;
                    buffer[dst_idx + 2] = pix.r;
                    buffer[dst_idx + 3] = pix.a;
                }
            }
        },
        .grayscale8 => |pixels| {
            for (0..height) |y| {
                for (0..width) |x| {
                    const gray = pixels[y * width + x].value;
                    const dst_idx = y * stride + x * 4;
                    buffer[dst_idx + 0] = gray;
                    buffer[dst_idx + 1] = gray;
                    buffer[dst_idx + 2] = gray;
                    buffer[dst_idx + 3] = 255;
                }
            }
        },
        else => {
            try stderr.print("Unsupported image format: {s}\n", .{@tagName(img.pixels)});
            try stderr.flush();
            std.process.exit(1);
        },
    }

    // Create image object
    var img_obj = doc.createImageObject() catch {
        try stderr.writeAll("Error creating image object\n");
        try stderr.flush();
        std.process.exit(1);
    };

    // Set the bitmap on the image object
    if (!img_obj.setBitmap(bitmap)) {
        try stderr.writeAll("Error setting bitmap on image object\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Position and scale the image
    if (!img_obj.setImageMatrix(scaled_width, scaled_height, x_offset, y_offset)) {
        try stderr.writeAll("Error positioning image\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Insert image into page
    page.insertObject(img_obj);
}
