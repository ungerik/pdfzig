//! Extract Images command - Extract embedded images from PDF pages

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const cli_parsing = @import("arg_parsing.zig");
const shared = @import("shared.zig");
const images = @import("../pdfcontent/images.zig");

const Args = struct {
    input_path: ?[]const u8 = null,
    output_dir: []const u8 = ".",
    page_range: ?[]const u8 = null,
    password: ?[]const u8 = null,
    format: images.Format = .png,
    quality: u8 = 90,
    quiet: bool = false,
    show_help: bool = false,
};

/// Run the extract_images command: extract embedded images from PDF pages.
/// Saves each image object as a separate file in PNG or JPEG format.
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
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                args.quiet = true;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pages")) {
                args.page_range = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                args.password = arg_it.next();
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
                const fmt_str = arg_it.next() orelse {
                    shared.exitWithErrorMsg(stderr, "Error: --format requires an argument\n");
                };
                args.format = images.Format.fromString(fmt_str) orelse {
                    shared.exitWithError(stderr, "Error: Invalid format '{s}'\n", .{fmt_str});
                };
            } else if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quality")) {
                const q_str = arg_it.next() orelse {
                    shared.exitWithErrorMsg(stderr, "Error: --quality requires an argument\n");
                };
                args.quality = std.fmt.parseInt(u8, q_str, 10) catch {
                    shared.exitWithErrorMsg(stderr, "Error: Invalid quality value\n");
                };
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

    // Create output directory
    shared.createOutputDirectory(args.output_dir, stderr);

    // Open document
    var doc = shared.openDocumentOrExit(allocator, input_path, args.password, stderr);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Parse page ranges
    var page_ranges: ?[]cli_parsing.PageRange = null;
    defer if (page_ranges) |ranges| allocator.free(ranges);

    if (args.page_range) |range_str| {
        page_ranges = shared.parsePageRangesOrExit(allocator, range_str, page_count, stderr);
    }

    var image_count: u32 = 0;

    // Extract images from each page
    for (1..page_count + 1) |page_num| {
        if (page_ranges) |ranges| {
            if (!cli_parsing.isPageInRanges(page_num, ranges)) continue;
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

            images.writeBitmap(allocator, bitmap, output_path, .{
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

fn printUsage(stdout: *std.Io.Writer) void {
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
