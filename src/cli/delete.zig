//! CLI: Delete command - Delete pages from PDF

const std = @import("std");
const cli_parsing = @import("arg_parsing.zig");
const shared = @import("shared.zig");
const pdfzig_delete = @import("../pdfzig/delete.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

/// Run the delete command: delete pages from a PDF document.
/// If no page range is specified, replaces all pages with a single empty page.
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
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        return;
    }

    const input_path = shared.requireInputPath(args.input_path, stderr);

    // Setup temp file for in-place editing
    const temp_ctx = shared.setupTempFileForInPlaceEdit(input_path, args.output_path, stderr);

    // Open the document
    var doc = shared.openDocumentOrExit(allocator, input_path, args.password, stderr);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Delete pages
    var deleted_count: usize = 0;
    if (shared.parsePageRangesOrExit(allocator, args.page_range, page_count, stderr)) |ranges| {
        defer allocator.free(ranges);

        // Count total pages to delete
        var total: usize = 0;
        for (ranges) |range| {
            total += range.end - range.start + 1;
        }
        if (total >= page_count) {
            shared.exitWithErrorMsg(stderr, "Error: Cannot delete all pages. Omit page range to replace all pages with an empty page.\n");
        }

        // Delete sub-ranges in reverse order to avoid index shifting
        var i = ranges.len;
        while (i > 0) {
            i -= 1;
            deleted_count += pdfzig_delete.deletePages(&doc, ranges[i].start, ranges[i].end) catch |err| {
                shared.exitWithError(stderr, "Error deleting pages: {}\n", .{err});
            };
        }
    } else {
        deleted_count = pdfzig_delete.replaceAllPagesWithEmpty(&doc) catch |err| {
            shared.exitWithError(stderr, "Error deleting pages: {}\n", .{err});
        };
    }

    // Save the document
    doc.saveWithVersion(temp_ctx.actual_output_path, null) catch |err| {
        shared.exitWithError(stderr, "Error saving PDF: {}\n", .{err});
    };

    // Complete temp file operation (rename if needed)
    shared.completeTempFileEdit(temp_ctx, stderr);

    // Report success
    if (args.page_range == null) {
        try stdout.print("Deleted all {d} pages, created empty page\n", .{page_count});
    } else {
        try stdout.print("Deleted {d} page(s), {d} page(s) remaining\n", .{ deleted_count, page_count - deleted_count });
    }

    shared.reportSaveSuccess(stdout, temp_ctx.output_path, temp_ctx.input_path);
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig delete [options] -p <pages> <input.pdf>
        \\
        \\Delete pages from a PDF document.
        \\
        \\Arguments:
        \\  input.pdf             Input PDF file
        \\
        \\Options:
        \\  -p, --pages <range>   Pages to delete (required, e.g., "1-5,8,10-12")
        \\  -o, --output <file>   Output file (default: overwrite input)
        \\  -P, --password <pwd>  Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig delete -p 1 document.pdf              # Delete first page
        \\  pdfzig delete -p 1-3 document.pdf            # Delete pages 1, 2, and 3
        \\  pdfzig delete -p 2,5,8 document.pdf          # Delete specific pages
        \\  pdfzig delete -p 1-3 -o out.pdf document.pdf # Delete and save to new file
        \\
    ) catch {};
}
