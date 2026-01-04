//! Integration tests for attachment extraction using ZUGFeRD/corpus sample PDFs
//! Downloads test files from https://github.com/ZUGFeRD/corpus

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");

const test_cache_dir = "test-cache/zugferd";
const base_download_url = "https://raw.githubusercontent.com/ZUGFeRD/corpus/master/";

/// Test file with expected XML attachment info
const TestFile = struct {
    path: []const u8,
    expected_xml_name: []const u8, // Expected name of embedded XML file
    zugferd_version: u8, // 1 or 2
};

/// Selected test files from ZUGFeRD corpus
const test_files = [_]TestFile{
    // ZUGFeRD v1 files (embedded ZUGFeRD-invoice.xml)
    .{
        .path = "ZUGFeRDv1/correct/Mustangproject/MustangGnuaccountingBeispielRE-20170509_505.pdf",
        .expected_xml_name = "ZUGFeRD-invoice.xml",
        .zugferd_version = 1,
    },
    .{
        .path = "ZUGFeRDv1/correct/Mustangproject/MustangGnuaccountingBeispielRE-20151008_504.pdf",
        .expected_xml_name = "ZUGFeRD-invoice.xml",
        .zugferd_version = 1,
    },
    // ZUGFeRD v2 / Factur-X files (embedded factur-x.xml)
    .{
        .path = "ZUGFeRDv2/correct/Mustangproject/MustangGnuaccountingBeispielRE-20201121_508.pdf",
        .expected_xml_name = "factur-x.xml",
        .zugferd_version = 2,
    },
    .{
        .path = "ZUGFeRDv2/correct/FNFE-factur-x-examples/Facture_FR_MINIMUM.pdf",
        .expected_xml_name = "factur-x.xml",
        .zugferd_version = 2,
    },
    .{
        .path = "ZUGFeRDv2/correct/FNFE-factur-x-examples/Facture_FR_BASICWL.pdf",
        .expected_xml_name = "factur-x.xml",
        .zugferd_version = 2,
    },
    .{
        .path = "ZUGFeRDv2/correct/FNFE-factur-x-examples/Facture_UE_MINIMUM.pdf",
        .expected_xml_name = "factur-x.xml",
        .zugferd_version = 2,
    },
};

/// Ensure test cache directory exists and download test files if needed
fn ensureTestFiles(allocator: std.mem.Allocator) !void {
    // Create test-cache/zugferd directory if it doesn't exist
    std.fs.cwd().makePath(test_cache_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Check each test file and download if missing
    for (test_files) |tf| {
        const local_path = try std.fs.path.join(allocator, &.{ test_cache_dir, tf.path });
        defer allocator.free(local_path);

        // Check if file exists
        const file = std.fs.cwd().openFile(local_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Need to download - create parent directories first
                const dir_path = std.fs.path.dirname(local_path) orelse test_cache_dir;
                std.fs.cwd().makePath(dir_path) catch {};

                // Download the file
                try downloadFile(allocator, tf.path, local_path);
                continue;
            }
            return err;
        };
        file.close();
    }
}

/// Download a file from the ZUGFeRD corpus repository using native Zig HTTP
fn downloadFile(allocator: std.mem.Allocator, remote_path: []const u8, local_path: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_download_url, remote_path });
    defer allocator.free(url);

    std.debug.print("Downloading: {s}\n", .{remote_path});

    // Use native Zig HTTP client
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_writer.writer,
    }) catch {
        std.debug.print("HTTP request failed\n", .{});
        return error.DownloadFailed;
    };

    if (result.status != .ok) {
        std.debug.print("HTTP status: {}\n", .{result.status});
        return error.DownloadFailed;
    }

    // Get the downloaded data and write to file
    var list = response_writer.toArrayList();
    const data = list.toOwnedSlice(allocator) catch return error.DownloadFailed;
    defer allocator.free(data);

    // Write to file
    const file = std.fs.cwd().createFile(local_path, .{}) catch |err| {
        std.debug.print("Failed to create file: {}\n", .{err});
        return err;
    };
    defer file.close();
    file.writeAll(data) catch |err| {
        std.debug.print("Failed to write file: {}\n", .{err});
        return err;
    };
}

