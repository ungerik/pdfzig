//! Info command - Display PDF metadata and information

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");
const main = @import("../main.zig");

pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *main.SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var input_path: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var show_help = false;

    while (arg_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                show_help = true;
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--password")) {
                password = arg_it.next();
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
                try printDocInfo(allocator, &d, path, true, stdout);
                d.close();
                return;
            } else {
                try stdout.print("File: {s}\n", .{path});
                try stdout.writeAll("Encrypted: Yes (password required to access)\n");
                try stdout.writeAll("\nUse -P <password> to provide the document password.\n");
                return;
            }
        } else {
            try stderr.print("Error: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        }
    };
    defer doc.close();

    try printDocInfo(allocator, &doc, path, doc.isEncrypted(), stdout);
}

fn printDocInfo(
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

pub fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig info [options] <input.pdf>
        \\
        \\Display PDF metadata and information.
        \\
        \\Options:
        \\  -P, --password <PW>   Password for encrypted PDFs
        \\  -h, --help            Show this help message
        \\
        \\Examples:
        \\  pdfzig info document.pdf
        \\  pdfzig info -P secret encrypted.pdf
        \\
    ) catch {};
}
