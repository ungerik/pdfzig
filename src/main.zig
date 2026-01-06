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
const images = @import("pdfcontent/images.zig");
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
const cmd_webui = @import("cmd/webui.zig");

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
    else if (std.mem.eql(u8, cmd_str, "webui"))
        .webui
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
        .webui => try cmd_webui.run(allocator, &cmd_arg_it, stdout, stderr),
        .download_pdfium => unreachable, // Handled above
        .help => printMainUsage(stdout, pdfium.getVersion(), pdfium.getLibraryPath()),
        .version_cmd => try stdout.print("pdfzig {s}\n", .{version}),
    }

    try stdout.flush();
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
    _ = @import("cli_parsing.zig");
    _ = @import("pdfcontent/images.zig");
    _ = @import("pdfcontent/textfmt.zig");
}
