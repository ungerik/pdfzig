//! JSON text block parsing and rendering for PDF creation
//!
//! This module handles parsing JSON files with formatted text blocks and
//! rendering them to PDF pages. The JSON format is compatible with the
//! output of `extract_text --format json`.

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const cli_parsing = @import("../cli_parsing.zig");

// ============================================================================
// UTF-8 to UTF-16 Conversion
// ============================================================================

/// Convert UTF-8 text to null-terminated UTF-16LE for PDFium.
/// If the input is not valid UTF-8, falls back to Latin-1 encoding.
fn encodeUtf8ToUtf16(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!std.array_list.Managed(u16) {
    var utf16_buf = std.array_list.Managed(u16).init(allocator);
    errdefer utf16_buf.deinit();

    var utf8_view = std.unicode.Utf8View.init(text) catch {
        // If not valid UTF-8, fall back to Latin-1
        for (text) |byte| {
            try utf16_buf.append(@as(u16, byte));
        }
        try utf16_buf.append(0); // Null terminator
        return utf16_buf;
    };

    var it = utf8_view.iterator();
    while (it.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xFFFF) {
            try utf16_buf.append(@intCast(codepoint));
        } else {
            // Surrogate pair for codepoints > 0xFFFF
            const cp = codepoint - 0x10000;
            try utf16_buf.append(@intCast(0xD800 + (cp >> 10)));
            try utf16_buf.append(@intCast(0xDC00 + (cp & 0x3FF)));
        }
    }
    try utf16_buf.append(0); // Null terminator

    return utf16_buf;
}

// ============================================================================
// JSON Text Extraction
// ============================================================================

/// Text block with formatting information
pub const TextBlock = struct {
    text: std.array_list.Managed(u8),
    bbox: struct { left: f64, top: f64, right: f64, bottom: f64 },
    font_name: ?[]const u8,
    font_size: f64,
    font_weight: i32,
    is_italic: bool,
    color: struct { r: u8, g: u8, b: u8, a: u8 },
};

/// Extract text from a PDF document as JSON with formatting information
pub fn extractTextAsJson(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page_count: u32,
    page_ranges: ?[]cli_parsing.PageRange,
    output: *std.Io.Writer,
) !void {
    try output.writeAll("{\"pages\":[");

    var first_page = true;
    for (1..page_count + 1) |i| {
        const page_num: u32 = @intCast(i);

        if (page_ranges) |ranges| {
            if (!cli_parsing.isPageInRanges(page_num, ranges)) continue;
        }

        var page = doc.loadPage(page_num - 1) catch continue;
        defer page.close();

        var text_page = page.loadTextPage() orelse continue;
        defer text_page.close();

        if (!first_page) try output.writeAll(",");
        first_page = false;

        try output.print("{{\"page\":{d},\"width\":{d:.2},\"height\":{d:.2},\"blocks\":[", .{
            page_num,
            page.getWidth(),
            page.getHeight(),
        });

        // Extract text blocks
        try extractPageBlocks(allocator, &text_page, output);

        try output.writeAll("]}");
    }

    try output.writeAll("]}\n");
}

