//! PDFium Download and Extraction
//! Downloads PDFium binaries from GitHub releases and extracts the library file

const std = @import("std");
const builtin = @import("builtin");
const loader = @import("loader.zig");
const Allocator = std.mem.Allocator;

/// Progress callback function type
/// When clear is true, the callback should clear the progress bar and print a final message
pub const ProgressCallback = *const fn (downloaded: u64, total: ?u64, clear: bool) void;

/// Standard progress bar display callback
pub fn displayProgress(downloaded: u64, total: ?u64, clear: bool) void {
    const stdout_file = std.fs.File.stdout();
    var buf: [128]u8 = undefined;

    const len = if (clear) blk: {
        // Clear progress bar and show success message (downloaded contains the version number)
        break :blk std.fmt.bufPrint(&buf, "\r                                                                                \rDownloaded PDFium build {d}\n\n", .{downloaded}) catch return;
    } else if (total) |t| blk: {
        const percent = if (t > 0) @as(u32, @intCast((downloaded * 100) / t)) else 0;
        const bar_width: u32 = 40;
        const filled = (percent * bar_width) / 100;

        var bar: [40]u8 = undefined;
        for (0..bar_width) |i| {
            bar[i] = if (i < filled) '=' else if (i == filled) '>' else ' ';
        }

        const downloaded_mb = @as(f64, @floatFromInt(downloaded)) / (1024 * 1024);
        const total_mb = @as(f64, @floatFromInt(t)) / (1024 * 1024);

        break :blk std.fmt.bufPrint(&buf, "\r[{s}] {d:3}% {d:.1}/{d:.1} MB", .{ bar[0..bar_width], percent, downloaded_mb, total_mb }) catch return;
    } else blk: {
        const downloaded_mb = @as(f64, @floatFromInt(downloaded)) / (1024 * 1024);
        break :blk std.fmt.bufPrint(&buf, "\rDownloaded: {d:.1} MB", .{downloaded_mb}) catch return;
    };

    _ = stdout_file.write(len) catch {};
    stdout_file.sync() catch {};
}

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
    return getPdfiumAssetNameForTarget(builtin.cpu.arch, builtin.os.tag);
}

/// Get the PDFium asset name for a specific target platform
pub fn getPdfiumAssetNameForTarget(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) ?[]const u8 {
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
    return getSourceLibNameForTarget(builtin.os.tag);
}

/// Get the source library name for a specific target OS
pub fn getSourceLibNameForTarget(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos => "libpdfium.dylib",
        .linux => "libpdfium.so",
        .windows => "pdfium.dll",
        else => "libpdfium.so",
    };
}

/// Get the source library directory inside the archive for a specific target OS
/// Windows uses bin/ while others use lib/
fn getSourceLibDirForTarget(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => "bin",
        else => "lib",
    };
}

/// Get the library file extension for a specific target OS
pub fn getLibraryExtensionForTarget(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos => ".dylib",
        .linux => ".so",
        .windows => ".dll",
        else => ".so",
    };
}

/// Build the library filename for a specific target
/// Always uses the format: pdfium_v{BUILD}.{ext}
pub fn buildLibraryFilenameForTarget(allocator: Allocator, version: u32, os: std.Target.Os.Tag) ![]u8 {
    const ext = getLibraryExtensionForTarget(os);
    return std.fmt.allocPrint(allocator, "pdfium_v{d}{s}", .{ version, ext });
}

/// Download PDFium for a specific target platform
pub fn downloadPdfiumForTarget(
    allocator: Allocator,
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    output_dir: []const u8,
) !u32 {
    const asset_name = getPdfiumAssetNameForTarget(arch, os) orelse return DownloadError.UnsupportedPlatform;

    // Always download latest
    const url = try std.fmt.allocPrint(allocator, "https://github.com/bblanchon/pdfium-binaries/releases/latest/download/{s}", .{asset_name});
    defer allocator.free(url);

    std.debug.print("Downloading PDFium for {s}-{s} from: {s}\n", .{ @tagName(arch), @tagName(os), url });

    return downloadAndExtractForTarget(allocator, url, null, output_dir, arch, os, null);
}

