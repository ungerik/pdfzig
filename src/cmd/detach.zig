//! Detach command - Remove attachments from PDF

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");
const cli_parsing = @import("../cli_parsing.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    glob_pattern: ?[]const u8 = null,
    indices: std.array_list.Managed(u32) = undefined,
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
    args.indices = std.array_list.Managed(u32).init(allocator);
    defer args.indices.deinit();

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                args.output_path = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--glob")) {
                args.glob_pattern = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--index")) {
                if (arg_it.next()) |idx_str| {
                    const idx = std.fmt.parseInt(u32, idx_str, 10) catch {
                        try stderr.print("Invalid index: {s}\n", .{idx_str});
                        try stderr.flush();
                        std.process.exit(1);
                    };
                    try args.indices.append(idx);
                }
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                args.password = arg_it.next();
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

    if (args.glob_pattern == null and args.indices.items.len == 0) {
        try stderr.writeAll("Error: Specify attachments to remove with -g (glob) or -i (index)\n\n");
        try stderr.flush();
        printUsage(stdout);
        std.process.exit(1);
    }

    // Determine output path
    const output_path = args.output_path orelse input_path;
    const overwrite_original = args.output_path == null;

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

    const attachment_count = doc.getAttachmentCount();

    // Build list of indices to delete
    var indices_to_delete = std.array_list.Managed(u32).init(allocator);
    defer indices_to_delete.deinit();

    // Add explicitly specified indices
    for (args.indices.items) |idx| {
        if (idx < attachment_count) {
            try indices_to_delete.append(idx);
        } else {
            try stderr.print("Warning: Attachment index {d} out of range (max {d})\n", .{ idx, attachment_count - 1 });
            try stderr.flush();
        }
    }

    // Match by glob pattern
    if (args.glob_pattern) |pattern| {
        var it = doc.attachments();
        while (it.next()) |att| {
            if (att.getName(allocator)) |name| {
                defer allocator.free(name);
                if (cli_parsing.matchGlobPatternCaseInsensitive(pattern, name)) {
                    // Add if not already in list
                    var found = false;
                    for (indices_to_delete.items) |existing| {
                        if (existing == it.index - 1) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try indices_to_delete.append(it.index - 1);
                    }
                }
            }
        }
    }

    if (indices_to_delete.items.len == 0) {
        try stderr.writeAll("No matching attachments found\n");
        try stderr.flush();
        return;
    }

    // Sort in descending order to delete from end first
    std.mem.sort(u32, indices_to_delete.items, {}, std.sort.desc(u32));

    const deleted_count = indices_to_delete.items.len;

    // Delete attachments
    for (indices_to_delete.items) |idx| {
        doc.deleteAttachment(idx) catch |err| {
            try stderr.print("Error deleting attachment {d}: {}\n", .{ idx, err });
            try stderr.flush();
        };
    }

    // Save the document
    doc.saveWithVersion(actual_output_path, null) catch |err| {
        try stderr.print("Error saving PDF: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    // If overwriting original, rename temp file
    if (overwrite_original) {
        std.fs.cwd().deleteFile(input_path) catch {};
        std.fs.cwd().rename(actual_output_path, input_path) catch |err| {
            try stderr.print("Error replacing original file: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        };
    }

    try stdout.print("Removed {d} attachment(s)\n", .{deleted_count});
    if (!std.mem.eql(u8, output_path, input_path)) {
        try stdout.print("Saved to: {s}\n", .{output_path});
    }
}

pub fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig detach [options] <input.pdf>
        \\
        \\Remove file attachments from a PDF document.
        \\
        \\Arguments:
        \\  input.pdf             Input PDF file
        \\
        \\Options:
        \\  -i, --index <num>     Attachment index to remove (0-based, can be repeated)
        \\  -g, --glob <pattern>  Glob pattern to match attachment names (e.g., "*.xml")
        \\  -o, --output <file>   Output file (default: overwrite input)
        \\  -P, --password <pwd>  Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig detach -i 0 document.pdf              # Remove first attachment
        \\  pdfzig detach -i 0 -i 2 document.pdf         # Remove attachments 0 and 2
        \\  pdfzig detach -g "*.xml" document.pdf        # Remove all XML attachments
        \\  pdfzig detach -g "*" document.pdf            # Remove all attachments
        \\  pdfzig detach -o out.pdf -i 0 document.pdf   # Save to new file
        \\
    ) catch {};
}
