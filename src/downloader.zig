//! PDFium Download and Extraction
//! Downloads PDFium binaries from GitHub releases and extracts the library file

const std = @import("std");
const builtin = @import("builtin");
const loader = @import("pdfium_loader.zig");
const Allocator = std.mem.Allocator;

pub const DownloadError = error{
    UnsupportedPlatform,
    DownloadFailed,
    ExtractionFailed,
    VersionNotFound,
    OutOfMemory,
    HttpError,
    TarError,
    HashMismatch,
};

/// Get the PDFium asset name for the current platform
pub fn getPdfiumAssetName() ?[]const u8 {
    const arch = builtin.cpu.arch;
    const os = builtin.os.tag;

    return switch (os) {
        .macos => switch (arch) {
            .aarch64 => "pdfium-mac-arm64.tgz",
            .x86_64 => "pdfium-mac-x64.tgz",
            else => null,
        },
        .linux => switch (arch) {
            .aarch64 => "pdfium-linux-arm64.tgz",
            .x86_64 => "pdfium-linux-x64.tgz",
            .arm => "pdfium-linux-arm.tgz",
            else => null,
        },
        .windows => switch (arch) {
            .aarch64 => "pdfium-win-arm64.tgz",
            .x86_64 => "pdfium-win-x64.tgz",
            .x86 => "pdfium-win-x86.tgz",
            else => null,
        },
        else => null,
    };
}

/// Get the source library name inside the archive
fn getSourceLibName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "libpdfium.dylib",
        .linux => "libpdfium.so",
        .windows => "pdfium.dll",
        else => "libpdfium.so",
    };
}

/// Download PDFium to the specified output directory
/// Returns the Chromium build version number
/// If version is null, downloads the latest release
pub fn downloadPdfium(allocator: Allocator, version: ?u32, output_dir: []const u8) !u32 {
    const asset_name = getPdfiumAssetName() orelse return DownloadError.UnsupportedPlatform;

    // Build the download URL
    const url = if (version) |v|
        try std.fmt.allocPrint(allocator, "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/{d}/{s}", .{ v, asset_name })
    else
        try std.fmt.allocPrint(allocator, "https://github.com/bblanchon/pdfium-binaries/releases/latest/download/{s}", .{asset_name});
    defer allocator.free(url);

    std.debug.print("Downloading PDFium from: {s}\n", .{url});

    const actual_version = try downloadAndExtract(allocator, url, version, output_dir);

    return actual_version;
}

/// Perform an HTTP GET request and return the response body
fn httpGet(allocator: Allocator, url: []const u8, extra_headers: []const std.http.Header) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Create an allocating writer to collect the response body
    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = extra_headers,
        .response_writer = &response_writer.writer,
    }) catch return DownloadError.HttpError;

    if (result.status != .ok) {
        response_writer.deinit();
        return DownloadError.HttpError;
    }

    // Get the collected data as an owned slice
    var list = response_writer.toArrayList();
    return list.toOwnedSlice(allocator);
}

/// Fetch the expected SHA256 hash from GitHub API for a release asset
fn fetchExpectedHash(allocator: Allocator, asset_name: []const u8, version: ?u32) ?[64]u8 {
    // Build the API URL
    const api_url = if (version) |v|
        std.fmt.allocPrint(allocator, "https://api.github.com/repos/bblanchon/pdfium-binaries/releases/tags/chromium/{d}", .{v}) catch return null
    else
        std.fmt.allocPrint(allocator, "https://api.github.com/repos/bblanchon/pdfium-binaries/releases/latest", .{}) catch return null;
    defer allocator.free(api_url);

    // Fetch the API response
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "User-Agent", .value = "pdfzig" },
    };
    const json_data = httpGet(allocator, api_url, &headers) catch return null;
    defer allocator.free(json_data);

    // Find the asset by name and extract its digest
    // Format: "name": "pdfium-mac-arm64.tgz", ... "digest": "sha256:abc123..."
    // Search for the name field specifically to avoid matching browser_download_url
    const asset_needle = std.fmt.allocPrint(allocator, "\"name\": \"{s}\"", .{asset_name}) catch return null;
    defer allocator.free(asset_needle);

    const asset_pos = std.mem.indexOf(u8, json_data, asset_needle) orelse return null;

    // Find "digest" near this asset (within next 3000 chars - enough for all fields in between)
    const search_start = asset_pos;
    const search_end = @min(asset_pos + 3000, json_data.len);
    const search_region = json_data[search_start..search_end];

    // Try both formats: with and without space after colon
    const digest_needle1 = "\"digest\": \"sha256:";
    const digest_needle2 = "\"digest\":\"sha256:";
    const digest_start = std.mem.indexOf(u8, search_region, digest_needle1) orelse
        std.mem.indexOf(u8, search_region, digest_needle2) orelse return null;
    const needle_len = if (std.mem.indexOf(u8, search_region, digest_needle1) != null) digest_needle1.len else digest_needle2.len;
    const hash_start = digest_start + needle_len;

    // Extract the 64-character hex hash
    if (hash_start + 64 > search_region.len) return null;
    const hash_slice = search_region[hash_start .. hash_start + 64];

    var hash: [64]u8 = undefined;
    @memcpy(&hash, hash_slice);

    return hash;
}

/// Calculate SHA256 hash of data
fn calculateHash(data: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    return hasher.finalResult();
}

/// Convert a 32-byte hash to 64-character hex string
fn hashToHex(hash: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return result;
}

