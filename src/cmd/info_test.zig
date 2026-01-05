//! Integration tests for the info subcommand using sample PDFs from py-pdf/sample-files

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const test_utils = @import("../test_utils.zig");

const test_cache_dir = "test-cache";
const base_download_url = "https://raw.githubusercontent.com/py-pdf/sample-files/refs/heads/main/";

/// Expected test file metadata from files.json
const TestFile = struct {
    path: []const u8,
    pages: ?u32,
    encrypted: bool,
    images: ?u32,
    forms: u32,
};

/// Selected test files covering different scenarios
const test_files = [_]TestFile{
    // Basic document
    .{
        .path = "001-trivial/minimal-document.pdf",
        .pages = 1,
        .encrypted = false,
        .images = 0,
        .forms = 0,
    },
    // Multi-page document
    .{
        .path = "004-pdflatex-4-pages/pdflatex-4-pages.pdf",
        .pages = 4,
        .encrypted = false,
        .images = 0,
        .forms = 0,
    },
    // Encrypted document (password protected)
    .{
        .path = "005-libreoffice-writer-password/libreoffice-writer-password.pdf",
        .pages = 1,
        .encrypted = true,
        .images = 0,
        .forms = 0,
    },
    // Document with image
    .{
        .path = "003-pdflatex-image/pdflatex-image.pdf",
        .pages = 1,
        .encrypted = false,
        .images = 1,
        .forms = 0,
    },
    // Document with forms
    .{
        .path = "010-pdflatex-forms/pdflatex-forms.pdf",
        .pages = 1,
        .encrypted = false,
        .images = 0,
        .forms = 1,
    },
    // LibreOffice form
    .{
        .path = "012-libreoffice-form/libreoffice-form.pdf",
        .pages = 1,
        .encrypted = false,
        .images = 0,
        .forms = 1,
    },
};

/// Ensure the test cache directory exists and download test files if needed
fn ensureTestFiles(allocator: std.mem.Allocator) !void {
    // Create test-cache directory if it doesn't exist
    std.fs.cwd().makeDir(test_cache_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Check each test file and download if missing
    for (test_files) |tf| {
        const local_path = try test_utils.ensureTestFile(allocator, base_download_url, tf.path, test_cache_dir);
        allocator.free(local_path);
    }
}

/// Get the local path for a test file
fn getTestFilePath(allocator: std.mem.Allocator, remote_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ test_cache_dir, remote_path });
}

// ============================================================================
// Tests
// ============================================================================

test "info: page count verification" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    for (test_files) |tf| {
        if (tf.encrypted) continue; // Skip encrypted files for page count test

        const local_path = try getTestFilePath(allocator, tf.path);
        defer allocator.free(local_path);

        var doc = pdfium.Document.open(local_path) catch |err| {
            std.debug.print("Failed to open {s}: {}\n", .{ tf.path, err });
            return err;
        };
        defer doc.close();

        const page_count = doc.getPageCount();
        if (tf.pages) |expected_pages| {
            try std.testing.expectEqual(expected_pages, page_count);
        }
    }
}

test "info: encrypted detection" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    for (test_files) |tf| {
        const local_path = try getTestFilePath(allocator, tf.path);
        defer allocator.free(local_path);

        if (tf.encrypted) {
            // Encrypted files should fail to open without password
            const result = pdfium.Document.open(local_path);
            try std.testing.expectError(pdfium.Error.PasswordRequired, result);
        } else {
            // Non-encrypted files should open successfully
            var doc = pdfium.Document.open(local_path) catch |err| {
                std.debug.print("Failed to open non-encrypted {s}: {}\n", .{ tf.path, err });
                return err;
            };
            defer doc.close();

            try std.testing.expect(!doc.isEncrypted());
        }
    }
}

test "info: metadata retrieval" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    // Test with minimal document
    const local_path = try getTestFilePath(allocator, "001-trivial/minimal-document.pdf");
    defer allocator.free(local_path);

    var doc = try pdfium.Document.open(local_path);
    defer doc.close();

    // Should be able to get metadata (even if some fields are null)
    var metadata = doc.getMetadata(allocator);
    defer metadata.deinit(allocator);

    // Producer should be set for this file (pdfTeX)
    try std.testing.expect(metadata.producer != null);
    if (metadata.producer) |producer| {
        try std.testing.expect(std.mem.indexOf(u8, producer, "pdfTeX") != null);
    }
}

test "info: file version" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    const local_path = try getTestFilePath(allocator, "001-trivial/minimal-document.pdf");
    defer allocator.free(local_path);

    var doc = try pdfium.Document.open(local_path);
    defer doc.close();

    // Should be able to get PDF version
    const version = doc.getFileVersion();
    try std.testing.expect(version != null);
    if (version) |v| {
        // Version should be reasonable (1.0 to 2.0 range = 10 to 20)
        try std.testing.expect(v >= 10 and v <= 20);
    }
}

test "info: image objects detection" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    // Test document with image
    {
        const local_path = try getTestFilePath(allocator, "003-pdflatex-image/pdflatex-image.pdf");
        defer allocator.free(local_path);

        var doc = try pdfium.Document.open(local_path);
        defer doc.close();

        var page = try doc.loadPage(0);
        defer page.close();

        // Count image objects
        var image_count: u32 = 0;
        var it = page.imageObjects();
        while (it.next()) |_| {
            image_count += 1;
        }

        // Should have at least one image
        try std.testing.expect(image_count >= 1);
    }

    // Test document without images
    {
        const local_path = try getTestFilePath(allocator, "001-trivial/minimal-document.pdf");
        defer allocator.free(local_path);

        var doc = try pdfium.Document.open(local_path);
        defer doc.close();

        var page = try doc.loadPage(0);
        defer page.close();

        // Count image objects
        var image_count: u32 = 0;
        var it = page.imageObjects();
        while (it.next()) |_| {
            image_count += 1;
        }

        // Should have no images
        try std.testing.expectEqual(@as(u32, 0), image_count);
    }
}

test "info: multi-page document" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    const local_path = try getTestFilePath(allocator, "004-pdflatex-4-pages/pdflatex-4-pages.pdf");
    defer allocator.free(local_path);

    var doc = try pdfium.Document.open(local_path);
    defer doc.close();

    try std.testing.expectEqual(@as(u32, 4), doc.getPageCount());

    // Should be able to load each page
    for (0..4) |i| {
        var page = try doc.loadPage(@intCast(i));
        page.close();
    }
}
