//! pdfzig - PDF utility tool using PDFium
//!
//! Commands:
//!   render              Render PDF pages to images
//!   extract_text        Extract text content from PDF
//!   extract_images      Extract embedded images from PDF
//!   extract_attachments Extract embedded attachments from PDF
//!   visual_diff         Compare two PDFs visually
//!   info                Display PDF metadata and information
//!   rotate              Rotate PDF pages
//!   mirror              Mirror PDF pages
//!   delete              Delete PDF pages
//!   add                 Add new page to PDF
//!   create              Create new PDF from sources
//!   attach              Attach files to PDF
//!   detach              Remove attachments from PDF
//!   download_pdfium     Download PDFium library
//!
//! Global Options:
//!   --link <path>          Link a specific PDFium library

const std = @import("std");
const pdfium = @import("pdfium.zig");
const renderer = @import("renderer.zig");
const image_writer = @import("image_writer.zig");
const downloader = @import("downloader.zig");
const loader = @import("pdfium_loader.zig");
const zigimg = @import("zigimg");
const cli = @import("cli.zig");

const version = "0.1.0";

const Command = cli.Command;
const SliceArgIterator = cli.SliceArgIterator;
const PageSize = cli.PageSize;
const OutputSpec = cli.OutputSpec;

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

    // Collect all arguments into a list for multi-pass parsing
    var args_list = std.array_list.Managed([]const u8).init(allocator);
    defer args_list.deinit();

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.skip(); // Skip program name
    while (arg_it.next()) |arg| {
        args_list.append(arg) catch {
            try stderr.writeAll("Error: Out of memory\n");
            try stderr.flush();
            std.process.exit(1);
        };
    }

    // Parse global options first
    var link_library_path: ?[]const u8 = null;
    var remaining_args = std.array_list.Managed([]const u8).init(allocator);
    defer remaining_args.deinit();

    var i: usize = 0;
    while (i < args_list.items.len) : (i += 1) {
        const arg = args_list.items[i];
        if (std.mem.eql(u8, arg, "--link")) {
            i += 1;
            if (i >= args_list.items.len) {
                try stderr.writeAll("Error: --link requires a library path argument\n");
                try stderr.flush();
                std.process.exit(1);
            }
            link_library_path = args_list.items[i];
        } else {
            remaining_args.append(arg) catch {
                try stderr.writeAll("Error: Out of memory\n");
                try stderr.flush();
                std.process.exit(1);
            };
        }
    }

    // Handle -link option - initialize PDFium from specified path
    if (link_library_path) |library_path| {
        pdfium.initWithPath(library_path) catch |err| {
            try stderr.print("Error: Failed to load PDFium library from '{s}': {}\n", .{ library_path, err });
            try stderr.flush();
            std.process.exit(1);
        };
        try stdout.print("Loaded PDFium from: {s}\n", .{library_path});
        try stdout.flush();
    }

    // Now parse the command from remaining args
    const command_str = if (remaining_args.items.len > 0) remaining_args.items[0] else null;

    if (command_str == null) {
        // Try to load PDFium to show version in help
        pdfium.init() catch {};
        defer pdfium.deinit();
        printMainUsage(stdout, pdfium.getVersion(), pdfium.getLibraryPath());
        try stdout.flush();
        return;
    }

    const cmd_str = command_str.?;

    // Check for global flags
    if (std.mem.eql(u8, cmd_str, "-h") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "help")) {
        pdfium.init() catch {};
        defer pdfium.deinit();
        printMainUsage(stdout, pdfium.getVersion(), pdfium.getLibraryPath());
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, cmd_str, "-v") or std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "version")) {
        try stdout.print("pdfzig {s}\n", .{version});
        try stdout.flush();
        return;
    }

    const command: Command = if (std.mem.eql(u8, cmd_str, "render"))
        .render
    else if (std.mem.eql(u8, cmd_str, "extract_text"))
        .extract_text
    else if (std.mem.eql(u8, cmd_str, "extract_images"))
        .extract_images
    else if (std.mem.eql(u8, cmd_str, "extract_attachments"))
        .extract_attachments
    else if (std.mem.eql(u8, cmd_str, "visual_diff"))
        .visual_diff
    else if (std.mem.eql(u8, cmd_str, "info"))
        .info
    else if (std.mem.eql(u8, cmd_str, "rotate"))
        .rotate
    else if (std.mem.eql(u8, cmd_str, "mirror"))
        .mirror
    else if (std.mem.eql(u8, cmd_str, "delete"))
        .delete
    else if (std.mem.eql(u8, cmd_str, "add"))
        .add
    else if (std.mem.eql(u8, cmd_str, "create"))
        .create
    else if (std.mem.eql(u8, cmd_str, "attach"))
        .attach
    else if (std.mem.eql(u8, cmd_str, "detach"))
        .detach
    else if (std.mem.eql(u8, cmd_str, "download_pdfium"))
        .download_pdfium
    else {
        try stderr.print("Unknown command: {s}\n\n", .{cmd_str});
        try stderr.flush();
        pdfium.init() catch {};
        defer pdfium.deinit();
        printMainUsage(stdout, pdfium.getVersion(), pdfium.getLibraryPath());
        try stdout.flush();
        std.process.exit(1);
    };

    // Create an iterator over remaining args (skip command name)
    var cmd_arg_it = SliceArgIterator.init(remaining_args.items[1..]);

    // Handle download_pdfium command separately (manages PDFium library)
    if (command == .download_pdfium) {
        runDownloadPdfiumCommand(allocator, &cmd_arg_it, stdout, stderr);
        try stdout.flush();
        return;
    }

    // Initialize PDFium
    pdfium.init() catch |err| {
        try stderr.print("Error: Failed to load PDFium library: {}\n", .{err});
        try stderr.writeAll("Run 'pdfzig download_pdfium' to download the library.\n");
        try stderr.flush();
        std.process.exit(1);
    };
    defer pdfium.deinit();

    switch (command) {
        .render => try runRenderCommand(allocator, &cmd_arg_it, stdout, stderr),
        .extract_text => try runExtractTextCommand(allocator, &cmd_arg_it, stdout, stderr),
        .extract_images => try runExtractImagesCommand(allocator, &cmd_arg_it, stdout, stderr),
        .extract_attachments => try runExtractAttachmentsCommand(allocator, &cmd_arg_it, stdout, stderr),
        .visual_diff => runVisualDiffCommand(allocator, &cmd_arg_it, stdout, stderr),
        .info => try runInfoCommand(allocator, &cmd_arg_it, stdout, stderr),
        .rotate => try runRotateCommand(allocator, &cmd_arg_it, stdout, stderr),
        .mirror => try runMirrorCommand(allocator, &cmd_arg_it, stdout, stderr),
        .delete => try runDeleteCommand(allocator, &cmd_arg_it, stdout, stderr),
        .add => try runAddCommand(allocator, &cmd_arg_it, stdout, stderr),
        .create => try runCreateCommand(allocator, &cmd_arg_it, stdout, stderr),
        .attach => try runAttachCommand(allocator, &cmd_arg_it, stdout, stderr),
        .detach => try runDetachCommand(allocator, &cmd_arg_it, stdout, stderr),
        .download_pdfium => unreachable, // Handled above
        .help => printMainUsage(stdout, pdfium.getVersion(), pdfium.getLibraryPath()),
        .version_cmd => try stdout.print("pdfzig {s}\n", .{version}),
    }

    try stdout.flush();
}

