//! Golden file generation for PDF operation testing
//! Generates reference files for visual and text output comparison

const std = @import("std");
const pdfium = @import("pdfium/pdfium.zig");
const images = @import("pdfcontent/images.zig");

// ============================================================================
// CONFIGURATION: Golden File Generation Constants
// ============================================================================
pub const TARGET_PIXEL_COUNT: u32 = 50_000; // Total pixels per page (width * height)
pub const PIXEL_TOLERANCE: u8 = 5; // Max allowed delta per channel for tests

// ============================================================================
// Golden File Generation
// ============================================================================

/// Main entry point: generate all golden files for all operations
pub fn createExpectedTestFiles(allocator: std.mem.Allocator) !void {
    try pdfium.init();
    defer pdfium.deinit();

    // Create expected/ directory
    std.fs.cwd().makeDir("test-files/expected") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Find all PDFs in test-files/input/
    var input_dir = try std.fs.cwd().openDir("test-files/input", .{ .iterate = true });
    defer input_dir.close();

    var iter = input_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pdf")) continue;

        const pdf_basename = std.fs.path.stem(entry.name); // e.g., "1Page"
        const input_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{entry.name});
        defer allocator.free(input_path);

        // Create directory: test-files/expected/{pdf_basename}/
        const expected_pdf_dir_path = try std.fmt.allocPrint(
            allocator,
            "test-files/expected/{s}",
            .{pdf_basename},
        );
        defer allocator.free(expected_pdf_dir_path);

        std.fs.cwd().makeDir(expected_pdf_dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Generate golden files for each operation
        try createExpectedTestFilesInfo(allocator, input_path, pdf_basename);
        try createExpectedTestFilesInfoJson(allocator, input_path, pdf_basename);
        try createExpectedTestFilesRenderPageBitmaps(allocator, input_path, pdf_basename);
        try createExpectedTestFilesRotate90(allocator, input_path, pdf_basename);
        try createExpectedTestFilesRotate180(allocator, input_path, pdf_basename);
        try createExpectedTestFilesRotate270(allocator, input_path, pdf_basename);
        try createExpectedTestFilesMirrorHorizontal(allocator, input_path, pdf_basename);
        try createExpectedTestFilesMirrorVertical(allocator, input_path, pdf_basename);
        // Add more visual operations here
    }
}

/// Generate golden file for info command plaintext output
fn createExpectedTestFilesInfo(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    pdf_basename: []const u8,
) !void {
    const output_path = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/info.txt",
        .{pdf_basename},
    );
    defer allocator.free(output_path);

    // Run info command and capture output
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig-out/bin/pdfzig", "info", pdf_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return error.InfoCommandFailed;
    }

    // Write output to file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(result.stdout);

    std.debug.print("Generated: {s}\n", .{output_path});
}

/// Generate golden file for info command JSON output
fn createExpectedTestFilesInfoJson(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    pdf_basename: []const u8,
) !void {
    const output_path = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/info.json",
        .{pdf_basename},
    );
    defer allocator.free(output_path);

    // Run info command with --json option and capture output
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig-out/bin/pdfzig", "info", "--json", pdf_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return error.InfoCommandFailed;
    }

    // Write output to file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(result.stdout);

    std.debug.print("Generated: {s}\n", .{output_path});
}

/// Generate golden files for basic page rendering
fn createExpectedTestFilesRenderPageBitmaps(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    pdf_basename: []const u8,
) !void {
    // Create operation directory
    const operation_dir = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/render-page-bitmaps",
        .{pdf_basename},
    );
    defer allocator.free(operation_dir);

    std.fs.cwd().makeDir(operation_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Open PDF
    var doc = try pdfium.Document.open(allocator, pdf_path);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Render each page
    for (0..page_count) |page_idx| {
        var page = try doc.loadPage(@intCast(page_idx));
        defer page.close();

        // Calculate dimensions preserving aspect ratio
        const dims = calculateTargetDimensions(page.getWidth(), page.getHeight());

        // Create bitmap and render
        var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
        defer bitmap.destroy();

        bitmap.fillWhite();
        page.render(&bitmap, .{});

        // Save to file
        const output_path = try std.fmt.allocPrint(
            allocator,
            "{s}/page-{d}.png",
            .{ operation_dir, page_idx + 1 },
        );
        defer allocator.free(output_path);

        try images.writeBitmap(bitmap, output_path, .{ .format = .png });
        std.debug.print("Generated: {s}\n", .{output_path});
    }
}