fn extractPageBlocks(
    allocator: std.mem.Allocator,
    text_page: *pdfium.TextPage,
    output: *std.Io.Writer,
) !void {
    const char_count = text_page.getCharCount();
    if (char_count == 0) return;

    // Arena allocator handles all cleanup
    var blocks = std.array_list.Managed(TextBlock).init(allocator);

    var current_block: ?TextBlock = null;

    var prev_font_size: f64 = 0;
    var prev_font_weight: i32 = 0;
    var prev_is_italic: bool = false;
    var prev_color: pdfium.TextPage.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var prev_y: f64 = 0;

    for (0..char_count) |idx| {
        const index: u32 = @intCast(idx);
        const unicode = text_page.getCharUnicode(index);

        // Skip control characters except space/newline
        if (unicode < 32 and unicode != 32 and unicode != 10 and unicode != 13) continue;

        // Get character properties
        const box = text_page.getCharBox(index) orelse continue;
        const font_size = text_page.getCharFontSize(index);
        const font_weight = text_page.getCharFontWeight(index);
        const color = text_page.getCharFillColor(index) orelse pdfium.TextPage.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

        var is_italic = false;
        if (text_page.getCharFontInfo(allocator, index)) |info| {
            is_italic = info.flags.isItalic();
            // Arena allocator handles cleanup
        }

        // Check if we need to start a new block
        const y_diff = @abs(box.top - prev_y);
        const is_new_line = prev_y != 0 and y_diff > font_size * 0.5;
        const size_changed = @abs(font_size - prev_font_size) > 0.5;
        const weight_changed = prev_font_weight != font_weight;
        const italic_changed = prev_is_italic != is_italic;
        const color_changed = prev_color.r != color.r or prev_color.g != color.g or
            prev_color.b != color.b or prev_color.a != color.a;

        const needs_new_block = current_block == null or is_new_line or
            size_changed or weight_changed or italic_changed or color_changed;

        if (needs_new_block) {
            // Save current block if any
            if (current_block) |*block| {
                try blocks.append(block.*);
                current_block = null;
            }

            // Get font name for this block
            var block_font_name: ?[]u8 = null;
            if (text_page.getCharFontInfo(allocator, index)) |info| {
                block_font_name = info.name;
            }

            const new_block = TextBlock{
                .text = std.array_list.Managed(u8).init(allocator),
                .bbox = .{ .left = box.left, .top = box.top, .right = box.right, .bottom = box.bottom },
                .font_name = block_font_name,
                .font_size = font_size,
                .font_weight = font_weight,
                .is_italic = is_italic,
                .color = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a },
            };
            current_block = new_block;
        }

        // Add character to current block
        if (current_block) |*block| {
            // Encode unicode to UTF-8
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(unicode), &utf8_buf) catch continue;
            try block.text.appendSlice(utf8_buf[0..len]);

            // Expand bounding box
            block.bbox.left = @min(block.bbox.left, box.left);
            block.bbox.right = @max(block.bbox.right, box.right);
            block.bbox.top = @max(block.bbox.top, box.top);
            block.bbox.bottom = @min(block.bbox.bottom, box.bottom);
        }

        prev_font_size = font_size;
        prev_font_weight = font_weight;
        prev_is_italic = is_italic;
        prev_color = color;
        prev_y = box.top;
    }

    // Save last block
    if (current_block) |*block| {
        try blocks.append(block.*);
    }

    // Output blocks as JSON
    for (blocks.items, 0..) |block, idx| {
        if (idx > 0) try output.writeAll(",");

        try output.writeAll("{\"text\":\"");
        // Escape JSON string
        for (block.text.items) |c| {
            switch (c) {
                '"' => try output.writeAll("\\\""),
                '\\' => try output.writeAll("\\\\"),
                '\n' => try output.writeAll("\\n"),
                '\r' => try output.writeAll("\\r"),
                '\t' => try output.writeAll("\\t"),
                else => {
                    if (c < 32) {
                        try output.print("\\u{x:0>4}", .{c});
                    } else {
                        try output.writeByte(c);
                    }
                },
            }
        }
        try output.writeAll("\",");

        try output.print("\"bbox\":{{\"left\":{d:.2},\"top\":{d:.2},\"right\":{d:.2},\"bottom\":{d:.2}}},", .{
            block.bbox.left,
            block.bbox.top,
            block.bbox.right,
            block.bbox.bottom,
        });

        if (block.font_name) |name| {
            try output.writeAll("\"font\":\"");
            try output.writeAll(name);
            try output.writeAll("\",");
        } else {
            try output.writeAll("\"font\":null,");
        }

        try output.print("\"size\":{d:.1},\"weight\":{d},\"italic\":{},", .{
            block.font_size,
            block.font_weight,
            block.is_italic,
        });

        // Output color as CSS-compatible hex (include alpha only if not fully opaque)
        if (block.color.a == 255) {
            try output.print("\"color\":\"#{x:0>2}{x:0>2}{x:0>2}\"}}", .{
                block.color.r,
                block.color.g,
                block.color.b,
            });
        } else {
            try output.print("\"color\":\"#{x:0>2}{x:0>2}{x:0>2}{x:0>2}\"}}", .{
                block.color.r,
                block.color.g,
                block.color.b,
                block.color.a,
            });
        }
    }
}