/// Parse a page range string (e.g., "1-5,8,10-12") into a list of page numbers.
/// If range_str is null, returns all pages from 1 to page_count.
/// Returns error message on stderr and exits on invalid input.
fn parsePageList(
    allocator: std.mem.Allocator,
    range_str: ?[]const u8,
    page_count: u32,
    stderr: *std.Io.Writer,
) std.mem.Allocator.Error![]u32 {
    var pages = std.array_list.Managed(u32).init(allocator);
    errdefer pages.deinit();

    if (range_str) |range| {
        var range_it = std.mem.splitScalar(u8, range, ',');
        while (range_it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOf(u8, trimmed, "-")) |dash_pos| {
                const start_str = std.mem.trim(u8, trimmed[0..dash_pos], " ");
                const end_str = std.mem.trim(u8, trimmed[dash_pos + 1 ..], " ");
                const start = std.fmt.parseInt(u32, start_str, 10) catch {
                    stderr.print("Invalid page range: {s}\n", .{part}) catch {};
                    stderr.flush() catch {};
                    std.process.exit(1);
                };
                const end = std.fmt.parseInt(u32, end_str, 10) catch {
                    stderr.print("Invalid page range: {s}\n", .{part}) catch {};
                    stderr.flush() catch {};
                    std.process.exit(1);
                };
                if (start < 1 or end > page_count or start > end) {
                    stderr.print("Invalid page range: {s} (document has {d} pages)\n", .{ part, page_count }) catch {};
                    stderr.flush() catch {};
                    std.process.exit(1);
                }
                var p = start;
                while (p <= end) : (p += 1) {
                    try pages.append(p);
                }
            } else {
                const page_num = std.fmt.parseInt(u32, trimmed, 10) catch {
                    stderr.print("Invalid page number: {s}\n", .{trimmed}) catch {};
                    stderr.flush() catch {};
                    std.process.exit(1);
                };
                if (page_num < 1 or page_num > page_count) {
                    stderr.print("Invalid page number: {d} (document has {d} pages)\n", .{ page_num, page_count }) catch {};
                    stderr.flush() catch {};
                    std.process.exit(1);
                }
                try pages.append(page_num);
            }
        }
    } else {
        // All pages
        var p: u32 = 1;
        while (p <= page_count) : (p += 1) {
            try pages.append(p);
        }
    }

    return pages.toOwnedSlice() catch unreachable;
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

fn runRenderCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
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
    const basename = renderer.getBasename(input_path);

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

const parseOutputSpec = cli.parseOutputSpec;
const parseResolution = cli.parseResolution;

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
    arg_it: *SliceArgIterator,
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
    arg_it: *SliceArgIterator,
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
    arg_it: *SliceArgIterator,
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

/// Simple glob pattern matching supporting * and ? wildcards (case-insensitive)
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
// Visual Diff Command
// ============================================================================

const VisualDiffArgs = struct {
    input1: ?[]const u8 = null,
    input2: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    dpi: f64 = 150.0,
    password1: ?[]const u8 = null,
    password2: ?[]const u8 = null,
    quiet: bool = false,
    show_help: bool = false,
};

