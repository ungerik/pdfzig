const std = @import("std");
const MetaData = @import("metadata.zig").MetaData;

/// Search PDF byte stream for XMP metadata and extract PDF/A conformance
/// PDF/A spec requires XMP to be uncompressed and unencrypted
pub fn extractPdfAConformance(pdf_bytes: []const u8) ?MetaData.PdfAConformance {
    // Search for XMP packet start marker
    const xmp_start = std.mem.indexOf(u8, pdf_bytes, "<?xpacket begin=") orelse return null;

    // Search for XMP packet end marker (after start)
    const xmp_end_marker = "<?xpacket end=";
    const search_from = xmp_start + 16;
    const xmp_end = std.mem.indexOf(u8, pdf_bytes[search_from..], xmp_end_marker) orelse return null;

    // Extract XMP packet
    const xmp_packet = pdf_bytes[xmp_start .. search_from + xmp_end + xmp_end_marker.len];

    // Verify this is PDF/A metadata (contains pdfaid namespace)
    if (std.mem.indexOf(u8, xmp_packet, "http://www.aiim.org/pdfa/ns/id/") == null) {
        return null;
    }

    // Extract part and level
    const part = extractPdfaidValue(xmp_packet, "pdfaid:part") orelse return null;
    const level = extractPdfaidLevel(xmp_packet) orelse return null;

    return MetaData.PdfAConformance{ .part = part, .level = level };
}

/// Extract pdfaid:part value (1-4)
fn extractPdfaidValue(xmp: []const u8, field: []const u8) ?u8 {
    // Try element syntax: <pdfaid:part>1</pdfaid:part>
    var buf: [128]u8 = undefined;

    const open_tag = std.fmt.bufPrint(&buf, "<{s}>", .{field}) catch return null;
    const close_tag_len = field.len + 3; // "</...>"

    if (std.mem.indexOf(u8, xmp, open_tag)) |start_idx| {
        const value_start = start_idx + open_tag.len;
        // Look for closing tag
        const remaining = xmp[value_start..];
        if (remaining.len > close_tag_len) {
            const close_tag = std.fmt.bufPrint(buf[open_tag.len..], "</{s}>", .{field}) catch return null;
            if (std.mem.indexOf(u8, remaining, close_tag)) |end_idx| {
                const value = remaining[0..end_idx];
                if (value.len == 1 and value[0] >= '1' and value[0] <= '4') {
                    return value[0] - '0';
                }
            }
        }
    }

    // Try attribute syntax: pdfaid:part="1"
    const attr_pattern = std.fmt.bufPrint(&buf, "{s}=\"", .{field}) catch return null;

    if (std.mem.indexOf(u8, xmp, attr_pattern)) |attr_idx| {
        const value_start = attr_idx + attr_pattern.len;
        if (xmp.len > value_start and xmp[value_start] >= '1' and xmp[value_start] <= '4') {
            return xmp[value_start] - '0';
        }
    }

    return null;
}

/// Extract pdfaid:conformance level ('a', 'b', 'u', 'e', 'f')
fn extractPdfaidLevel(xmp: []const u8) ?u8 {
    // Try element syntax: <pdfaid:conformance>b</pdfaid:conformance>
    const open_tag = "<pdfaid:conformance>";
    const close_tag = "</pdfaid:conformance>";

    if (std.mem.indexOf(u8, xmp, open_tag)) |start_idx| {
        const value_start = start_idx + open_tag.len;
        if (std.mem.indexOf(u8, xmp[value_start..], close_tag)) |end_idx| {
            const value = xmp[value_start .. value_start + end_idx];
            if (value.len == 1 and isValidLevel(value[0])) {
                return std.ascii.toLower(value[0]);
            }
        }
    }

    // Try attribute syntax: pdfaid:conformance="b"
    const attr_pattern = "pdfaid:conformance=\"";
    if (std.mem.indexOf(u8, xmp, attr_pattern)) |attr_idx| {
        const value_start = attr_idx + attr_pattern.len;
        if (xmp.len > value_start and isValidLevel(xmp[value_start])) {
            return std.ascii.toLower(xmp[value_start]);
        }
    }

    return null;
}

fn isValidLevel(c: u8) bool {
    const lower = std.ascii.toLower(c);
    return lower == 'a' or lower == 'b' or lower == 'u' or lower == 'e' or lower == 'f';
}