/// Get the local path for a test file
fn getTestFilePath(allocator: std.mem.Allocator, remote_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ test_cache_dir, remote_path });
}

// ============================================================================
// Tests
// ============================================================================

test "xml: ZUGFeRD PDFs have attachments" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    for (test_files) |tf| {
        const local_path = try getTestFilePath(allocator, tf.path);
        defer allocator.free(local_path);

        var doc = pdfium.Document.open(local_path) catch |err| {
            std.debug.print("Failed to open {s}: {}\n", .{ tf.path, err });
            return err;
        };
        defer doc.close();

        const attachment_count = doc.getAttachmentCount();
        try std.testing.expect(attachment_count > 0);
    }
}

test "xml: ZUGFeRD PDFs contain expected XML file" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    for (test_files) |tf| {
        const local_path = try getTestFilePath(allocator, tf.path);
        defer allocator.free(local_path);

        var doc = pdfium.Document.open(local_path) catch |err| {
            std.debug.print("Failed to open {s}: {}\n", .{ tf.path, err });
            return err;
        };
        defer doc.close();

        // Look for the expected XML file
        var found_xml = false;
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator);
            if (name) |n| {
                defer allocator.free(n);
                if (std.mem.eql(u8, n, tf.expected_xml_name)) {
                    found_xml = true;
                    break;
                }
            }
        }

        if (!found_xml) {
            std.debug.print("Expected XML file '{s}' not found in {s}\n", .{ tf.expected_xml_name, tf.path });
        }
        try std.testing.expect(found_xml);
    }
}

test "xml: isXml correctly identifies XML attachments" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    for (test_files) |tf| {
        const local_path = try getTestFilePath(allocator, tf.path);
        defer allocator.free(local_path);

        var doc = pdfium.Document.open(local_path) catch |err| {
            std.debug.print("Failed to open {s}: {}\n", .{ tf.path, err });
            return err;
        };
        defer doc.close();

        // Find the expected XML attachment and verify isXml returns true
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator);
            if (name) |n| {
                defer allocator.free(n);
                if (std.mem.eql(u8, n, tf.expected_xml_name)) {
                    try std.testing.expect(attachment.isXml(allocator));
                    break;
                }
            }
        }
    }
}

test "xml: can extract XML data from ZUGFeRD PDFs" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    for (test_files) |tf| {
        const local_path = try getTestFilePath(allocator, tf.path);
        defer allocator.free(local_path);

        var doc = pdfium.Document.open(local_path) catch |err| {
            std.debug.print("Failed to open {s}: {}\n", .{ tf.path, err });
            return err;
        };
        defer doc.close();

        // Find and extract the XML attachment
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator);
            if (name) |n| {
                defer allocator.free(n);
                if (std.mem.eql(u8, n, tf.expected_xml_name)) {
                    const data = attachment.getData(allocator);
                    try std.testing.expect(data != null);
                    if (data) |d| {
                        defer allocator.free(d);
                        // Verify it's valid XML (starts with <?xml or <rsm: or similar)
                        try std.testing.expect(d.len > 10);
                        // Check for XML declaration or root element
                        const starts_with_xml = std.mem.startsWith(u8, d, "<?xml") or
                            std.mem.startsWith(u8, d, "<rsm:") or
                            std.mem.startsWith(u8, d, "<CrossIndustryDocument") or
                            std.mem.startsWith(u8, d, "\xef\xbb\xbf<?xml"); // BOM + XML declaration
                        if (!starts_with_xml) {
                            std.debug.print("XML data doesn't start with expected prefix in {s}\n", .{tf.path});
                            std.debug.print("First 100 bytes: {s}\n", .{d[0..@min(100, d.len)]});
                        }
                        try std.testing.expect(starts_with_xml);
                    }
                    break;
                }
            }
        }
    }
}

