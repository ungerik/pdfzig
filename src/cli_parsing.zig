//! CLI argument parsing and types for pdfzig

const std = @import("std");
const glob = @import("glob");
const images = @import("pdfcontent/images.zig");

/// Available commands
pub const Command = enum {
    render,
    extract_text,
    extract_images,
    extract_attachments,
    visual_diff,
    info,
    rotate,
    mirror,
    delete,
    add,
    create,
    attach,
    detach,
    download_pdfium,
    help,
    version_cmd,
};

/// Special constant for blank page in create command
pub const BLANK_PAGE: []const u8 = ":blank";

/// Simple slice-based argument iterator
pub const SliceArgIterator = struct {
    args: []const []const u8,
    index: usize,

    pub fn init(args: []const []const u8) SliceArgIterator {
        return .{ .args = args, .index = 0 };
    }

    pub fn next(self: *SliceArgIterator) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }

    pub fn skip(self: *SliceArgIterator) bool {
        if (self.index >= self.args.len) return false;
        self.index += 1;
        return true;
    }
};

// ============================================================================
// Output Specification Parsing
// ============================================================================

pub const OutputSpec = struct {
    dpi: f64,
    format: images.Format,
    quality: u8,
    template: []const u8,
};

pub fn parseOutputSpec(spec_str: []const u8) !OutputSpec {
    var it = std.mem.splitScalar(u8, spec_str, ':');

    const dpi_str = it.next() orelse return error.InvalidSpec;
    const format_str = it.next() orelse return error.InvalidSpec;
    const quality_str = it.next() orelse return error.InvalidSpec;
    const template = it.next() orelse return error.InvalidSpec;

    const dpi = std.fmt.parseFloat(f64, dpi_str) catch return error.InvalidSpec;
    const format = images.Format.fromString(format_str) orelse return error.InvalidSpec;
    const quality = std.fmt.parseInt(u8, quality_str, 10) catch return error.InvalidSpec;

    return .{
        .dpi = dpi,
        .format = format,
        .quality = quality,
        .template = template,
    };
}

/// Parse a resolution string with optional "dpi" suffix.
/// Returns null if parsing fails.
pub fn parseResolution(str: []const u8) ?f64 {
    if (str.len == 0) return null;
    const num_str = if (std.mem.endsWith(u8, str, "dpi"))
        str[0 .. str.len - 3]
    else
        str;
    if (num_str.len == 0) return null;
    return std.fmt.parseFloat(f64, num_str) catch null;
}

/// Simple glob pattern matching supporting * and ? wildcards (case-insensitive)
pub fn matchGlobPatternCaseInsensitive(pattern: []const u8, name: []const u8) bool {
    // Convert both to lowercase for case-insensitive matching
    var pattern_lower: [256]u8 = undefined;
    var name_lower: [256]u8 = undefined;

    if (pattern.len > pattern_lower.len or name.len > name_lower.len) {
        return false;
    }

    for (pattern, 0..) |c, i| {
        pattern_lower[i] = std.ascii.toLower(c);
    }
    for (name, 0..) |c, i| {
        name_lower[i] = std.ascii.toLower(c);
    }

    return glob.match(pattern_lower[0..pattern.len], name_lower[0..name.len]);
}

// ============================================================================
// Page Range Parsing
// ============================================================================

pub const PageRange = struct {
    start: u32,
    end: u32, // inclusive

    pub fn contains(self: PageRange, page: u32) bool {
        return page >= self.start and page <= self.end;
    }
};