// ============================================================================
// JSON Text Rendering (PDF Creation)
// ============================================================================

/// Standard PDF base fonts (guaranteed to be available per PDF specification)
///
/// These 14 fonts are required to be available in all PDF readers:
/// - Courier (regular, bold, oblique, bold-oblique)
/// - Helvetica (regular, bold, oblique, bold-oblique)
/// - Times (roman, bold, italic, bold-italic)
/// - Symbol
/// - ZapfDingbats
pub const StandardFont = enum {
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    times_roman,
    times_bold,
    times_italic,
    times_bold_italic,
    symbol,
    zapf_dingbats,

    /// Get the PDF font name
    pub fn name(self: StandardFont) []const u8 {
        return switch (self) {
            .courier => "Courier",
            .courier_bold => "Courier-Bold",
            .courier_oblique => "Courier-Oblique",
            .courier_bold_oblique => "Courier-BoldOblique",
            .helvetica => "Helvetica",
            .helvetica_bold => "Helvetica-Bold",
            .helvetica_oblique => "Helvetica-Oblique",
            .helvetica_bold_oblique => "Helvetica-BoldOblique",
            .times_roman => "Times-Roman",
            .times_bold => "Times-Bold",
            .times_italic => "Times-Italic",
            .times_bold_italic => "Times-BoldItalic",
            .symbol => "Symbol",
            .zapf_dingbats => "ZapfDingbats",
        };
    }

    /// Map a font name from JSON to a standard PDF font with sensible fallbacks
    pub fn fromJsonFont(font_name: ?[]const u8, is_bold: bool, is_italic: bool) StandardFont {
        return if (font_name) |n| blk: {
            var has_bold = is_bold;
            var has_italic = is_italic;

            // Check if font name contains bold/italic indicators
            if (containsIgnoreCase(n, "Bold")) {
                has_bold = true;
            }
            if (containsIgnoreCase(n, "Italic") or containsIgnoreCase(n, "Oblique")) {
                has_italic = true;
            }

            // Detect font family
            if (containsIgnoreCase(n, "Courier") or containsIgnoreCase(n, "Mono")) {
                break :blk if (has_bold and has_italic)
                    StandardFont.courier_bold_oblique
                else if (has_bold)
                    StandardFont.courier_bold
                else if (has_italic)
                    StandardFont.courier_oblique
                else
                    StandardFont.courier;
            }

            if (containsIgnoreCase(n, "Times") or containsIgnoreCase(n, "Serif")) {
                break :blk if (has_bold and has_italic)
                    StandardFont.times_bold_italic
                else if (has_bold)
                    StandardFont.times_bold
                else if (has_italic)
                    StandardFont.times_italic
                else
                    StandardFont.times_roman;
            }

            // Default to Helvetica (sans-serif)
            break :blk if (has_bold and has_italic)
                StandardFont.helvetica_bold_oblique
            else if (has_bold)
                StandardFont.helvetica_bold
            else if (has_italic)
                StandardFont.helvetica_oblique
            else
                StandardFont.helvetica;
        } else blk: {
            // No font name, use weight/italic flags
            break :blk if (is_bold and is_italic)
                StandardFont.helvetica_bold_oblique
            else if (is_bold)
                StandardFont.helvetica_bold
            else if (is_italic)
                StandardFont.helvetica_oblique
            else
                StandardFont.helvetica;
        };
    }
};

