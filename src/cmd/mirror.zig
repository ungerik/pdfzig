//! Mirror command - Mirror PDF pages horizontally or vertically

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    updown: bool = false,
    leftright: bool = false,
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
            } else if (std.mem.eql(u8, arg, "--updown")) {
                args.updown = true;
            } else if (std.mem.eql(u8, arg, "--leftright")) {
                args.leftright = true;
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (args.input_path == null) {
            args.input_path = arg;
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

    // Default to leftright if neither specified
    if (!args.updown and !args.leftright) {
        args.leftright = true;
    }

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

    // Parse page range or use all pages
    const pages_to_mirror = try main.parsePageList(allocator, args.page_range, page_count, stderr);
    defer allocator.free(pages_to_mirror);

    // Mirror each specified page
    for (pages_to_mirror) |page_num| {
        var page = doc.loadPage(page_num - 1) catch |err| {
            try stderr.print("Error loading page {d}: {}\n", .{ page_num, err });
            try stderr.flush();
            std.process.exit(1);
        };
        defer page.close();

        const page_width = page.getWidth();
        const page_height = page.getHeight();

        // Apply transformations to all objects on the page
        const obj_count = page.getObjectCount();
        var obj_idx: u32 = 0;
        while (obj_idx < obj_count) : (obj_idx += 1) {
            if (page.getObject(obj_idx)) |obj| {
                // Apply left-right mirror first if requested
                if (args.leftright) {
                    // Mirror horizontally: scale X by -1, translate by page width
                    obj.transform(-1, 0, 0, 1, page_width, 0);
                }
                // Apply up-down mirror second if requested
                if (args.updown) {
                    // Mirror vertically: scale Y by -1, translate by page height
                    obj.transform(1, 0, 0, -1, 0, page_height);
                }
            }
        }

        if (!page.generateContent()) {
            try stderr.print("Error generating content for page {d}\n", .{page_num});
            try stderr.flush();
            std.process.exit(1);
        }
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
    const mirror_type: []const u8 = if (args.leftright and args.updown)
        "left-right and up-down"
    else if (args.updown)
        "up-down"
    else
        "left-right";

    if (pages_to_mirror.len == page_count) {
        try stdout.print("Mirrored all {d} pages ({s})\n", .{ page_count, mirror_type });
    } else {
        try stdout.print("Mirrored {d} page(s) ({s})\n", .{ pages_to_mirror.len, mirror_type });
    }

    if (!std.mem.eql(u8, output_path, input_path)) {
        try stdout.print("Saved to: {s}\n", .{output_path});
    }
}

pub fn printUsage(stdout: *std.Io.Writer) void {
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
