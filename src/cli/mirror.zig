//! CLI: Mirror command - Mirror PDF pages horizontally or vertically

const std = @import("std");
const cli_parsing = @import("arg_parsing.zig");
const shared = @import("shared.zig");
const pdfzig_mirror = @import("../pdfzig/mirror.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    updown: bool = false,
    leftright: bool = false,
    show_help: bool = false,
};

/// Run the mirror command: mirror PDF pages horizontally or vertically.
/// Defaults to horizontal (left-right) if neither --leftright nor --updown is specified.
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
            } else if (std.mem.eql(u8, arg, "--updown")) {
                args.updown = true;
            } else if (std.mem.eql(u8, arg, "--leftright")) {
                args.leftright = true;
            } else {
                shared.exitWithError(stderr, "Unknown option: {s}\n", .{arg});
            }
        } else if (args.input_path == null) {
            args.input_path = arg;
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        return;
    }

    const input_path = shared.requireInputPath(args.input_path, stderr);

    // Default to leftright if neither specified
    if (!args.updown and !args.leftright) {
        args.leftright = true;
    }

    // Setup temp file for in-place editing
    const temp_ctx = shared.setupTempFileForInPlaceEdit(input_path, args.output_path, stderr);

    // Open the document
    var doc = shared.openDocumentOrExit(allocator, input_path, args.password, stderr);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Mirror pages using library function
    var mirrored_count: usize = 0;
    if (shared.parsePageRangesOrExit(allocator, args.page_range, page_count, stderr)) |ranges| {
        defer allocator.free(ranges);
        for (ranges) |range| {
            mirrored_count += pdfzig_mirror.mirrorPages(&doc, args.leftright, args.updown, range.start, range.end) catch |err| {
                shared.exitWithError(stderr, "Error mirroring pages: {}\n", .{err});
            };
        }
    } else {
        mirrored_count = pdfzig_mirror.mirrorPages(&doc, args.leftright, args.updown, 1, page_count) catch |err| {
            shared.exitWithError(stderr, "Error mirroring pages: {}\n", .{err});
        };
    }

    // Save the document
    doc.saveWithVersion(temp_ctx.actual_output_path, null) catch |err| {
        shared.exitWithError(stderr, "Error saving PDF: {}\n", .{err});
    };

    // Complete temp file operation (rename if needed)
    shared.completeTempFileEdit(temp_ctx, stderr);

    // Report success
    const mirror_type: []const u8 = if (args.leftright and args.updown)
        "left-right and up-down"
    else if (args.updown)
        "up-down"
    else
        "left-right";

    if (mirrored_count == page_count) {
        try stdout.print("Mirrored all {d} pages ({s})\n", .{ page_count, mirror_type });
    } else {
        try stdout.print("Mirrored {d} page(s) ({s})\n", .{ mirrored_count, mirror_type });
    }

    shared.reportSaveSuccess(stdout, temp_ctx.output_path, temp_ctx.input_path);
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig mirror [options] <input.pdf>
        \\
        \\Mirror PDF pages horizontally (left-right) or vertically (up-down).
        \\
        \\Arguments:
        \\  input.pdf               Input PDF file
        \\
        \\Options:
        \\  --leftright             Mirror left to right (horizontal flip)
        \\  --updown                Mirror up to down (vertical flip)
        \\  -o, --output <file>     Output file (default: overwrite input)
        \\  -p, --pages <range>     Pages to mirror (e.g., "1-5,8,10-12", default: all)
        \\  -P, --password <pwd>    Password for encrypted PDFs
        \\  -h, --help              Show this help message
        \\
        \\If neither --leftright nor --updown is specified, defaults to --leftright.
        \\Both options can be used together; transformations are applied in order.
        \\
        \\Examples:
        \\  pdfzig mirror document.pdf                      # Mirror all pages left-right
        \\  pdfzig mirror --updown document.pdf             # Mirror all pages up-down
        \\  pdfzig mirror --leftright --updown document.pdf # Apply both transforms
        \\  pdfzig mirror -p 1,3 document.pdf             # Mirror pages 1 and 3
        \\  pdfzig mirror -o out.pdf document.pdf         # Mirror and save to new file
        \\
    ) catch {};
}