/// Case-insensitive substring search
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) {
            return true;
        }
    }
    return false;
}

/// Parse a hex color string like "#rrggbb" or "#rrggbbaa"
pub fn parseHexColor(color_str: []const u8) struct { r: u8, g: u8, b: u8, a: u8 } {
    if (color_str.len < 7 or color_str[0] != '#') {
        return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    }

    const r = std.fmt.parseInt(u8, color_str[1..3], 16) catch 0;
    const g = std.fmt.parseInt(u8, color_str[3..5], 16) catch 0;
    const b = std.fmt.parseInt(u8, color_str[5..7], 16) catch 0;
    const a = if (color_str.len >= 9)
        std.fmt.parseInt(u8, color_str[7..9], 16) catch 255
    else
        255;

    return .{ .r = r, .g = g, .b = b, .a = a };
}

/// Add formatted text from a JSON file to a PDF page
pub fn addJsonToPage(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    json_path: []const u8,
    stderr: *std.Io.Writer,
) !void {
    // Read JSON file
    const file = std.fs.cwd().openFile(json_path, .{}) catch {
        try stderr.print("Error opening JSON file: {s}\n", .{json_path});
        try stderr.flush();
        std.process.exit(1);
    };
    defer file.close();

    const json_text = file.readToEndAlloc(allocator, 50 * 1024 * 1024) catch {
        try stderr.writeAll("Error reading JSON file\n");
        try stderr.flush();
        std.process.exit(1);
    };

    // Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
        try stderr.writeAll("Error parsing JSON\n");
        try stderr.flush();
        std.process.exit(1);
    };

    const root = parsed.value;

    // Get pages array
    const pages = if (root == .object)
        root.object.get("pages") orelse root.object.get("blocks")
    else if (root == .array)
        root // Direct array of blocks
    else
        null;

    if (pages == null) {
        try stderr.writeAll("Error: JSON must have 'pages' array or 'blocks' array\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Handle different JSON structures
    if (pages.? == .array) {
        for (pages.?.array.items) |item| {
            if (item == .object) {
                // Check if this is a page object with blocks
                if (item.object.get("blocks")) |blocks| {
                    if (blocks == .array) {
                        try renderBlocks(allocator, doc, page, blocks.array.items, stderr);
                    }
                } else {
                    // This is a block object directly
                    try renderBlock(allocator, doc, page, item, stderr);
                }
            }
        }
    }
}

fn renderBlocks(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    blocks: []const std.json.Value,
    stderr: *std.Io.Writer,
) !void {
    for (blocks) |block| {
        try renderBlock(allocator, doc, page, block, stderr);
    }
}

fn renderBlock(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    block: std.json.Value,
    stderr: *std.Io.Writer,
) !void {
    if (block != .object) return;

    const obj = block.object;

    // Get text content
    const text_value = obj.get("text") orelse return;
    if (text_value != .string) return;
    const text = text_value.string;

    // Skip whitespace-only blocks
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;

    // Get bounding box
    const bbox = obj.get("bbox");
    var x: f64 = 72.0; // Default margin
    var y: f64 = 720.0;

    if (bbox != null and bbox.? == .object) {
        const bbox_obj = bbox.?.object;
        if (bbox_obj.get("left")) |left| {
            if (left == .float) x = left.float;
            if (left == .integer) x = @floatFromInt(left.integer);
        }
        if (bbox_obj.get("bottom")) |bottom| {
            if (bottom == .float) y = bottom.float;
            if (bottom == .integer) y = @floatFromInt(bottom.integer);
        }
    }

    // Get font size
    var font_size: f32 = 12.0;
    if (obj.get("size")) |size| {
        if (size == .float) font_size = @floatCast(size.float);
        if (size == .integer) font_size = @floatFromInt(size.integer);
    }

    // Get font style
    const font_name: ?[]const u8 = if (obj.get("font")) |f| (if (f == .string) f.string else null) else null;
    const is_bold = if (obj.get("weight")) |w| (if (w == .integer) w.integer >= 600 else false) else false;
    const is_italic = if (obj.get("italic")) |i| (if (i == .bool) i.bool else false) else false;

    // Map to standard PDF font
    const std_font = StandardFont.fromJsonFont(font_name, is_bold, is_italic);

    // Get color
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var a: u8 = 255;

    if (obj.get("color")) |color| {
        if (color == .string) {
            const parsed_color = parseHexColor(color.string);
            r = parsed_color.r;
            g = parsed_color.g;
            b = parsed_color.b;
            a = parsed_color.a;
        }
    }

    // Create text object
    var text_obj = doc.createTextObject(std_font.name(), font_size) catch {
        try stderr.writeAll("Error creating text object\n");
        return;
    };

    // Convert UTF-8 to UTF-16LE for PDFium
    var utf16_buf = encodeUtf8ToUtf16(allocator, text) catch return;
    defer utf16_buf.deinit();

    if (!text_obj.setText(utf16_buf.items)) return;

    // Set color (failure is non-fatal - object uses default black color)
    _ = text_obj.setFillColor(r, g, b, a);

    // Position the text
    text_obj.transform(1, 0, 0, 1, x, y);

    // Insert into page
    page.insertObject(text_obj);
}

// ============================================================================
// Tests
// ============================================================================

test "parseHexColor" {
    // Standard 6-digit hex
    const black = parseHexColor("#000000");
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);
    try std.testing.expectEqual(@as(u8, 255), black.a);

    const white = parseHexColor("#ffffff");
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);
    try std.testing.expectEqual(@as(u8, 255), white.a);

    const red = parseHexColor("#ff0000");
    try std.testing.expectEqual(@as(u8, 255), red.r);
    try std.testing.expectEqual(@as(u8, 0), red.g);
    try std.testing.expectEqual(@as(u8, 0), red.b);

    // 8-digit hex with alpha
    const semi_transparent = parseHexColor("#ff000080");
    try std.testing.expectEqual(@as(u8, 255), semi_transparent.r);
    try std.testing.expectEqual(@as(u8, 0), semi_transparent.g);
    try std.testing.expectEqual(@as(u8, 0), semi_transparent.b);
    try std.testing.expectEqual(@as(u8, 128), semi_transparent.a);

    // Invalid format - returns black
    const invalid = parseHexColor("invalid");
    try std.testing.expectEqual(@as(u8, 0), invalid.r);
    try std.testing.expectEqual(@as(u8, 0), invalid.g);
    try std.testing.expectEqual(@as(u8, 0), invalid.b);
    try std.testing.expectEqual(@as(u8, 255), invalid.a);

    // Missing hash
    const no_hash = parseHexColor("ff0000");
    try std.testing.expectEqual(@as(u8, 0), no_hash.r);
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("Helvetica-Bold", "bold"));
    try std.testing.expect(containsIgnoreCase("Helvetica-Bold", "Bold"));
    try std.testing.expect(containsIgnoreCase("BOLD", "bold"));
    try std.testing.expect(containsIgnoreCase("Monaco", "Monaco"));
    try std.testing.expect(!containsIgnoreCase("Monaco", "Mono"));
    try std.testing.expect(containsIgnoreCase("DejaVu Sans Mono", "Mono"));
    try std.testing.expect(containsIgnoreCase("DejaVu Sans Mono", "mono"));
}

