//! Attach command - Attach files to PDF

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");
const cli_parsing = @import("../cli_parsing.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    glob_pattern: ?[]const u8 = null,
    files: std.array_list.Managed([]const u8) = undefined,
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
    args.files = std.array_list.Managed([]const u8).init(allocator);
    defer args.files.deinit();

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                args.output_path = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--glob")) {
                args.glob_pattern = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                args.password = arg_it.next();
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (args.input_path == null) {
            args.input_path = arg;
        } else {
            try args.files.append(arg);
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

    // Handle glob pattern
    if (args.glob_pattern) |pattern| {
        // Expand glob pattern
        var glob_results = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
            try stderr.writeAll("Error: Cannot open current directory\n");
            try stderr.flush();
            std.process.exit(1);
        };
        defer glob_results.close();

        var it = glob_results.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (cli_parsing.matchGlobPatternCaseInsensitive(pattern, entry.name)) {
                const path_copy = allocator.dupe(u8, entry.name) catch {
                    try stderr.writeAll("Error: Out of memory\n");
                    try stderr.flush();
                    std.process.exit(1);
                };
                try args.files.append(path_copy);
            }
        }
    }

    if (args.files.items.len == 0) {
        try stderr.writeAll("Error: No files to attach specified\n\n");
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

    // Attach each file
    var attached_count: u32 = 0;
    for (args.files.items) |file_path| {
        // Read file content
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try stderr.print("Error opening file: {s}\n", .{file_path});
            try stderr.flush();
            continue;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
            try stderr.print("Error reading file: {s}\n", .{file_path});
            try stderr.flush();
            continue;
        };
        defer allocator.free(content);

        // Get just the filename for the attachment name
        const name = std.fs.path.basename(file_path);

        doc.addAttachment(allocator, name, content) catch {
            try stderr.print("Error attaching file: {s}\n", .{file_path});
            try stderr.flush();
            continue;
        };

        attached_count += 1;
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

    try stdout.print("Attached {d} file(s)\n", .{attached_count});
    if (!std.mem.eql(u8, output_path, input_path)) {
        try stdout.print("Saved to: {s}\n", .{output_path});
    }
}

pub fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig attach [options] <input.pdf> <file1> [file2] ...
        \\
        \\Add invisible file attachments to a PDF document.
        \\
        \\Arguments:
        \\  input.pdf             Input PDF file
        \\  file1, file2, ...     Files to attach
        \\
        \\Options:
        \\  -g, --glob <pattern>  Glob pattern to match files (e.g., "*.xml")
        \\  -o, --output <file>   Output file (default: overwrite input)
        \\  -P, --password <pwd>  Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig attach document.pdf invoice.xml       # Attach single file
        \\  pdfzig attach document.pdf a.txt b.txt       # Attach multiple files
        \\  pdfzig attach -g "*.xml" document.pdf        # Attach all XML files
        \\  pdfzig attach -o out.pdf doc.pdf data.json   # Save to new file
        \\
    ) catch {};
}
