//! Download PDFium command - Download PDFium library for your platform

const std = @import("std");
const downloader = @import("../pdfium/downloader.zig");
const loader = @import("../pdfium/loader.zig");
const main = @import("../main.zig");

const Args = struct {
    build_version: ?u32 = null,
    show_help: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *main.SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) void {
    var args = Args{};

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else {
                stderr.print("Unknown option: {s}\n", .{arg}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            }
        } else {
            // Parse version number
            args.build_version = std.fmt.parseInt(u32, arg, 10) catch {
                stderr.print("Error: Invalid build version '{s}'\n", .{arg}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        stdout.flush() catch {};
        return;
    }

    // Get the executable directory
    const exe_dir = loader.getExecutableDir(allocator) catch |err| {
        stderr.print("Error: Could not determine executable directory: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(exe_dir);

    if (args.build_version) |ver| {
        stdout.print("Downloading PDFium build {d}...\n", .{ver}) catch {};
    } else {
        stdout.writeAll("Downloading latest PDFium build...\n") catch {};
    }
    stdout.flush() catch {};

    _ = downloader.downloadPdfiumWithProgress(allocator, args.build_version, exe_dir, downloader.displayProgress) catch |err| {
        stdout.writeAll("\n") catch {}; // Clear progress line on error
        stderr.print("Error: Download failed: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    // Show info about installed library
    if (loader.findBestPdfiumLibrary(allocator, exe_dir) catch null) |lib_info| {
        defer allocator.free(lib_info.path);
        stdout.print("Library installed at: {s}\n", .{lib_info.path}) catch {};
    }
}

pub fn printUsage(stdout: *std.Io.Writer) void {
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