test "StandardFont.fromJsonFont" {
    // Default sans-serif (Helvetica)
    try std.testing.expectEqual(StandardFont.helvetica, StandardFont.fromJsonFont(null, false, false));
    try std.testing.expectEqual(StandardFont.helvetica_bold, StandardFont.fromJsonFont(null, true, false));
    try std.testing.expectEqual(StandardFont.helvetica_oblique, StandardFont.fromJsonFont(null, false, true));
    try std.testing.expectEqual(StandardFont.helvetica_bold_oblique, StandardFont.fromJsonFont(null, true, true));

    // Courier/monospace detection
    try std.testing.expectEqual(StandardFont.courier, StandardFont.fromJsonFont("Courier", false, false));
    try std.testing.expectEqual(StandardFont.courier_bold, StandardFont.fromJsonFont("Courier-Bold", false, false));
    try std.testing.expectEqual(StandardFont.courier, StandardFont.fromJsonFont("DejaVu Sans Mono", false, false));

    // Monaco doesn't contain "Mono" so it falls back to Helvetica
    try std.testing.expectEqual(StandardFont.helvetica, StandardFont.fromJsonFont("Monaco", false, false));

    // Times/serif detection
    try std.testing.expectEqual(StandardFont.times_roman, StandardFont.fromJsonFont("Times-Roman", false, false));
    try std.testing.expectEqual(StandardFont.times_bold, StandardFont.fromJsonFont("Times New Roman", true, false));

    // Georgia doesn't match Times or Serif, falls back to Helvetica
    try std.testing.expectEqual(StandardFont.helvetica_oblique, StandardFont.fromJsonFont("Georgia", false, true));

    // Font name with Bold/Italic in name overrides flags
    try std.testing.expectEqual(StandardFont.helvetica_bold, StandardFont.fromJsonFont("Arial-Bold", false, false));
    try std.testing.expectEqual(StandardFont.helvetica_oblique, StandardFont.fromJsonFont("Arial-Italic", false, false));
    try std.testing.expectEqual(StandardFont.courier_bold_oblique, StandardFont.fromJsonFont("Courier-BoldOblique", false, false));
}