// ============================================================================
// Tests
// ============================================================================

test "extractPdfAConformance element syntax PDF/A-1b" {
    const xmp =
        \\<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<x:xmpmeta xmlns:x="adobe:ns:meta/">
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        \\<rdf:Description xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
        \\<pdfaid:part>1</pdfaid:part>
        \\<pdfaid:conformance>b</pdfaid:conformance>
        \\</rdf:Description>
        \\</rdf:RDF>
        \\</x:xmpmeta>
        \\<?xpacket end="w"?>
    ;
    const result = extractPdfAConformance(xmp).?;
    try std.testing.expectEqual(@as(u8, 1), result.part);
    try std.testing.expectEqual(@as(u8, 'b'), result.level);
}

test "extractPdfAConformance element syntax PDF/A-2a" {
    const xmp =
        \\<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<rdf:Description xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
        \\<pdfaid:part>2</pdfaid:part>
        \\<pdfaid:conformance>a</pdfaid:conformance>
        \\</rdf:Description>
        \\<?xpacket end="w"?>
    ;
    const result = extractPdfAConformance(xmp).?;
    try std.testing.expectEqual(@as(u8, 2), result.part);
    try std.testing.expectEqual(@as(u8, 'a'), result.level);
}

test "extractPdfAConformance attribute syntax PDF/A-3u" {
    const xmp =
        \\<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<rdf:Description xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"
        \\ pdfaid:part="3" pdfaid:conformance="u"/>
        \\<?xpacket end="w"?>
    ;
    const result = extractPdfAConformance(xmp).?;
    try std.testing.expectEqual(@as(u8, 3), result.part);
    try std.testing.expectEqual(@as(u8, 'u'), result.level);
}

test "extractPdfAConformance uppercase level normalized to lowercase" {
    const xmp =
        \\<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<rdf:Description xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
        \\<pdfaid:part>1</pdfaid:part>
        \\<pdfaid:conformance>B</pdfaid:conformance>
        \\</rdf:Description>
        \\<?xpacket end="w"?>
    ;
    const result = extractPdfAConformance(xmp).?;
    try std.testing.expectEqual(@as(u8, 'b'), result.level);
}

test "extractPdfAConformance returns null for no XMP packet" {
    try std.testing.expect(extractPdfAConformance("not a pdf") == null);
}

test "extractPdfAConformance returns null for XMP without pdfaid namespace" {
    const xmp =
        \\<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
        \\<dc:title>Test</dc:title>
        \\</rdf:Description>
        \\<?xpacket end="w"?>
    ;
    try std.testing.expect(extractPdfAConformance(xmp) == null);
}

test "extractPdfAConformance returns null for missing conformance level" {
    const xmp =
        \\<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<rdf:Description xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
        \\<pdfaid:part>1</pdfaid:part>
        \\</rdf:Description>
        \\<?xpacket end="w"?>
    ;
    try std.testing.expect(extractPdfAConformance(xmp) == null);
}

test "extractPdfAConformance returns null for missing part" {
    const xmp =
        \\<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<rdf:Description xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
        \\<pdfaid:conformance>b</pdfaid:conformance>
        \\</rdf:Description>
        \\<?xpacket end="w"?>
    ;
    try std.testing.expect(extractPdfAConformance(xmp) == null);
}

test "extractPdfAConformance PDF/A-4f" {
    const xmp =
        \\<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<rdf:Description xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
        \\<pdfaid:part>4</pdfaid:part>
        \\<pdfaid:conformance>f</pdfaid:conformance>
        \\</rdf:Description>
        \\<?xpacket end="w"?>
    ;
    const result = extractPdfAConformance(xmp).?;
    try std.testing.expectEqual(@as(u8, 4), result.part);
    try std.testing.expectEqual(@as(u8, 'f'), result.level);
}

test "isValidLevel" {
    try std.testing.expect(isValidLevel('a'));
    try std.testing.expect(isValidLevel('b'));
    try std.testing.expect(isValidLevel('u'));
    try std.testing.expect(isValidLevel('e'));
    try std.testing.expect(isValidLevel('f'));
    try std.testing.expect(isValidLevel('A'));
    try std.testing.expect(isValidLevel('B'));
    try std.testing.expect(!isValidLevel('c'));
    try std.testing.expect(!isValidLevel('x'));
    try std.testing.expect(!isValidLevel('1'));
}
