//! Visual comparison module for pixel-level PNG image comparison
//! Compares decoded pixel data instead of encoded PNG bytes

const std = @import("std");
const zigimg = @import("zigimg");

pub const PixelDifference = struct {
    max_delta: u8,
    total_diff_pixels: u32,
    avg_delta: f64,

    pub fn withinTolerance(self: PixelDifference, tolerance: u8) bool {
        return self.max_delta <= tolerance;
    }

    pub fn format(
        self: PixelDifference,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "max_delta={}, diff_pixels={}, avg_delta={d:.2}",
            .{ self.max_delta, self.total_diff_pixels, self.avg_delta },
        );
    }
};

/// Compare two RGBA pixel arrays
pub fn comparePixels(
    pixels1: []const u8, // RGBA format (4 bytes per pixel)
    pixels2: []const u8, // RGBA format
    width: u32,
    height: u32,
) PixelDifference {
    const pixel_count = width * height;
    const byte_count = pixel_count * 4; // RGBA

    std.debug.assert(pixels1.len == byte_count);
    std.debug.assert(pixels2.len == byte_count);

    var max_delta: u8 = 0;
    var total_diff_pixels: u32 = 0;
    var sum_delta: u64 = 0;

    var i: usize = 0;
    while (i < byte_count) : (i += 4) {
        const r1 = pixels1[i];
        const g1 = pixels1[i + 1];
        const b1 = pixels1[i + 2];
        const a1 = pixels1[i + 3];

        const r2 = pixels2[i];
        const g2 = pixels2[i + 1];
        const b2 = pixels2[i + 2];
        const a2 = pixels2[i + 3];

        // Calculate per-channel deltas
        const dr = if (r1 > r2) r1 - r2 else r2 - r1;
        const dg = if (g1 > g2) g1 - g2 else g2 - g1;
        const db = if (b1 > b2) b1 - b2 else b2 - b1;
        const da = if (a1 > a2) a1 - a2 else a2 - a1;

        // Max delta across all channels
        const pixel_max_delta = @max(@max(dr, dg), @max(db, da));

        if (pixel_max_delta > 0) {
            total_diff_pixels += 1;
            sum_delta += pixel_max_delta;
        }

        max_delta = @max(max_delta, pixel_max_delta);
    }

    const avg_delta: f64 = if (total_diff_pixels > 0)
        @as(f64, @floatFromInt(sum_delta)) / @as(f64, @floatFromInt(total_diff_pixels))
    else
        0.0;

    return .{
        .max_delta = max_delta,
        .total_diff_pixels = total_diff_pixels,
        .avg_delta = avg_delta,
    };
}

/// Load two PNG files, decode, and compare pixels
pub fn comparePngFiles(
    allocator: std.mem.Allocator,
    path1: []const u8,
    path2: []const u8,
) !PixelDifference {
    // Load first PNG
    var read_buffer1: [1024 * 1024]u8 = undefined;
    var img1 = try zigimg.Image.fromFilePath(allocator, path1, &read_buffer1);
    defer img1.deinit(allocator);

    // Load second PNG
    var read_buffer2: [1024 * 1024]u8 = undefined;
    var img2 = try zigimg.Image.fromFilePath(allocator, path2, &read_buffer2);
    defer img2.deinit(allocator);

    // Verify dimensions match
    if (img1.width != img2.width or img1.height != img2.height) {
        return error.DimensionMismatch;
    }

    // Convert to RGBA32 if needed
    const rgba1 = try convertToRgba32(allocator, &img1);
    defer if (rgba1.owned) allocator.free(rgba1.pixels);

    const rgba2 = try convertToRgba32(allocator, &img2);
    defer if (rgba2.owned) allocator.free(rgba2.pixels);

    // Compare pixel data
    return comparePixels(
        rgba1.pixels,
        rgba2.pixels,
        @intCast(img1.width),
        @intCast(img1.height),
    );
}

const RgbaPixels = struct {
    pixels: []const u8,
    owned: bool,
};

/// Convert image to RGBA32 format
fn convertToRgba32(allocator: std.mem.Allocator, img: *zigimg.Image) !RgbaPixels {
    switch (img.pixels) {
        .rgba32 => |rgba| {
            // Already RGBA32, use directly
            return .{ .pixels = std.mem.sliceAsBytes(rgba), .owned = false };
        },
        .rgb24 => |rgb| {
            // Convert RGB24 to RGBA32
            const pixel_count = img.width * img.height;
            const rgba_bytes = try allocator.alloc(u8, pixel_count * 4);

            for (rgb, 0..) |rgb_pixel, i| {
                rgba_bytes[i * 4] = rgb_pixel.r;
                rgba_bytes[i * 4 + 1] = rgb_pixel.g;
                rgba_bytes[i * 4 + 2] = rgb_pixel.b;
                rgba_bytes[i * 4 + 3] = 255; // Full alpha
            }

            return .{ .pixels = rgba_bytes, .owned = true };
        },
        .grayscale8 => |gray| {
            // Convert Grayscale8 to RGBA32
            const pixel_count = img.width * img.height;
            const rgba_bytes = try allocator.alloc(u8, pixel_count * 4);

            for (gray, 0..) |gray_pixel, i| {
                rgba_bytes[i * 4] = gray_pixel.value;
                rgba_bytes[i * 4 + 1] = gray_pixel.value;
                rgba_bytes[i * 4 + 2] = gray_pixel.value;
                rgba_bytes[i * 4 + 3] = 255; // Full alpha
            }

            return .{ .pixels = rgba_bytes, .owned = true };
        },
        else => return error.UnsupportedPixelFormat,
    }
}
