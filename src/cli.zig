//! CLI argument parsing and types for pdfzig

const std = @import("std");
const image_writer = @import("image_writer.zig");

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
    format: image_writer.Format,
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
    const format = image_writer.Format.fromString(format_str) orelse return error.InvalidSpec;
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
    try std.testing.expectEqual(image_writer.Format.png, spec1.format);
    try std.testing.expectEqual(@as(u8, 0), spec1.quality);
    try std.testing.expectEqualStrings("page_{num}.png", spec1.template);

    const spec2 = try parseOutputSpec("150:jpeg:85:thumb_{num0}.jpg");
    try std.testing.expectApproxEqAbs(@as(f64, 150.0), spec2.dpi, 0.1);
    try std.testing.expectEqual(image_writer.Format.jpeg, spec2.format);
    try std.testing.expectEqual(@as(u8, 85), spec2.quality);
    try std.testing.expectEqualStrings("thumb_{num0}.jpg", spec2.template);

    const spec3 = try parseOutputSpec("72:jpg:90:output.jpg");
    try std.testing.expectEqual(image_writer.Format.jpeg, spec3.format);
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
