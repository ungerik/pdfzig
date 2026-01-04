//! Download PDFium command - Download PDFium library for your platform

const std = @import("std");
const downloader = @import("../pdfium/downloader.zig");
const loader = @import("../pdfium/loader.zig");
const main = @import("../main.zig");

const Args = struct {
    build_version: ?u32 = null,
    show_help: bool = false,
};

/// Display a progress bar for downloads
fn displayProgress(downloaded: u64, total: ?u64) void {
    const stderr_file = std.fs.File.stderr();
    var buf: [128]u8 = undefined;

    if (total) |t| {
        const percent = if (t > 0) @as(u32, @intCast((downloaded * 100) / t)) else 0;
        const bar_width: u32 = 40;
        const filled = (percent * bar_width) / 100;

        // Build progress bar
        var bar: [40]u8 = undefined;
        for (0..bar_width) |i| {
            bar[i] = if (i < filled) '=' else if (i == filled) '>' else ' ';
        }

        // Format: [=====>     ] 45% 12.3/27.0 MB
        const downloaded_mb = @as(f64, @floatFromInt(downloaded)) / (1024 * 1024);
        const total_mb = @as(f64, @floatFromInt(t)) / (1024 * 1024);

        const len = std.fmt.bufPrint(&buf, "\r[{s}] {d:3}% {d:.1}/{d:.1} MB", .{ bar[0..bar_width], percent, downloaded_mb, total_mb }) catch return;
        _ = stderr_file.write(len) catch {};
    } else {
        // Unknown total size
        const downloaded_mb = @as(f64, @floatFromInt(downloaded)) / (1024 * 1024);
        const len = std.fmt.bufPrint(&buf, "\rDownloaded: {d:.1} MB", .{downloaded_mb}) catch return;
        _ = stderr_file.write(len) catch {};
    }
}

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

    const downloaded_version = downloader.downloadPdfiumWithProgress(allocator, args.build_version, exe_dir, displayProgress) catch |err| {
        stderr.writeAll("\n") catch {}; // Clear progress line
        stderr.print("Error: Download failed: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    // Clear progress line and show success
    stderr.writeAll("\r\x1b[K") catch {}; // Clear line with ANSI escape
    stdout.print("Successfully downloaded PDFium build {d}\n", .{downloaded_version}) catch {};

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
