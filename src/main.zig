//! pdfzig - PDF utility tool using PDFium
//!
//! Commands:
//!   render              Render PDF pages to images
//!   extract-text        Extract text content from PDF
//!   extract-images      Extract embedded images from PDF
//!   extract-attachments Extract embedded attachments from PDF
//!   info                Display PDF metadata and information

const std = @import("std");
const pdfium = @import("pdfium.zig");
const renderer = @import("renderer.zig");
const image_writer = @import("image_writer.zig");

const version = "0.1.0";

const Command = enum {
    render,
    extract_text,
    extract_images,
    extract_attachments,
    info,
    help,
    version_cmd,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up stdout/stderr writers
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    var arg_it = std.process.args();
    _ = arg_it.skip(); // Skip program name

    const command_str = arg_it.next() orelse {
        printMainUsage(stdout);
        try stdout.flush();
        return;
    };

    // Check for global flags first
    if (std.mem.eql(u8, command_str, "-h") or std.mem.eql(u8, command_str, "--help") or std.mem.eql(u8, command_str, "help")) {
        printMainUsage(stdout);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, command_str, "-v") or std.mem.eql(u8, command_str, "--version") or std.mem.eql(u8, command_str, "version")) {
        try stdout.print("pdfzig {s}\n", .{version});
        try stdout.flush();
        return;
    }

    const command: Command = if (std.mem.eql(u8, command_str, "render"))
        .render
    else if (std.mem.eql(u8, command_str, "extract-text"))
        .extract_text
    else if (std.mem.eql(u8, command_str, "extract-images"))
        .extract_images
    else if (std.mem.eql(u8, command_str, "extract-attachments"))
        .extract_attachments
    else if (std.mem.eql(u8, command_str, "info"))
        .info
    else {
        try stderr.print("Unknown command: {s}\n\n", .{command_str});
        try stderr.flush();
        printMainUsage(stdout);
        try stdout.flush();
        std.process.exit(1);
    };

    // Initialize PDFium
    pdfium.init();
    defer pdfium.deinit();

    switch (command) {
        .render => try runRenderCommand(allocator, &arg_it, stdout, stderr),
        .extract_text => try runExtractTextCommand(allocator, &arg_it, stdout, stderr),
        .extract_images => try runExtractImagesCommand(allocator, &arg_it, stdout, stderr),
        .extract_attachments => try runExtractAttachmentsCommand(allocator, &arg_it, stdout, stderr),
        .info => try runInfoCommand(allocator, &arg_it, stdout, stderr),
        .help => printMainUsage(stdout),
        .version_cmd => try stdout.print("pdfzig {s}\n", .{version}),
    }

    try stdout.flush();
}

// ============================================================================
// Render Command
// ============================================================================

const RenderArgs = struct {
    input_path: ?[]const u8 = null,
    output_dir: []const u8 = ".",
    outputs: std.ArrayListUnmanaged(OutputSpec) = .empty,
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    quiet: bool = false,
    show_help: bool = false,
};

const OutputSpec = struct {
    dpi: f64,
    format: image_writer.Format,
    quality: u8,
    template: []const u8,
};

