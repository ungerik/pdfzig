//! Extract Text command - Extract text content from PDF pages

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const cli_parsing = @import("../cli_parsing.zig");
const shared = @import("shared.zig");
const textfmt = @import("../pdfcontent/textfmt.zig");
const main = @import("../main.zig");

pub const TextOutputFormat = enum {
    text,
    json,

    pub fn fromString(str: []const u8) ?TextOutputFormat {
        if (std.mem.eql(u8, str, "text")) return .text;
        if (std.mem.eql(u8, str, "json")) return .json;
        return null;
    }
};

const Args = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    format: TextOutputFormat = .text,
    page_separator: ?[]const u8 = null, // null = default, "" = no separator
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
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
                if (arg_it.next()) |fmt_str| {
                    args.format = TextOutputFormat.fromString(fmt_str) orelse {
                        try stderr.print("Error: Unknown format '{s}'. Use 'text' or 'json'\n", .{fmt_str});
                        try stderr.flush();
                        std.process.exit(1);
                    };
                }
            } else if (std.mem.eql(u8, arg, "--page-separator") or std.mem.eql(u8, arg, "--page_separator")) {
                args.page_separator = arg_it.next() orelse "";
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else {
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

    // Open document
    var doc = main.openDocument(allocator, input_path, args.password, stderr) orelse std.process.exit(1);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Parse page ranges
    var page_ranges: ?[]cli_parsing.PageRange = null;
    defer if (page_ranges) |ranges| allocator.free(ranges);

    if (args.page_range) |range_str| {
        page_ranges = shared.parsePageRangesOrExit(allocator, range_str, page_count, stderr);
    }

    // Open output file or use stdout
    var output_file: ?std.fs.File = null;
    defer if (output_file) |f| f.close();

    var out_buf: [4096]u8 = undefined;
    var out_writer: @TypeOf(std.fs.File.stdout().writer(&out_buf)) = undefined;
    var output: *std.Io.Writer = stdout;

    if (args.output_path) |path| {
        output_file = std.fs.cwd().createFile(path, .{}) catch |err| {
            try stderr.print("Error: Could not create output file: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        };
        out_writer = output_file.?.writer(&out_buf);
        output = &out_writer.interface;
    }

    // Extract text based on format
    switch (args.format) {
        .text => {
            // Plain text extraction
            var first_page = true;
            for (1..page_count + 1) |i| {
                const page_num: u32 = @intCast(i);

                if (page_ranges) |ranges| {
                    if (!cli_parsing.isPageInRanges(page_num, ranges)) continue;
                }

                var page = doc.loadPage(page_num - 1) catch continue;
                defer page.close();

                var text_page = page.loadTextPage() orelse continue;
                defer text_page.close();

                if (text_page.getText(allocator)) |text| {
                    defer allocator.free(text);

                    // Print page separator (only if not first page and multi-page document)
                    if (!first_page and page_count > 1) {
                        if (args.page_separator) |sep| {
                            // User specified a separator (could be empty string)
                            if (sep.len > 0) {
                                // Replace {{PAGE_NO}} with actual page number
                                try printPageSeparator(allocator, output, sep, page_num);
                            } else {
                                // Empty string = just newline
                                try output.writeAll("\n");
                            }
                        } else {
                            // Default separator
                            try output.print("--- Page {d} ---\n", .{page_num});
                        }
                    }

                    try output.writeAll(text);
                    if (first_page or args.page_separator != null) {
                        try output.writeAll("\n");
                    } else {
                        try output.writeAll("\n\n");
                    }
                    first_page = false;
                }
            }
        },
        .json => {
            try textfmt.extractTextAsJson(allocator, &doc, page_count, page_ranges, output);
        },
    }

    try output.flush();
}

/// Print page separator with template variable replacement
fn printPageSeparator(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    separator_template: []const u8,
    page_num: u32,
) !void {
    // First, expand escape sequences like \n
    const expanded = try expandEscapeSequences(allocator, separator_template);
    defer allocator.free(expanded);

    // Check if template contains {{PAGE_NO}}
    if (std.mem.indexOf(u8, expanded, "{{PAGE_NO}}")) |pos| {
        // Split and replace
        const before = expanded[0..pos];
        const after = expanded[pos + "{{PAGE_NO}}".len ..];

        try output.writeAll(before);
        try output.print("{d}", .{page_num});
        try output.writeAll(after);
        try output.writeAll("\n");
    } else {
        // No template variable, just print as-is
        try output.writeAll(expanded);
        try output.writeAll("\n");
    }
}

/// Expand escape sequences like \n to actual characters
fn expandEscapeSequences(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            switch (input[i + 1]) {
                'n' => {
                    try result.append('\n');
                    i += 2;
                },
                't' => {
                    try result.append('\t');
                    i += 2;
                },
                'r' => {
                    try result.append('\r');
                    i += 2;
                },
                '\\' => {
                    try result.append('\\');
                    i += 2;
                },
                else => {
                    try result.append(input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

pub fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig extract_text [options] <input.pdf>
        \\
        \\Extract text content from PDF pages.
        \\
        \\Options:
        \\  -o, --output <FILE>        Write output to file (default: stdout)
        \\  -f, --format <FMT>         Output format: text (default) or json
        \\  -p, --pages <RANGE>        Page range, e.g., "1-5,8,10-12" (default: all)
        \\  -P, --password <PW>        Password for encrypted PDFs
        \\  --page-separator <SEP>     Custom page separator (text format only)
        \\                             Use {{PAGE_NO}} for page number placeholder
        \\                             Supports escape sequences: \n \t \r \\
        \\                             Empty string "" = no separator, just newline
        \\                             Default: "--- Page {{PAGE_NO}} ---"
        \\  -h, --help                 Show this help message
        \\
        \\Examples:
        \\  pdfzig extract_text document.pdf
        \\  pdfzig extract_text -o text.txt document.pdf
        \\  pdfzig extract_text -f json document.pdf > blocks.json
        \\  pdfzig extract_text -p 1-10 document.pdf > first_pages.txt
        \\  pdfzig extract_text --page-separator "=== Page {{PAGE_NO}} ===" doc.pdf
        \\  pdfzig extract_text --page-separator "" document.pdf
        \\
    ) catch {};
}

test "TextOutputFormat.fromString" {
    try std.testing.expectEqual(TextOutputFormat.text, TextOutputFormat.fromString("text"));
    try std.testing.expectEqual(TextOutputFormat.json, TextOutputFormat.fromString("json"));
    try std.testing.expectEqual(@as(?TextOutputFormat, null), TextOutputFormat.fromString("xml"));
    try std.testing.expectEqual(@as(?TextOutputFormat, null), TextOutputFormat.fromString(""));
    try std.testing.expectEqual(@as(?TextOutputFormat, null), TextOutputFormat.fromString("JSON")); // case sensitive
}