/// Parse a page range string like "1-5,8,10-12" into a list of PageRanges
pub fn parsePageRanges(allocator: std.mem.Allocator, range_str: []const u8, max_page: u32) ![]PageRange {
    var ranges: std.ArrayListUnmanaged(PageRange) = .empty;
    errdefer ranges.deinit(allocator);

    var it = std.mem.splitSequence(u8, range_str, ",");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, "-")) |dash_pos| {
            // Range like "1-5"
            const start_str = std.mem.trim(u8, trimmed[0..dash_pos], " ");
            const end_str = std.mem.trim(u8, trimmed[dash_pos + 1 ..], " ");

            const start = std.fmt.parseInt(u32, start_str, 10) catch return error.InvalidPageRange;
            const end = std.fmt.parseInt(u32, end_str, 10) catch return error.InvalidPageRange;

            if (start == 0 or end == 0 or start > end or end > max_page) {
                return error.InvalidPageRange;
            }

            try ranges.append(allocator, .{ .start = start, .end = end });
        } else {
            // Single page like "8"
            const page = std.fmt.parseInt(u32, trimmed, 10) catch return error.InvalidPageRange;
            if (page == 0 or page > max_page) {
                return error.InvalidPageRange;
            }
            try ranges.append(allocator, .{ .start = page, .end = page });
        }
    }

    return ranges.toOwnedSlice(allocator);
}

/// Check if a page number (1-based) is in any of the ranges
pub fn isPageInRanges(page: u32, ranges: []const PageRange) bool {
    for (ranges) |range| {
        if (range.contains(page)) return true;
    }
    return false;
}

// ============================================================================
// Path Utilities
// ============================================================================

/// Extract basename (filename without extension) from a path
pub fn getBasename(path: []const u8) []const u8 {
    // Find the last path separator
    const filename = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |pos|
        path[pos + 1 ..]
    else
        path;

    // Remove extension
    return if (std.mem.lastIndexOfScalar(u8, filename, '.')) |pos|
        filename[0..pos]
    else
        filename;
}

// ============================================================================
// Page Size Parsing
// ============================================================================

