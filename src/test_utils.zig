//! Shared test utilities for downloading and caching test files

const std = @import("std");

/// Download a file from a URL to a local path using native Zig HTTP
pub fn downloadFile(allocator: std.mem.Allocator, url: []const u8, local_path: []const u8) !void {
    std.debug.print("Downloading: {s}\n", .{url});

    // Use native Zig HTTP client
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_writer.writer,
    }) catch |err| {
        std.debug.print("HTTP request failed for URL: {s}\n", .{url});
        std.debug.print("Error: {}\n", .{err});
        return error.DownloadFailed;
    };

    if (result.status != .ok) {
        std.debug.print("HTTP status {} for URL: {s}\n", .{ result.status, url });
        return error.DownloadFailed;
    }

    // Get the downloaded data and write to file
    var list = response_writer.toArrayList();
    const data = list.toOwnedSlice(allocator) catch return error.DownloadFailed;
    defer allocator.free(data);

    // Write to file
    const file = std.fs.cwd().createFile(local_path, .{}) catch |err| {
        std.debug.print("Failed to create file: {}\n", .{err});
        return err;
    };
    defer file.close();
    file.writeAll(data) catch |err| {
        std.debug.print("Failed to write file: {}\n", .{err});
        return err;
    };
}

/// Ensure a test file exists, downloading it if necessary
pub fn ensureTestFile(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    remote_path: []const u8,
    cache_dir: []const u8,
) ![]u8 {
    const local_path = try std.fs.path.join(allocator, &.{ cache_dir, remote_path });
    errdefer allocator.free(local_path);

    // Check if file exists
    const file = std.fs.cwd().openFile(local_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Create parent directories
            const dir_path = std.fs.path.dirname(local_path) orelse cache_dir;
            std.fs.cwd().makePath(dir_path) catch {};

            // Build full URL and download
            const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, remote_path });
            defer allocator.free(url);
            try downloadFile(allocator, url, local_path);
            return local_path;
        }
        allocator.free(local_path);
        return err;
    };
    file.close();
    return local_path;
}
