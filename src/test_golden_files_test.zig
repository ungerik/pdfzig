//! Golden file comparison tests
//! Tests PDF operations by comparing output against reference files

const std = @import("std");
const pdfium = @import("pdfium/pdfium.zig");
const visual_compare = @import("test_visual_compare.zig");
const test_golden = @import("test_golden_files.zig");
const images = @import("pdfcontent/images.zig");

// Import constants from golden file generator (single source of truth)
const TARGET_PIXEL_COUNT = test_golden.TARGET_PIXEL_COUNT;
const PIXEL_TOLERANCE = test_golden.PIXEL_TOLERANCE;

/// Discover all PDF filenames in test-files/input/
fn discoverTestPdfs(allocator: std.mem.Allocator) ![][]const u8 {
    var pdf_list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (pdf_list.items) |item| allocator.free(item);
        pdf_list.deinit();
    }

    var input_dir = std.fs.cwd().openDir("test-files/input", .{ .iterate = true }) catch {
        return pdf_list.toOwnedSlice();
    };
    defer input_dir.close();

    var iter = input_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pdf")) continue;
        try pdf_list.append(try allocator.dupe(u8, entry.name));
    }

    return pdf_list.toOwnedSlice();
}

/// Render a page to a temp PNG, compare against a golden file.
/// operation_setup is called with the page before rendering to apply transformations.
fn compareRenderedPageWithGolden(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page_idx: usize,
    pdf_basename: []const u8,
    pdf_filename: []const u8,
    temp_prefix: []const u8,
    golden_subdir: []const u8,
) !void {
    var page = try doc.loadPage(page_idx);
    defer page.close();

    // Calculate dimensions (same as golden file generation)
    const dims = test_golden.calculateTargetDimensions(page.getWidth(), page.getHeight());

    var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
    defer bitmap.destroy();

    bitmap.fillWhite();
    page.render(&bitmap, .{});

    const temp_path = try std.fmt.allocPrint(
        allocator,
        "test-cache/temp-{s}-{s}-page-{d}.png",
        .{ pdf_basename, temp_prefix, page_idx + 1 },
    );
    defer allocator.free(temp_path);

    std.fs.cwd().makeDir("test-cache") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    try images.writeBitmap(allocator, bitmap, temp_path, .{ .format = .png });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    const golden_path = try std.fmt.allocPrint(
        allocator,
        "test-files/expected/{s}/{s}/page-{d}.png",
        .{ pdf_basename, golden_subdir, page_idx + 1 },
    );
    defer allocator.free(golden_path);

    const diff = try visual_compare.comparePngFiles(allocator, temp_path, golden_path);

    if (!diff.withinTolerance(PIXEL_TOLERANCE)) {
        std.debug.print(
            "{s} page {d} of {s} differs from golden file: {any}\n",
            .{ golden_subdir, page_idx + 1, pdf_filename, diff },
        );
        return error.TestFailed;
    }
}

test "render page bitmaps matches golden files" {
    if (!pdfium.isAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    try pdfium.init();
    defer pdfium.deinit();

    const test_pdfs = try discoverTestPdfs(allocator);
    defer {
        for (test_pdfs) |name| allocator.free(name);
        allocator.free(test_pdfs);
    }

    for (test_pdfs) |pdf_filename| {
        const pdf_basename = std.fs.path.stem(pdf_filename);

        const pdf_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{pdf_filename});
        defer allocator.free(pdf_path);

        var doc = try pdfium.Document.open(allocator, pdf_path);
        defer doc.close();

        const page_count = doc.getPageCount();

        for (0..page_count) |page_idx| {
            try compareRenderedPageWithGolden(
                allocator,
                &doc,
                page_idx,
                pdf_basename,
                pdf_filename,
                "render",
                "render-page-bitmaps",
            );
        }
    }
}