fn runRenderCommand(
    allocator: std.mem.Allocator,
    arg_it: *std.process.ArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = RenderArgs{};
    defer args.outputs.deinit(allocator);

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
                    try stderr.writeAll("Error: --output-spec requires an argument\n");
                    try stderr.flush();
                    std.process.exit(1);
                };
                const spec = parseOutputSpec(spec_str) catch {
                    try stderr.print("Error: Invalid output spec '{s}'\n", .{spec_str});
                    try stderr.flush();
                    std.process.exit(1);
                };
                try args.outputs.append(allocator, spec);
                has_output_spec = true;
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
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
        printRenderUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printRenderUsage(stdout);
        std.process.exit(1);
    };

    // Add default output spec if none provided
    if (!has_output_spec) {
        try args.outputs.append(allocator, .{
            .dpi = 150.0,
            .format = .png,
            .quality = 90,
            .template = "page_{num}.{ext}",
        });
    }

    // Create output directory
    std.fs.cwd().makePath(args.output_dir) catch |err| {
        try stderr.print("Error: Could not create output directory: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    // Open document
    var doc = openDocument(input_path, args.password, stderr) orelse std.process.exit(1);
    defer doc.close();

    const page_count = doc.getPageCount();
    if (page_count == 0) {
        try stderr.writeAll("Error: PDF has no pages\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Parse page ranges
    var page_ranges: ?[]renderer.PageRange = null;
    defer if (page_ranges) |ranges| allocator.free(ranges);

    if (args.page_range) |range_str| {
        page_ranges = renderer.parsePageRanges(allocator, range_str, page_count) catch {
            try stderr.print("Error: Invalid page range '{s}'\n", .{range_str});
            try stderr.flush();
            std.process.exit(1);
        };
    }

    // Get basename
    const basename = getBasename(input_path);

    // Render pages
    var rendered_count: u32 = 0;
    for (1..page_count + 1) |i| {
        const page_num: u32 = @intCast(i);

        if (page_ranges) |ranges| {
            if (!renderer.isPageInRanges(page_num, ranges)) continue;
        }

        var page = doc.loadPage(page_num - 1) catch {
            try stderr.print("Error: Could not load page {d}\n", .{page_num});
            try stderr.flush();
            continue;
        };
        defer page.close();

        // Render with each output spec
        for (args.outputs.items) |spec| {
            const dims = page.getDimensionsAtDpi(spec.dpi);

            var bitmap = pdfium.Bitmap.create(dims.width, dims.height, .bgra) catch {
                try stderr.print("Error: Could not create bitmap for page {d}\n", .{page_num});
                try stderr.flush();
                continue;
            };
            defer bitmap.destroy();

            bitmap.fillWhite();
            page.render(&bitmap, .{});

            const filename = try image_writer.formatOutputPath(
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

            image_writer.writeBitmap(bitmap, output_path, .{
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

fn parseOutputSpec(spec_str: []const u8) !OutputSpec {
    var it = std.mem.splitScalar(u8, spec_str, ':');

    const dpi_str = it.next() orelse return error.InvalidSpec;
    const format_str = it.next() orelse return error.InvalidSpec;
    const quality_str = it.next() orelse return error.InvalidSpec;
    const template = it.next() orelse return error.InvalidSpec;

    const dpi = std.fmt.parseFloat(f64, dpi_str) catch return error.InvalidSpec;
    const format = image_writer.Format.fromString(format_str) orelse return error.InvalidSpec;
    const quality = std.fmt.parseInt(u8, quality_str, 10) catch return error.InvalidSpec;

    return .{
        .dpi = dpi,
        .format = format,
        .quality = quality,
        .template = template,
    };
}

// ============================================================================
// Extract Text Command
// ============================================================================

const ExtractTextArgs = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

fn runExtractTextCommand(
    allocator: std.mem.Allocator,
    arg_it: *std.process.ArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = ExtractTextArgs{};

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
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else {
            args.input_path = arg;
        }
    }

    if (args.show_help) {
        printExtractTextUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printExtractTextUsage(stdout);
        std.process.exit(1);
    };

    // Open document
    var doc = openDocument(input_path, args.password, stderr) orelse std.process.exit(1);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Parse page ranges
    var page_ranges: ?[]renderer.PageRange = null;
    defer if (page_ranges) |ranges| allocator.free(ranges);

    if (args.page_range) |range_str| {
        page_ranges = renderer.parsePageRanges(allocator, range_str, page_count) catch {
            try stderr.print("Error: Invalid page range '{s}'\n", .{range_str});
            try stderr.flush();
            std.process.exit(1);
        };
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

    // Extract text from each page
    for (1..page_count + 1) |i| {
        const page_num: u32 = @intCast(i);

        if (page_ranges) |ranges| {
            if (!renderer.isPageInRanges(page_num, ranges)) continue;
        }

        var page = doc.loadPage(page_num - 1) catch continue;
        defer page.close();

        var text_page = page.loadTextPage() orelse continue;
        defer text_page.close();

        if (text_page.getText(allocator)) |text| {
            defer allocator.free(text);

            if (page_count > 1) {
                try output.print("--- Page {d} ---\n", .{page_num});
            }
            try output.writeAll(text);
            try output.writeAll("\n\n");
        }
    }

    try output.flush();
}

// ============================================================================
// Extract Images Command
// ============================================================================

const ExtractImagesArgs = struct {
    input_path: ?[]const u8 = null,
    output_dir: []const u8 = ".",
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    format: image_writer.Format = .png,
    quality: u8 = 90,
    quiet: bool = false,
    show_help: bool = false,
};

fn runExtractImagesCommand(
    allocator: std.mem.Allocator,
    arg_it: *std.process.ArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = ExtractImagesArgs{};

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
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
                const fmt_str = arg_it.next() orelse {
                    try stderr.writeAll("Error: --format requires an argument\n");
                    try stderr.flush();
                    std.process.exit(1);
                };
                args.format = image_writer.Format.fromString(fmt_str) orelse {
                    try stderr.print("Error: Invalid format '{s}'\n", .{fmt_str});
                    try stderr.flush();
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quality")) {
                const q_str = arg_it.next() orelse {
                    try stderr.writeAll("Error: --quality requires an argument\n");
                    try stderr.flush();
                    std.process.exit(1);
                };
                args.quality = std.fmt.parseInt(u8, q_str, 10) catch {
                    try stderr.writeAll("Error: Invalid quality value\n");
                    try stderr.flush();
                    std.process.exit(1);
                };
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
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
        printExtractImagesUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printExtractImagesUsage(stdout);
        std.process.exit(1);
    };

    // Create output directory
    std.fs.cwd().makePath(args.output_dir) catch |err| {
        try stderr.print("Error: Could not create output directory: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    // Open document
    var doc = openDocument(input_path, args.password, stderr) orelse std.process.exit(1);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Parse page ranges
    var page_ranges: ?[]renderer.PageRange = null;
    defer if (page_ranges) |ranges| allocator.free(ranges);

    if (args.page_range) |range_str| {
        page_ranges = renderer.parsePageRanges(allocator, range_str, page_count) catch {
            try stderr.print("Error: Invalid page range '{s}'\n", .{range_str});
            try stderr.flush();
            std.process.exit(1);
        };
    }

    var image_count: u32 = 0;

    // Extract images from each page
    for (1..page_count + 1) |i| {
        const page_num: u32 = @intCast(i);

        if (page_ranges) |ranges| {
            if (!renderer.isPageInRanges(page_num, ranges)) continue;
        }

        var page = doc.loadPage(page_num - 1) catch continue;
        defer page.close();

        var img_index: u32 = 0;
        var img_it = page.imageObjects();
        while (img_it.next()) |img_obj| {
            var bitmap = img_obj.getRenderedBitmap(doc) orelse img_obj.getBitmap() orelse continue;
            defer bitmap.destroy();

            // Generate filename
            var filename_buf: [256]u8 = undefined;
            const filename = std.fmt.bufPrint(&filename_buf, "page{d}_img{d}.{s}", .{
                page_num,
                img_index,
                args.format.extension(),
            }) catch continue;

            const output_path = std.fs.path.join(allocator, &.{ args.output_dir, filename }) catch continue;
            defer allocator.free(output_path);

            image_writer.writeBitmap(bitmap, output_path, .{
                .format = args.format,
                .jpeg_quality = args.quality,
            }) catch {
                try stderr.print("Error: Could not write {s}\n", .{output_path});
                try stderr.flush();
                continue;
            };

            if (!args.quiet) {
                try stdout.print("Extracted: {s}\n", .{output_path});
            }

            img_index += 1;
            image_count += 1;
        }
    }

    if (!args.quiet) {
        try stdout.print("\nExtracted {d} image(s)\n", .{image_count});
    }
}

// ============================================================================
// Extract Attachments Command
// ============================================================================

const ExtractAttachmentsArgs = struct {
    input_path: ?[]const u8 = null,
    output_dir: []const u8 = ".",
    pattern: ?[]const u8 = null, // Glob pattern like "*.xml"
    password: ?[]const u8 = null,
    list_only: bool = false,
    quiet: bool = false,
    show_help: bool = false,
};

fn runExtractAttachmentsCommand(
    allocator: std.mem.Allocator,
    arg_it: *std.process.ArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = ExtractAttachmentsArgs{};

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
        printExtractAttachmentsUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printExtractAttachmentsUsage(stdout);
        std.process.exit(1);
    };

    // Create output directory if not list-only mode
    if (!args.list_only) {
        std.fs.cwd().makePath(args.output_dir) catch |err| {
            try stderr.print("Error: Could not create output directory: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        };
    }

    // Open document
    var doc = openDocument(input_path, args.password, stderr) orelse std.process.exit(1);
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
            if (!matchGlobPattern(pattern, std.fs.path.basename(name))) {
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

/// Simple glob pattern matching supporting * and ? wildcards
pub fn matchGlobPattern(pattern: []const u8, name: []const u8) bool {
    var p_idx: usize = 0;
    var n_idx: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;

    while (n_idx < name.len) {
        if (p_idx < pattern.len) {
            const p_char = pattern[p_idx];
            const n_char = name[n_idx];

            if (p_char == '*') {
                // Record position for backtracking
                star_p = p_idx;
                star_n = n_idx;
                p_idx += 1;
                continue;
            } else if (p_char == '?' or std.ascii.toLower(p_char) == std.ascii.toLower(n_char)) {
                // Match single character (case-insensitive)
                p_idx += 1;
                n_idx += 1;
                continue;
            }
        }

        // Mismatch - try to backtrack to last *
        if (star_p) |sp| {
            p_idx = sp + 1;
            star_n += 1;
            n_idx = star_n;
        } else {
            return false;
        }
    }

    // Skip trailing *s in pattern
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

// ============================================================================
// Info Command
// ============================================================================

fn runInfoCommand(
    allocator: std.mem.Allocator,
    arg_it: *std.process.ArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var input_path: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var show_help = false;

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                show_help = true;
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                password = arg_it.next();
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else {
            input_path = arg;
        }
    }

    if (show_help) {
        printInfoUsage(stdout);
        return;
    }

    const path = input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printInfoUsage(stdout);
        std.process.exit(1);
    };

    // Try to open without password first to check encryption
    var doc = pdfium.Document.open(path) catch |err| {
        if (err == pdfium.Error.PasswordRequired) {
            if (password) |pwd| {
                var d = pdfium.Document.openWithPassword(path, pwd) catch |e| {
                    try stderr.print("Error: {}\n", .{e});
                    try stderr.flush();
                    std.process.exit(1);
                };
                try printDocInfo(allocator, &d, path, true, stdout);
                d.close();
                return;
            } else {
                try stdout.print("File: {s}\n", .{path});
                try stdout.writeAll("Encrypted: Yes (password required to access)\n");
                try stdout.writeAll("\nUse -P <password> to provide the document password.\n");
                return;
            }
        } else {
            try stderr.print("Error: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        }
    };
    defer doc.close();

    try printDocInfo(allocator, &doc, path, doc.isEncrypted(), stdout);
}

fn printDocInfo(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    path: []const u8,
    encrypted: bool,
    stdout: *std.Io.Writer,
) !void {
    try stdout.print("File: {s}\n", .{path});
    try stdout.print("Pages: {d}\n", .{doc.getPageCount()});

    if (doc.getFileVersion()) |ver| {
        const major = ver / 10;
        const minor = ver % 10;
        try stdout.print("PDF Version: {d}.{d}\n", .{ major, minor });
    }

    try stdout.print("Encrypted: {s}\n", .{if (encrypted) "Yes" else "No"});

    if (encrypted) {
        const revision = doc.getSecurityHandlerRevision();
        if (revision >= 0) {
            try stdout.print("Security Handler Revision: {d}\n", .{revision});
        }
    }

    // Metadata
    var metadata = doc.getMetadata(allocator);
    defer metadata.deinit(allocator);

    try stdout.writeAll("\nMetadata:\n");
    if (metadata.title) |t| try stdout.print("  Title: {s}\n", .{t});
    if (metadata.author) |a| try stdout.print("  Author: {s}\n", .{a});
    if (metadata.subject) |s| try stdout.print("  Subject: {s}\n", .{s});
    if (metadata.keywords) |k| try stdout.print("  Keywords: {s}\n", .{k});
    if (metadata.creator) |c_| try stdout.print("  Creator: {s}\n", .{c_});
    if (metadata.producer) |p| try stdout.print("  Producer: {s}\n", .{p});
    if (metadata.creation_date) |cd| try stdout.print("  Creation Date: {s}\n", .{cd});
    if (metadata.mod_date) |md| try stdout.print("  Modification Date: {s}\n", .{md});

    // Attachments
    const attachment_count = doc.getAttachmentCount();
    if (attachment_count > 0) {
        try stdout.print("\nAttachments: {d}\n", .{attachment_count});

        var xml_count: u32 = 0;
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator) orelse continue;
            defer allocator.free(name);

            const is_xml = attachment.isXml(allocator);
            if (is_xml) xml_count += 1;

            try stdout.print("  {s}{s}\n", .{ name, if (is_xml) " [XML]" else "" });
        }

        if (xml_count > 0) {
            try stdout.print("\nXML files: {d} (use 'extract-attachments \"*.xml\"' to extract)\n", .{xml_count});
        }
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn openDocument(path: []const u8, password: ?[]const u8, stderr: *std.Io.Writer) ?pdfium.Document {
    if (password) |pwd| {
        return pdfium.Document.openWithPassword(path, pwd) catch |err| {
            stderr.print("Error: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return null;
        };
    } else {
        return pdfium.Document.open(path) catch |err| {
            if (err == pdfium.Error.PasswordRequired) {
                stderr.writeAll("Error: PDF is password protected. Use -P to provide password.\n") catch {};
            } else {
                stderr.print("Error: {}\n", .{err}) catch {};
            }
            stderr.flush() catch {};
            return null;
        };
    }
}

fn getBasename(path: []const u8) []const u8 {
    const filename = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |pos|
        path[pos + 1 ..]
    else
        path;

    return if (std.mem.lastIndexOfScalar(u8, filename, '.')) |pos|
        filename[0..pos]
    else
        filename;
}

// ============================================================================
// Usage Messages
// ============================================================================

fn printMainUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\pdfzig - PDF utility tool using PDFium
        \\
        \\Usage: pdfzig <command> [options]
        \\
        \\Commands:
        \\  render              Render PDF pages to images
        \\  extract-text        Extract text content from PDF
        \\  extract-images      Extract embedded images from PDF
        \\  extract-attachments Extract embedded attachments from PDF
        \\  info                Display PDF metadata and information
        \\
        \\Global Options:
        \\  -h, --help      Show this help message
        \\  -v, --version   Show version
        \\
        \\Run 'pdfzig <command> --help' for command-specific help.
        \\
    ) catch {};
}

fn printRenderUsage(stdout: *std.Io.Writer) void {
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

fn printExtractTextUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig extract-text [options] <input.pdf>
        \\
        \\Extract text content from PDF pages.
        \\
        \\Options:
        \\  -o, --output <FILE>   Write output to file (default: stdout)
        \\  -p, --pages <RANGE>   Page range, e.g., "1-5,8,10-12" (default: all)
        \\  -P, --password <PW>   Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig extract-text document.pdf
        \\  pdfzig extract-text -o text.txt document.pdf
        \\  pdfzig extract-text -p 1-10 document.pdf > first_pages.txt
        \\
    ) catch {};
}

fn printExtractImagesUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig extract-images [options] <input.pdf> [output_dir]
        \\
        \\Extract embedded images from PDF pages.
        \\
        \\Options:
        \\  -f, --format <FMT>    Output format: png, jpeg/jpg (default: png)
        \\  -Q, --quality <N>     JPEG quality 1-100 (default: 90)
        \\  -p, --pages <RANGE>   Page range, e.g., "1-5,8,10-12" (default: all)
        \\  -P, --password <PW>   Password for encrypted PDFs
        \\  -q, --quiet           Suppress progress output
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig extract-images document.pdf
        \\  pdfzig extract-images -f jpeg -Q 85 document.pdf ./images
        \\  pdfzig extract-images -p 1-5 document.pdf
        \\
    ) catch {};
}

fn printExtractAttachmentsUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig extract-attachments [options] <input.pdf> [pattern] [output_dir]
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
        \\  pdfzig extract-attachments document.pdf                  # Extract all
        \\  pdfzig extract-attachments document.pdf "*.xml"          # Extract XML files
        \\  pdfzig extract-attachments document.pdf "*.xml" ./out    # Extract to directory
        \\  pdfzig extract-attachments -l document.pdf               # List all attachments
        \\  pdfzig extract-attachments -l document.pdf "*.json"      # List JSON files only
        \\
    ) catch {};
}

fn printInfoUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig info [options] <input.pdf>
        \\
        \\Display PDF metadata and information.
        \\
        \\Options:
        \\  -P, --password <PW>   Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig info document.pdf
        \\  pdfzig info -P secret encrypted.pdf
        \\
    ) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test {
    // Import test modules to include their tests
    _ = @import("info_test.zig");
    _ = @import("attachments_test.zig");
    _ = @import("renderer.zig");
    _ = @import("image_writer.zig");
}
