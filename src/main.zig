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
const pdfium = @import("pdfium/pdfium.zig");
const renderer = @import("renderer.zig");
const image_writer = @import("image_writer.zig");
const downloader = @import("pdfium/downloader.zig");
const loader = @import("pdfium/loader.zig");
const zigimg = @import("zigimg");
const cli_parsing = @import("cli_parsing.zig");

// Command modules
const cmd_info = @import("cmd/info.zig");
const cmd_render = @import("cmd/render.zig");
const cmd_extract_text = @import("cmd/extract_text.zig");
const cmd_extract_images = @import("cmd/extract_images.zig");
const cmd_extract_attachments = @import("cmd/extract_attachments.zig");
const cmd_visual_diff = @import("cmd/visual_diff.zig");
const cmd_download_pdfium = @import("cmd/download_pdfium.zig");
const cmd_rotate = @import("cmd/rotate.zig");
const cmd_mirror = @import("cmd/mirror.zig");
const cmd_delete = @import("cmd/delete.zig");
const cmd_add = @import("cmd/add.zig");
const cmd_create = @import("cmd/create.zig");
const cmd_attach = @import("cmd/attach.zig");
const cmd_detach = @import("cmd/detach.zig");

const version = "0.1.0";

const Command = cli_parsing.Command;
pub const SliceArgIterator = cli_parsing.SliceArgIterator;
const PageSize = cli_parsing.PageSize;
const OutputSpec = cli_parsing.OutputSpec;
const parseResolution = cli_parsing.parseResolution;

pub fn main() !void {
    // Use arena allocator - the app runs one command then exits,
    // so we can free all memory at once (or let OS reclaim it)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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
        cmd_download_pdfium.run(allocator, &cmd_arg_it, stdout, stderr);
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
        .render => try cmd_render.run(allocator, &cmd_arg_it, stdout, stderr),
        .extract_text => try cmd_extract_text.run(allocator, &cmd_arg_it, stdout, stderr),
        .extract_images => try cmd_extract_images.run(allocator, &cmd_arg_it, stdout, stderr),
        .extract_attachments => try cmd_extract_attachments.run(allocator, &cmd_arg_it, stdout, stderr),
        .visual_diff => cmd_visual_diff.run(allocator, &cmd_arg_it, stdout, stderr),
        .info => try cmd_info.run(allocator, &cmd_arg_it, stdout, stderr),
        .rotate => try cmd_rotate.run(allocator, &cmd_arg_it, stdout, stderr),
        .mirror => try cmd_mirror.run(allocator, &cmd_arg_it, stdout, stderr),
        .delete => try cmd_delete.run(allocator, &cmd_arg_it, stdout, stderr),
        .add => try cmd_add.run(allocator, &cmd_arg_it, stdout, stderr),
        .create => try cmd_create.run(allocator, &cmd_arg_it, stdout, stderr),
        .attach => try cmd_attach.run(allocator, &cmd_arg_it, stdout, stderr),
        .detach => try cmd_detach.run(allocator, &cmd_arg_it, stdout, stderr),
        .download_pdfium => unreachable, // Handled above
        .help => printMainUsage(stdout, pdfium.getVersion(), pdfium.getLibraryPath()),
        .version_cmd => try stdout.print("pdfzig {s}\n", .{version}),
    }

    try stdout.flush();
}

/// Parse a page range string (e.g., "1-5,8,10-12") into a list of page numbers.
/// If range_str is null, returns all pages from 1 to page_count.
/// Returns error message on stderr and exits on invalid input.
pub fn parsePageList(
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
// Helper Functions for Page Content
// ============================================================================

pub fn addImageToPage(
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

pub fn addTextToPage(
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

// ============================================================================
// Helper Functions
// ============================================================================

pub fn openDocument(path: []const u8, password: ?[]const u8, stderr: *std.Io.Writer) ?pdfium.Document {
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

// ============================================================================
// Tests
// ============================================================================

test {
    // Import test modules to include their tests
    _ = @import("cmd/info_test.zig");
    _ = @import("cmd/extract_text.zig");
    _ = @import("renderer.zig");
    _ = @import("image_writer.zig");
    _ = @import("text/formatting.zig");
}