test "rotate 90 matches golden files" {
    if (!pdfium.isAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    try pdfium.init();
    defer pdfium.deinit();

    const test_pdfs = try discoverTestPdfs(allocator);
    defer {
        for (test_pdfs) |name| allocator.free(name);
        allocator.free(test_pdfs);
    }

    for (test_pdfs) |pdf_filename| {
        const pdf_basename = std.fs.path.stem(pdf_filename);

        const pdf_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{pdf_filename});
        defer allocator.free(pdf_path);

        var doc = try pdfium.Document.open(allocator, pdf_path);
        defer doc.close();

        const page_count = doc.getPageCount();

        for (0..page_count) |page_idx| {
            var page = try doc.loadPage(page_idx);
            defer page.close();

            _ = page.rotate(90);

            const dims = test_golden.calculateTargetDimensions(page.getWidth(), page.getHeight());

            var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
            defer bitmap.destroy();

            bitmap.fillWhite();
            page.render(&bitmap, .{});

            const temp_path = try std.fmt.allocPrint(
                allocator,
                "test-cache/temp-{s}-rotate90-page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(temp_path);

            std.fs.cwd().makeDir("test-cache") catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            try images.writeBitmap(allocator, bitmap, temp_path, .{ .format = .png });
            defer std.fs.cwd().deleteFile(temp_path) catch {};

            const golden_path = try std.fmt.allocPrint(
                allocator,
                "test-files/expected/{s}/rotate-90/page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(golden_path);

            const diff = try visual_compare.comparePngFiles(allocator, temp_path, golden_path);

            if (!diff.withinTolerance(PIXEL_TOLERANCE)) {
                std.debug.print(
                    "Rotated page {d} of {s} differs: {any}\n",
                    .{ page_idx + 1, pdf_filename, diff },
                );
                return error.TestFailed;
            }
        }
    }
}

test "rotate 180 matches golden files" {
    if (!pdfium.isAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    try pdfium.init();
    defer pdfium.deinit();

    const test_pdfs = try discoverTestPdfs(allocator);
    defer {
        for (test_pdfs) |name| allocator.free(name);
        allocator.free(test_pdfs);
    }

    for (test_pdfs) |pdf_filename| {
        const pdf_basename = std.fs.path.stem(pdf_filename);

        const pdf_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{pdf_filename});
        defer allocator.free(pdf_path);

        var doc = try pdfium.Document.open(allocator, pdf_path);
        defer doc.close();

        const page_count = doc.getPageCount();

        for (0..page_count) |page_idx| {
            var page = try doc.loadPage(page_idx);
            defer page.close();

            _ = page.rotate(180);

            const dims = test_golden.calculateTargetDimensions(page.getWidth(), page.getHeight());

            var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
            defer bitmap.destroy();

            bitmap.fillWhite();
            page.render(&bitmap, .{});

            const temp_path = try std.fmt.allocPrint(
                allocator,
                "test-cache/temp-{s}-rotate180-page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(temp_path);

            std.fs.cwd().makeDir("test-cache") catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            try images.writeBitmap(allocator, bitmap, temp_path, .{ .format = .png });
            defer std.fs.cwd().deleteFile(temp_path) catch {};

            const golden_path = try std.fmt.allocPrint(
                allocator,
                "test-files/expected/{s}/rotate-180/page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(golden_path);

            const diff = try visual_compare.comparePngFiles(allocator, temp_path, golden_path);

            if (!diff.withinTolerance(PIXEL_TOLERANCE)) {
                std.debug.print(
                    "Rotated 180° page {d} of {s} differs: {any}\n",
                    .{ page_idx + 1, pdf_filename, diff },
                );
                return error.TestFailed;
            }
        }
    }
}

test "rotate 270 matches golden files" {
    if (!pdfium.isAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    try pdfium.init();
    defer pdfium.deinit();

    const test_pdfs = try discoverTestPdfs(allocator);
    defer {
        for (test_pdfs) |name| allocator.free(name);
        allocator.free(test_pdfs);
    }

    for (test_pdfs) |pdf_filename| {
        const pdf_basename = std.fs.path.stem(pdf_filename);

        const pdf_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{pdf_filename});
        defer allocator.free(pdf_path);

        var doc = try pdfium.Document.open(allocator, pdf_path);
        defer doc.close();

        const page_count = doc.getPageCount();

        for (0..page_count) |page_idx| {
            var page = try doc.loadPage(page_idx);
            defer page.close();

            _ = page.rotate(270);

            const dims = test_golden.calculateTargetDimensions(page.getWidth(), page.getHeight());

            var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
            defer bitmap.destroy();

            bitmap.fillWhite();
            page.render(&bitmap, .{});

            const temp_path = try std.fmt.allocPrint(
                allocator,
                "test-cache/temp-{s}-rotate270-page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(temp_path);

            std.fs.cwd().makeDir("test-cache") catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            try images.writeBitmap(allocator, bitmap, temp_path, .{ .format = .png });
            defer std.fs.cwd().deleteFile(temp_path) catch {};

            const golden_path = try std.fmt.allocPrint(
                allocator,
                "test-files/expected/{s}/rotate-270/page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(golden_path);

            const diff = try visual_compare.comparePngFiles(allocator, temp_path, golden_path);

            if (!diff.withinTolerance(PIXEL_TOLERANCE)) {
                std.debug.print(
                    "Rotated 270° page {d} of {s} differs: {any}\n",
                    .{ page_idx + 1, pdf_filename, diff },
                );
                return error.TestFailed;
            }
        }
    }
}

test "mirror horizontal matches golden files" {
    if (!pdfium.isAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    try pdfium.init();
    defer pdfium.deinit();

    const test_pdfs = try discoverTestPdfs(allocator);
    defer {
        for (test_pdfs) |name| allocator.free(name);
        allocator.free(test_pdfs);
    }

    for (test_pdfs) |pdf_filename| {
        const pdf_basename = std.fs.path.stem(pdf_filename);

        const pdf_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{pdf_filename});
        defer allocator.free(pdf_path);

        var doc = try pdfium.Document.open(allocator, pdf_path);
        defer doc.close();

        const page_count = doc.getPageCount();

        for (0..page_count) |page_idx| {
            var page = try doc.loadPage(page_idx);
            defer page.close();

            // Apply horizontal mirror transformation
            const page_width = page.getWidth();
            const obj_count = page.getObjectCount();
            var obj_idx: u32 = 0;
            while (obj_idx < obj_count) : (obj_idx += 1) {
                if (page.getObject(obj_idx)) |obj| {
                    obj.transform(-1, 0, 0, 1, page_width, 0);
                }
            }
            _ = page.generateContent();

            const dims = test_golden.calculateTargetDimensions(page.getWidth(), page.getHeight());

            var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
            defer bitmap.destroy();

            bitmap.fillWhite();
            page.render(&bitmap, .{});

            const temp_path = try std.fmt.allocPrint(
                allocator,
                "test-cache/temp-{s}-mirror-horizontal-page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(temp_path);

            std.fs.cwd().makeDir("test-cache") catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            try images.writeBitmap(allocator, bitmap, temp_path, .{ .format = .png });
            defer std.fs.cwd().deleteFile(temp_path) catch {};

            const golden_path = try std.fmt.allocPrint(
                allocator,
                "test-files/expected/{s}/mirror-horizontal/page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(golden_path);

            const diff = try visual_compare.comparePngFiles(allocator, temp_path, golden_path);

            if (!diff.withinTolerance(PIXEL_TOLERANCE)) {
                std.debug.print(
                    "Mirrored page {d} of {s} differs: {any}\n",
                    .{ page_idx + 1, pdf_filename, diff },
                );
                return error.TestFailed;
            }
        }
    }
}

test "mirror vertical matches golden files" {
    if (!pdfium.isAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    try pdfium.init();
    defer pdfium.deinit();

    const test_pdfs = try discoverTestPdfs(allocator);
    defer {
        for (test_pdfs) |name| allocator.free(name);
        allocator.free(test_pdfs);
    }

    for (test_pdfs) |pdf_filename| {
        const pdf_basename = std.fs.path.stem(pdf_filename);

        const pdf_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{pdf_filename});
        defer allocator.free(pdf_path);

        var doc = try pdfium.Document.open(allocator, pdf_path);
        defer doc.close();

        const page_count = doc.getPageCount();

        for (0..page_count) |page_idx| {
            var page = try doc.loadPage(page_idx);
            defer page.close();

            // Apply vertical mirror transformation
            const page_height = page.getHeight();
            const obj_count = page.getObjectCount();
            var obj_idx: u32 = 0;
            while (obj_idx < obj_count) : (obj_idx += 1) {
                if (page.getObject(obj_idx)) |obj| {
                    obj.transform(1, 0, 0, -1, 0, page_height);
                }
            }
            _ = page.generateContent();

            const dims = test_golden.calculateTargetDimensions(page.getWidth(), page.getHeight());

            var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
            defer bitmap.destroy();

            bitmap.fillWhite();
            page.render(&bitmap, .{});

            const temp_path = try std.fmt.allocPrint(
                allocator,
                "test-cache/temp-{s}-mirror-vertical-page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(temp_path);

            std.fs.cwd().makeDir("test-cache") catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            try images.writeBitmap(allocator, bitmap, temp_path, .{ .format = .png });
            defer std.fs.cwd().deleteFile(temp_path) catch {};

            const golden_path = try std.fmt.allocPrint(
                allocator,
                "test-files/expected/{s}/mirror-vertical/page-{d}.png",
                .{ pdf_basename, page_idx + 1 },
            );
            defer allocator.free(golden_path);

            const diff = try visual_compare.comparePngFiles(allocator, temp_path, golden_path);

            if (!diff.withinTolerance(PIXEL_TOLERANCE)) {
                std.debug.print(
                    "Vertically mirrored page {d} of {s} differs: {any}\n",
                    .{ page_idx + 1, pdf_filename, diff },
                );
                return error.TestFailed;
            }
        }
    }
}

test "info plaintext matches golden files" {
    if (!pdfium.isAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const test_pdfs = try discoverTestPdfs(allocator);
    defer {
        for (test_pdfs) |name| allocator.free(name);
        allocator.free(test_pdfs);
    }

    for (test_pdfs) |pdf_filename| {
        const pdf_basename = std.fs.path.stem(pdf_filename);

        const pdf_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{pdf_filename});
        defer allocator.free(pdf_path);

        // Run info command and capture output
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig-out/bin/pdfzig", "info", pdf_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try std.testing.expectEqual(@as(u8, 0), result.term.Exited);

        // Load golden file
        const golden_path = try std.fmt.allocPrint(
            allocator,
            "test-files/expected/{s}/info.txt",
            .{pdf_basename},
        );
        defer allocator.free(golden_path);

        const golden_file = try std.fs.cwd().openFile(golden_path, .{});
        defer golden_file.close();

        const golden_content = try golden_file.readToEndAlloc(allocator, 100 * 1024);
        defer allocator.free(golden_content);

        // Compare outputs
        try std.testing.expectEqualStrings(golden_content, result.stdout);
    }
}

test "info JSON matches golden files" {
    if (!pdfium.isAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const test_pdfs = try discoverTestPdfs(allocator);
    defer {
        for (test_pdfs) |name| allocator.free(name);
        allocator.free(test_pdfs);
    }

    for (test_pdfs) |pdf_filename| {
        const pdf_basename = std.fs.path.stem(pdf_filename);

        const pdf_path = try std.fmt.allocPrint(allocator, "test-files/input/{s}", .{pdf_filename});
        defer allocator.free(pdf_path);

        // Run info command with --json option
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig-out/bin/pdfzig", "info", "--json", pdf_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try std.testing.expectEqual(@as(u8, 0), result.term.Exited);

        // Load golden file
        const golden_path = try std.fmt.allocPrint(
            allocator,
            "test-files/expected/{s}/info.json",
            .{pdf_basename},
        );
        defer allocator.free(golden_path);

        const golden_file = try std.fs.cwd().openFile(golden_path, .{});
        defer golden_file.close();

        const golden_content = try golden_file.readToEndAlloc(allocator, 100 * 1024);
        defer allocator.free(golden_content);

        // Compare outputs
        try std.testing.expectEqualStrings(golden_content, result.stdout);
    }
}