test "xml: ZUGFeRD v1 contains ZUGFeRD-invoice.xml" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    for (test_files) |tf| {
        if (tf.zugferd_version != 1) continue;

        const local_path = try getTestFilePath(allocator, tf.path);
        defer allocator.free(local_path);

        var doc = pdfium.Document.open(local_path) catch |err| {
            std.debug.print("Failed to open {s}: {}\n", .{ tf.path, err });
            return err;
        };
        defer doc.close();

        // ZUGFeRD v1 should have ZUGFeRD-invoice.xml
        var found = false;
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator);
            if (name) |n| {
                defer allocator.free(n);
                if (std.mem.eql(u8, n, "ZUGFeRD-invoice.xml")) {
                    found = true;
                    break;
                }
            }
        }
        try std.testing.expect(found);
    }
}

test "xml: ZUGFeRD v2/Factur-X contains factur-x.xml" {
    const allocator = std.testing.allocator;

    try ensureTestFiles(allocator);

    try pdfium.init();
    defer pdfium.deinit();

    for (test_files) |tf| {
        if (tf.zugferd_version != 2) continue;

        const local_path = try getTestFilePath(allocator, tf.path);
        defer allocator.free(local_path);

        var doc = pdfium.Document.open(local_path) catch |err| {
            std.debug.print("Failed to open {s}: {}\n", .{ tf.path, err });
            return err;
        };
        defer doc.close();

        // ZUGFeRD v2 / Factur-X should have factur-x.xml
        var found = false;
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator);
            if (name) |n| {
                defer allocator.free(n);
                if (std.mem.eql(u8, n, "factur-x.xml")) {
                    found = true;
                    break;
                }
            }
        }
        try std.testing.expect(found);
    }
}

// ============================================================================
// Glob Pattern Matching Tests
// ============================================================================

test "glob: exact match" {
    try std.testing.expect(main.matchGlobPattern("test.xml", "test.xml"));
    try std.testing.expect(!main.matchGlobPattern("test.xml", "test.json"));
    try std.testing.expect(!main.matchGlobPattern("test.xml", "test.xmlx"));
}

test "glob: star wildcard" {
    // *.xml matches any .xml file
    try std.testing.expect(main.matchGlobPattern("*.xml", "test.xml"));
    try std.testing.expect(main.matchGlobPattern("*.xml", "invoice.xml"));
    try std.testing.expect(main.matchGlobPattern("*.xml", "ZUGFeRD-invoice.xml"));
    try std.testing.expect(!main.matchGlobPattern("*.xml", "test.json"));
    try std.testing.expect(!main.matchGlobPattern("*.xml", "test.xmlx"));

    // test.* matches test with any extension
    try std.testing.expect(main.matchGlobPattern("test.*", "test.xml"));
    try std.testing.expect(main.matchGlobPattern("test.*", "test.json"));
    try std.testing.expect(!main.matchGlobPattern("test.*", "other.xml"));

    // *invoice* matches anything containing invoice
    try std.testing.expect(main.matchGlobPattern("*invoice*", "invoice.xml"));
    try std.testing.expect(main.matchGlobPattern("*invoice*", "ZUGFeRD-invoice.xml"));
    try std.testing.expect(main.matchGlobPattern("*invoice*", "my-invoice-2024.pdf"));
    try std.testing.expect(!main.matchGlobPattern("*invoice*", "factur-x.xml"));
}

test "glob: question mark wildcard" {
    try std.testing.expect(main.matchGlobPattern("test?.xml", "test1.xml"));
    try std.testing.expect(main.matchGlobPattern("test?.xml", "testA.xml"));
    try std.testing.expect(!main.matchGlobPattern("test?.xml", "test.xml"));
    try std.testing.expect(!main.matchGlobPattern("test?.xml", "test12.xml"));
}

test "glob: case insensitive" {
    try std.testing.expect(main.matchGlobPattern("*.XML", "test.xml"));
    try std.testing.expect(main.matchGlobPattern("*.xml", "TEST.XML"));
    try std.testing.expect(main.matchGlobPattern("Test.xml", "test.xml"));
    try std.testing.expect(main.matchGlobPattern("test.xml", "TEST.XML"));
}

test "glob: factur-x pattern" {
    try std.testing.expect(main.matchGlobPattern("factur-x.xml", "factur-x.xml"));
    try std.testing.expect(main.matchGlobPattern("factur*.xml", "factur-x.xml"));
    try std.testing.expect(main.matchGlobPattern("*factur*", "factur-x.xml"));
}
