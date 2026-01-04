//! Delete command - Delete pages from PDF

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");
const cli_parsing = @import("../cli_parsing.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
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
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                args.password = arg_it.next();
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (args.input_path == null) {
            args.input_path = arg;
        } else if (args.page_range == null) {
            args.page_range = arg;
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printUsage(stdout);
        std.process.exit(1);
    };

    // Determine output path
    const output_path = args.output_path orelse input_path;
    const overwrite_original = args.output_path == null;

    // If overwriting, we need to save to a temp file first
    var temp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const actual_output_path = if (overwrite_original) blk: {
        const temp_path = std.fmt.bufPrint(&temp_path_buf, "{s}.tmp", .{input_path}) catch {
            try stderr.writeAll("Error: Path too long\n");
            try stderr.flush();
            std.process.exit(1);
        };
        break :blk temp_path;
    } else output_path;

    // Open the document
    var doc = if (args.password) |pwd|
        pdfium.Document.openWithPassword(input_path, pwd) catch |err| {
            try stderr.print("Error opening PDF: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        }
    else
        pdfium.Document.open(input_path) catch |err| {
            if (err == pdfium.Error.PasswordRequired) {
                try stderr.writeAll("Error: PDF is password protected. Use -P to provide password.\n");
            } else {
                try stderr.print("Error opening PDF: {}\n", .{err});
            }
            try stderr.flush();
            std.process.exit(1);
        };
    defer doc.close();

    const page_count = doc.getPageCount();

    // Handle "delete all pages" case - replace with single empty page
    if (args.page_range == null) {
        // Get dimensions of first page
        var first_page_width: f64 = 612; // Default letter size
        var first_page_height: f64 = 792;
        if (page_count > 0) {
            if (doc.loadPage(0)) |fp| {
                var first_page = fp;
                first_page_width = first_page.getWidth();
                first_page_height = first_page.getHeight();
                first_page.close();
            } else |_| {}
        }

        // Delete all pages (in reverse order)
        var p = page_count;
        while (p > 0) : (p -= 1) {
            doc.deletePage(p - 1) catch {};
        }

        // Insert one empty page with same dimensions
        _ = doc.createPage(0, first_page_width, first_page_height) catch {
            try stderr.writeAll("Error: Could not create empty page\n");
            try stderr.flush();
            std.process.exit(1);
        };

        // Save the document
        doc.saveWithVersion(actual_output_path, null) catch |err| {
            try stderr.print("Error saving PDF: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        };

        // If overwriting original, rename temp file to original
        if (overwrite_original) {
            std.fs.cwd().deleteFile(input_path) catch {};
            std.fs.cwd().rename(actual_output_path, input_path) catch |err| {
                try stderr.print("Error replacing original file: {}\n", .{err});
                try stderr.flush();
                std.process.exit(1);
            };
        }

        try stdout.print("Deleted all {d} pages, created empty page ({d}x{d})\n", .{ page_count, @as(u32, @intFromFloat(first_page_width)), @as(u32, @intFromFloat(first_page_height)) });
        if (!std.mem.eql(u8, output_path, input_path)) {
            try stdout.print("Saved to: {s}\n", .{output_path});
        }
        return;
    }

    // Parse page range to get pages to delete
    const pages_to_delete = try cli_parsing.parsePageList(allocator, args.page_range, page_count, stderr);
    defer allocator.free(pages_to_delete);

    // Check if trying to delete all pages
    if (pages_to_delete.len >= page_count) {
        try stderr.writeAll("Error: Cannot delete all pages. Omit page range to replace all pages with an empty page.\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Sort pages in descending order so we delete from the end first
    // (to avoid index shifting issues)
    std.mem.sort(u32, pages_to_delete, {}, std.sort.desc(u32));

    const deleted_count = pages_to_delete.len;

    // Delete pages (from highest to lowest index to avoid shifting issues)
    for (pages_to_delete) |page_num| {
        doc.deletePage(page_num - 1) catch |err| {
            try stderr.print("Error deleting page {d}: {}\n", .{ page_num, err });
            try stderr.flush();
            std.process.exit(1);
        };
    }

    // Save the document
    doc.saveWithVersion(actual_output_path, null) catch |err| {
        try stderr.print("Error saving PDF: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    // If overwriting original, rename temp file to original
    if (overwrite_original) {
        std.fs.cwd().deleteFile(input_path) catch {};
        std.fs.cwd().rename(actual_output_path, input_path) catch |err| {
            try stderr.print("Error replacing original file: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        };
    }

    // Report success
    try stdout.print("Deleted {d} page(s), {d} page(s) remaining\n", .{ deleted_count, page_count - deleted_count });

    if (!std.mem.eql(u8, output_path, input_path)) {
        try stdout.print("Saved to: {s}\n", .{output_path});
    }
}

pub fn printUsage(stdout: *std.Io.Writer) void {
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
