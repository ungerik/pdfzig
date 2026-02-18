//! Visual Diff command - Compare two PDFs visually

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const cli_parsing = @import("arg_parsing.zig");
const shared = @import("shared.zig");
const zigimg = @import("zigimg");
const lib_render = @import("../pdfzig/render.zig");

const parseResolution = cli_parsing.parseResolution;

/// Color mode for diff output images
pub const ColorMode = enum {
    rgb, // Per-channel RGB diff values
    gray, // Average diff as grayscale
    contrast, // Grayscale scaled to maximum contrast

    pub fn fromString(str: []const u8) ?ColorMode {
        if (std.mem.eql(u8, str, "rgb")) return .rgb;
        if (std.mem.eql(u8, str, "gray") or std.mem.eql(u8, str, "grey")) return .gray;
        if (std.mem.eql(u8, str, "contrast")) return .contrast;
        return null;
    }
};

const Args = struct {
    input1: ?[]const u8 = null,
    input2: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    dpi: f64 = 150.0,
    password1: ?[]const u8 = null,
    password2: ?[]const u8 = null,
    quiet: bool = false,
    show_help: bool = false,
    color_mode: ColorMode = .contrast,
    invert: bool = false,
};

/// Run the visual_diff command: compare two PDFs by rendering and diffing pixels.
/// Exits with code 0 if identical, 1 if differences are found.
/// Optionally writes diff images in rgb, grayscale, or contrast mode.
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
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--resolution")) {
                const res_str = arg_it.next() orelse {
                    shared.exitWithErrorMsg(stderr, "Error: --resolution requires an argument\n");
                };
                args.dpi = parseResolution(res_str) orelse {
                    shared.exitWithError(stderr, "Error: Invalid resolution value '{s}'\n", .{res_str});
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
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--colors")) {
                const mode_str = arg_it.next() orelse {
                    shared.exitWithErrorMsg(stderr, "Error: --colors requires an argument (rgb, gray, or contrast)\n");
                };
                args.color_mode = ColorMode.fromString(mode_str) orelse {
                    shared.exitWithError(stderr, "Error: Invalid color mode '{s}'. Use rgb, gray, or contrast.\n", .{mode_str});
                };
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--invert")) {
                args.invert = true;
            } else {
                shared.exitWithError(stderr, "Unknown option: {s}\n", .{arg});
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
        printUsage(stdout);
        return;
    }

    const input1 = args.input1 orelse {
        shared.exitWithErrorMsg(stderr, "Error: No input PDF files specified\n");
    };

    const input2 = args.input2 orelse {
        shared.exitWithErrorMsg(stderr, "Error: Second input PDF file not specified\n");
    };

    // Create output directory if specified
    if (args.output_dir) |out_dir| {
        std.fs.cwd().makePath(out_dir) catch |err| {
            shared.exitWithError(stderr, "Error: Could not create output directory: {}\n", .{err});
        };
    }

    // Open both documents
    var doc1 = shared.openDocumentOrExit(allocator, input1, args.password1, stderr);
    defer doc1.close();

    var doc2 = shared.openDocumentOrExit(allocator, input2, args.password2, stderr);
    defer doc2.close();

    const page_count1 = doc1.getPageCount();
    const page_count2 = doc2.getPageCount();

    if (page_count1 != page_count2) {
        shared.exitWithError(stderr, "Error: Page count mismatch: {s} has {d} pages, {s} has {d} pages\n", .{
            input1,
            page_count1,
            input2,
            page_count2,
        });
    }

    if (page_count1 == 0) {
        shared.exitWithErrorMsg(stderr, "Error: PDFs have no pages\n");
    }

    var total_diff_pixels: u64 = 0;
    var has_differences = false;

    for (0..page_count1) |page_idx| {
        // Load pages
        var page1 = doc1.loadPage(page_idx) catch {
            shared.exitWithError(stderr, "Error: Could not load page {d} from first PDF\n", .{page_idx + 1});
        };
        defer page1.close();

        var page2 = doc2.loadPage(page_idx) catch {
            shared.exitWithError(stderr, "Error: Could not load page {d} from second PDF\n", .{page_idx + 1});
        };
        defer page2.close();

        // Render both pages to bitmaps at specified DPI
        var bitmap1 = lib_render.renderPageToBitmap(&page1, args.dpi) catch {
            shared.exitWithError(stderr, "Error: Could not create bitmap for page {d}\n", .{page_idx + 1});
        };
        defer bitmap1.destroy();

        var bitmap2 = lib_render.renderPageToBitmap(&page2, args.dpi) catch {
            shared.exitWithError(stderr, "Error: Could not create bitmap for page {d}\n", .{page_idx + 1});
        };
        defer bitmap2.destroy();

        // Compare pixels
        const data1 = bitmap1.getData() orelse {
            shared.exitWithError(stderr, "Error: Could not get buffer for page {d}\n", .{page_idx + 1});
        };
        const data2 = bitmap2.getData() orelse {
            shared.exitWithError(stderr, "Error: Could not get buffer for page {d}\n", .{page_idx + 1});
        };
        const stride = bitmap1.stride;
        const width = bitmap1.width;
        const height = bitmap1.height;

        var page_diff_pixels: u64 = 0;

        // Allocate diff buffer if output is requested
        // RGB mode needs 3 bytes per pixel, gray/contrast need 1 byte
        const bytes_per_pixel: usize = if (args.color_mode == .rgb) 3 else 1;
        var diff_buffer: ?[]u8 = null;
        defer if (diff_buffer) |buf| allocator.free(buf);

        if (args.output_dir != null) {
            diff_buffer = allocator.alloc(u8, @as(usize, width) * @as(usize, height) * bytes_per_pixel) catch {
                shared.exitWithErrorMsg(stderr, "Error: Could not allocate diff buffer\n");
            };
        }

        // Track max value for contrast mode scaling
        var max_gray_value: u8 = 0;

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

                    switch (args.color_mode) {
                        .rgb => {
                            const pixel_idx = (y * @as(usize, width) + x) * 3;
                            buf[pixel_idx] = diff_r;
                            buf[pixel_idx + 1] = diff_g;
                            buf[pixel_idx + 2] = diff_b;
                        },
                        .gray, .contrast => {
                            // Average of absolute differences
                            const avg_diff: u8 = @intCast((@as(u16, diff_r) + @as(u16, diff_g) + @as(u16, diff_b)) / 3);
                            buf[y * @as(usize, width) + x] = avg_diff;
                            if (avg_diff > max_gray_value) {
                                max_gray_value = avg_diff;
                            }
                        },
                    }
                }
            }
        }

        // Apply contrast scaling for contrast mode
        if (diff_buffer) |buf| {
            if (args.color_mode == .contrast and max_gray_value > 0) {
                const pixel_count = @as(usize, width) * @as(usize, height);
                for (0..pixel_count) |i| {
                    // Scale so max_gray_value becomes 255
                    buf[i] = @intCast(@min(255, (@as(u32, buf[i]) * 255) / @as(u32, max_gray_value)));
                }
            }

            // Apply inversion if requested
            if (args.invert) {
                const total_bytes = @as(usize, width) * @as(usize, height) * bytes_per_pixel;
                for (0..total_bytes) |i| {
                    buf[i] = 255 - buf[i];
                }
            }
        }

        total_diff_pixels += page_diff_pixels;
        if (page_diff_pixels > 0) {
            has_differences = true;
        }

        if (!args.quiet) {
            try stdout.print("Page {d}: {d} different pixels\n", .{ page_idx + 1, page_diff_pixels });
        }

        // Write diff image if requested
        if (args.output_dir) |out_dir| {
            if (diff_buffer) |buf| {
                var filename_buf: [256]u8 = undefined;
                const filename = std.fmt.bufPrint(&filename_buf, "diff_page{d}.png", .{page_idx + 1}) catch continue;

                const output_path = std.fs.path.join(allocator, &.{ out_dir, filename }) catch continue;
                defer allocator.free(output_path);

                const write_result = switch (args.color_mode) {
                    .rgb => writeRgbPng(allocator, buf, width, height, output_path),
                    .gray, .contrast => writeGrayscalePng(allocator, buf, width, height, output_path),
                };

                write_result catch |err| {
                    try stderr.print("Warning: Could not write diff image: {}\n", .{err});
                    try stderr.flush();
                };

                if (!args.quiet) {
                    try stdout.print("  Wrote: {s}\n", .{output_path});
                }
            }
        }
    }

    try stdout.print("\nTotal different pixels: {d}\n", .{total_diff_pixels});
    try stdout.flush();

    if (has_differences) {
        std.process.exit(1);
    }
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig visual_diff [options] <first.pdf> <second.pdf>
        \\
        \\Compare two PDFs visually by rendering and comparing pixels.
        \\
        \\Renders each page at the specified resolution and compares pixel by pixel.
        \\Returns exit code 0 if PDFs are identical, 1 if different.
        \\
        \\Options:
        \\  -r, --resolution <N>    Resolution in DPI for comparison (default: 150)
        \\  -o, --output <DIR>      Output directory for diff images
        \\  -c, --colors <MODE>     Color mode for diff output (default: contrast)
        \\                            rgb      - per-channel RGB diff values
        \\                            gray     - average diff as grayscale
        \\                            contrast - grayscale scaled to max contrast
        \\  -i, --invert            Invert diff image colors
        \\  -P, --password <PW>     Password (use twice for both PDFs)
        \\  --password1 <PW>        Password for first PDF
        \\  --password2 <PW>        Password for second PDF
        \\  -q, --quiet             Only show total, suppress per-page output
        \\  -h, --help              Show this help message
        \\
        \\When -o is specified, diff images are created showing pixel differences.
        \\In contrast mode (default), the image is scaled so the maximum difference
        \\appears as white. Use --invert to flip colors (white = identical).
        \\
        \\Examples:
        \\  pdfzig visual_diff original.pdf modified.pdf
        \\  pdfzig visual_diff -r 300 doc1.pdf doc2.pdf
        \\  pdfzig visual_diff -o ./diffs doc1.pdf doc2.pdf
        \\  pdfzig visual_diff -o ./diffs --colors rgb doc1.pdf doc2.pdf
        \\  pdfzig visual_diff -o ./diffs --invert doc1.pdf doc2.pdf
        \\  pdfzig visual_diff -P secret1 -P secret2 enc1.pdf enc2.pdf
        \\
    ) catch {};
}

