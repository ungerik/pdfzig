//! CLI: Info command - Display PDF metadata and information

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const pdf = @import("../pdf/metadata.zig");
const pdfzig_info = @import("../pdfzig/info.zig");
const cli_parsing = @import("arg_parsing.zig");
const shared = @import("shared.zig");
const textfmt = @import("../pdfcontent/textfmt.zig");

const OutputFormat = enum {
    text,
    json,
};

/// Run the info command: display PDF metadata and document information.
/// Outputs as plain text by default, or as JSON with --json.
/// Shows page count, PDF version, encryption status, metadata fields,
/// per-page dimensions (JSON only), and attachment listing.
pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *cli_parsing.SliceArgIterator,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};

    var input_path: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var output_format: OutputFormat = .text;
    var show_help = false;

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                show_help = true;
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                password = arg_it.next();
            } else if (std.mem.eql(u8, arg, "--json")) {
                output_format = .json;
            } else {
                shared.exitWithError(stderr, "Unknown option: {s}\n", .{arg});
            }
        } else {
            input_path = arg;
        }
    }

    if (show_help) {
        printUsage(stdout);
        return;
    }

    const path = shared.requireInputPath(input_path, stderr);

    // Open document
    var doc = shared.openDocument(allocator, path, password) catch |err| {
        if (err == pdfium.Error.PasswordRequired) {
            // Password required but not provided
            switch (output_format) {
                .text => {
                    try stdout.print("File: {s}\n", .{path});
                    try stdout.writeAll("Encrypted: Yes (password required to access)\n");
                    try stdout.writeAll("\nUse -P <password> to provide the document password.\n");
                },
                .json => {
                    try stdout.print(
                        \\{{"file":"{s}","encrypted":true,"password_required":true}}
                        \\
                    , .{path});
                },
            }
            return;
        } else {
            shared.exitWithError(stderr, "Error: {}\n", .{err});
        }
    };
    defer doc.close();

    // Extract metadata from the open document
    var metadata = pdfzig_info.getInfo(allocator, &doc) catch |err| {
        shared.exitWithError(stderr, "Error extracting metadata: {}\n", .{err});
    };
    defer metadata.deinit(allocator);

    try printDocInfo(allocator, &metadata, doc, path, output_format, stdout);
}

fn printDocInfo(
    allocator: std.mem.Allocator,
    metadata: *pdf.MetaData,
    doc: pdfium.Document,
    path: []const u8,
    format: OutputFormat,
    stdout: *std.Io.Writer,
) !void {
    switch (format) {
        .text => try printDocInfoText(allocator, metadata, doc, path, stdout),
        .json => try printDocInfoJson(allocator, metadata, doc, path, stdout),
    }
}

fn printDocInfoText(
    allocator: std.mem.Allocator,
    metadata: *pdf.MetaData,
    doc: pdfium.Document,
    path: []const u8,
    stdout: *std.Io.Writer,
) !void {
    try stdout.print("File: {s}\n", .{path});
    try stdout.print("Pages: {d}\n", .{metadata.page_count});

    if (metadata.pdf_version) |ver| {
        try stdout.print("PDF Version: {s}\n", .{ver});
    }

    try stdout.print("Encrypted: {s}\n", .{if (metadata.encrypted) "Yes" else "No"});

    if (metadata.encrypted) {
        if (metadata.security_handler_revision) |revision| {
            try stdout.print("Security Handler Revision: {d}\n", .{revision});
        }
    }

    try stdout.writeAll("\nMetadata:\n");
    if (metadata.title) |t| try stdout.print("  Title: {s}\n", .{t});
    if (metadata.author) |a| try stdout.print("  Author: {s}\n", .{a});
    if (metadata.subject) |s| try stdout.print("  Subject: {s}\n", .{s});
    if (metadata.keywords) |k| try stdout.print("  Keywords: {s}\n", .{k});
    if (metadata.creator) |c_| try stdout.print("  Creator: {s}\n", .{c_});
    if (metadata.producer) |p| try stdout.print("  Producer: {s}\n", .{p});
    if (metadata.creation_date) |cd| try stdout.print("  Creation Date: {s}\n", .{cd});
    if (metadata.mod_date) |md| try stdout.print("  Modification Date: {s}\n", .{md});
    if (metadata.pdfa_conformance) |pdfa| {
        try stdout.writeAll("  PDF/A: ");
        try pdfa.format("", .{}, stdout);
        try stdout.writeAll("\n");
    }

    // Attachments
    const attachment_count = doc.getAttachmentCount();
    if (attachment_count > 0) {
        try stdout.print("\nAttachments: {d}\n", .{attachment_count});

        var xml_count: u32 = 0;
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator) orelse continue;
            defer allocator.free(name);

            const is_xml = shared.hasXmlExtension(name);
            if (is_xml) xml_count += 1;

            try stdout.print("  {s}{s}\n", .{ name, if (is_xml) " [XML]" else "" });
        }

        if (xml_count > 0) {
            try stdout.print("\nXML files: {d} (use 'extract_attachments \"*.xml\"' to extract)\n", .{xml_count});
        }
    }
}

