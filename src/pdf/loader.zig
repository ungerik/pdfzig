const std = @import("std");

/// Load entire PDF file into memory buffer
pub fn loadPdfFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const buffer = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != stat.size) {
        return error.IncompleteRead;
    }

    return buffer;
}
