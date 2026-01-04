//! Build-time helper for downloading PDFium for cross-compilation targets
//! This is a standalone program that gets built and run during `zig build all`

const std = @import("std");
const downloader = @import("downloader.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    // Parse arguments: <arch> <os> <output_dir>
    const arch_str = args.next() orelse {
        std.debug.print("Usage: build_download_helper <arch> <os> <output_dir>\n", .{});
        return error.InvalidArguments;
    };
    const os_str = args.next() orelse {
        std.debug.print("Usage: build_download_helper <arch> <os> <output_dir>\n", .{});
        return error.InvalidArguments;
    };
    const output_dir = args.next() orelse {
        std.debug.print("Usage: build_download_helper <arch> <os> <output_dir>\n", .{});
        return error.InvalidArguments;
    };

    // Parse architecture
    const arch: std.Target.Cpu.Arch = std.meta.stringToEnum(std.Target.Cpu.Arch, arch_str) orelse {
        std.debug.print("Unknown architecture: {s}\n", .{arch_str});
        return error.InvalidArguments;
    };

    // Parse OS
    const os: std.Target.Os.Tag = std.meta.stringToEnum(std.Target.Os.Tag, os_str) orelse {
        std.debug.print("Unknown OS: {s}\n", .{os_str});
        return error.InvalidArguments;
    };

    // Create output directory if it doesn't exist
    std.fs.makeDirAbsolute(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Failed to create output directory: {}\n", .{err});
            return err;
        }
    };

    // Download PDFium for the target
    const version = downloader.downloadPdfiumForTarget(allocator, arch, os, output_dir) catch |err| {
        std.debug.print("Download failed: {}\n", .{err});
        return err;
    };

    std.debug.print("Successfully downloaded PDFium v{d} for {s}-{s}\n", .{ version, arch_str, os_str });
}
