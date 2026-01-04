//! Create command - Create new PDF from sources

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const cli_parsing = @import("../cli_parsing.zig");
const json_text = @import("../text/formatting.zig");
const main = @import("../main.zig");

const PageSize = cli_parsing.PageSize;

const Args = struct {
    output_path: ?[]const u8 = null,
    page_size: ?PageSize = null,
    sources: std.array_list.Managed(SourceSpec) = undefined,
    show_help: bool = false,
};

const SourceSpec = struct {
    path: []const u8,
    page_range: ?[]const u8 = null, // For PDFs: "1-3,5" or null for all
};

pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *main.SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = Args{
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
        printUsage(stdout);
        return;
    }

    if (args.sources.items.len == 0) {
        try stderr.writeAll("Error: No source files specified\n\n");
        try stderr.flush();
        printUsage(stdout);
        std.process.exit(1);
    }

    const output_path = args.output_path orelse {
        try stderr.writeAll("Error: Output file required (-o <file>)\n\n");
        try stderr.flush();
        printUsage(stdout);
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
        if (std.mem.eql(u8, source.path, cli_parsing.BLANK_PAGE)) {
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
            } else if (std.mem.eql(u8, ext_lower, ".json")) {
                // Add page with formatted text from JSON
                var page = doc.createPage(pages_added, default_size.width, default_size.height) catch |err| {
                    try stderr.print("Error creating page: {}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer page.close();

                try json_text.addJsonToPage(allocator, &doc, &page, source.path, default_size.width, default_size.height, stderr);

                if (!page.generateContent()) {
                    try stderr.writeAll("Error generating page content\n");
                    try stderr.flush();
                    std.process.exit(1);
                }
                pages_added += 1;
                try stdout.print("Added page with formatted text from: {s}\n", .{std.fs.path.basename(source.path)});
            } else if (std.mem.eql(u8, ext_lower, ".txt") or std.mem.eql(u8, ext_lower, ".text")) {
                // Add page with text content
                var page = doc.createPage(pages_added, default_size.width, default_size.height) catch |err| {
                    try stderr.print("Error creating page: {}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer page.close();

                try main.addTextToPage(allocator, &doc, &page, source.path, default_size.width, default_size.height, stderr);

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

                try main.addImageToPage(allocator, &doc, &page, source.path, default_size.width, default_size.height, stderr);

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

pub fn printUsage(stdout: *std.Io.Writer) void {
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