/// Download and extract PDFium for a specific target
fn downloadAndExtractForTarget(
    allocator: Allocator,
    url: []const u8,
    version: ?u32,
    output_dir: []const u8,
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    progress_cb: ?ProgressCallback,
) !u32 {
    const asset_name = getPdfiumAssetNameForTarget(arch, os) orelse return DownloadError.UnsupportedPlatform;

    // Try to fetch the expected hash from GitHub API
    const expected_hash = fetchExpectedHash(allocator, asset_name, version);
    if (expected_hash) |_| {}

    // Download the archive with progress
    const archive_data = try httpGetWithProgress(allocator, url, &.{}, progress_cb);
    defer allocator.free(archive_data);

    if (archive_data.len < 1000) {
        return DownloadError.DownloadFailed;
    }

    // Verify hash if we have an expected hash
    if (expected_hash) |exp_hash| {
        const actual_hash = calculateHash(archive_data);
        const actual_hex = hashToHex(actual_hash);

        if (!std.mem.eql(u8, &actual_hex, &exp_hash)) {
            std.debug.print("Expected: {s}\n", .{exp_hash});
            std.debug.print("Actual:   {s}\n", .{actual_hex});
            return DownloadError.HashMismatch;
        }
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

    // Find the library in the appropriate subdirectory (lib/ for macOS/Linux, bin/ for Windows)
    const src_lib_name = getSourceLibNameForTarget(os);
    const src_lib_dir = getSourceLibDirForTarget(os);
    const lib_src_path = try std.fs.path.join(allocator, &.{ tmp_dir, src_lib_dir, src_lib_name });
    defer allocator.free(lib_src_path);

    // Build destination filename with version
    const dest_filename = try buildLibraryFilenameForTarget(allocator, actual_version, os);
    defer allocator.free(dest_filename);

    const dest_path = try std.fs.path.join(allocator, &.{ output_dir, dest_filename });
    defer allocator.free(dest_path);

    // Copy the library file
    std.fs.copyFileAbsolute(lib_src_path, dest_path, .{}) catch |err| {
        std.debug.print("Failed to copy library from {s} to {s}: {}\n", .{ lib_src_path, dest_path, err });
        return DownloadError.ExtractionFailed;
    };

    return actual_version;
}

/// Download PDFium to the specified output directory
/// Returns the Chromium build version number
/// If version is null, downloads the latest release
pub fn downloadPdfium(allocator: Allocator, version: ?u32, output_dir: []const u8) !u32 {
    return downloadPdfiumWithProgress(allocator, version, output_dir, null);
}

/// Download PDFium with progress callback
pub fn downloadPdfiumWithProgress(allocator: Allocator, version: ?u32, output_dir: []const u8, progress_cb: ?ProgressCallback) !u32 {
    const asset_name = getPdfiumAssetName() orelse return DownloadError.UnsupportedPlatform;

    // Build the download URL
    const url = if (version) |v|
        try std.fmt.allocPrint(allocator, "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/{d}/{s}", .{ v, asset_name })
    else
        try std.fmt.allocPrint(allocator, "https://github.com/bblanchon/pdfium-binaries/releases/latest/download/{s}", .{asset_name});
    defer allocator.free(url);

    const actual_version = try downloadAndExtract(allocator, url, version, output_dir, progress_cb);

    // Clear the progress bar
    if (progress_cb) |cb| {
        cb(actual_version, null, true);
    }

    return actual_version;
}

/// Perform an HTTP GET request and return the response body
fn httpGet(allocator: Allocator, url: []const u8, extra_headers: []const std.http.Header) ![]u8 {
    return httpGetWithProgress(allocator, url, extra_headers, null);
}

/// Perform an HTTP GET request with progress reporting
fn httpGetWithProgress(allocator: Allocator, url: []const u8, extra_headers: []const std.http.Header, progress_cb: ?ProgressCallback) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return DownloadError.HttpError;

    var req = client.request(.GET, uri, .{
        .extra_headers = extra_headers,
    }) catch return DownloadError.HttpError;
    defer req.deinit();

    req.sendBodiless() catch return DownloadError.HttpError;

    var header_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&header_buffer) catch return DownloadError.HttpError;

    if (response.head.status != .ok) {
        return DownloadError.HttpError;
    }

    const content_length = response.head.content_length;

    // Read response body in chunks with progress reporting
    var body_data = std.array_list.Managed(u8).init(allocator);
    errdefer body_data.deinit();

    // Pre-allocate if we know the size
    if (content_length) |len| {
        body_data.ensureTotalCapacity(@intCast(len)) catch {};
    }

    var transfer_buffer: [16384]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var downloaded: u64 = 0;
    var read_buf: [16384]u8 = undefined;

    // Determine how many bytes to read
    const total_to_read = content_length orelse std.math.maxInt(u64);

    while (downloaded < total_to_read) {
        const remaining = total_to_read - downloaded;
        const read_len = @min(read_buf.len, remaining);
        const bytes_read = reader.readSliceShort(read_buf[0..@intCast(read_len)]) catch return DownloadError.HttpError;
        if (bytes_read == 0) break;

        body_data.appendSlice(read_buf[0..bytes_read]) catch return DownloadError.OutOfMemory;
        downloaded += bytes_read;

        if (progress_cb) |cb| {
            cb(downloaded, content_length, false);
        }
    }

    return body_data.toOwnedSlice() catch return DownloadError.OutOfMemory;
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
fn downloadAndExtract(allocator: Allocator, url: []const u8, version: ?u32, output_dir: []const u8, progress_cb: ?ProgressCallback) !u32 {
    const asset_name = getPdfiumAssetName() orelse return DownloadError.UnsupportedPlatform;

    // Try to fetch the expected hash from GitHub API
    const expected_hash = fetchExpectedHash(allocator, asset_name, version);
    if (expected_hash) |_| {}

    // Download the archive with progress
    const archive_data = try httpGetWithProgress(allocator, url, &.{}, progress_cb);
    defer allocator.free(archive_data);

    if (archive_data.len < 1000) {
        return DownloadError.DownloadFailed;
    }

    // Verify hash if we have an expected hash
    if (expected_hash) |exp_hash| {
        const actual_hash = calculateHash(archive_data);
        const actual_hex = hashToHex(actual_hash);

        if (!std.mem.eql(u8, &actual_hex, &exp_hash)) {
            std.debug.print("Expected: {s}\n", .{exp_hash});
            std.debug.print("Actual:   {s}\n", .{actual_hex});
            return DownloadError.HashMismatch;
        }
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

test "getPdfiumAssetNameForTarget macOS" {
    try std.testing.expectEqualStrings("pdfium-mac-arm64.tgz", getPdfiumAssetNameForTarget(.aarch64, .macos).?);
    try std.testing.expectEqualStrings("pdfium-mac-x64.tgz", getPdfiumAssetNameForTarget(.x86_64, .macos).?);
    try std.testing.expect(getPdfiumAssetNameForTarget(.arm, .macos) == null);
}

test "getPdfiumAssetNameForTarget Linux" {
    try std.testing.expectEqualStrings("pdfium-linux-arm64.tgz", getPdfiumAssetNameForTarget(.aarch64, .linux).?);
    try std.testing.expectEqualStrings("pdfium-linux-x64.tgz", getPdfiumAssetNameForTarget(.x86_64, .linux).?);
    try std.testing.expectEqualStrings("pdfium-linux-arm.tgz", getPdfiumAssetNameForTarget(.arm, .linux).?);
}

test "getPdfiumAssetNameForTarget Windows" {
    try std.testing.expectEqualStrings("pdfium-win-arm64.tgz", getPdfiumAssetNameForTarget(.aarch64, .windows).?);
    try std.testing.expectEqualStrings("pdfium-win-x64.tgz", getPdfiumAssetNameForTarget(.x86_64, .windows).?);
    try std.testing.expectEqualStrings("pdfium-win-x86.tgz", getPdfiumAssetNameForTarget(.x86, .windows).?);
}

test "getPdfiumAssetNameForTarget unsupported" {
    try std.testing.expect(getPdfiumAssetNameForTarget(.x86_64, .freebsd) == null);
    try std.testing.expect(getPdfiumAssetNameForTarget(.mips, .linux) == null);
}

test "getSourceLibNameForTarget" {
    try std.testing.expectEqualStrings("libpdfium.dylib", getSourceLibNameForTarget(.macos));
    try std.testing.expectEqualStrings("libpdfium.so", getSourceLibNameForTarget(.linux));
    try std.testing.expectEqualStrings("pdfium.dll", getSourceLibNameForTarget(.windows));
    try std.testing.expectEqualStrings("libpdfium.so", getSourceLibNameForTarget(.freebsd));
}

test "getLibraryExtensionForTarget" {
    try std.testing.expectEqualStrings(".dylib", getLibraryExtensionForTarget(.macos));
    try std.testing.expectEqualStrings(".so", getLibraryExtensionForTarget(.linux));
    try std.testing.expectEqualStrings(".dll", getLibraryExtensionForTarget(.windows));
    try std.testing.expectEqualStrings(".so", getLibraryExtensionForTarget(.freebsd));
}

test "buildLibraryFilenameForTarget" {
    const allocator = std.testing.allocator;

    {
        const filename = try buildLibraryFilenameForTarget(allocator, 7606, .macos);
        defer allocator.free(filename);
        try std.testing.expectEqualStrings("pdfium_v7606.dylib", filename);
    }

    {
        const filename = try buildLibraryFilenameForTarget(allocator, 7606, .linux);
        defer allocator.free(filename);
        try std.testing.expectEqualStrings("pdfium_v7606.so", filename);
    }

    {
        const filename = try buildLibraryFilenameForTarget(allocator, 7606, .windows);
        defer allocator.free(filename);
        try std.testing.expectEqualStrings("pdfium_v7606.dll", filename);
    }
}

test "calculateHash" {
    // Test with empty input
    const empty_hash = calculateHash("");
    try std.testing.expect(empty_hash[0] != 0 or empty_hash[1] != 0); // Should produce a hash

    // Test with known input (SHA256 of "hello")
    const hello_hash = calculateHash("hello");
    const hello_hex = hashToHex(hello_hash);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", &hello_hex);
}