pub const PageSize = struct {
    width: f64,
    height: f64,

    /// Unit conversion factors to PDF points (1 inch = 72 points)
    const pt_per_mm: f64 = 72.0 / 25.4;
    const pt_per_cm: f64 = 72.0 / 2.54;
    const pt_per_inch: f64 = 72.0;

    /// Standard paper sizes (width x height in points, portrait orientation)
    pub const StandardSize = enum {
        // ISO A series
        a0,
        a1,
        a2,
        a3,
        a4,
        a5,
        a6,
        a7,
        a8,
        // ISO B series
        b0,
        b1,
        b2,
        b3,
        b4,
        b5,
        b6,
        // ISO C series (envelopes)
        c4,
        c5,
        c6,
        // US sizes
        letter,
        legal,
        tabloid,
        ledger,
        executive,
        // Other common sizes
        folio,
        quarto,
        statement,

        pub fn getSize(self: StandardSize) PageSize {
            return switch (self) {
                // ISO A series (mm converted to points)
                .a0 => .{ .width = 841 * pt_per_mm, .height = 1189 * pt_per_mm },
                .a1 => .{ .width = 594 * pt_per_mm, .height = 841 * pt_per_mm },
                .a2 => .{ .width = 420 * pt_per_mm, .height = 594 * pt_per_mm },
                .a3 => .{ .width = 297 * pt_per_mm, .height = 420 * pt_per_mm },
                .a4 => .{ .width = 210 * pt_per_mm, .height = 297 * pt_per_mm },
                .a5 => .{ .width = 148 * pt_per_mm, .height = 210 * pt_per_mm },
                .a6 => .{ .width = 105 * pt_per_mm, .height = 148 * pt_per_mm },
                .a7 => .{ .width = 74 * pt_per_mm, .height = 105 * pt_per_mm },
                .a8 => .{ .width = 52 * pt_per_mm, .height = 74 * pt_per_mm },
                // ISO B series
                .b0 => .{ .width = 1000 * pt_per_mm, .height = 1414 * pt_per_mm },
                .b1 => .{ .width = 707 * pt_per_mm, .height = 1000 * pt_per_mm },
                .b2 => .{ .width = 500 * pt_per_mm, .height = 707 * pt_per_mm },
                .b3 => .{ .width = 353 * pt_per_mm, .height = 500 * pt_per_mm },
                .b4 => .{ .width = 250 * pt_per_mm, .height = 353 * pt_per_mm },
                .b5 => .{ .width = 176 * pt_per_mm, .height = 250 * pt_per_mm },
                .b6 => .{ .width = 125 * pt_per_mm, .height = 176 * pt_per_mm },
                // ISO C series (envelopes)
                .c4 => .{ .width = 229 * pt_per_mm, .height = 324 * pt_per_mm },
                .c5 => .{ .width = 162 * pt_per_mm, .height = 229 * pt_per_mm },
                .c6 => .{ .width = 114 * pt_per_mm, .height = 162 * pt_per_mm },
                // US sizes (inches converted to points)
                .letter => .{ .width = 8.5 * pt_per_inch, .height = 11 * pt_per_inch },
                .legal => .{ .width = 8.5 * pt_per_inch, .height = 14 * pt_per_inch },
                .tabloid => .{ .width = 11 * pt_per_inch, .height = 17 * pt_per_inch },
                .ledger => .{ .width = 17 * pt_per_inch, .height = 11 * pt_per_inch },
                .executive => .{ .width = 7.25 * pt_per_inch, .height = 10.5 * pt_per_inch },
                // Other common sizes
                .folio => .{ .width = 8.5 * pt_per_inch, .height = 13 * pt_per_inch },
                .quarto => .{ .width = 8 * pt_per_inch, .height = 10 * pt_per_inch },
                .statement => .{ .width = 5.5 * pt_per_inch, .height = 8.5 * pt_per_inch },
            };
        }

        pub fn fromString(str: []const u8) ?StandardSize {
            const lower = blk: {
                var buf: [16]u8 = undefined;
                if (str.len > buf.len) return null;
                for (str, 0..) |c, i| {
                    buf[i] = std.ascii.toLower(c);
                }
                break :blk buf[0..str.len];
            };

            if (std.mem.eql(u8, lower, "a0")) return .a0;
            if (std.mem.eql(u8, lower, "a1")) return .a1;
            if (std.mem.eql(u8, lower, "a2")) return .a2;
            if (std.mem.eql(u8, lower, "a3")) return .a3;
            if (std.mem.eql(u8, lower, "a4")) return .a4;
            if (std.mem.eql(u8, lower, "a5")) return .a5;
            if (std.mem.eql(u8, lower, "a6")) return .a6;
            if (std.mem.eql(u8, lower, "a7")) return .a7;
            if (std.mem.eql(u8, lower, "a8")) return .a8;
            if (std.mem.eql(u8, lower, "b0")) return .b0;
            if (std.mem.eql(u8, lower, "b1")) return .b1;
            if (std.mem.eql(u8, lower, "b2")) return .b2;
            if (std.mem.eql(u8, lower, "b3")) return .b3;
            if (std.mem.eql(u8, lower, "b4")) return .b4;
            if (std.mem.eql(u8, lower, "b5")) return .b5;
            if (std.mem.eql(u8, lower, "b6")) return .b6;
            if (std.mem.eql(u8, lower, "c4")) return .c4;
            if (std.mem.eql(u8, lower, "c5")) return .c5;
            if (std.mem.eql(u8, lower, "c6")) return .c6;
            if (std.mem.eql(u8, lower, "letter")) return .letter;
            if (std.mem.eql(u8, lower, "legal")) return .legal;
            if (std.mem.eql(u8, lower, "tabloid")) return .tabloid;
            if (std.mem.eql(u8, lower, "ledger")) return .ledger;
            if (std.mem.eql(u8, lower, "executive")) return .executive;
            if (std.mem.eql(u8, lower, "folio")) return .folio;
            if (std.mem.eql(u8, lower, "quarto")) return .quarto;
            if (std.mem.eql(u8, lower, "statement")) return .statement;
            return null;
        }
    };

    pub fn landscape(self: PageSize) PageSize {
        return .{ .width = self.height, .height = self.width };
    }

    /// Parse a page size string. Supported formats:
    /// - Standard names: "A4", "Letter", "Legal", etc.
    /// - Standard names with L suffix for landscape: "A4L", "LetterL"
    /// - Dimensions with units: "210x297mm", "8.5x11inch", "612x792pt", "21x29.7cm"
    /// - Dimensions without units (assumes points): "612x792"
    pub fn parse(str: []const u8) ?PageSize {
        if (str.len == 0) return null;

        // First try to parse as standard size name (without landscape suffix)
        if (StandardSize.fromString(str)) |std_size| {
            return std_size.getSize();
        }

        // Check for landscape suffix - only if it's not a dimension (no 'x')
        if (str.len > 1 and std.mem.indexOf(u8, str, "x") == null) {
            if (str[str.len - 1] == 'L' or str[str.len - 1] == 'l') {
                const name = str[0 .. str.len - 1];
                if (StandardSize.fromString(name)) |std_size| {
                    return std_size.getSize().landscape();
                }
            }
        }

        // Parse as WIDTHxHEIGHT with optional unit suffix
        const x_pos = std.mem.indexOf(u8, str, "x") orelse return null;
        if (x_pos == 0 or x_pos >= str.len - 1) return null;

        const width_part = str[0..x_pos];
        const height_and_unit = str[x_pos + 1 ..];

        // Determine unit and extract height number
        var unit_factor: f64 = 1.0; // default: points
        var height_part: []const u8 = height_and_unit;

        if (std.mem.endsWith(u8, height_and_unit, "mm")) {
            unit_factor = pt_per_mm;
            height_part = height_and_unit[0 .. height_and_unit.len - 2];
        } else if (std.mem.endsWith(u8, height_and_unit, "cm")) {
            unit_factor = pt_per_cm;
            height_part = height_and_unit[0 .. height_and_unit.len - 2];
        } else if (std.mem.endsWith(u8, height_and_unit, "inch")) {
            unit_factor = pt_per_inch;
            height_part = height_and_unit[0 .. height_and_unit.len - 4];
        } else if (std.mem.endsWith(u8, height_and_unit, "in")) {
            unit_factor = pt_per_inch;
            height_part = height_and_unit[0 .. height_and_unit.len - 2];
        } else if (std.mem.endsWith(u8, height_and_unit, "pt")) {
            unit_factor = 1.0;
            height_part = height_and_unit[0 .. height_and_unit.len - 2];
        }

        const width = std.fmt.parseFloat(f64, width_part) catch return null;
        const height = std.fmt.parseFloat(f64, height_part) catch return null;

        if (width <= 0 or height <= 0) return null;

        return .{
            .width = width * unit_factor,
            .height = height * unit_factor,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PageSize.parse standard sizes" {
    // A4 portrait
    const a4 = PageSize.parse("A4").?;
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), a4.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 841.89), a4.height, 0.5);

    // A4 landscape
    const a4l = PageSize.parse("A4L").?;
    try std.testing.expectApproxEqAbs(@as(f64, 841.89), a4l.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), a4l.height, 0.5);

    // Letter
    const letter = PageSize.parse("Letter").?;
    try std.testing.expectApproxEqAbs(@as(f64, 612.0), letter.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 792.0), letter.height, 0.1);

    // Letter landscape (lowercase)
    const letterl = PageSize.parse("letterl").?;
    try std.testing.expectApproxEqAbs(@as(f64, 792.0), letterl.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 612.0), letterl.height, 0.1);

    // Legal
    const legal = PageSize.parse("LEGAL").?;
    try std.testing.expectApproxEqAbs(@as(f64, 612.0), legal.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 1008.0), legal.height, 0.1);
}

