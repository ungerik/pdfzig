//! Rotate command - Rotate PDF pages

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");
const cli_parsing = @import("../cli_parsing.zig");
const shared = @import("shared.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    rotation: ?i32 = null,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *main.SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
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
                    try stderr.print("Invalid rotation angle: {s}\n", .{arg});
                    shared.exitWithErrorMsg(stderr, "Use: 90, 180, 270, -90, -180, -270, left, or right\n");
                };
            }
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        return;
    }

    const input_path = shared.requireInputPath(args.input_path, stderr, stdout, printUsage);

    const rotation = args.rotation orelse {
        try stderr.writeAll("Error: No rotation angle specified\n\n");
        try stderr.flush();
        printUsage(stdout);
        std.process.exit(1);
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

    // Parse page range or use all pages
    const pages_to_rotate = try cli_parsing.parsePageList(allocator, args.page_range, page_count, stderr);
    defer allocator.free(pages_to_rotate);

    // Rotate each specified page
    for (pages_to_rotate) |page_num| {
        var page = shared.loadPageOrExit(&doc, page_num, stderr);
        defer page.close();

        if (!page.rotate(rotation)) {
            shared.exitWithError(stderr, "Error: Invalid rotation angle {d}\n", .{rotation});
        }

        shared.generatePageContentWithNumOrExit(&page, page_num, stderr);
    }

    // Save the document
    doc.saveWithVersion(temp_ctx.actual_output_path, null) catch |err| {
        shared.exitWithError(stderr, "Error saving PDF: {}\n", .{err});
    };

    // Complete temp file operation (rename if needed)
    shared.completeTempFileEdit(temp_ctx, stderr);

    // Report success
    if (pages_to_rotate.len == page_count) {
        try stdout.print("Rotated all {d} pages by {d}°\n", .{ page_count, rotation });
    } else {
        try stdout.print("Rotated {d} page(s) by {d}°\n", .{ pages_to_rotate.len, rotation });
    }

    shared.reportSaveSuccess(stdout, temp_ctx.output_path, temp_ctx.input_path);
}

pub fn printUsage(stdout: *std.Io.Writer) void {
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