/// Generate golden files for 90° rotation
fn createExpectedTestFilesRotate90(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    pdf_basename: []const u8,
) !void {
    const operation_dir = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/rotate-90",
        .{pdf_basename},
    );
    defer allocator.free(operation_dir);

    std.fs.cwd().makeDir(operation_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Open PDF
    var doc = try pdfium.Document.open(allocator, pdf_path);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Rotate and render each page
    for (0..page_count) |page_idx| {
        var page = try doc.loadPage(@intCast(page_idx));
        defer page.close();

        // Rotate 90° clockwise
        _ = page.rotate(90);

        // Calculate dimensions (width and height swap after 90° rotation)
        const dims = calculateTargetDimensions(page.getWidth(), page.getHeight());

        var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
        defer bitmap.destroy();

        bitmap.fillWhite();
        page.render(&bitmap, .{});

        const output_path = try std.fmt.allocPrint(
            allocator,
            "{s}/page-{d}.png",
            .{ operation_dir, page_idx + 1 },
        );
        defer allocator.free(output_path);

        try images.writeBitmap(bitmap, output_path, .{ .format = .png });
        std.debug.print("Generated: {s}\n", .{output_path});
    }
}

/// Generate golden files for horizontal mirror
fn createExpectedTestFilesMirrorHorizontal(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    pdf_basename: []const u8,
) !void {
    const operation_dir = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/mirror-horizontal",
        .{pdf_basename},
    );
    defer allocator.free(operation_dir);

    std.fs.cwd().makeDir(operation_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Open PDF
    var doc = try pdfium.Document.open(allocator, pdf_path);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Mirror and render each page
    for (0..page_count) |page_idx| {
        var page = try doc.loadPage(@intCast(page_idx));
        defer page.close();

        // Apply horizontal mirror transformation to all objects
        const page_width = page.getWidth();
        const obj_count = page.getObjectCount();
        var obj_idx: u32 = 0;
        while (obj_idx < obj_count) : (obj_idx += 1) {
            if (page.getObject(obj_idx)) |obj| {
                // Horizontal mirror: scale X by -1, translate by page width
                obj.transform(-1, 0, 0, 1, page_width, 0);
            }
        }

        // Finalize transformations
        _ = page.generateContent();

        // Calculate dimensions
        const dims = calculateTargetDimensions(page.getWidth(), page.getHeight());

        var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
        defer bitmap.destroy();

        bitmap.fillWhite();
        page.render(&bitmap, .{});

        const output_path = try std.fmt.allocPrint(
            allocator,
            "{s}/page-{d}.png",
            .{ operation_dir, page_idx + 1 },
        );
        defer allocator.free(output_path);

        try images.writeBitmap(bitmap, output_path, .{ .format = .png });
        std.debug.print("Generated: {s}\n", .{output_path});
    }
}

/// Generate golden files for vertical mirror
fn createExpectedTestFilesMirrorVertical(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    pdf_basename: []const u8,
) !void {
    const operation_dir = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/mirror-vertical",
        .{pdf_basename},
    );
    defer allocator.free(operation_dir);

    std.fs.cwd().makeDir(operation_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Open PDF
    var doc = try pdfium.Document.open(allocator, pdf_path);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Mirror and render each page
    for (0..page_count) |page_idx| {
        var page = try doc.loadPage(@intCast(page_idx));
        defer page.close();

        // Apply vertical mirror transformation to all objects
        const page_height = page.getHeight();
        const obj_count = page.getObjectCount();
        var obj_idx: u32 = 0;
        while (obj_idx < obj_count) : (obj_idx += 1) {
            if (page.getObject(obj_idx)) |obj| {
                // Vertical mirror: scale Y by -1, translate by page height
                obj.transform(1, 0, 0, -1, 0, page_height);
            }
        }

        // Finalize transformations
        _ = page.generateContent();

        // Calculate dimensions
        const dims = calculateTargetDimensions(page.getWidth(), page.getHeight());

        var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
        defer bitmap.destroy();

        bitmap.fillWhite();
        page.render(&bitmap, .{});

        const output_path = try std.fmt.allocPrint(
            allocator,
            "{s}/page-{d}.png",
            .{ operation_dir, page_idx + 1 },
        );
        defer allocator.free(output_path);

        try images.writeBitmap(bitmap, output_path, .{ .format = .png });
        std.debug.print("Generated: {s}\n", .{output_path});
    }
}

