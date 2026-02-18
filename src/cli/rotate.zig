//! CLI: Rotate command - Rotate PDF pages

const std = @import("std");
const cli_parsing = @import("arg_parsing.zig");
const shared = @import("shared.zig");
const pdfzig_rotate = @import("../pdfzig/rotate.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    rotation: ?i32 = null,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

/// Run the rotate command: rotate PDF pages by a specified angle.
/// Supports 90/180/270 degree rotations and aliases "left"/"right".
/// Modifies the input file in-place unless -o is specified.
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
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                args.output_path = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pages")) {
                args.page_range = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                args.password = arg_it.next();
            } else {
                shared.exitWithError(stderr, "Unknown option: {s}\n", .{arg});
            }
        } else if (args.input_path == null) {
            args.input_path = arg;
        } else if (args.rotation == null) {
            // Parse rotation angle or alias
            if (std.mem.eql(u8, arg, "left")) {
                args.rotation = 270;
            } else if (std.mem.eql(u8, arg, "right")) {
                args.rotation = 90;
            } else {
                args.rotation = std.fmt.parseInt(i32, arg, 10) catch {
                    shared.exitWithError(stderr, "Invalid rotation angle: {s}\nUse: 90, 180, 270, -90, -180, -270, left, or right\n", .{arg});
                };
            }
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        return;
    }

    const input_path = shared.requireInputPath(args.input_path, stderr);

    const rotation = args.rotation orelse {
        shared.exitWithErrorMsg(stderr, "Error: No rotation angle specified\n");
    };

    // Validate rotation angle
    if (@mod(rotation, 90) != 0) {
        shared.exitWithErrorMsg(stderr, "Error: Rotation must be a multiple of 90 degrees\n");
    }

    // Setup temp file for in-place editing
    const temp_ctx = shared.setupTempFileForInPlaceEdit(input_path, args.output_path, stderr);

    // Open the document
    var doc = shared.openDocumentOrExit(allocator, input_path, args.password, stderr);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Rotate pages using library function
    var rotated_count: usize = 0;
    if (shared.parsePageRangesOrExit(allocator, args.page_range, page_count, stderr)) |ranges| {
        defer allocator.free(ranges);
        for (ranges) |range| {
            rotated_count += pdfzig_rotate.rotatePages(&doc, rotation, range.start, range.end) catch |err| {
                shared.exitWithError(stderr, "Error rotating pages: {}\n", .{err});
            };
        }
    } else {
        rotated_count = pdfzig_rotate.rotatePages(&doc, rotation, 1, page_count) catch |err| {
            shared.exitWithError(stderr, "Error rotating pages: {}\n", .{err});
        };
    }

    // Save the document
    doc.saveWithVersion(temp_ctx.actual_output_path, null) catch |err| {
        shared.exitWithError(stderr, "Error saving PDF: {}\n", .{err});
    };

    // Complete temp file operation (rename if needed)
    shared.completeTempFileEdit(temp_ctx, stderr);

    // Report success
    if (rotated_count == page_count) {
        try stdout.print("Rotated all {d} pages by {d}°\n", .{ page_count, rotation });
    } else {
        try stdout.print("Rotated {d} page(s) by {d}°\n", .{ rotated_count, rotation });
    }

    shared.reportSaveSuccess(stdout, temp_ctx.output_path, temp_ctx.input_path);
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig rotate [options] <input.pdf> <degrees>
        \\
        \\Rotate PDF pages by the specified angle.
        \\
        \\Arguments:
        \\  input.pdf             Input PDF file
        \\  degrees               Rotation: 90, 180, 270, -90, -180, -270, left, right
        \\                        (left = -90°, right = 90°)
        \\
        \\Options:
        \\  -o, --output <file>   Output file (default: overwrite input)
        \\  -p, --pages <range>   Pages to rotate (e.g., "1-5,8,10-12", default: all)
        \\  -P, --password <pwd>  Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig rotate document.pdf right           # Rotate all pages 90° clockwise
        \\  pdfzig rotate document.pdf left            # Rotate all pages 90° counter-clockwise
        \\  pdfzig rotate document.pdf 180             # Rotate all pages 180°
        \\  pdfzig rotate -p 1,3 document.pdf 90       # Rotate pages 1 and 3 by 90°
        \\  pdfzig rotate -o out.pdf document.pdf left # Rotate and save to new file
        \\
    ) catch {};
}