test "PageSize.parse with units" {
    // Millimeters
    const mm = PageSize.parse("210x297mm").?;
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), mm.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 841.89), mm.height, 0.5);

    // Centimeters
    const cm = PageSize.parse("21x29.7cm").?;
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), cm.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 841.89), cm.height, 0.5);

    // Inches
    const inch = PageSize.parse("8.5x11inch").?;
    try std.testing.expectApproxEqAbs(@as(f64, 612.0), inch.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 792.0), inch.height, 0.1);

    // Inches (short form)
    const in_short = PageSize.parse("8.5x11in").?;
    try std.testing.expectApproxEqAbs(@as(f64, 612.0), in_short.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 792.0), in_short.height, 0.1);

    // Points explicit
    const pt = PageSize.parse("612x792pt").?;
    try std.testing.expectApproxEqAbs(@as(f64, 612.0), pt.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 792.0), pt.height, 0.1);

    // Points implicit (no unit)
    const no_unit = PageSize.parse("612x792").?;
    try std.testing.expectApproxEqAbs(@as(f64, 612.0), no_unit.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 792.0), no_unit.height, 0.1);
}

test "PageSize.parse invalid inputs" {
    try std.testing.expect(PageSize.parse("") == null);
    try std.testing.expect(PageSize.parse("invalid") == null);
    try std.testing.expect(PageSize.parse("x100") == null);
    try std.testing.expect(PageSize.parse("100x") == null);
    try std.testing.expect(PageSize.parse("100") == null);
    try std.testing.expect(PageSize.parse("abcxdef") == null);
}