fn writeGrayscalePng(allocator: std.mem.Allocator, data: []u8, width: u32, height: u32, path: []const u8) !void {
    // Create grayscale pixel data slice with correct type
    const pixel_data: []zigimg.color.Grayscale8 = @as(
        [*]zigimg.color.Grayscale8,
        @ptrCast(data.ptr),
    )[0 .. @as(usize, width) * @as(usize, height)];

    // Create image with grayscale pixels
    const img = zigimg.Image{
        .width = width,
        .height = height,
        .pixels = .{ .grayscale8 = pixel_data },
    };

    // Write to file with best filter choice for compression
    var write_buffer: [4096]u8 = undefined;
    img.writeToFilePath(allocator, path, &write_buffer, .{
        .png = .{ .filter_choice = .heuristic },
    }) catch return error.WriteError;
}

fn writeRgbPng(allocator: std.mem.Allocator, data: []u8, width: u32, height: u32, path: []const u8) !void {
    // Create RGB pixel data slice with correct type
    const pixel_data: []zigimg.color.Rgb24 = @as(
        [*]zigimg.color.Rgb24,
        @ptrCast(data.ptr),
    )[0 .. @as(usize, width) * @as(usize, height)];

    // Create image with RGB pixels
    const img = zigimg.Image{
        .width = width,
        .height = height,
        .pixels = .{ .rgb24 = pixel_data },
    };

    // Write to file with best filter choice for compression
    var write_buffer: [4096]u8 = undefined;
    img.writeToFilePath(allocator, path, &write_buffer, .{
        .png = .{ .filter_choice = .heuristic },
    }) catch return error.WriteError;
}
