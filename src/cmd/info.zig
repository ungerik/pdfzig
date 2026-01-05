//! Info command - Display PDF metadata and information

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");

const OutputFormat = enum {
    text,
    json,
};

pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *main.SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
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
                try stderr.print("Unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else {
            input_path = arg;
        }
    }

    if (show_help) {
        printUsage(stdout);
        return;
    }

    const path = input_path orelse {
        try stderr.writeAll("Error: No input PDF file specified\n\n");
        try stderr.flush();
        printUsage(stdout);
        std.process.exit(1);
    };

    // Try to open without password first to check encryption
    var doc = pdfium.Document.open(path) catch |err| {
        if (err == pdfium.Error.PasswordRequired) {
            if (password) |pwd| {
                var d = pdfium.Document.openWithPassword(path, pwd) catch |e| {
                    try stderr.print("Error: {}\n", .{e});
                    try stderr.flush();
                    std.process.exit(1);
                };
                try printDocInfo(allocator, &d, path, true, output_format, stdout);
                d.close();
                return;
            } else {
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
            }
        } else {
            try stderr.print("Error: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        }
    };
    defer doc.close();

    try printDocInfo(allocator, &doc, path, doc.isEncrypted(), output_format, stdout);
}

fn printDocInfo(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    path: []const u8,
    encrypted: bool,
    format: OutputFormat,
    stdout: *std.Io.Writer,
) !void {
    switch (format) {
        .text => try printDocInfoText(allocator, doc, path, encrypted, stdout),
        .json => try printDocInfoJson(allocator, doc, path, encrypted, stdout),
    }
}

fn printDocInfoText(
    allocator: std.mem.Allocator,
    doc: *pdfium.Document,
    path: []const u8,
    encrypted: bool,
    stdout: *std.Io.Writer,
) !void {
    try stdout.print("File: {s}\n", .{path});
    try stdout.print("Pages: {d}\n", .{doc.getPageCount()});

    if (doc.getFileVersion()) |ver| {
        const major = ver / 10;
        const minor = ver % 10;
        try stdout.print("PDF Version: {d}.{d}\n", .{ major, minor });
    }

    try stdout.print("Encrypted: {s}\n", .{if (encrypted) "Yes" else "No"});

    if (encrypted) {
        const revision = doc.getSecurityHandlerRevision();
        if (revision >= 0) {
            try stdout.print("Security Handler Revision: {d}\n", .{revision});
        }
    }

    // Metadata
    var metadata = doc.getMetadata(allocator);
    defer metadata.deinit(allocator);

    try stdout.writeAll("\nMetadata:\n");
    if (metadata.title) |t| try stdout.print("  Title: {s}\n", .{t});
    if (metadata.author) |a| try stdout.print("  Author: {s}\n", .{a});
    if (metadata.subject) |s| try stdout.print("  Subject: {s}\n", .{s});
    if (metadata.keywords) |k| try stdout.print("  Keywords: {s}\n", .{k});
    if (metadata.creator) |c_| try stdout.print("  Creator: {s}\n", .{c_});
    if (metadata.producer) |p| try stdout.print("  Producer: {s}\n", .{p});
    if (metadata.creation_date) |cd| try stdout.print("  Creation Date: {s}\n", .{cd});
    if (metadata.mod_date) |md| try stdout.print("  Modification Date: {s}\n", .{md});

    // Attachments
    const attachment_count = doc.getAttachmentCount();
    if (attachment_count > 0) {
        try stdout.print("\nAttachments: {d}\n", .{attachment_count});

        var xml_count: u32 = 0;
        var it = doc.attachments();
        while (it.next()) |attachment| {
            const name = attachment.getName(allocator) orelse continue;
            defer allocator.free(name);

            const is_xml = attachment.isXml(allocator);
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
    doc: *pdfium.Document,
    path: []const u8,
    encrypted: bool,
    stdout: *std.Io.Writer,
) !void {
    try stdout.writeAll("{");

    // File path
    try stdout.writeAll("\"file\":");
    try writeJsonString(stdout, path);

    // Page count
    try stdout.print(",\"pages\":{d}", .{doc.getPageCount()});

    // PDF version
    if (doc.getFileVersion()) |ver| {
        const major = ver / 10;
        const minor = ver % 10;
        try stdout.print(",\"pdf_version\":\"{d}.{d}\"", .{ major, minor });
    }

    // Encryption
    try stdout.print(",\"encrypted\":{s}", .{if (encrypted) "true" else "false"});

    if (encrypted) {
        const revision = doc.getSecurityHandlerRevision();
        if (revision >= 0) {
            try stdout.print(",\"security_handler_revision\":{d}", .{revision});
        }
    }

    // Metadata
    var metadata = doc.getMetadata(allocator);
    defer metadata.deinit(allocator);

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
    try stdout.writeAll("}");

    // Page details
    const page_count = doc.getPageCount();
    try stdout.writeAll(",\"pages_info\":[");
    var page_idx: u32 = 0;
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

            const is_xml = attachment.isXml(allocator);
            try stdout.print(",\"is_xml\":{s}}}", .{if (is_xml) "true" else "false"});
        }

        try stdout.writeAll("]");
    }

    try stdout.writeAll("}\n");
}

/// Write a JSON-escaped string
fn writeJsonString(writer: *std.Io.Writer, str: []const u8) !void {
    try writer.writeAll("\"");
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeAll("\"");
}

pub fn printUsage(stdout: *std.Io.Writer) void {
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