test "StandardFont.name" {
    try std.testing.expectEqualStrings("Helvetica", StandardFont.helvetica.name());
    try std.testing.expectEqualStrings("Helvetica-Bold", StandardFont.helvetica_bold.name());
    try std.testing.expectEqualStrings("Courier", StandardFont.courier.name());
    try std.testing.expectEqualStrings("Times-Roman", StandardFont.times_roman.name());
    try std.testing.expectEqualStrings("Times-BoldItalic", StandardFont.times_bold_italic.name());
}

test "roundtrip: create PDF from JSON and extract text" {
    const allocator = std.testing.allocator;

    // Initialize PDFium
    try pdfium.init();
    defer pdfium.deinit();

    // Create JSON input with formatted text blocks using standard PDF fonts
    const input_json =
        \\{
        \\  "pages": [
        \\    {
        \\      "page": 1,
        \\      "width": 595.28,
        \\      "height": 841.89,
        \\      "blocks": [
        \\        {
        \\          "text": "Hello World",
        \\          "bbox": {"left": 72.0, "top": 750.0, "right": 200.0, "bottom": 738.0},
        \\          "font": "Helvetica",
        \\          "size": 12.0,
        \\          "weight": 400,
        \\          "italic": false,
        \\          "color": "#000000"
        \\        },
        \\        {
        \\          "text": "Bold Text",
        \\          "bbox": {"left": 72.0, "top": 720.0, "right": 200.0, "bottom": 708.0},
        \\          "font": "Helvetica",
        \\          "size": 12.0,
        \\          "weight": 700,
        \\          "italic": false,
        \\          "color": "#ff0000"
        \\        },
        \\        {
        \\          "text": "Courier Text",
        \\          "bbox": {"left": 72.0, "top": 690.0, "right": 200.0, "bottom": 678.0},
        \\          "font": "Courier",
        \\          "size": 10.0,
        \\          "weight": 400,
        \\          "italic": false,
        \\          "color": "#0000ff"
        \\        },
        \\        {
        \\          "text": "Times Italic",
        \\          "bbox": {"left": 72.0, "top": 660.0, "right": 200.0, "bottom": 648.0},
        \\          "font": "Times-Roman",
        \\          "size": 14.0,
        \\          "weight": 400,
        \\          "italic": true,
        \\          "color": "#008000"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    // Create a new PDF document
    var doc = try pdfium.Document.createNew();
    defer doc.close();

    // Create a page
    var page = try doc.createPage(0, 595.28, 841.89);
    defer page.close();

    // Parse JSON and add text to page
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input_json, .{});
    defer parsed.deinit();

    // Use stderr for any error messages
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    // Get pages array
    const pages = parsed.value.object.get("pages");
    if (pages != null and pages.? == .array) {
        for (pages.?.array.items) |item| {
            if (item == .object) {
                if (item.object.get("blocks")) |blocks| {
                    if (blocks == .array) {
                        try renderBlocks(allocator, &doc, &page, blocks.array.items, stderr);
                    }
                }
            }
        }
    }

    // Generate content to finalize the page
    if (!page.generateContent()) return error.TestFailed;

    // Save to a temporary file
    const tmp_path = "test-cache/roundtrip_test.pdf";

    // Create test-cache directory if it doesn't exist
    std.fs.cwd().makeDir("test-cache") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    try doc.save(tmp_path);

    // Re-open the saved PDF
    var doc2 = try pdfium.Document.open(tmp_path);
    defer doc2.close();

    // Verify page count
    try std.testing.expectEqual(@as(u32, 1), doc2.getPageCount());

    // Load the page
    var page2 = try doc2.loadPage(0);
    defer page2.close();

    // Load text page
    var text_page = page2.loadTextPage() orelse return error.TestFailed;
    defer text_page.close();

    // Extract text
    const extracted_text = text_page.getText(allocator) orelse return error.TestFailed;
    defer allocator.free(extracted_text);

    // Verify that all our text blocks are present in the extracted text
    try std.testing.expect(std.mem.indexOf(u8, extracted_text, "Hello World") != null);
    try std.testing.expect(std.mem.indexOf(u8, extracted_text, "Bold Text") != null);
    try std.testing.expect(std.mem.indexOf(u8, extracted_text, "Courier Text") != null);
    try std.testing.expect(std.mem.indexOf(u8, extracted_text, "Times Italic") != null);

    // Clean up temp file
    std.fs.cwd().deleteFile(tmp_path) catch {};
}

pub fn addTextToPage(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    page: *pdfium.Page,
    text_path: []const u8,
    page_width: f64,
    page_height: f64,
    stderr: *std.Io.Writer,
) !void {
    // Read text file
    const file = std.fs.cwd().openFile(text_path, .{}) catch {
        try stderr.print("Error opening text file: {s}\n", .{text_path});
        try stderr.flush();
        std.process.exit(1);
    };
    defer file.close();

    const text = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.writeAll("Error reading text file\n");
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(text);

    const font_size: f32 = 12.0;
    const line_height: f64 = font_size * 1.2;
    const margin: f64 = 72.0; // 1 inch margin
    const max_width = page_width - 2 * margin;

    var y_pos = page_height - margin - font_size;

    // Split into lines and render each
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |line| {
        if (y_pos < margin) break; // Out of page space

        if (line.len == 0) {
            y_pos -= line_height;
            continue;
        }

        // Create text object
        var text_obj = doc.createTextObject("Courier", font_size) catch {
            try stderr.writeAll("Error creating text object\n");
            try stderr.flush();
            std.process.exit(1);
        };

        // Convert UTF-8 to UTF-16LE for PDFium
        var utf16_buf = encodeUtf8ToUtf16(allocator, line) catch continue;
        defer utf16_buf.deinit();

        if (!text_obj.setText(utf16_buf.items)) {
            continue;
        }

        // Position the text
        text_obj.transform(1, 0, 0, 1, margin, y_pos);

        // Insert into page
        page.insertObject(text_obj);

        y_pos -= line_height;
    }

    _ = max_width; // Will be used for text wrapping in future
}