test "parseOutputSpec valid specs" {
    const spec1 = try parseOutputSpec("300:png:0:page_{num}.png");
    try std.testing.expectApproxEqAbs(@as(f64, 300.0), spec1.dpi, 0.1);
    try std.testing.expectEqual(images.Format.png, spec1.format);
    try std.testing.expectEqual(@as(u8, 0), spec1.quality);
    try std.testing.expectEqualStrings("page_{num}.png", spec1.template);

    const spec2 = try parseOutputSpec("150:jpeg:85:thumb_{num0}.jpg");
    try std.testing.expectApproxEqAbs(@as(f64, 150.0), spec2.dpi, 0.1);
    try std.testing.expectEqual(images.Format.jpeg, spec2.format);
    try std.testing.expectEqual(@as(u8, 85), spec2.quality);
    try std.testing.expectEqualStrings("thumb_{num0}.jpg", spec2.template);

    const spec3 = try parseOutputSpec("72:jpg:90:output.jpg");
    try std.testing.expectEqual(images.Format.jpeg, spec3.format);
}

test "parseOutputSpec invalid specs" {
    try std.testing.expectError(error.InvalidSpec, parseOutputSpec(""));
    try std.testing.expectError(error.InvalidSpec, parseOutputSpec("300"));
    try std.testing.expectError(error.InvalidSpec, parseOutputSpec("300:png"));
    try std.testing.expectError(error.InvalidSpec, parseOutputSpec("300:png:0"));
    try std.testing.expectError(error.InvalidSpec, parseOutputSpec("abc:png:0:file.png"));
    try std.testing.expectError(error.InvalidSpec, parseOutputSpec("300:xyz:0:file.png"));
    try std.testing.expectError(error.InvalidSpec, parseOutputSpec("300:png:abc:file.png"));
}

test "parseResolution valid values" {
    try std.testing.expectApproxEqAbs(@as(f64, 300.0), parseResolution("300").?, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 300.0), parseResolution("300dpi").?, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 150.5), parseResolution("150.5").?, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 150.5), parseResolution("150.5dpi").?, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 72.0), parseResolution("72dpi").?, 0.1);
}

test "parseResolution invalid values" {
    try std.testing.expect(parseResolution("") == null);
    try std.testing.expect(parseResolution("abc") == null);
    try std.testing.expect(parseResolution("abcdpi") == null);
    try std.testing.expect(parseResolution("dpi") == null);
}