/// Generate golden files for 180° rotation
fn createExpectedTestFilesRotate180(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    pdf_basename: []const u8,
) !void {
    const operation_dir = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/rotate-180",
        .{pdf_basename},
    );
    defer allocator.free(operation_dir);

    std.fs.cwd().makeDir(operation_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Open PDF
    var doc = try pdfium.Document.open(allocator, pdf_path);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Rotate and render each page
    for (0..page_count) |page_idx| {
        var page = try doc.loadPage(@intCast(page_idx));
        defer page.close();

        // Rotate 180°
        _ = page.rotate(180);

        // Calculate dimensions (no dimension swap for 180° rotation)
        const dims = calculateTargetDimensions(page.getWidth(), page.getHeight());

        var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
        defer bitmap.destroy();

        bitmap.fillWhite();
        page.render(&bitmap, .{});

        const output_path = try std.fmt.allocPrint(
            allocator,
            "{s}/page-{d}.png",
            .{ operation_dir, page_idx + 1 },
        );
        defer allocator.free(output_path);

        try images.writeBitmap(bitmap, output_path, .{ .format = .png });
        std.debug.print("Generated: {s}\n", .{output_path});
    }
}

/// Generate golden files for 270° rotation
fn createExpectedTestFilesRotate270(
    allocator: std.mem.Allocator,
    pdf_path: []const u8,
    pdf_basename: []const u8,
) !void {
    const operation_dir = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/rotate-270",
        .{pdf_basename},
    );
    defer allocator.free(operation_dir);

    std.fs.cwd().makeDir(operation_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Open PDF
    var doc = try pdfium.Document.open(allocator, pdf_path);
    defer doc.close();

    const page_count = doc.getPageCount();

    // Rotate and render each page
    for (0..page_count) |page_idx| {
        var page = try doc.loadPage(@intCast(page_idx));
        defer page.close();

        // Rotate 270° clockwise
        _ = page.rotate(270);

        // Calculate dimensions (width and height swap after 270° rotation)
        const dims = calculateTargetDimensions(page.getWidth(), page.getHeight());

        var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
        defer bitmap.destroy();

        bitmap.fillWhite();
        page.render(&bitmap, .{});

        const output_path = try std.fmt.allocPrint(
            allocator,
            "{s}/page-{d}.png",
            .{ operation_dir, page_idx + 1 },
        );
        defer allocator.free(output_path);

        try images.writeBitmap(bitmap, output_path, .{ .format = .png });
        std.debug.print("Generated: {s}\n", .{output_path});
    }
}

/// Calculate target dimensions for 50k total pixels, preserving aspect ratio
/// Formula: width * height = TARGET_PIXEL_COUNT
///          height / width = aspect_ratio
///          => width = sqrt(TARGET_PIXEL_COUNT / aspect_ratio)
///          => height = width * aspect_ratio
pub fn calculateTargetDimensions(page_width: f64, page_height: f64) struct { width: u32, height: u32 } {
    const aspect_ratio = page_height / page_width;

    // Calculate width from pixel count and aspect ratio
    const target_width_f = @sqrt(@as(f64, @floatFromInt(TARGET_PIXEL_COUNT)) / aspect_ratio);
    const target_width: u32 = @intFromFloat(@ceil(target_width_f));

    // Calculate height from width and aspect ratio
    const target_height: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(target_width)) * aspect_ratio));

    return .{
        .width = target_width,
        .height = target_height,
    };
}
