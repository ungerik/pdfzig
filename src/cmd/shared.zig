//! Shared utilities for command implementations
//! Consolidates common patterns to reduce code duplication

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");
const cli_parsing = @import("../cli_parsing.zig");

// ============================================================================
// Error Handling Utilities
// ============================================================================

/// Print an error message and exit with code 1
pub fn exitWithError(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

/// Print an error message without formatting and exit with code 1
pub fn exitWithErrorMsg(stderr: *std.Io.Writer, msg: []const u8) noreturn {
    stderr.writeAll(msg) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

// ============================================================================
// Input Validation Utilities
// ============================================================================

/// Require an input path or exit with error message and usage
pub fn requireInputPath(
    maybe_path: ?[]const u8,
    stderr: *std.Io.Writer,
    stdout: *std.Io.Writer,
    printUsageFn: fn (*std.Io.Writer) void,
) []const u8 {
    if (maybe_path) |path| {
        return path;
    }
    stderr.writeAll("Error: No input PDF file specified\n\n") catch {};
    stderr.flush() catch {};
    printUsageFn(stdout);
    std.process.exit(1);
}

// ============================================================================
// Document Handling Utilities
// ============================================================================

/// Open a PDF document with optional password, exit on error
pub fn openDocumentOrExit(
    path: []const u8,
    password: ?[]const u8,
    stderr: *std.Io.Writer,
) pdfium.Document {
    if (password) |pwd| {
        return pdfium.Document.openWithPassword(path, pwd) catch |err| {
            exitWithError(stderr, "Error opening PDF: {}\n", .{err});
        };
    } else {
        return pdfium.Document.open(path) catch |err| {
            if (err == pdfium.Error.PasswordRequired) {
                exitWithErrorMsg(stderr, "Error: PDF is password protected. Use -P to provide password.\n");
            } else {
                exitWithError(stderr, "Error opening PDF: {}\n", .{err});
            }
        };
    }
}

/// Load a page from a document, exit on error
pub fn loadPageOrExit(
    doc: *pdfium.Document,
    page_num: u32,
    stderr: *std.Io.Writer,
) pdfium.Page {
    return doc.loadPage(page_num - 1) catch |err| {
        exitWithError(stderr, "Error loading page {d}: {}\n", .{ page_num, err });
    };
}

// ============================================================================
// Page Range Parsing Utilities
// ============================================================================

/// Parse page ranges with error handling, exit on invalid range
pub fn parsePageRangesOrExit(
    allocator: std.mem.Allocator,
    range_str: ?[]const u8,
    page_count: u32,
    stderr: *std.Io.Writer,
) ?[]cli_parsing.PageRange {
    const range = range_str orelse return null;

    return cli_parsing.parsePageRanges(allocator, range, page_count) catch {
        exitWithError(stderr, "Error: Invalid page range '{s}'\n", .{range});
    };
}

/// Parse page list (like parsePageList in cli_parsing but returns []u32)
/// This wraps cli_parsing.parsePageList for convenience
pub fn parsePageListOrExit(
    allocator: std.mem.Allocator,
    range_str: ?[]const u8,
    page_count: u32,
    stderr: *std.Io.Writer,
) []u32 {
    return cli_parsing.parsePageList(allocator, range_str, page_count, stderr) catch |err| {
        exitWithError(stderr, "Error parsing page range: {}\n", .{err});
    };
}

// ============================================================================
// File and Directory Utilities
// ============================================================================

/// Create output directory with error handling, exit on failure
pub fn createOutputDirectory(dir_path: []const u8, stderr: *std.Io.Writer) void {
    std.fs.cwd().makePath(dir_path) catch |err| {
        exitWithError(stderr, "Error: Could not create output directory: {}\n", .{err});
    };
}

/// Report save success if output path differs from input path
pub fn reportSaveSuccess(
    stdout: *std.Io.Writer,
    output_path: []const u8,
    input_path: []const u8,
) void {
    if (!std.mem.eql(u8, output_path, input_path)) {
        stdout.print("Saved to: {s}\n", .{output_path}) catch {};
    }
}

// ============================================================================
// Temp File Handling for In-Place Editing
// ============================================================================

pub const TempFileContext = struct {
    input_path: []const u8,
    output_path: []const u8,
    actual_output_path: []const u8,
    temp_path_buf: [std.fs.max_path_bytes]u8,
    overwrite_original: bool,
};

/// Setup temp file for in-place editing (when output_path is null)
pub fn setupTempFileForInPlaceEdit(
    input_path: []const u8,
    output_path: ?[]const u8,
    stderr: *std.Io.Writer,
) TempFileContext {
    var ctx: TempFileContext = undefined;
    ctx.input_path = input_path;
    ctx.output_path = output_path orelse input_path;
    ctx.overwrite_original = output_path == null;

    if (ctx.overwrite_original) {
        const temp_path = std.fmt.bufPrint(&ctx.temp_path_buf, "{s}.tmp", .{input_path}) catch {
            exitWithErrorMsg(stderr, "Error: Path too long\n");
        };
        ctx.actual_output_path = temp_path;
    } else {
        ctx.actual_output_path = ctx.output_path;
    }

    return ctx;
}

/// Complete temp file operation (rename temp to original if needed)
pub fn completeTempFileEdit(ctx: TempFileContext, stderr: *std.Io.Writer) void {
    if (ctx.overwrite_original) {
        std.fs.cwd().deleteFile(ctx.input_path) catch {};
        std.fs.cwd().rename(ctx.actual_output_path, ctx.input_path) catch |err| {
            exitWithError(stderr, "Error replacing original file: {}\n", .{err});
        };
    }
}

/// High-level wrapper for temp file operations with document save
pub fn withTempFileForInPlaceEdit(
    input_path: []const u8,
    output_path: ?[]const u8,
    password: ?[]const u8,
    stderr: *std.Io.Writer,
    stdout: *std.Io.Writer,
    processFn: fn (*pdfium.Document, *std.Io.Writer) anyerror!void,
) !void {
    const ctx = setupTempFileForInPlaceEdit(input_path, output_path, stderr);

    var doc = openDocumentOrExit(input_path, password, stderr);
    defer doc.close();

    // Process the document
    try processFn(&doc, stderr);

    // Save the document
    doc.saveWithVersion(ctx.actual_output_path, null) catch |err| {
        exitWithError(stderr, "Error saving PDF: {}\n", .{err});
    };

    // Complete temp file operation
    completeTempFileEdit(ctx, stderr);

    // Report success
    reportSaveSuccess(stdout, ctx.output_path, ctx.input_path);
}

// ============================================================================
// Page Content Generation
// ============================================================================

/// Generate page content or exit on failure
pub fn generatePageContentOrExit(page: *pdfium.Page, stderr: *std.Io.Writer) void {
    if (!page.generateContent()) {
        exitWithErrorMsg(stderr, "Error generating page content\n");
    }
}

/// Generate page content for specific page number or exit on failure
pub fn generatePageContentWithNumOrExit(
    page: *pdfium.Page,
    page_num: u32,
    stderr: *std.Io.Writer,
) void {
    if (!page.generateContent()) {
        exitWithError(stderr, "Error generating content for page {d}\n", .{page_num});
    }
}