test "SliceArgIterator" {
    const args = [_][]const u8{ "arg1", "arg2", "arg3" };
    var it = SliceArgIterator.init(&args);

    try std.testing.expectEqualStrings("arg1", it.next().?);
    try std.testing.expectEqualStrings("arg2", it.next().?);
    try std.testing.expectEqualStrings("arg3", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "SliceArgIterator skip" {
    const args = [_][]const u8{ "arg1", "arg2", "arg3" };
    var it = SliceArgIterator.init(&args);

    try std.testing.expect(it.skip() == true);
    try std.testing.expectEqualStrings("arg2", it.next().?);
    try std.testing.expect(it.skip() == true);
    try std.testing.expect(it.skip() == false);
    try std.testing.expect(it.next() == null);
}

test "SliceArgIterator empty" {
    const args = [_][]const u8{};
    var it = SliceArgIterator.init(&args);

    try std.testing.expect(it.next() == null);
    try std.testing.expect(it.skip() == false);
}

test "PageSize.landscape" {
    const portrait = PageSize{ .width = 100, .height = 200 };
    const landscape = portrait.landscape();
    try std.testing.expectApproxEqAbs(@as(f64, 200), landscape.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 100), landscape.height, 0.01);
}

test "PageSize.StandardSize.getSize" {
    // Test a few key sizes
    const a4 = PageSize.StandardSize.a4.getSize();
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), a4.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 841.89), a4.height, 0.5);

    const letter = PageSize.StandardSize.letter.getSize();
    try std.testing.expectApproxEqAbs(@as(f64, 612.0), letter.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 792.0), letter.height, 0.1);

    // Ledger is landscape by default
    const ledger = PageSize.StandardSize.ledger.getSize();
    try std.testing.expectApproxEqAbs(@as(f64, 17 * 72), ledger.width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 11 * 72), ledger.height, 0.1);
}

test "PageSize.StandardSize.fromString" {
    try std.testing.expectEqual(PageSize.StandardSize.a4, PageSize.StandardSize.fromString("a4").?);
    try std.testing.expectEqual(PageSize.StandardSize.a4, PageSize.StandardSize.fromString("A4").?);
    try std.testing.expectEqual(PageSize.StandardSize.letter, PageSize.StandardSize.fromString("Letter").?);
    try std.testing.expectEqual(PageSize.StandardSize.letter, PageSize.StandardSize.fromString("LETTER").?);
    try std.testing.expect(PageSize.StandardSize.fromString("invalid") == null);
    try std.testing.expect(PageSize.StandardSize.fromString("") == null);
}

test "BLANK_PAGE constant" {
    try std.testing.expectEqualStrings(":blank", BLANK_PAGE);
}

test "getBasename" {
    try std.testing.expectEqualStrings("document", getBasename("/path/to/document.pdf"));
    try std.testing.expectEqualStrings("file", getBasename("file.txt"));
    try std.testing.expectEqualStrings("noext", getBasename("noext"));
}

test "getBasename edge cases" {
    try std.testing.expectEqualStrings("file", getBasename("file."));
    try std.testing.expectEqualStrings("", getBasename(".hidden"));
    try std.testing.expectEqualStrings("doc", getBasename("/doc.pdf"));
    try std.testing.expectEqualStrings("doc", getBasename("C:\\path\\doc.pdf"));
}

test "parsePageRanges" {
    const allocator = std.testing.allocator;

    {
        const ranges = try parsePageRanges(allocator, "1-5,8,10-12", 20);
        defer allocator.free(ranges);

        try std.testing.expectEqual(@as(usize, 3), ranges.len);
        try std.testing.expectEqual(PageRange{ .start = 1, .end = 5 }, ranges[0]);
        try std.testing.expectEqual(PageRange{ .start = 8, .end = 8 }, ranges[1]);
        try std.testing.expectEqual(PageRange{ .start = 10, .end = 12 }, ranges[2]);
    }
}