fn runVisualDiffCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) void {
    var args = VisualDiffArgs{};

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                args.quiet = true;
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--resolution")) {
                const res_str = arg_it.next() orelse {
                    stderr.writeAll("Error: --resolution requires an argument\n") catch {};
                    stderr.flush() catch {};
                    std.process.exit(1);
                };
                args.dpi = parseResolution(res_str) orelse {
                    stderr.print("Error: Invalid resolution value '{s}'\n", .{res_str}) catch {};
                    stderr.flush() catch {};
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                args.output_dir = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                // First -P is for first PDF, second is for second PDF
                if (args.password1 == null) {
                    args.password1 = arg_it.next();
                } else {
                    args.password2 = arg_it.next();
                }
            } else if (std.mem.eql(u8, arg, "--password1")) {
                args.password1 = arg_it.next();
            } else if (std.mem.eql(u8, arg, "--password2")) {
                args.password2 = arg_it.next();
            } else {
                stderr.print("Unknown option: {s}\n", .{arg}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            }
        } else {
            if (args.input1 == null) {
                args.input1 = arg;
            } else if (args.input2 == null) {
                args.input2 = arg;
            }
        }
    }

    if (args.show_help) {
        printVisualDiffUsage(stdout);
        stdout.flush() catch {};
        return;
    }

    const input1 = args.input1 orelse {
        stderr.writeAll("Error: No input PDF files specified\n\n") catch {};
        stderr.flush() catch {};
        printVisualDiffUsage(stdout);
        stdout.flush() catch {};
        std.process.exit(1);
    };

    const input2 = args.input2 orelse {
        stderr.writeAll("Error: Second input PDF file not specified\n\n") catch {};
        stderr.flush() catch {};
        printVisualDiffUsage(stdout);
        stdout.flush() catch {};
        std.process.exit(1);
    };

    // Create output directory if specified
    if (args.output_dir) |out_dir| {
        std.fs.cwd().makePath(out_dir) catch |err| {
            stderr.print("Error: Could not create output directory: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
    }

    // Open both documents
    var doc1 = openDocument(input1, args.password1, stderr) orelse std.process.exit(1);
    defer doc1.close();

    var doc2 = openDocument(input2, args.password2, stderr) orelse std.process.exit(1);
    defer doc2.close();

    const page_count1 = doc1.getPageCount();
    const page_count2 = doc2.getPageCount();

    if (page_count1 != page_count2) {
        stderr.print("Error: Page count mismatch: {s} has {d} pages, {s} has {d} pages\n", .{
            input1,
            page_count1,
            input2,
            page_count2,
        }) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    if (page_count1 == 0) {
        stderr.writeAll("Error: PDFs have no pages\n") catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    var total_diff_pixels: u64 = 0;
    var has_differences = false;

    for (0..page_count1) |page_idx| {
        const page_num: u32 = @intCast(page_idx);

        // Load pages
        var page1 = doc1.loadPage(page_num) catch {
            stderr.print("Error: Could not load page {d} from first PDF\n", .{page_num + 1}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        defer page1.close();

        var page2 = doc2.loadPage(page_num) catch {
            stderr.print("Error: Could not load page {d} from second PDF\n", .{page_num + 1}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        defer page2.close();

        // Use page dimensions from first PDF at specified DPI
        const dims = page1.getDimensionsAtDpi(args.dpi);

        // Create bitmaps
        var bitmap1 = pdfium.Bitmap.create(dims.width, dims.height, .bgra) catch {
            stderr.print("Error: Could not create bitmap for page {d}\n", .{page_num + 1}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        defer bitmap1.destroy();

        var bitmap2 = pdfium.Bitmap.create(dims.width, dims.height, .bgra) catch {
            stderr.print("Error: Could not create bitmap for page {d}\n", .{page_num + 1}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        defer bitmap2.destroy();

        // Fill with white and render
        bitmap1.fillWhite();
        page1.render(&bitmap1, .{});

        bitmap2.fillWhite();
        page2.render(&bitmap2, .{});

        // Compare pixels
        const data1 = bitmap1.getData() orelse {
            stderr.print("Error: Could not get buffer for page {d}\n", .{page_num + 1}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        const data2 = bitmap2.getData() orelse {
            stderr.print("Error: Could not get buffer for page {d}\n", .{page_num + 1}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        const stride = bitmap1.stride;
        const width = bitmap1.width;
        const height = bitmap1.height;

        var page_diff_pixels: u64 = 0;

        // Allocate diff buffer if output is requested
        var diff_buffer: ?[]u8 = null;
        defer if (diff_buffer) |buf| allocator.free(buf);

        if (args.output_dir != null) {
            diff_buffer = allocator.alloc(u8, @as(usize, width) * @as(usize, height)) catch {
                stderr.writeAll("Error: Could not allocate diff buffer\n") catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
        }

        for (0..height) |y| {
            const row_offset = y * @as(usize, stride);
            for (0..width) |x| {
                const pixel_offset = row_offset + x * 4;

                // BGRA format
                const b1 = data1[pixel_offset];
                const g1 = data1[pixel_offset + 1];
                const r1 = data1[pixel_offset + 2];

                const b2 = data2[pixel_offset];
                const g2 = data2[pixel_offset + 1];
                const r2 = data2[pixel_offset + 2];

                // Check if pixels differ
                const pixels_match = (r1 == r2 and g1 == g2 and b1 == b2);

                if (!pixels_match) {
                    page_diff_pixels += 1;
                }

                // Calculate diff for output image
                if (diff_buffer) |buf| {
                    const diff_r = if (r1 > r2) r1 - r2 else r2 - r1;
                    const diff_g = if (g1 > g2) g1 - g2 else g2 - g1;
                    const diff_b = if (b1 > b2) b1 - b2 else b2 - b1;

                    // Average of absolute differences
                    const avg_diff: u8 = @intCast((@as(u16, diff_r) + @as(u16, diff_g) + @as(u16, diff_b)) / 3);

                    buf[y * @as(usize, width) + x] = avg_diff;
                }
            }
        }

        total_diff_pixels += page_diff_pixels;
        if (page_diff_pixels > 0) {
            has_differences = true;
        }

        if (!args.quiet) {
            stdout.print("Page {d}: {d} different pixels\n", .{ page_num + 1, page_diff_pixels }) catch {};
        }

        // Write diff image if requested
        if (args.output_dir) |out_dir| {
            if (diff_buffer) |buf| {
                var filename_buf: [256]u8 = undefined;
                const filename = std.fmt.bufPrint(&filename_buf, "diff_page{d}.png", .{page_num + 1}) catch continue;

                const output_path = std.fs.path.join(allocator, &.{ out_dir, filename }) catch continue;
                defer allocator.free(output_path);

                writeGrayscalePng(buf, width, height, output_path) catch |err| {
                    stderr.print("Warning: Could not write diff image: {}\n", .{err}) catch {};
                    stderr.flush() catch {};
                };

                if (!args.quiet) {
                    stdout.print("  Wrote: {s}\n", .{output_path}) catch {};
                }
            }
        }
    }

    stdout.print("\nTotal different pixels: {d}\n", .{total_diff_pixels}) catch {};
    stdout.flush() catch {};

    if (has_differences) {
        std.process.exit(1);
    }
}

fn writeGrayscalePng(data: []const u8, width: u32, height: u32, path: []const u8) !void {
    // Create grayscale pixel data slice with correct type
    const pixel_data: []zigimg.color.Grayscale8 = @as(
        [*]zigimg.color.Grayscale8,
        @ptrCast(@constCast(data.ptr)),
    )[0 .. @as(usize, width) * @as(usize, height)];

    // Create image with grayscale pixels
    var img = zigimg.Image{
        .width = width,
        .height = height,
        .pixels = .{ .grayscale8 = pixel_data },
    };

    // Write to file
    var write_buffer: [4096]u8 = undefined;
    img.writeToFilePath(std.heap.page_allocator, path, &write_buffer, .{ .png = .{} }) catch return error.WriteError;
}

// ============================================================================
// Download PDFium Command
// ============================================================================

const DownloadPdfiumArgs = struct {
    build_version: ?u32 = null,
    show_help: bool = false,
};

/// Display a progress bar for downloads
fn displayProgress(downloaded: u64, total: ?u64) void {
    const stderr_file = std.fs.File.stderr();
    var buf: [128]u8 = undefined;

    if (total) |t| {
        const percent = if (t > 0) @as(u32, @intCast((downloaded * 100) / t)) else 0;
        const bar_width: u32 = 40;
        const filled = (percent * bar_width) / 100;

        // Build progress bar
        var bar: [40]u8 = undefined;
        for (0..bar_width) |i| {
            bar[i] = if (i < filled) '=' else if (i == filled) '>' else ' ';
        }

        // Format: [=====>     ] 45% 12.3/27.0 MB
        const downloaded_mb = @as(f64, @floatFromInt(downloaded)) / (1024 * 1024);
        const total_mb = @as(f64, @floatFromInt(t)) / (1024 * 1024);

        const len = std.fmt.bufPrint(&buf, "\r[{s}] {d:3}% {d:.1}/{d:.1} MB", .{ bar[0..bar_width], percent, downloaded_mb, total_mb }) catch return;
        _ = stderr_file.write(len) catch {};
    } else {
        // Unknown total size
        const downloaded_mb = @as(f64, @floatFromInt(downloaded)) / (1024 * 1024);
        const len = std.fmt.bufPrint(&buf, "\rDownloaded: {d:.1} MB", .{downloaded_mb}) catch return;
        _ = stderr_file.write(len) catch {};
    }
}

fn runDownloadPdfiumCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) void {
    var args = DownloadPdfiumArgs{};

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else {
                stderr.print("Unknown option: {s}\n", .{arg}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            }
        } else {
            // Parse version number
            args.build_version = std.fmt.parseInt(u32, arg, 10) catch {
                stderr.print("Error: Invalid build version '{s}'\n", .{arg}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
        }
    }

    if (args.show_help) {
        printDownloadPdfiumUsage(stdout);
        stdout.flush() catch {};
        return;
    }

    // Get the executable directory
    const exe_dir = loader.getExecutableDir(allocator) catch |err| {
        stderr.print("Error: Could not determine executable directory: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(exe_dir);

    if (args.build_version) |ver| {
        stdout.print("Downloading PDFium build {d}...\n", .{ver}) catch {};
    } else {
        stdout.writeAll("Downloading latest PDFium build...\n") catch {};
    }
    stdout.flush() catch {};

    const downloaded_version = downloader.downloadPdfiumWithProgress(allocator, args.build_version, exe_dir, displayProgress) catch |err| {
        stderr.writeAll("\n") catch {}; // Clear progress line
        stderr.print("Error: Download failed: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    // Clear progress line and show success
    stderr.writeAll("\r\x1b[K") catch {}; // Clear line with ANSI escape
    stdout.print("Successfully downloaded PDFium build {d}\n", .{downloaded_version}) catch {};

    // Show info about installed library
    if (loader.findBestPdfiumLibrary(allocator, exe_dir) catch null) |lib_info| {
        defer allocator.free(lib_info.path);
        stdout.print("Library installed at: {s}\n", .{lib_info.path}) catch {};
    }
}

// ============================================================================
// Info Command
// ============================================================================

fn runInfoCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
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
            try stdout.print("\nXML files: {d} (use 'extract_attachments \"*.xml\"' to extract)\n", .{xml_count});
        }
    }
}

// ============================================================================
// Rotate Command
// ============================================================================

const RotateArgs = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    rotation: ?i32 = null,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

fn runRotateCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = RotateArgs{};

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
        } else if (args.input_path == null) {
            args.input_path = arg;
        } else if (args.rotation == null) {
            // Parse rotation angle or alias
            if (std.mem.eql(u8, arg, "left")) {
                args.rotation = 270;
            } else if (std.mem.eql(u8, arg, "right")) {
                args.rotation = 90;
            } else {
                args.rotation = std.fmt.parseInt(i32, arg, 10) catch {
                    try stderr.print("Invalid rotation angle: {s}\n", .{arg});
                    try stderr.writeAll("Use: 90, 180, 270, -90, -180, -270, left, or right\n");
                    try stderr.flush();
                    std.process.exit(1);
                };
            }
        }
    }

    if (args.show_help) {
        printRotateUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printRotateUsage(stdout);
        std.process.exit(1);
    };

    const rotation = args.rotation orelse {
        try stderr.writeAll("Error: No rotation angle specified\n\n");
        try stderr.flush();
        printRotateUsage(stdout);
        std.process.exit(1);
    };

    // Validate rotation angle
    if (@mod(rotation, 90) != 0) {
        try stderr.writeAll("Error: Rotation must be a multiple of 90 degrees\n");
        try stderr.flush();
        std.process.exit(1);
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
    const pages_to_rotate = try parsePageList(allocator, args.page_range, page_count, stderr);
    defer allocator.free(pages_to_rotate);

    // Rotate each specified page
    for (pages_to_rotate) |page_num| {
        var page = doc.loadPage(page_num - 1) catch |err| {
            try stderr.print("Error loading page {d}: {}\n", .{ page_num, err });
            try stderr.flush();
            std.process.exit(1);
        };
        defer page.close();

        if (!page.rotate(rotation)) {
            try stderr.print("Error: Invalid rotation angle {d}\n", .{rotation});
            try stderr.flush();
            std.process.exit(1);
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
    if (pages_to_rotate.len == page_count) {
        try stdout.print("Rotated all {d} pages by {d}°\n", .{ page_count, rotation });
    } else {
        try stdout.print("Rotated {d} page(s) by {d}°\n", .{ pages_to_rotate.len, rotation });
    }

    if (!std.mem.eql(u8, output_path, input_path)) {
        try stdout.print("Saved to: {s}\n", .{output_path});
    }
}

fn printRotateUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig rotate [options] <input.pdf> <degrees>
        \\
        \\Rotate PDF pages by the specified angle.
        \\
        \\Arguments:
        \\  input.pdf             Input PDF file
        \\  degrees               Rotation: 90, 180, 270, -90, -180, -270, left, right
        \\                        (left = -90°, right = 90°)
        \\
        \\Options:
        \\  -o, --output <file>   Output file (default: overwrite input)
        \\  -p, --pages <range>   Pages to rotate (e.g., "1-5,8,10-12", default: all)
        \\  -P, --password <pwd>  Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig rotate document.pdf right           # Rotate all pages 90° clockwise
        \\  pdfzig rotate document.pdf left            # Rotate all pages 90° counter-clockwise
        \\  pdfzig rotate document.pdf 180             # Rotate all pages 180°
        \\  pdfzig rotate -p 1,3 document.pdf 90       # Rotate pages 1 and 3 by 90°
        \\  pdfzig rotate -o out.pdf document.pdf left # Rotate and save to new file
        \\
    ) catch {};
}

// ============================================================================
// Mirror Command
// ============================================================================

const MirrorArgs = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    updown: bool = false,
    leftright: bool = false,
    show_help: bool = false,
};

fn runMirrorCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = MirrorArgs{};

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
        printMirrorUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printMirrorUsage(stdout);
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
    const pages_to_mirror = try parsePageList(allocator, args.page_range, page_count, stderr);
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

fn printMirrorUsage(stdout: *std.Io.Writer) void {
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

// ============================================================================
// Delete Command
// ============================================================================

const DeleteArgs = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

fn runDeleteCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = DeleteArgs{};

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
        printDeleteUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printDeleteUsage(stdout);
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
    const pages_to_delete = try parsePageList(allocator, args.page_range, page_count, stderr);
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

fn printDeleteUsage(stdout: *std.Io.Writer) void {
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

// ============================================================================
// Add Command
// ============================================================================

const AddArgs = struct {
    input_path: ?[]const u8 = null,
    content_file: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_number: ?u32 = null, // 1-based page number to insert at
    page_size: ?PageSize = null,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

fn runAddCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = AddArgs{};

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                args.output_path = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--page")) {
                if (arg_it.next()) |page_str| {
                    args.page_number = std.fmt.parseInt(u32, page_str, 10) catch {
                        try stderr.print("Invalid page number: {s}\n", .{page_str});
                        try stderr.flush();
                        std.process.exit(1);
                    };
                }
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
                if (arg_it.next()) |size_str| {
                    args.page_size = PageSize.parse(size_str) orelse {
                        try stderr.print("Invalid size: {s}\n", .{size_str});
                        try stderr.print("Use: A4, Letter, 210x297mm, 8.5x11in, 612x792pt, or 612x792\n", .{});
                        try stderr.print("Add 'L' suffix for landscape: A4L, LetterL\n", .{});
                        try stderr.flush();
                        std.process.exit(1);
                    };
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
        } else if (args.content_file == null) {
            args.content_file = arg;
        }
    }

    if (args.show_help) {
        printAddUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printAddUsage(stdout);
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

    // Determine page size
    const page_size: PageSize = if (args.page_size) |size|
        size
    else if (page_count > 0) blk: {
        // Use size of last page
        var last_page = doc.loadPage(page_count - 1) catch {
            break :blk PageSize{ .width = 612, .height = 792 }; // US Letter
        };
        defer last_page.close();
        break :blk PageSize{ .width = last_page.getWidth(), .height = last_page.getHeight() };
    } else PageSize{ .width = 612, .height = 792 }; // US Letter default

    // Determine insertion index (0-based)
    const insert_index: u32 = if (args.page_number) |p|
        if (p == 0) 0 else @min(p - 1, page_count)
    else
        page_count; // Insert at end

    // Create the new page
    var new_page = doc.createPage(insert_index, page_size.width, page_size.height) catch |err| {
        try stderr.print("Error creating page: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer new_page.close();

    // If content file is specified, add it to the page
    if (args.content_file) |content_path| {
        const ext = std.fs.path.extension(content_path);
        const is_text = std.mem.eql(u8, ext, ".txt") or std.mem.eql(u8, ext, ".text");

        if (is_text) {
            // Handle text file
            try addTextToPage(allocator, &doc, &new_page, content_path, page_size.width, page_size.height, stderr);
        } else {
            // Handle image file
            try addImageToPage(allocator, &doc, &new_page, content_path, page_size.width, page_size.height, stderr);
        }
    }

    // Generate content for the new page
    if (!new_page.generateContent()) {
        try stderr.writeAll("Error generating page content\n");
        try stderr.flush();
        std.process.exit(1);
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
    if (args.content_file) |content_path| {
        try stdout.print("Added page with content from: {s}\n", .{std.fs.path.basename(content_path)});
    } else {
        try stdout.writeAll("Added empty page\n");
    }

    if (!std.mem.eql(u8, output_path, input_path)) {
        try stdout.print("Saved to: {s}\n", .{output_path});
    }
}

fn addImageToPage(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    image_path: []const u8,
    page_width: f64,
    page_height: f64,
    stderr: *std.Io.Writer,
) !void {
    // Load image using zigimg
    var read_buffer: [1024 * 1024]u8 = undefined;
    var img = zigimg.Image.fromFilePath(allocator, image_path, &read_buffer) catch {
        try stderr.print("Error loading image: {s}\n", .{image_path});
        try stderr.flush();
        std.process.exit(1);
    };
    defer img.deinit(allocator);

    const img_width: f64 = @floatFromInt(img.width);
    const img_height: f64 = @floatFromInt(img.height);

    // Calculate scale to fit page while maintaining aspect ratio
    const scale_x = page_width / img_width;
    const scale_y = page_height / img_height;
    const scale = @min(scale_x, scale_y);

    const scaled_width = img_width * scale;
    const scaled_height = img_height * scale;

    // Center on page
    const x_offset = (page_width - scaled_width) / 2;
    const y_offset = (page_height - scaled_height) / 2;

    // Create bitmap in BGRA format for PDFium
    var bitmap = pdfium.Bitmap.create(@intFromFloat(img_width), @intFromFloat(img_height), .bgra) catch {
        try stderr.writeAll("Error creating bitmap\n");
        try stderr.flush();
        std.process.exit(1);
    };
    defer bitmap.destroy();

    // Copy image data to bitmap (convert to BGRA)
    const buffer = bitmap.getBuffer() orelse {
        try stderr.writeAll("Error getting bitmap buffer\n");
        try stderr.flush();
        std.process.exit(1);
    };

    // Convert image pixels to BGRA
    const width: usize = @intCast(img.width);
    const height: usize = @intCast(img.height);
    const stride: usize = @intCast(bitmap.stride);

    // Handle different pixel formats using zigimg's PixelStorage union
    switch (img.pixels) {
        .rgba32 => |pixels| {
            for (0..height) |y| {
                for (0..width) |x| {
                    const pix = pixels[y * width + x];
                    const dst_idx = y * stride + x * 4;
                    buffer[dst_idx + 0] = pix.b;
                    buffer[dst_idx + 1] = pix.g;
                    buffer[dst_idx + 2] = pix.r;
                    buffer[dst_idx + 3] = pix.a;
                }
            }
        },
        .rgb24 => |pixels| {
            for (0..height) |y| {
                for (0..width) |x| {
                    const pix = pixels[y * width + x];
                    const dst_idx = y * stride + x * 4;
                    buffer[dst_idx + 0] = pix.b;
                    buffer[dst_idx + 1] = pix.g;
                    buffer[dst_idx + 2] = pix.r;
                    buffer[dst_idx + 3] = 255;
                }
            }
        },
        .bgra32 => |pixels| {
            // Already BGRA, just copy
            for (0..height) |y| {
                for (0..width) |x| {
                    const pix = pixels[y * width + x];
                    const dst_idx = y * stride + x * 4;
                    buffer[dst_idx + 0] = pix.b;
                    buffer[dst_idx + 1] = pix.g;
                    buffer[dst_idx + 2] = pix.r;
                    buffer[dst_idx + 3] = pix.a;
                }
            }
        },
        .grayscale8 => |pixels| {
            for (0..height) |y| {
                for (0..width) |x| {
                    const gray = pixels[y * width + x].value;
                    const dst_idx = y * stride + x * 4;
                    buffer[dst_idx + 0] = gray;
                    buffer[dst_idx + 1] = gray;
                    buffer[dst_idx + 2] = gray;
                    buffer[dst_idx + 3] = 255;
                }
            }
        },
        else => {
            try stderr.print("Unsupported image format: {s}\n", .{@tagName(img.pixels)});
            try stderr.flush();
            std.process.exit(1);
        },
    }

    // Create image object
    var img_obj = doc.createImageObject() catch {
        try stderr.writeAll("Error creating image object\n");
        try stderr.flush();
        std.process.exit(1);
    };

    // Set the bitmap on the image object
    if (!img_obj.setBitmap(bitmap)) {
        try stderr.writeAll("Error setting bitmap on image object\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Position and scale the image
    if (!img_obj.setImageMatrix(scaled_width, scaled_height, x_offset, y_offset)) {
        try stderr.writeAll("Error positioning image\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Insert image into page
    page.insertObject(img_obj);
}

fn addTextToPage(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    text_path: []const u8,
    page_width: f64,
    page_height: f64,
    stderr: *std.Io.Writer,
) !void {
    // Read text file
    const file = std.fs.cwd().openFile(text_path, .{}) catch {
        try stderr.print("Error opening text file: {s}\n", .{text_path});
        try stderr.flush();
        std.process.exit(1);
    };
    defer file.close();

    const text = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.writeAll("Error reading text file\n");
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(text);

    const font_size: f32 = 12.0;
    const line_height: f64 = font_size * 1.2;
    const margin: f64 = 72.0; // 1 inch margin
    const max_width = page_width - 2 * margin;

    var y_pos = page_height - margin - font_size;

    // Split into lines and render each
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |line| {
        if (y_pos < margin) break; // Out of page space

        if (line.len == 0) {
            y_pos -= line_height;
            continue;
        }

        // Create text object
        var text_obj = doc.createTextObject("Courier", font_size) catch {
            try stderr.writeAll("Error creating text object\n");
            try stderr.flush();
            std.process.exit(1);
        };

        // Convert UTF-8 to UTF-16LE for PDFium
        var utf16_buf = std.array_list.Managed(u16).init(allocator);
        defer utf16_buf.deinit();

        var utf8_view = std.unicode.Utf8View.init(line) catch {
            // If not valid UTF-8, try Latin-1
            for (line) |byte| {
                try utf16_buf.append(@as(u16, byte));
            }
            try utf16_buf.append(0); // Null terminator
            if (!text_obj.setText(utf16_buf.items)) {
                continue;
            }
            text_obj.transform(1, 0, 0, 1, margin, y_pos);
            page.insertObject(text_obj);
            y_pos -= line_height;
            continue;
        };

        var it = utf8_view.iterator();
        while (it.nextCodepoint()) |codepoint| {
            if (codepoint <= 0xFFFF) {
                try utf16_buf.append(@intCast(codepoint));
            } else {
                // Surrogate pair for codepoints > 0xFFFF
                const cp = codepoint - 0x10000;
                try utf16_buf.append(@intCast(0xD800 + (cp >> 10)));
                try utf16_buf.append(@intCast(0xDC00 + (cp & 0x3FF)));
            }
        }
        try utf16_buf.append(0); // Null terminator

        if (!text_obj.setText(utf16_buf.items)) {
            continue;
        }

        // Position the text
        text_obj.transform(1, 0, 0, 1, margin, y_pos);

        // Insert into page
        page.insertObject(text_obj);

        y_pos -= line_height;
    }

    _ = max_width; // Will be used for text wrapping in future
}

fn printAddUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig add [options] <input.pdf> [content_file]
        \\
        \\Add a new page to a PDF document.
        \\
        \\Arguments:
        \\  input.pdf             Input PDF file
        \\  content_file          Optional file to show on the page (image or .txt)
        \\
        \\Options:
        \\  -p, --page <num>      Page number to insert at (default: end)
        \\  -s, --size <SIZE>     Page size (default: previous page or US Letter)
        \\  -o, --output <file>   Output file (default: overwrite input)
        \\  -P, --password <pwd>  Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Size formats:
        \\  Standard names: A0-A8, B0-B6, C4-C6, Letter, Legal, Tabloid, Ledger, Executive
        \\  With units: 210x297mm, 8.5x11in, 21x29.7cm, 612x792pt
        \\  Points only: 612x792
        \\  Landscape: A4L, LetterL (append 'L' for landscape orientation)
        \\
        \\Supported image formats: PNG, JPEG, BMP, TGA, PBM, PGM, PPM
        \\
        \\Examples:
        \\  pdfzig add document.pdf                        # Add empty page at end
        \\  pdfzig add -p 1 document.pdf                   # Insert empty page at beginning
        \\  pdfzig add document.pdf image.png              # Add page with image
        \\  pdfzig add -s A4 document.pdf                  # Add A4-sized page
        \\  pdfzig add -s A4L document.pdf                 # Add A4 landscape page
        \\  pdfzig add -s 200x300mm document.pdf           # Add page with custom size
        \\  pdfzig add document.pdf notes.txt              # Add page with text content
        \\  pdfzig add -o out.pdf document.pdf photo.jpg   # Add and save to new file
        \\
    ) catch {};
}

// ============================================================================
// Create Command
// ============================================================================

const CreateArgs = struct {
    output_path: ?[]const u8 = null,
    page_size: ?PageSize = null,
    sources: std.array_list.Managed(SourceSpec) = undefined,
    show_help: bool = false,
};

const SourceSpec = struct {
    path: []const u8,
    page_range: ?[]const u8 = null, // For PDFs: "1-3,5" or null for all
};

fn runCreateCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = CreateArgs{
        .sources = std.array_list.Managed(SourceSpec).init(allocator),
    };
    defer args.sources.deinit();

    var current_page_range: ?[]const u8 = null;

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                args.output_path = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
                if (arg_it.next()) |size_str| {
                    args.page_size = PageSize.parse(size_str) orelse {
                        try stderr.print("Invalid size: {s}\n", .{size_str});
                        try stderr.flush();
                        std.process.exit(1);
                    };
                }
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pages")) {
                current_page_range = arg_it.next();
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else {
            // Source file
            try args.sources.append(.{
                .path = arg,
                .page_range = current_page_range,
            });
            current_page_range = null; // Reset for next source
        }
    }

    if (args.show_help) {
        printCreateUsage(stdout);
        return;
    }

    if (args.sources.items.len == 0) {
        try stderr.writeAll("Error: No source files specified\n\n");
        try stderr.flush();
        printCreateUsage(stdout);
        std.process.exit(1);
    }

    const output_path = args.output_path orelse {
        try stderr.writeAll("Error: Output file required (-o <file>)\n\n");
        try stderr.flush();
        printCreateUsage(stdout);
        std.process.exit(1);
    };

    // Default page size
    const default_size = args.page_size orelse PageSize{ .width = 612, .height = 792 }; // US Letter

    // Create new document
    var doc = pdfium.Document.createNew() catch |err| {
        try stderr.print("Error creating document: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer doc.close();

    var pages_added: u32 = 0;

    // Process each source
    for (args.sources.items) |source| {
        if (std.mem.eql(u8, source.path, cli.BLANK_PAGE)) {
            // Add blank page
            var page = doc.createPage(pages_added, default_size.width, default_size.height) catch |err| {
                try stderr.print("Error creating blank page: {}\n", .{err});
                try stderr.flush();
                std.process.exit(1);
            };
            if (!page.generateContent()) {
                try stderr.writeAll("Error generating page content\n");
                try stderr.flush();
                std.process.exit(1);
            }
            page.close();
            pages_added += 1;
            try stdout.writeAll("Added blank page\n");
        } else {
            const ext = std.fs.path.extension(source.path);
            const ext_lower = blk: {
                var buf: [16]u8 = undefined;
                const len = @min(ext.len, buf.len);
                for (ext[0..len], 0..) |c, i| {
                    buf[i] = std.ascii.toLower(c);
                }
                break :blk buf[0..len];
            };

            if (std.mem.eql(u8, ext_lower, ".pdf")) {
                // Import pages from PDF
                var src_doc = pdfium.Document.open(source.path) catch |err| {
                    try stderr.print("Error opening PDF {s}: {}\n", .{ source.path, err });
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer src_doc.close();

                const src_page_count = src_doc.getPageCount();

                if (source.page_range) |range| {
                    // Import specific pages
                    if (!doc.importPagesRange(&src_doc, range, pages_added)) {
                        try stderr.print("Error importing pages from {s}\n", .{source.path});
                        try stderr.flush();
                        std.process.exit(1);
                    }
                    // Count pages in range (approximate for reporting)
                    try stdout.print("Imported pages {s} from: {s}\n", .{ range, std.fs.path.basename(source.path) });
                } else {
                    // Import all pages
                    if (!doc.importPagesRange(&src_doc, null, pages_added)) {
                        try stderr.print("Error importing pages from {s}\n", .{source.path});
                        try stderr.flush();
                        std.process.exit(1);
                    }
                    pages_added += src_page_count;
                    try stdout.print("Imported {d} pages from: {s}\n", .{ src_page_count, std.fs.path.basename(source.path) });
                }
            } else if (std.mem.eql(u8, ext_lower, ".txt") or std.mem.eql(u8, ext_lower, ".text")) {
                // Add page with text content
                var page = doc.createPage(pages_added, default_size.width, default_size.height) catch |err| {
                    try stderr.print("Error creating page: {}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer page.close();

                try addTextToPage(allocator, &doc, &page, source.path, default_size.width, default_size.height, stderr);

                if (!page.generateContent()) {
                    try stderr.writeAll("Error generating page content\n");
                    try stderr.flush();
                    std.process.exit(1);
                }
                pages_added += 1;
                try stdout.print("Added page with text from: {s}\n", .{std.fs.path.basename(source.path)});
            } else {
                // Try to add as image
                var page = doc.createPage(pages_added, default_size.width, default_size.height) catch |err| {
                    try stderr.print("Error creating page: {}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer page.close();

                try addImageToPage(allocator, &doc, &page, source.path, default_size.width, default_size.height, stderr);

                if (!page.generateContent()) {
                    try stderr.writeAll("Error generating page content\n");
                    try stderr.flush();
                    std.process.exit(1);
                }
                pages_added += 1;
                try stdout.print("Added page with image from: {s}\n", .{std.fs.path.basename(source.path)});
            }
        }
    }

    // Save the document
    doc.saveWithVersion(output_path, null) catch |err| {
        try stderr.print("Error saving PDF: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    try stdout.print("Created: {s} ({d} pages)\n", .{ output_path, pages_added });
}

fn printCreateUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig create -o <output.pdf> [options] <sources...>
        \\
        \\Create a new PDF from one or multiple source files.
        \\
        \\Arguments:
        \\  sources               Source files (PDFs, images, text files, or :blank)
        \\
        \\Options:
        \\  -o, --output <file>   Output PDF file (required)
        \\  -s, --size <SIZE>     Page size for images/text/blank (default: US Letter)
        \\  -p, --pages <RANGE>   Page range for next PDF source (e.g., "1-3,5")
        \\  -h, --help            Show this help message
        \\
        \\Source types:
        \\  PDF files             Pages are imported (use -p before PDF for specific pages)
        \\  Image files           PNG, JPEG, BMP, TGA, PBM, PGM, PPM
        \\  Text files            .txt or .text files
        \\  :blank                Insert a blank page
        \\
        \\Page range syntax (for PDFs):
        \\  1-5                   Pages 1 through 5
        \\  1,3,5                 Pages 1, 3, and 5
        \\  1-3,7,9-12            Combined ranges
        \\
        \\Examples:
        \\  pdfzig create -o out.pdf doc1.pdf doc2.pdf          # Merge two PDFs
        \\  pdfzig create -o out.pdf -p 1-5 doc.pdf             # First 5 pages only
        \\  pdfzig create -o out.pdf cover.png doc.pdf          # Image + PDF
        \\  pdfzig create -o out.pdf :blank doc.pdf :blank      # Blank + PDF + blank
        \\  pdfzig create -o out.pdf -s A4 notes.txt            # Text file as A4 PDF
        \\  pdfzig create -o out.pdf -p 1 a.pdf -p 2-3 b.pdf    # Page 1 of a, pages 2-3 of b
        \\
    ) catch {};
}

// ============================================================================
// Attach Command
// ============================================================================

const AttachArgs = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    glob_pattern: ?[]const u8 = null,
    files: std.array_list.Managed([]const u8) = undefined,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

fn runAttachCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = AttachArgs{};
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
        printAttachUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printAttachUsage(stdout);
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
            if (matchGlobPattern(pattern, entry.name)) {
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
        printAttachUsage(stdout);
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

fn printAttachUsage(stdout: *std.Io.Writer) void {
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

// ============================================================================
// Detach Command
// ============================================================================

const DetachArgs = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    glob_pattern: ?[]const u8 = null,
    indices: std.array_list.Managed(u32) = undefined,
    password: ?[]const u8 = null,
    show_help: bool = false,
};

fn runDetachCommand(
    allocator: std.mem.Allocator,
    arg_it: *SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = DetachArgs{};
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
        printDetachUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printDetachUsage(stdout);
        std.process.exit(1);
    };

    if (args.glob_pattern == null and args.indices.items.len == 0) {
        try stderr.writeAll("Error: Specify attachments to remove with -g (glob) or -i (index)\n\n");
        try stderr.flush();
        printDetachUsage(stdout);
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
                if (matchGlobPattern(pattern, name)) {
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

fn printDetachUsage(stdout: *std.Io.Writer) void {
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

// ============================================================================
// Usage Messages
// ============================================================================

fn printMainUsage(stdout: *std.Io.Writer, pdfium_version: ?u32, pdfium_path: ?[]const u8) void {
    stdout.writeAll(
        \\pdfzig - PDF utility tool using PDFium
        \\
    ) catch {};
    if (pdfium_path) |path| {
        if (pdfium_version) |v| {
            stdout.print("PDFium version: {d} ({s})\n", .{ v, path }) catch {};
        } else {
            stdout.print("PDFium version: unknown ({s})\n", .{path}) catch {};
        }
    } else {
        stdout.writeAll("PDFium: not linked\n") catch {};
    }
    stdout.writeAll(
        \\
        \\Usage: pdfzig [global-options] <command> [options]
        \\
        \\Commands:
        \\  render              Render PDF pages to images
        \\  extract_text        Extract text content from PDF
        \\  extract_images      Extract embedded images from PDF
        \\  extract_attachments Extract embedded attachments from PDF
        \\  visual_diff         Compare two PDFs visually
        \\  info                Display PDF metadata and information
        \\  rotate              Rotate PDF pages
        \\  mirror              Mirror PDF pages
        \\  delete              Delete PDF pages
        \\  add                 Add new page to PDF
        \\  create              Create new PDF from sources
        \\  attach              Attach files to PDF
        \\  detach              Remove attachments from PDF
        \\  download_pdfium     Download PDFium library
        \\
        \\Global Options:
        \\  --link <path>          Load PDFium library from specified path
        \\  -h, --help             Show this help message
        \\  -v, --version          Show version
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
        \\Usage: pdfzig extract_text [options] <input.pdf>
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
        \\  pdfzig extract_text document.pdf
        \\  pdfzig extract_text -o text.txt document.pdf
        \\  pdfzig extract_text -p 1-10 document.pdf > first_pages.txt
        \\
    ) catch {};
}

fn printExtractImagesUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig extract_images [options] <input.pdf> [output_dir]
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
        \\  pdfzig extract_images document.pdf
        \\  pdfzig extract_images -f jpeg -Q 85 document.pdf ./images
        \\  pdfzig extract_images -p 1-5 document.pdf
        \\
    ) catch {};
}

fn printExtractAttachmentsUsage(stdout: *std.Io.Writer) void {
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

fn printVisualDiffUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig visual_diff [options] <first.pdf> <second.pdf>
        \\
        \\Compare two PDFs visually by rendering and comparing pixels.
        \\
        \\Renders each page at the specified resolution and compares pixel by pixel.
        \\Returns exit code 0 if PDFs are identical, 1 if different.
        \\
        \\Options:
        \\  -r, --resolution <N>  Resolution in DPI for comparison (default: 150)
        \\  -o, --output <DIR>    Output directory for diff images
        \\  -P, --password <PW>   Password (use twice for both PDFs)
        \\  --password1 <PW>      Password for first PDF
        \\  --password2 <PW>      Password for second PDF
        \\  -q, --quiet           Only show total, suppress per-page output
        \\  -h, --help            Show this help message
        \\
        \\When -o is specified, grayscale diff images are created where each
        \\pixel's brightness represents the average RGB difference between
        \\the two PDFs (black = identical, white = maximum difference).
        \\
        \\Examples:
        \\  pdfzig visual_diff original.pdf modified.pdf
        \\  pdfzig visual_diff -r 300 doc1.pdf doc2.pdf
        \\  pdfzig visual_diff -o ./diffs doc1.pdf doc2.pdf
        \\  pdfzig visual_diff -P secret1 -P secret2 enc1.pdf enc2.pdf
        \\
    ) catch {};
}

fn printDownloadPdfiumUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig download_pdfium [build]
        \\
        \\Download PDFium library for your platform.
        \\
        \\Arguments:
        \\  build                 Chromium build version (optional, default: latest)
        \\
        \\Options:
        \\  -h, --help            Show this help message
        \\
        \\The library is downloaded from github.com/bblanchon/pdfium-binaries
        \\and installed next to the pdfzig executable.
        \\
        \\Examples:
        \\  pdfzig download_pdfium           # Download latest build
        \\  pdfzig download_pdfium 7606      # Download specific Chromium build
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
