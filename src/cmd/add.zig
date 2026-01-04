//! Add command - Add a new page to PDF

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const cli_parsing = @import("../cli_parsing.zig");
const textfmt = @import("../pdfcontent/textfmt.zig");
const images = @import("../pdfcontent/images.zig");
const main = @import("../main.zig");

const PageSize = cli_parsing.PageSize;

const Args = struct {
    input_path: ?[]const u8 = null,
    content_file: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    page_number: ?u32 = null, // 1-based page number to insert at
    page_size: ?PageSize = null,
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
        printUsage(stdout);
        return;
    }

    const input_path = args.input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printUsage(stdout);
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
        const is_json = std.mem.eql(u8, ext, ".json");

        if (is_json) {
            // Handle JSON file with formatted text blocks
            try textfmt.addJsonToPage(allocator, &doc, &new_page, content_path, page_size.width, page_size.height, stderr);
        } else if (is_text) {
            // Handle text file
            try textfmt.addTextToPage(allocator, &doc, &new_page, content_path, page_size.width, page_size.height, stderr);
        } else {
            // Handle image file
            try images.addImageToPage(allocator, &doc, &new_page, content_path, page_size.width, page_size.height, stderr);
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

pub fn printUsage(stdout: *std.Io.Writer) void {
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