test "isPageInRanges" {
    const ranges = [_]PageRange{
        .{ .start = 1, .end = 5 },
        .{ .start = 10, .end = 10 },
    };

    try std.testing.expect(isPageInRanges(1, &ranges));
    try std.testing.expect(isPageInRanges(3, &ranges));
    try std.testing.expect(isPageInRanges(5, &ranges));
    try std.testing.expect(!isPageInRanges(6, &ranges));
    try std.testing.expect(isPageInRanges(10, &ranges));
    try std.testing.expect(!isPageInRanges(11, &ranges));
}

test "PageRange.contains" {
    const range = PageRange{ .start = 5, .end = 10 };
    try std.testing.expect(!range.contains(4));
    try std.testing.expect(range.contains(5));
    try std.testing.expect(range.contains(7));
    try std.testing.expect(range.contains(10));
    try std.testing.expect(!range.contains(11));
}

test "PageRange single page" {
    const range = PageRange{ .start = 3, .end = 3 };
    try std.testing.expect(!range.contains(2));
    try std.testing.expect(range.contains(3));
    try std.testing.expect(!range.contains(4));
}

test "parsePageRanges edge cases" {
    const allocator = std.testing.allocator;

    // With spaces
    {
        const ranges = try parsePageRanges(allocator, " 1 - 5 , 8 ", 20);
        defer allocator.free(ranges);
        try std.testing.expectEqual(@as(usize, 2), ranges.len);
    }

    // Empty parts ignored
    {
        const ranges = try parsePageRanges(allocator, "1,,3", 20);
        defer allocator.free(ranges);
        try std.testing.expectEqual(@as(usize, 2), ranges.len);
    }
}

test "parsePageRanges errors" {
    const allocator = std.testing.allocator;

    // Page 0 is invalid
    try std.testing.expectError(error.InvalidPageRange, parsePageRanges(allocator, "0", 20));

    // Page exceeds max
    try std.testing.expectError(error.InvalidPageRange, parsePageRanges(allocator, "25", 20));

    // Start > end
    try std.testing.expectError(error.InvalidPageRange, parsePageRanges(allocator, "10-5", 20));

    // Invalid number
    try std.testing.expectError(error.InvalidPageRange, parsePageRanges(allocator, "abc", 20));
}

/// Expand a list of PageRanges into a flat list of page numbers.
pub fn expandPageRanges(allocator: std.mem.Allocator, ranges: []const PageRange) std.mem.Allocator.Error![]u32 {
    var pages = std.array_list.Managed(u32).init(allocator);
    errdefer pages.deinit();

    for (ranges) |range| {
        var p = range.start;
        while (p <= range.end) : (p += 1) {
            try pages.append(p);
        }
    }

    return try pages.toOwnedSlice();
}

/// Parse a page range string (e.g., "1-5,8,10-12") into a list of page numbers.
/// If range_str is null, returns all pages from 1 to page_count.
/// Prints error message on stderr and exits on invalid input.
pub fn parsePageList(
    allocator: std.mem.Allocator,
    range_str: ?[]const u8,
    page_count: u32,
    stderr: *std.Io.Writer,
) std.mem.Allocator.Error![]u32 {
    if (range_str) |range| {
        const ranges = parsePageRanges(allocator, range, page_count) catch {
            stderr.print("Invalid page range: {s} (document has {d} pages)\n", .{ range, page_count }) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        defer allocator.free(ranges);

        return expandPageRanges(allocator, ranges);
    } else {
        // All pages
        var pages = std.array_list.Managed(u32).init(allocator);
        errdefer pages.deinit();

        var p: u32 = 1;
        while (p <= page_count) : (p += 1) {
            try pages.append(p);
        }

        return try pages.toOwnedSlice();
    }
}
