//! WebUI command - Serve web interface for PDF viewing and editing

const std = @import("std");
const main = @import("../main.zig");
const server_mod = @import("../webui/server.zig");
const pdfium = @import("../pdfium/pdfium.zig");

const Args = struct {
    port: u16 = 8080,
    readonly: bool = false,
    pdf_paths: std.array_list.Managed([]const u8),
    show_help: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *main.SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = Args{
        .pdf_paths = std.array_list.Managed([]const u8).init(allocator),
    };
    defer args.pdf_paths.deinit();

    // Parse command-line arguments
    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                args.show_help = true;
            } else if (std.mem.eql(u8, arg, "--port")) {
                const port_str = arg_it.next() orelse {
                    try stderr.writeAll("Error: --port requires a value\n");
                    try stderr.flush();
                    std.process.exit(1);
                };
                args.port = std.fmt.parseInt(u16, port_str, 10) catch {
                    try stderr.print("Error: Invalid port number: {s}\n", .{port_str});
                    try stderr.flush();
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, arg, "--readonly")) {
                args.readonly = true;
            } else {
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                printUsage(stdout);
                std.process.exit(1);
            }
        } else {
            // Positional argument - PDF file path
            try args.pdf_paths.append(arg);
        }
    }

    if (args.show_help) {
        printUsage(stdout);
        return;
    }

    // Initialize PDFium library
    try pdfium.initWithAllocator(allocator);
    defer pdfium.deinit();

    // Create server
    var web_server = try server_mod.Server.init(allocator, args.port, args.readonly);
    defer web_server.deinit();

    // Load initial documents if provided
    if (args.pdf_paths.items.len > 0) {
        web_server.loadInitialDocuments(args.pdf_paths.items) catch |err| {
            try stderr.print("Error loading PDF files: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        };
    }

    // Print startup message
    try stdout.print("Starting pdfzig WebUI server on http://127.0.0.1:{d}\n", .{args.port});
    if (args.readonly) {
        try stdout.writeAll("Mode: READ-ONLY (no modifications allowed)\n");
    }
    if (args.pdf_paths.items.len > 0) {
        try stdout.print("Loaded {d} PDF file(s)\n", .{args.pdf_paths.items.len});
    }
    try stdout.writeAll("\n");
    try stdout.flush();

    // Start server (blocks until interrupted)
    try web_server.start();
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig webui [options] [file1.pdf file2.pdf ...]
        \\
        \\Serve a web interface for viewing and editing PDF files.
        \\
        \\Options:
        \\  --port <number>     Port to listen on (default: 8080)
        \\  --readonly          Read-only mode, no editing allowed
        \\  -h, --help          Show this help message
        \\
        \\Examples:
        \\  pdfzig webui document.pdf
        \\  pdfzig webui --port 3000 doc1.pdf doc2.pdf
        \\  pdfzig webui --readonly report.pdf
        \\
    ) catch {};
}
