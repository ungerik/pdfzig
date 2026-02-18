//! Download PDFium command - Download PDFium library for your platform

const std = @import("std");
const downloader = @import("../pdfium/downloader.zig");
const loader = @import("../pdfium/loader.zig");
const cli_parsing = @import("arg_parsing.zig");
const shared = @import("shared.zig");

const Args = struct {
    build_version: ?u32 = null,
    show_help: bool = false,
};

/// Run the download_pdfium command: download the PDFium library for the current platform.
/// Optionally accepts a specific Chromium build version; defaults to latest.
/// The library is installed next to the pdfzig executable.
pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *cli_parsing.SliceArgIterator,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    var args = Args{};

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else {
                shared.exitWithError(stderr, "Unknown option: {s}\n", .{arg});
            }
        } else {
            // Parse version number
            args.build_version = std.fmt.parseInt(u32, arg, 10) catch {
                shared.exitWithError(stderr, "Error: Invalid build version '{s}'\n", .{arg});
            };
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        try stdout.flush();
        return;
    }

    // Get the executable directory
    const exe_dir = loader.getExecutableDir(allocator) catch |err| {
        shared.exitWithError(stderr, "Error: Could not determine executable directory: {}\n", .{err});
    };
    defer allocator.free(exe_dir);

    if (args.build_version) |ver| {
        try stdout.print("Downloading PDFium build {d}...\n", .{ver});
    } else {
        try stdout.writeAll("Downloading latest PDFium build...\n");
    }
    try stdout.flush();

    _ = downloader.downloadPdfiumWithProgress(allocator, args.build_version, exe_dir, downloader.displayProgress) catch |err| {
        stdout.writeAll("\n") catch {}; // Clear progress line on error
        shared.exitWithError(stderr, "Error: Download failed: {}\n", .{err});
    };

    // Show info about installed library
    if (loader.findBestPdfiumLibrary(allocator, exe_dir) catch null) |lib_info| {
        defer allocator.free(lib_info.path);
        try stdout.print("Library installed at: {s}\n", .{lib_info.path});
    }
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig download_pdfium [build]
        \\
        \\Download PDFium library for your platform.
        \\
        \\Arguments:
        \\  build                 Chromium build version (optional, default: latest)
        \\
        \\Options:
        \\  -h, --help            Show this help message
        \\
        \\The library is downloaded from github.com/bblanchon/pdfium-binaries
        \\and installed next to the pdfzig executable.
        \\
        \\Examples:
        \\  pdfzig download_pdfium           # Download latest build
        \\  pdfzig download_pdfium 7606      # Download specific Chromium build
        \\
    ) catch {};
}
