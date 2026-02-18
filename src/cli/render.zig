//! Render command - Render PDF pages to image files

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const images = @import("../pdfcontent/images.zig");
const shared = @import("shared.zig");
const cli_parsing = @import("arg_parsing.zig");
const lib_render = @import("../pdfzig/render.zig");

const OutputSpec = cli_parsing.OutputSpec;

const Args = struct {
    input_path: ?[]const u8 = null,
    output_dir: []const u8 = ".",
    outputs: std.array_list.Managed(OutputSpec),
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    quiet: bool = false,
    show_help: bool = false,
};

/// Run the render command: render PDF pages to image files.
/// Supports multiple output specs (-O DPI:FORMAT:QUALITY:TEMPLATE) for
/// generating images at different resolutions and formats in one pass.
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

    var args = Args{ .outputs = std.array_list.Managed(OutputSpec).init(allocator) };
    defer args.outputs.deinit();

    // Default output if none specified
    var has_output_spec = false;

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                args.quiet = true;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pages")) {
                args.page_range = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                args.password = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "--output-spec")) {
                // Format: DPI:FORMAT:QUALITY:TEMPLATE
                // Example: 300:png:0:page_{num}.png or 72:jpeg:85:thumb_{num}.jpg
                const spec_str = arg_it.next() orelse {
                    shared.exitWithErrorMsg(stderr, "Error: --output-spec requires an argument\n");
                };
                const spec = cli_parsing.parseOutputSpec(spec_str) catch {
                    shared.exitWithError(stderr, "Error: Invalid output spec '{s}'\n", .{spec_str});
                };
                try args.outputs.append(spec);
                has_output_spec = true;
            } else {
                shared.exitWithError(stderr, "Unknown option: {s}\n", .{arg});
            }
        } else {
            if (args.input_path == null) {
                args.input_path = arg;
            } else {
                args.output_dir = arg;
            }
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        return;
    }

    const input_path = shared.requireInputPath(args.input_path, stderr);

    // Add default output spec if none provided
    if (!has_output_spec) {
        try args.outputs.append(.{
            .dpi = 150.0,
            .format = .png,
            .quality = 90,
            .template = "page_{num}.{ext}",
        });
    }

    // Create output directory
    shared.createOutputDirectory(args.output_dir, stderr);

    // Open document
    var doc = shared.openDocumentOrExit(allocator, input_path, args.password, stderr);
    defer doc.close();

    const page_count = doc.getPageCount();
    if (page_count == 0) {
        shared.exitWithErrorMsg(stderr, "Error: PDF has no pages\n");
    }

    // Parse page ranges
    var page_ranges: ?[]cli_parsing.PageRange = null;
    defer if (page_ranges) |ranges| allocator.free(ranges);

    if (args.page_range) |range_str| {
        page_ranges = shared.parsePageRangesOrExit(allocator, range_str, page_count, stderr);
    }

    // Get basename
    const basename = cli_parsing.getBasename(input_path);

    // Render pages
    var rendered_count: usize = 0;
    for (1..page_count + 1) |page_num| {
        if (page_ranges) |ranges| {
            if (!cli_parsing.isPageInRanges(page_num, ranges)) continue;
        }

        var page = doc.loadPage(page_num - 1) catch {
            try stderr.print("Error: Could not load page {d}\n", .{page_num});
            try stderr.flush();
            continue;
        };
        defer page.close();

        // Render with each output spec
        for (args.outputs.items) |spec| {
            var bitmap = lib_render.renderPageToBitmap(&page, spec.dpi) catch {
                try stderr.print("Error: Could not create bitmap for page {d}\n", .{page_num});
                try stderr.flush();
                continue;
            };
            defer bitmap.destroy();

            const filename = try formatOutputPath(
                allocator,
                spec.template,
                page_num,
                page_count,
                basename,
                spec.format,
            );
            defer allocator.free(filename);

            const output_path = try std.fs.path.join(allocator, &.{ args.output_dir, filename });
            defer allocator.free(output_path);

            images.writeBitmap(allocator, bitmap, output_path, .{
                .format = spec.format,
                .jpeg_quality = spec.quality,
            }) catch {
                try stderr.print("Error: Could not write {s}\n", .{output_path});
                try stderr.flush();
                continue;
            };

            if (!args.quiet) {
                try stdout.print("Wrote: {s}\n", .{output_path});
            }
        }

        rendered_count += 1;
    }

    if (!args.quiet) {
        try stdout.print("\nRendered {d} page(s)\n", .{rendered_count});
    }
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig render [options] <input.pdf> [output_dir]
        \\
        \\Render PDF pages to image files.
        \\
        \\Options:
        \\  -O, --output-spec <SPEC>  Output specification (can be repeated)
        \\                            Format: DPI:FORMAT:QUALITY:TEMPLATE
        \\                            Example: 300:png:0:page_{num}.png
        \\                            Example: 72:jpeg:85:thumb_{num}.jpg
        \\  -p, --pages <RANGE>       Page range, e.g., "1-5,8,10-12" (default: all)
        \\  -P, --password <PW>       Password for encrypted PDFs
        \\  -q, --quiet               Suppress progress output
        \\  -h, --help                Show this help message
        \\
        \\Template Variables:
        \\  {num}      Page number (1-based)
        \\  {num0}     Zero-padded page number
        \\  {basename} Input PDF filename without extension
        \\  {ext}      File extension based on format
        \\
        \\Examples:
        \\  pdfzig render document.pdf
        \\  pdfzig render -O 300:png:0:page_{num}.png document.pdf ./output
        \\  pdfzig render -O 300:png:0:{basename}_{num0}.png -O 72:jpeg:85:thumb_{num}.jpg doc.pdf
        \\
    ) catch {};
}

