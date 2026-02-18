//! CLI shared utilities — error printing, OrExit wrappers, etc.

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const cli_parsing = @import("arg_parsing.zig");

// Re-export library shared functions for CLI convenience
const lib = @import("../pdfzig/shared.zig");
pub const openDocument = lib.openDocument;
pub const loadPage = lib.loadPage;
pub const createDirectory = lib.createDirectory;
pub const generatePageContent = lib.generatePageContent;
pub const extensionLower = lib.extensionLower;
pub const hasXmlExtension = lib.hasXmlExtension;

// ============================================================================
// Temp File Management (CLI-only: used for in-place file editing)
// ============================================================================

pub const TempFileContext = struct {
    input_path: []const u8,
    output_path: []const u8,
    actual_output_path: []const u8,
    temp_path_buf: [std.fs.max_path_bytes]u8,
    overwrite_original: bool,
};

/// Setup temp file for in-place editing (when output_path is null)
pub fn setupTempFile(
    input_path: []const u8,
    output_path: ?[]const u8,
) !TempFileContext {
    var ctx: TempFileContext = undefined;
    ctx.input_path = input_path;
    ctx.output_path = output_path orelse input_path;
    ctx.overwrite_original = output_path == null;

    if (ctx.overwrite_original) {
        const temp_path = std.fmt.bufPrint(&ctx.temp_path_buf, "{s}.tmp", .{input_path}) catch {
            return error.PathTooLong;
        };
        ctx.actual_output_path = temp_path;
    } else {
        ctx.actual_output_path = ctx.output_path;
    }

    return ctx;
}

/// Complete temp file operation (rename temp to original if needed)
/// On POSIX, rename atomically replaces the target file.
pub fn completeTempFile(ctx: TempFileContext) !void {
    if (ctx.overwrite_original) {
        try std.fs.cwd().rename(ctx.actual_output_path, ctx.input_path);
    }
}

// ============================================================================
// CLI Helper Functions (use process.exit for error handling)
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

/// Require an input path or exit with error message
pub fn requireInputPath(
    maybe_path: ?[]const u8,
    stderr: *std.Io.Writer,
) []const u8 {
    if (maybe_path) |path| {
        return path;
    }
    exitWithErrorMsg(stderr, "Error: No input PDF file specified\n");
}

/// Open a PDF document or exit on error (CLI helper)
pub fn openDocumentOrExit(
    allocator: std.mem.Allocator,
    path: []const u8,
    password: ?[]const u8,
    stderr: *std.Io.Writer,
) pdfium.Document {
    return openDocument(allocator, path, password) catch |err| {
        if (err == pdfium.Error.PasswordRequired) {
            exitWithErrorMsg(stderr, "Error: PDF is password protected. Use -P to provide password.\n");
        } else {
            exitWithError(stderr, "Error opening PDF: {}\n", .{err});
        }
    };
}

/// Load a page from a document or exit on error (CLI helper)
pub fn loadPageOrExit(
    doc: *pdfium.Document,
    page_num: usize,
    stderr: *std.Io.Writer,
) pdfium.Page {
    return loadPage(doc, page_num) catch |err| {
        exitWithError(stderr, "Error loading page {d}: {}\n", .{ page_num, err });
    };
}

/// Parse page ranges with error handling, exit on invalid range (CLI helper)
pub fn parsePageRangesOrExit(
    allocator: std.mem.Allocator,
    range_str: ?[]const u8,
    page_count: usize,
    stderr: *std.Io.Writer,
) ?[]cli_parsing.PageRange {
    const range = range_str orelse return null;

    return cli_parsing.parsePageRanges(allocator, range, page_count) catch {
        exitWithError(stderr, "Error: Invalid page range '{s}'\n", .{range});
    };
}

/// Create output directory or exit on failure (CLI helper)
pub fn createOutputDirectory(dir_path: []const u8, stderr: *std.Io.Writer) void {
    createDirectory(dir_path) catch |err| {
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

/// Setup temp file for in-place editing or exit on error (CLI helper)
pub fn setupTempFileForInPlaceEdit(
    input_path: []const u8,
    output_path: ?[]const u8,
    stderr: *std.Io.Writer,
) TempFileContext {
    return setupTempFile(input_path, output_path) catch {
        exitWithErrorMsg(stderr, "Error: Path too long\n");
    };
}

/// Complete temp file operation or exit on error (CLI helper)
pub fn completeTempFileEdit(ctx: TempFileContext, stderr: *std.Io.Writer) void {
    completeTempFile(ctx) catch |err| {
        exitWithError(stderr, "Error replacing original file: {}\n", .{err});
    };
}

/// Generate page content or exit on failure (CLI helper)
pub fn generatePageContentOrExit(page: *pdfium.Page, stderr: *std.Io.Writer) void {
    generatePageContent(page) catch {
        exitWithErrorMsg(stderr, "Error generating page content\n");
    };
}

/// Add content (image, text, or JSON) to a page based on file extension.
/// Exits with error if the content could not be added.
pub fn addFileContentToPage(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    content_path: []const u8,
    page_width: f64,
    page_height: f64,
    stderr: *std.Io.Writer,
) void {
    lib.addFileContentToPage(allocator, doc, page, content_path, page_width, page_height) catch |err| {
        exitWithError(stderr, "Error adding content from {s}: {}\n", .{ content_path, err });
    };
}

/// Generate page content for specific page number or exit on failure (CLI helper)
pub fn generatePageContentWithNumOrExit(
    page: *pdfium.Page,
    page_num: usize,
    stderr: *std.Io.Writer,
) void {
    generatePageContent(page) catch {
        exitWithError(stderr, "Error generating content for page {d}\n", .{page_num});
    };
}
