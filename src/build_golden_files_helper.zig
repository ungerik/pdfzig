//! Build helper for generating golden test files
//! Runs as separate executable during build step

const std = @import("std");
const test_golden_files = @import("test_golden_files.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const clean = blk: {
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--clean")) break :blk true;
        }
        break :blk false;
    };

    // Clean existing golden files if requested
    if (clean) {
        std.debug.print("Cleaning test-files/expected/ directory...\n", .{});
        std.fs.cwd().deleteTree("test-files/expected") catch |err| {
            if (err != error.FileNotFound) {
                std.debug.print("Warning: Failed to clean expected directory: {}\n", .{err});
            }
        };
    }

    // Generate golden files
    std.debug.print("Generating golden files...\n", .{});
    try test_golden_files.createExpectedTestFiles(allocator);
    std.debug.print("Golden files generated successfully.\n", .{});
}