/// Format an output filename from a template
pub fn formatOutputPath(
    allocator: std.mem.Allocator,
    template: []const u8,
    page_num: usize,
    total_pages: usize,
    basename: []const u8,
    format: images.Format,
) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    // Calculate padding width for zero-padded numbers
    const padding_width = std.math.log10(total_pages) + 1;

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            // Find closing brace
            const end = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                try result.append(template[i]);
                i += 1;
                continue;
            };

            const var_name = template[i + 1 .. end];

            if (std.mem.eql(u8, var_name, "num")) {
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d}", .{page_num}) catch unreachable;
                try result.appendSlice(num_str);
            } else if (std.mem.eql(u8, var_name, "num0")) {
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d:0>[1]}", .{ page_num, padding_width }) catch unreachable;
                try result.appendSlice(num_str);
            } else if (std.mem.eql(u8, var_name, "basename")) {
                try result.appendSlice(basename);
            } else if (std.mem.eql(u8, var_name, "ext")) {
                try result.appendSlice(format.extension());
            } else {
                // Unknown variable, keep as-is
                try result.appendSlice(template[i .. end + 1]);
            }

            i = end + 1;
        } else {
            try result.append(template[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice();
}

test "formatOutputPath" {
    const allocator = std.testing.allocator;

    {
        const path = try formatOutputPath(allocator, "page_{num}.{ext}", 5, 100, "test", .png);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("page_5.png", path);
    }

    {
        const path = try formatOutputPath(allocator, "{basename}_{num0}.{ext}", 5, 100, "document", .jpeg);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("document_005.jpg", path);
    }
}

test "formatOutputPath with unknown variable" {
    const allocator = std.testing.allocator;
    const path = try formatOutputPath(allocator, "page_{unknown}.{ext}", 1, 10, "test", .png);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("page_{unknown}.png", path);
}

test "formatOutputPath zero padding" {
    const allocator = std.testing.allocator;

    // Single digit total pages - no padding needed
    {
        const path = try formatOutputPath(allocator, "{num0}.png", 1, 9, "test", .png);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("1.png", path);
    }

    // Two digit total pages
    {
        const path = try formatOutputPath(allocator, "{num0}.png", 1, 99, "test", .png);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("01.png", path);
    }

    // Three digit total pages
    {
        const path = try formatOutputPath(allocator, "{num0}.png", 1, 100, "test", .png);
        defer allocator.free(path);
        try std.testing.expectEqualStrings("001.png", path);
    }
}