fn printDocInfoJson(
    allocator: std.mem.Allocator,
    metadata: *pdf.MetaData,
    doc: pdfium.Document,
    path: []const u8,
    stdout: *std.Io.Writer,
) !void {
    try stdout.writeAll("{");

    // File path
    try stdout.writeAll("\"file\":");
    try writeJsonString(stdout, path);

    // Page count
    try stdout.print(",\"pages\":{d}", .{metadata.page_count});

    // PDF version
    if (metadata.pdf_version) |ver| {
        try stdout.writeAll(",\"pdf_version\":");
        try writeJsonString(stdout, ver);
    }

    // Encryption
    try stdout.print(",\"encrypted\":{s}", .{if (metadata.encrypted) "true" else "false"});

    if (metadata.encrypted) {
        if (metadata.security_handler_revision) |revision| {
            try stdout.print(",\"security_handler_revision\":{d}", .{revision});
        }
    }

    // Metadata
    try stdout.writeAll(",\"metadata\":{");
    var first_meta = true;

    if (metadata.title) |t| {
        if (!first_meta) try stdout.writeAll(",");
        try stdout.writeAll("\"title\":");
        try writeJsonString(stdout, t);
        first_meta = false;
    }
    if (metadata.author) |a| {
        if (!first_meta) try stdout.writeAll(",");
        try stdout.writeAll("\"author\":");
        try writeJsonString(stdout, a);
        first_meta = false;
    }
    if (metadata.subject) |s| {
        if (!first_meta) try stdout.writeAll(",");
        try stdout.writeAll("\"subject\":");
        try writeJsonString(stdout, s);
        first_meta = false;
    }
    if (metadata.keywords) |k| {
        if (!first_meta) try stdout.writeAll(",");
        try stdout.writeAll("\"keywords\":");
        try writeJsonString(stdout, k);
        first_meta = false;
    }
    if (metadata.creator) |c_| {
        if (!first_meta) try stdout.writeAll(",");
        try stdout.writeAll("\"creator\":");
        try writeJsonString(stdout, c_);
        first_meta = false;
    }
    if (metadata.producer) |p| {
        if (!first_meta) try stdout.writeAll(",");
        try stdout.writeAll("\"producer\":");
        try writeJsonString(stdout, p);
        first_meta = false;
    }
    if (metadata.creation_date) |cd| {
        if (!first_meta) try stdout.writeAll(",");
        try stdout.writeAll("\"creation_date\":");
        try writeJsonString(stdout, cd);
        first_meta = false;
    }
    if (metadata.mod_date) |md| {
        if (!first_meta) try stdout.writeAll(",");
        try stdout.writeAll("\"modification_date\":");
        try writeJsonString(stdout, md);
        first_meta = false;
    }
    if (metadata.pdfa_conformance) |pdfa| {
        if (!first_meta) try stdout.writeAll(",");
        var pdfa_buf: [32]u8 = undefined;
        const pdfa_str = std.fmt.bufPrint(&pdfa_buf, "{any}", .{pdfa}) catch "PDF/A";
        try stdout.writeAll("\"pdfa_conformance\":");
        try writeJsonString(stdout, pdfa_str);
        first_meta = false;
    }
    try stdout.writeAll("}");

    // Page details
    const page_count = doc.getPageCount();
    try stdout.writeAll(",\"pages_info\":[");
    var page_idx: usize = 0;
    while (page_idx < page_count) : (page_idx += 1) {
        if (page_idx > 0) try stdout.writeAll(",");

        if (doc.loadPage(page_idx)) |p| {
            var page = p;
            defer page.close();

            const width_pts = page.getWidth();
            const height_pts = page.getHeight();
            // Convert points to inches (72 points per inch)
            const width_inches = width_pts / 72.0;
            const height_inches = height_pts / 72.0;

            try stdout.print("{{\"page\":{d},\"width_pts\":{d:.2},\"height_pts\":{d:.2},\"width_inches\":{d:.2},\"height_inches\":{d:.2}}}", .{
                page_idx + 1,
                width_pts,
                height_pts,
                width_inches,
                height_inches,
            });
        } else |_| {
            try stdout.print("{{\"page\":{d},\"error\":\"could not load page\"}}", .{page_idx + 1});
        }
    }
    try stdout.writeAll("]");

    // Attachments
    const attachment_count = doc.getAttachmentCount();
    try stdout.print(",\"attachment_count\":{d}", .{attachment_count});

    if (attachment_count > 0) {
        try stdout.writeAll(",\"attachments\":[");

        var first_attachment = true;
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator) orelse continue;
            defer allocator.free(name);

            if (!first_attachment) try stdout.writeAll(",");
            first_attachment = false;

            try stdout.writeAll("{\"name\":");
            try writeJsonString(stdout, name);

            const is_xml = shared.hasXmlExtension(name);
            try stdout.print(",\"is_xml\":{s}}}", .{if (is_xml) "true" else "false"});
        }

        try stdout.writeAll("]");
    }

    try stdout.writeAll("}\n");
}

/// Write a JSON-escaped string with surrounding quotes
fn writeJsonString(writer: *std.Io.Writer, str: []const u8) !void {
    try writer.writeAll("\"");
    try textfmt.writeJsonEscaped(writer, str);
    try writer.writeAll("\"");
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig info [options] <input.pdf>
        \\
        \\Display PDF metadata and information.
        \\
        \\Options:
        \\  --json                Output as JSON
        \\  -P, --password <PW>   Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig info document.pdf
        \\  pdfzig info --json document.pdf
        \\  pdfzig info -P secret encrypted.pdf
        \\
    ) catch {};
}