/// Download and extract PDFium using native Zig HTTP and tar
fn downloadAndExtract(allocator: Allocator, url: []const u8, version: ?u32, output_dir: []const u8) !u32 {
    const asset_name = getPdfiumAssetName() orelse return DownloadError.UnsupportedPlatform;

    // Try to fetch the expected hash from GitHub API
    const expected_hash = fetchExpectedHash(allocator, asset_name, version);
    if (expected_hash) |_| {
        std.debug.print("Retrieved SHA256 hash from GitHub\n", .{});
    }

    // Download the archive
    const archive_data = try httpGet(allocator, url, &.{});
    defer allocator.free(archive_data);

    if (archive_data.len < 1000) {
        std.debug.print("Downloaded file too small ({d} bytes), download likely failed\n", .{archive_data.len});
        return DownloadError.DownloadFailed;
    }

    std.debug.print("Downloaded {d} bytes\n", .{archive_data.len});

    // Verify hash if we have an expected hash
    if (expected_hash) |exp_hash| {
        const actual_hash = calculateHash(archive_data);
        const actual_hex = hashToHex(actual_hash);

        if (!std.mem.eql(u8, &actual_hex, &exp_hash)) {
            std.debug.print("Hash mismatch!\n", .{});
            std.debug.print("Expected: {s}\n", .{exp_hash});
            std.debug.print("Actual:   {s}\n", .{actual_hex});
            return DownloadError.HashMismatch;
        }
        std.debug.print("SHA256 hash verified\n", .{});
    }

    // Create a temporary directory for extraction
    const tmp_dir = try std.fs.path.join(allocator, &.{ output_dir, ".pdfium_tmp" });
    defer allocator.free(tmp_dir);

    // Clean up any existing temp directory
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create temp directory
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Decompress gzip and extract tar
    var input_reader: std.Io.Reader = .fixed(archive_data);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input_reader, .gzip, &decompress_buffer);

    var tmp_dir_handle = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer tmp_dir_handle.close();

    std.tar.pipeToFileSystem(tmp_dir_handle, &decompress.reader, .{
        .strip_components = 0,
    }) catch |err| {
        std.debug.print("Tar extraction failed: {}\n", .{err});
        return DownloadError.ExtractionFailed;
    };

    // Get the version from VERSION file if not specified
    const actual_version = version orelse blk: {
        const version_file_path = try std.fs.path.join(allocator, &.{ tmp_dir, "VERSION" });
        defer allocator.free(version_file_path);

        // Read VERSION file using absolute path
        const version_file = std.fs.openFileAbsolute(version_file_path, .{}) catch {
            std.debug.print("Warning: Could not open VERSION file at {s}\n", .{version_file_path});
            break :blk @as(u32, 0);
        };
        defer version_file.close();

        var version_buf: [256]u8 = undefined;
        const bytes_read = version_file.readAll(&version_buf) catch {
            std.debug.print("Warning: Could not read VERSION file\n", .{});
            break :blk @as(u32, 0);
        };

        // VERSION file contains KEY=VALUE pairs, we want BUILD=
        const content = version_buf[0..bytes_read];
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            if (std.mem.startsWith(u8, line, "BUILD=")) {
                const build_str = std.mem.trim(u8, line["BUILD=".len..], &std.ascii.whitespace);
                break :blk std.fmt.parseInt(u32, build_str, 10) catch 0;
            }
        }
        break :blk @as(u32, 0);
    };

    std.debug.print("PDFium version: {d}\n", .{actual_version});

    // Find the library in lib/ subdirectory
    const src_lib_name = getSourceLibName();
    const lib_src_path = try std.fs.path.join(allocator, &.{ tmp_dir, "lib", src_lib_name });
    defer allocator.free(lib_src_path);

    // Build destination filename with version
    const dest_filename = try loader.buildLibraryFilename(allocator, actual_version);
    defer allocator.free(dest_filename);

    const dest_path = try std.fs.path.join(allocator, &.{ output_dir, dest_filename });
    defer allocator.free(dest_path);

    // Copy the library file
    std.fs.copyFileAbsolute(lib_src_path, dest_path, .{}) catch |err| {
        std.debug.print("Failed to copy library from {s} to {s}: {}\n", .{ lib_src_path, dest_path, err });
        return DownloadError.ExtractionFailed;
    };

    // On macOS, fix the library's install name
    if (builtin.os.tag == .macos) {
        const rpath_name = try std.fmt.allocPrint(allocator, "@rpath/{s}", .{dest_filename});
        defer allocator.free(rpath_name);

        var fix_child = std.process.Child.init(
            &.{ "install_name_tool", "-id", rpath_name, dest_path },
            allocator,
        );
        fix_child.spawn() catch {};
        _ = fix_child.wait() catch {};
    }

    std.debug.print("Installed: {s}\n", .{dest_filename});

    return actual_version;
}

// ============================================================================
// Tests
// ============================================================================

test "getPdfiumAssetName returns value for supported platforms" {
    // This test will pass on supported platforms
    const asset = getPdfiumAssetName();
    if (builtin.os.tag == .macos or builtin.os.tag == .linux or builtin.os.tag == .windows) {
        try std.testing.expect(asset != null);
        try std.testing.expect(std.mem.endsWith(u8, asset.?, ".tgz"));
    }
}

test "getSourceLibName returns platform-specific name" {
    const name = getSourceLibName();
    try std.testing.expect(name.len > 0);

    switch (builtin.os.tag) {
        .macos => try std.testing.expectEqualStrings("libpdfium.dylib", name),
        .linux => try std.testing.expectEqualStrings("libpdfium.so", name),
        .windows => try std.testing.expectEqualStrings("pdfium.dll", name),
        else => {},
    }
}

test "hashToHex produces correct output" {
    const input = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff } ++
        [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const expected = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const result = hashToHex(input);
    try std.testing.expectEqualStrings(expected, &result);
}
