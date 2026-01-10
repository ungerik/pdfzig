//! Extract Attachments command - Extract embedded attachments from PDF

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");
const cli_parsing = @import("../cli_parsing.zig");
const shared = @import("shared.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_dir: []const u8 = ".",
    pattern: ?[]const u8 = null, // Glob pattern like "*.xml"
    password: ?[]const u8 = null,
    list_only: bool = false,
    quiet: bool = false,
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
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                args.quiet = true;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                args.list_only = true;
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                args.password = arg_it.next();
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else {
            if (args.input_path == null) {
                args.input_path = arg;
            } else if (args.pattern == null and std.mem.indexOfAny(u8, arg, "*?") != null) {
                // If it contains wildcards, treat as pattern
                args.pattern = arg;
            } else if (args.pattern == null and args.output_dir[0] == '.') {
                // First non-wildcard positional after input is output_dir
                args.output_dir = arg;
            } else if (args.pattern == null) {
                // Could be a pattern without wildcards (exact match) or output_dir
                // Heuristic: if it looks like a filename with extension, it's a pattern
                if (std.mem.lastIndexOfScalar(u8, arg, '.')) |_| {
                    args.pattern = arg;
                } else {
                    args.output_dir = arg;
                }
            }
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

    // Create output directory if not list-only mode
    if (!args.list_only) {
        shared.createOutputDirectory(args.output_dir, stderr);
    }

    // Open document
    var doc = main.openDocument(allocator, input_path, args.password, stderr) orelse std.process.exit(1);
    defer doc.close();

    const attachment_count = doc.getAttachmentCount();
    if (attachment_count == 0) {
        if (!args.quiet) {
            try stdout.writeAll("No embedded files found.\n");
        }
        return;
    }

    var extracted_count: u32 = 0;
    var it = doc.attachments();

    while (it.next()) |attachment| {
        const name = attachment.getName(allocator) orelse continue;
        defer allocator.free(name);

        // Apply pattern filter if specified
        if (args.pattern) |pattern| {
            if (!cli_parsing.matchGlobPatternCaseInsensitive(pattern, std.fs.path.basename(name))) {
                continue;
            }
        }

        extracted_count += 1;

        if (args.list_only) {
            try stdout.print("{s}\n", .{name});
            continue;
        }

        // Get the file data
        const data = attachment.getData(allocator) orelse {
            try stderr.print("Warning: Could not read data for {s}\n", .{name});
            try stderr.flush();
            continue;
        };
        defer allocator.free(data);

        // Create output path - use basename of attachment name
        const basename = std.fs.path.basename(name);
        const output_path = std.fs.path.join(allocator, &.{ args.output_dir, basename }) catch continue;
        defer allocator.free(output_path);

        // Write the file
        const file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
            try stderr.print("Error: Could not create {s}: {}\n", .{ output_path, err });
            try stderr.flush();
            continue;
        };
        defer file.close();

        file.writeAll(data) catch |err| {
            try stderr.print("Error: Could not write {s}: {}\n", .{ output_path, err });
            try stderr.flush();
            continue;
        };

        if (!args.quiet) {
            try stdout.print("Extracted: {s}\n", .{output_path});
        }
    }

    if (!args.quiet and !args.list_only) {
        try stdout.print("\nExtracted {d} file(s)\n", .{extracted_count});
    } else if (!args.quiet and args.list_only) {
        try stdout.print("\nFound {d} file(s)\n", .{extracted_count});
    }
}

pub fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig extract_attachments [options] <input.pdf> [pattern] [output_dir]
        \\
        \\Extract embedded attachments from PDF.
        \\
        \\Arguments:
        \\  input.pdf             Input PDF file
        \\  pattern               Optional glob pattern to filter files (e.g., "*.xml")
        \\  output_dir            Output directory (default: current directory)
        \\
        \\Options:
        \\  -l, --list            List attachments without extracting
        \\  -P, --password <PW>   Password for encrypted PDFs
        \\  -q, --quiet           Suppress progress output
        \\  -h, --help            Show this help message
        \\
        \\Pattern Syntax:
        \\  *                     Match any characters
        \\  ?                     Match single character
        \\
        \\Examples:
        \\  pdfzig extract_attachments document.pdf                  # Extract all
        \\  pdfzig extract_attachments document.pdf "*.xml"          # Extract XML files
        \\  pdfzig extract_attachments document.pdf "*.xml" ./out    # Extract to directory
        \\  pdfzig extract_attachments -l document.pdf               # List all attachments
        \\  pdfzig extract_attachments -l document.pdf "*.json"      # List JSON files only
        \\
    ) catch {};
}
