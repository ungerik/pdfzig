//! HTTP route handling for WebUI

const std = @import("std");
const state_mod = @import("state.zig");
const GlobalState = state_mod.GlobalState;
const PageId = state_mod.PageId;
const assets = @import("assets.zig");
const page_renderer = @import("page_renderer.zig");
const operations = @import("operations.zig");
const pdfium = @import("../pdfium/pdfium.zig");

/// Dispatch HTTP request to appropriate handler
pub fn dispatch(
    global_state: *GlobalState,
    connection: std.net.Server.Connection,
    method: []const u8,
    target: []const u8,
    readonly: bool,
) !void {
    const is_post = std.mem.eql(u8, method, "POST");

    // Route static assets (GET only)
    if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/index.html")) {
        return serveHTML(connection, assets.index_html, readonly);
    } else if (std.mem.eql(u8, target, "/style.css")) {
        return serveCSS(connection, assets.style_css);
    } else if (std.mem.eql(u8, target, "/app.js")) {
        return serveJS(connection, assets.app_js);
    } else if (std.mem.eql(u8, target, "/favicon.ico")) {
        return serveStaticFile(connection, assets.favicon_ico, "image/x-icon");
    } else if (std.mem.eql(u8, target, "/favicon-16x16.png")) {
        return serveStaticFile(connection, assets.favicon_16x16_png, "image/png");
    } else if (std.mem.eql(u8, target, "/favicon-32x32.png")) {
        return serveStaticFile(connection, assets.favicon_32x32_png, "image/png");
    } else if (std.mem.eql(u8, target, "/favicon-48x48.png")) {
        return serveStaticFile(connection, assets.favicon_48x48_png, "image/png");
    } else if (std.mem.eql(u8, target, "/apple-touch-icon.png")) {
        return serveStaticFile(connection, assets.apple_touch_icon_png, "image/png");
    } else if (std.mem.eql(u8, target, "/android-chrome-192x192.png")) {
        return serveStaticFile(connection, assets.android_chrome_192x192_png, "image/png");
    } else if (std.mem.eql(u8, target, "/android-chrome-512x512.png")) {
        return serveStaticFile(connection, assets.android_chrome_512x512_png, "image/png");
    } else if (std.mem.eql(u8, target, "/site.webmanifest")) {
        return serveStaticFile(connection, assets.site_webmanifest, "application/manifest+json");
    }

    // API routes
    if (std.mem.eql(u8, target, "/api/documents")) {
        return serveDocumentList(global_state, connection);
    } else if (std.mem.eql(u8, target, "/api/documents/status")) {
        return serveDocumentStatus(global_state, connection);
    } else if (std.mem.eql(u8, target, "/api/pages/list")) {
        return servePageList(global_state, connection);
    } else if (std.mem.eql(u8, target, "/api/reset")) {
        if (!is_post) return serveMethodNotAllowed(connection);
        if (readonly) return serveForbidden(connection);
        return handleReset(global_state, connection);
    } else if (std.mem.eql(u8, target, "/api/clear")) {
        if (!is_post) return serveMethodNotAllowed(connection);
        if (readonly) return serveForbidden(connection);
        return handleClear(global_state, connection);
    } else if (std.mem.eql(u8, target, "/api/settings/dpi")) {
        if (!is_post) return serveMethodNotAllowed(connection);
        return handleUpdateDPI(global_state, connection);
    } else if (std.mem.eql(u8, target, "/api/pages/reorder")) {
        if (!is_post) return serveMethodNotAllowed(connection);
        if (readonly) return serveForbidden(connection);
        return handleReorder(global_state, connection);
    } else if (std.mem.eql(u8, target, "/api/documents/upload")) {
        if (!is_post) return serveMethodNotAllowed(connection);
        if (readonly) return serveForbidden(connection);
        return handleUpload(global_state, connection);
    } else if (std.mem.eql(u8, target, "/api/documents/download-all")) {
        return handleDownloadAll(global_state, connection);
    } else if (std.mem.startsWith(u8, target, "/api/documents/")) {
        // Handle /api/documents/{id}/{action}
        const path_after_docs = target["/api/documents/".len..];
        var parts = std.mem.splitScalar(u8, path_after_docs, '/');
        const doc_id_str = parts.next() orelse return serve404(connection);
        const action = parts.next() orelse return serve404(connection);

        // Parse document ID
        const doc_id = std.fmt.parseInt(u32, doc_id_str, 10) catch return serve404(connection);

        if (std.mem.eql(u8, action, "download")) {
            return handleDownloadDocument(global_state, connection, doc_id);
        } else if (std.mem.eql(u8, action, "delete-all")) {
            if (!is_post) return serveMethodNotAllowed(connection);
            if (readonly) return serveForbidden(connection);
            return handleDeleteAllPages(global_state, connection, doc_id);
        } else if (std.mem.eql(u8, action, "split")) {
            if (!is_post) return serveMethodNotAllowed(connection);
            if (readonly) return serveForbidden(connection);
            const split_after = parts.next() orelse return serve404(connection);
            const page_idx = std.fmt.parseInt(u32, split_after, 10) catch return serve404(connection);
            return handleSplitDocument(global_state, connection, doc_id, page_idx);
        }

        return serve404(connection);
    } else if (std.mem.startsWith(u8, target, "/api/pages/")) {
        // Parse page ID from URL like /api/pages/0-1/thumbnail or /api/pages/0-1/rotate
        const path_after_pages = target["/api/pages/".len..];
        var parts = std.mem.splitScalar(u8, path_after_pages, '/');
        const page_id_str = parts.next() orelse return serve404(connection);
        const action = parts.next() orelse return serve404(connection);

        const page_id = PageId.parse(page_id_str) catch return serve404(connection);

        if (std.mem.eql(u8, action, "thumbnail")) {
            return serveThumbnail(global_state, connection, page_id);
        } else if (std.mem.eql(u8, action, "rotate")) {
            if (!is_post) return serveMethodNotAllowed(connection);
            if (readonly) return serveForbidden(connection);
            return handleRotate(global_state, connection, page_id);
        } else if (std.mem.eql(u8, action, "mirror")) {
            if (!is_post) return serveMethodNotAllowed(connection);
            if (readonly) return serveForbidden(connection);
            return handleMirror(global_state, connection, page_id);
        } else if (std.mem.eql(u8, action, "delete")) {
            if (!is_post) return serveMethodNotAllowed(connection);
            if (readonly) return serveForbidden(connection);
            return handleDelete(global_state, connection, page_id);
        } else if (std.mem.eql(u8, action, "revert")) {
            if (!is_post) return serveMethodNotAllowed(connection);
            if (readonly) return serveForbidden(connection);
            return handleRevert(global_state, connection, page_id);
        }

        return serve404(connection);
    } else if (std.mem.startsWith(u8, target, "/api/")) {
        return serveNotImplemented(connection, target);
    }

    // 404 for everything else
    return serve404(connection);
}

/// Serve HTML with template replacement for readonly flag
fn serveHTML(connection: std.net.Server.Connection, html_template: []const u8, readonly: bool) !void {
    // Use arena for temporary HTML replacement
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    // Replace {READONLY} placeholder
    const readonly_str = if (readonly) "true" else "false";
    const html = try std.mem.replaceOwned(u8, temp_allocator, html_template, "{READONLY}", readonly_str);

    // Write headers and body separately to avoid large stack buffer
    var buffer: [256]u8 = undefined;
    const response_header = try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{html.len});

    _ = try connection.stream.write(response_header);
    _ = try connection.stream.write(html);
}

/// Serve static file with specified content type
fn serveStaticFile(connection: std.net.Server.Connection, content: []const u8, content_type: []const u8) !void {
    var buffer: [256]u8 = undefined;

    // Only add charset for text-based content types
    const add_charset = std.mem.startsWith(u8, content_type, "text/") or
        std.mem.startsWith(u8, content_type, "application/javascript") or
        std.mem.startsWith(u8, content_type, "application/json") or
        std.mem.startsWith(u8, content_type, "application/manifest+json");

    const response_str = if (add_charset)
        try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n", .{ content_type, content.len })
    else
        try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n", .{ content_type, content.len });

    _ = try connection.stream.write(response_str);
    _ = try connection.stream.write(content);
}

/// Serve CSS file
fn serveCSS(connection: std.net.Server.Connection, css: []const u8) !void {
    return serveStaticFile(connection, css, "text/css");
}

/// Serve JavaScript file
fn serveJS(connection: std.net.Server.Connection, js: []const u8) !void {
    return serveStaticFile(connection, js, "application/javascript");
}

/// Serve 404 Not Found
fn serve404(connection: std.net.Server.Connection) !void {
    const html = "<html><body><h1>404 Not Found</h1></body></html>";

    var buffer: [512]u8 = undefined;
    const response =
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{s}";

    const response_str = try std.fmt.bufPrint(&buffer, response, .{ html.len, html });
    _ = try connection.stream.write(response_str);
}

/// Serve 501 Not Implemented for API endpoints
fn serveNotImplemented(connection: std.net.Server.Connection, endpoint: []const u8) !void {
    _ = endpoint;

    const html = "<html><body><h1>501 Not Implemented</h1><p>This API endpoint is not yet implemented.</p></body></html>";

    var buffer: [512]u8 = undefined;
    const response =
        "HTTP/1.1 501 Not Implemented\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{s}";

    const response_str = try std.fmt.bufPrint(&buffer, response, .{ html.len, html });
    _ = try connection.stream.write(response_str);
}

/// Serve JSON list of documents
fn serveDocumentList(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build JSON response
    var json = std.array_list.Managed(u8).init(allocator);
    var json_writer = json.writer();

    try json_writer.writeAll("{\"documents\":[");

    for (global_state.documents.items, 0..) |doc, i| {
        if (i > 0) try json_writer.writeAll(",");

        try json_writer.print(
            "{{\"id\":{d},\"filename\":\"{s}\",\"page_count\":{d},\"modified\":{s}}}",
            .{
                doc.id,
                doc.filename,
                doc.pages.items.len,
                if (doc.modified) "true" else "false",
            },
        );
    }

    try json_writer.writeAll("]}");

    const json_str = json.items;

    // Send response
    var buffer: [256]u8 = undefined;
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const response_str = try std.fmt.bufPrint(&buffer, response, .{json_str.len});
    _ = try connection.stream.write(response_str);
    _ = try connection.stream.write(json_str);
}

/// Serve document status (for UI state updates)
fn serveDocumentStatus(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Check if any document has modifications
    var has_modifications = false;
    for (global_state.documents.items) |doc| {
        if (doc.modified) {
            has_modifications = true;
            break;
        }
    }

    const doc_count = global_state.documents.items.len;

    // Build JSON response
    const json_str = try std.fmt.allocPrint(
        allocator,
        "{{\"hasModifications\":{s},\"documentCount\":{d}}}",
        .{ if (has_modifications) "true" else "false", doc_count },
    );
    // Arena allocator cleans up automatically

    try serveJson(connection, json_str);
}

/// Serve HTML fragment with all pages
fn servePageList(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build HTML response
    var html = std.array_list.Managed(u8).init(allocator);
    var html_writer = html.writer();

    // Check if we have any documents
    if (global_state.documents.items.len == 0) {
        try html_writer.writeAll(
            \\<div id="drop-zone" style="display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 60vh; border: 3px dashed #666; border-radius: 10px; margin: 20px; padding: 40px; text-align: center;">
            \\  <p style="font-size: 1.5em; margin-bottom: 20px;">No PDF documents loaded</p>
            \\  <p style="margin-bottom: 30px;">Drop PDF files here or</p>
            \\  <button onclick="document.getElementById('file-input').click()" style="padding: 15px 30px; font-size: 1.2em; cursor: pointer; background: #4a9eff; color: white; border: none; border-radius: 5px;">
            \\    📁 Upload PDF Files
            \\  </button>
            \\</div>
        );
    } else {
        // Wrapper for flowing layout
        try html_writer.writeAll(
            \\<div style="display: flex; flex-wrap: wrap; gap: 10px; align-items: flex-start;">
        );

        // Render each document as a group
        for (global_state.documents.items) |doc| {
            const color = doc.color;
            try html_writer.print(
                \\<div style="position: relative; display: inline-block; margin: 20px;">
                \\  <button onclick="window.location.href='/api/documents/{d}/download';" style="position: absolute; left: -40px; top: 50%; transform: translateY(-50%); background: rgba(0,150,0,0.9); color: white; border: none; border-radius: 8px; width: 35px; height: 60px; cursor: pointer; font-size: 1.2em; display: flex; align-items: center; justify-content: center; z-index: 5;" title="Download {s}">💾</button>
                \\  <div class="document-group" title="{s}" style="display: inline-flex; padding: 20px; border-radius: 20px; background-color: rgb({d},{d},{d});">
                \\    <div class="pages-grid" style="display: flex; flex-wrap: wrap; gap: 10px;">
            , .{ doc.id, doc.filename, doc.filename, color[0], color[1], color[2] });

            // Render each page
            for (doc.pages.items, 0..) |page, page_idx| {
                const page_id = page.id;
                const deleted_attr = if (page.modifications.deleted) "true" else "false";
                const modified_attr = if (!page.modifications.isEmpty()) "true" else "false";

                // Build modification description for tooltip
                const mod_desc = try page.modifications.describe(allocator);
                defer allocator.free(mod_desc);

                try html_writer.print(
                    \\<div class="page-card" data-page-id="{d}-{d}" data-deleted="{s}" data-modified="{s}" draggable="true" onclick="openModal('/api/pages/{d}-{d}/fullsize?dpi=150')" style="position: relative; display: inline-block;">
                    \\  <img class="page-thumbnail" src="/api/pages/{d}-{d}/thumbnail" alt="Page {d}">
                    \\  <div class="page-overlay" style="position: absolute; inset: 0; opacity: 0; transition: opacity 0.2s; pointer-events: none;">
                    \\    <button onclick="event.stopPropagation(); rotatePage('{d}-{d}', -90);" style="position: absolute; top: 2%; left: 2%; pointer-events: auto; background: rgba(0,0,0,0.8); color: white; border: none; border-radius: 50%; width: 15%; height: 15%; aspect-ratio: 1; cursor: pointer; font-size: 1em; display: flex; align-items: center; justify-content: center;" title="Rotate left">↺</button>
                    \\    <button onclick="event.stopPropagation(); rotatePage('{d}-{d}', 90);" style="position: absolute; top: 2%; right: 2%; pointer-events: auto; background: rgba(0,0,0,0.8); color: white; border: none; border-radius: 50%; width: 15%; height: 15%; aspect-ratio: 1; cursor: pointer; font-size: 1em; display: flex; align-items: center; justify-content: center;" title="Rotate right">↻</button>
                    \\    <button onclick="event.stopPropagation(); deletePage('{d}-{d}');" style="position: absolute; top: 2%; left: 50%; transform: translateX(-50%); pointer-events: auto; background: rgba(200,0,0,0.8); color: white; border: none; border-radius: 50%; width: 15%; height: 15%; aspect-ratio: 1; cursor: pointer; font-size: 1em; display: flex; align-items: center; justify-content: center;" title="Delete">🗑</button>
                    \\    <button onclick="event.stopPropagation(); mirrorPage('{d}-{d}', 'updown');" style="position: absolute; right: 2%; top: 50%; transform: translateY(-50%); pointer-events: auto; background: rgba(0,0,0,0.8); color: white; border: none; border-radius: 50%; width: 15%; height: 15%; aspect-ratio: 1; cursor: pointer; font-size: 1em; display: flex; align-items: center; justify-content: center;" title="Mirror vertical">⇅</button>
                    \\    <button onclick="event.stopPropagation(); mirrorPage('{d}-{d}', 'leftright');" style="position: absolute; bottom: 2%; left: 35%; transform: translateX(-50%); pointer-events: auto; background: rgba(0,0,0,0.8); color: white; border: none; border-radius: 50%; width: 15%; height: 15%; aspect-ratio: 1; cursor: pointer; font-size: 1em; display: flex; align-items: center; justify-content: center;" title="Mirror horizontal">⇄</button>
                    \\    <button onclick="event.stopPropagation(); window.location.href='/api/pages/{d}-{d}/download';" style="position: absolute; bottom: 2%; right: 35%; transform: translateX(50%); pointer-events: auto; background: rgba(0,100,0,0.8); color: white; border: none; border-radius: 50%; width: 15%; height: 15%; aspect-ratio: 1; cursor: pointer; font-size: 1em; display: flex; align-items: center; justify-content: center;" title="Download page">💾</button>
                    \\  </div>
                    \\</div>
                , .{
                    page_id.doc_id,
                    page_id.page_num,
                    deleted_attr,
                    modified_attr,
                    page_id.doc_id,
                    page_id.page_num,
                    page_id.doc_id,
                    page_id.page_num,
                    page.original_index + 1,
                    page_id.doc_id,
                    page_id.page_num,
                    page_id.doc_id,
                    page_id.page_num,
                    page_id.doc_id,
                    page_id.page_num,
                    page_id.doc_id,
                    page_id.page_num,
                    page_id.doc_id,
                    page_id.page_num,
                    page_id.doc_id,
                    page_id.page_num,
                });

                // Add revert button if page is modified (and not deleted)
                if (!page.modifications.isEmpty() and !page.modifications.deleted) {
                    try html_writer.print(
                        \\<button class="revert-btn" onclick="event.stopPropagation(); revertPage('{d}-{d}');" style="position: absolute; bottom: 8px; right: 8px; pointer-events: auto; background: rgba(255,165,0,0.9); color: white; border: none; border-radius: 4px; padding: 6px 10px; cursor: pointer; font-size: 0.85em; z-index: 10;" title="Revert: {s}">↶ Revert</button>
                    , .{
                        page_id.doc_id,
                        page_id.page_num,
                        mod_desc,
                    });
                }

                // Add split indicator between pages (except after the last page)
                if (page_idx < doc.pages.items.len - 1) {
                    try html_writer.print(
                        \\<div class="split-indicator" style="display: inline-flex; align-items: center; justify-content: center; width: 30px; height: auto; margin: 0 5px; opacity: 0.3; transition: opacity 0.2s; cursor: pointer;" onmouseover="this.style.opacity='1'" onmouseout="this.style.opacity='0.3'" onclick="if(confirm('Split document after page {d}?')) {{ fetch('/api/documents/{d}/split/{d}', {{method:'POST',headers:{{'X-Client-ID':clientId}}}}).then(()=>htmx.trigger(document.body,'pageUpdate')); }}" title="Split document here">
                        \\  <svg width="24" height="60" viewBox="0 0 24 60" style="fill: white; stroke: white; stroke-width: 1;">
                        \\    <line x1="12" y1="0" x2="12" y2="25" stroke-dasharray="3,3"/>
                        \\    <path d="M12 30 L8 26 L10 26 L10 22 L14 22 L14 26 L16 26 Z"/>
                        \\    <line x1="12" y1="35" x2="12" y2="60" stroke-dasharray="3,3"/>
                        \\  </svg>
                        \\</div>
                    , .{ page_idx + 1, doc.id, page_idx });
                }
            }

            try html_writer.print(
                \\    </div>
                \\  </div>
                \\  <button onclick="if(confirm('Delete all pages in {s}?')) {{ fetch('/api/documents/{d}/delete-all', {{method:'POST',headers:{{'X-Client-ID':clientId}}}}).then(()=>htmx.trigger(document.body,'pageUpdate')); }}" style="position: absolute; right: -40px; top: 50%; transform: translateY(-50%); background: rgba(200,0,0,0.9); color: white; border: none; border-radius: 8px; width: 35px; height: 60px; cursor: pointer; font-size: 1.2em; display: flex; align-items: center; justify-content: center; z-index: 5;" title="Delete all pages in {s}">🗑</button>
                \\</div>
            , .{ doc.filename, doc.id, doc.filename });
        }

        // Close wrapper
        try html_writer.writeAll(
            \\</div>
        );
    }

    const html_str = html.items;

    // Send response
    var buffer: [256]u8 = undefined;
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const response_str = try std.fmt.bufPrint(&buffer, response, .{html_str.len});
    _ = try connection.stream.write(response_str);
    _ = try connection.stream.write(html_str);
}

/// Serve PNG thumbnail for a page
fn serveThumbnail(global_state: *GlobalState, connection: std.net.Server.Connection, page_id: PageId) !void {
    const allocator = std.heap.page_allocator;

    // Get document and page
    const doc = global_state.getDocument(page_id.doc_id) orelse return serve404(connection);
    if (page_id.page_num >= doc.pages.items.len) return serve404(connection);

    const page_state = &doc.pages.items[page_id.page_num];

    // Render thumbnail (cached)
    const png_bytes = page_renderer.renderThumbnail(
        allocator,
        page_state,
        doc,
        global_state.thumbnail_dpi,
    ) catch |err| {
        std.debug.print("Error rendering thumbnail: {}\n", .{err});
        return serve404(connection);
    };

    // Send PNG response
    var buffer: [256]u8 = undefined;
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: image/png\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Cache-Control: public, max-age=3600\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const response_str = try std.fmt.bufPrint(&buffer, response, .{png_bytes.len});
    try connection.stream.writeAll(response_str);
    try connection.stream.writeAll(png_bytes);
}

/// Parse JSON request body
fn parseJsonBody(comptime T: type, connection: std.net.Server.Connection, allocator: std.mem.Allocator) !std.json.Parsed(T) {
    var body_buffer: [1024]u8 = undefined;
    const bytes_read = try connection.stream.read(&body_buffer);
    const body = body_buffer[0..bytes_read];
    return std.json.parseFromSlice(T, allocator, body, .{});
}

/// Handle rotate page request
fn handleRotate(global_state: *GlobalState, connection: std.net.Server.Connection, page_id: PageId) !void {
    const allocator = std.heap.page_allocator;

    // Parse JSON: {"degrees": 90}
    const parsed = parseJsonBody(
        struct { degrees: i32 },
        connection,
        allocator,
    ) catch {
        return serveError(connection, .bad_request, "Invalid JSON");
    };
    defer parsed.deinit();

    // Perform rotation
    operations.rotatePage(global_state, page_id.doc_id, page_id.page_num, parsed.value.degrees) catch {
        return serveError(connection, .internal_server_error, "Rotation failed");
    };

    // Send success response
    try serveJson(connection, "{\"success\":true}");
}

/// Handle mirror page request
fn handleMirror(global_state: *GlobalState, connection: std.net.Server.Connection, page_id: PageId) !void {
    const allocator = std.heap.page_allocator;

    // Parse JSON: {"direction": "updown" | "leftright"}
    const parsed = parseJsonBody(
        struct { direction: []const u8 },
        connection,
        allocator,
    ) catch {
        return serveError(connection, .bad_request, "Invalid JSON");
    };
    defer parsed.deinit();

    const direction: operations.MirrorDirection = blk: {
        if (std.mem.eql(u8, parsed.value.direction, "updown")) break :blk .updown;
        if (std.mem.eql(u8, parsed.value.direction, "leftright")) break :blk .leftright;
        return serveError(connection, .bad_request, "Invalid direction");
    };

    // Perform mirror
    operations.mirrorPage(global_state, page_id.doc_id, page_id.page_num, direction) catch {
        return serveError(connection, .internal_server_error, "Mirror failed");
    };

    // Send success response
    try serveJson(connection, "{\"success\":true}");
}

/// Handle delete page request
fn handleDelete(global_state: *GlobalState, connection: std.net.Server.Connection, page_id: PageId) !void {
    // Perform delete (toggle)
    operations.deletePage(global_state, page_id.doc_id, page_id.page_num) catch {
        return serveError(connection, .internal_server_error, "Delete failed");
    };

    // Send success response
    try serveJson(connection, "{\"success\":true}");
}

/// Handle revert page request
fn handleRevert(global_state: *GlobalState, connection: std.net.Server.Connection, page_id: PageId) !void {
    // Perform revert
    operations.revertPage(global_state, page_id.doc_id, page_id.page_num) catch {
        return serveError(connection, .internal_server_error, "Revert failed");
    };

    // Send success response
    try serveJson(connection, "{\"success\":true}");
}

/// Handle reorder pages request
fn handleReorder(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    const allocator = std.heap.page_allocator;

    // Parse JSON: {"source": "0-1", "target": "0-2"}
    const parsed = parseJsonBody(
        struct { source: []const u8, target: []const u8 },
        connection,
        allocator,
    ) catch {
        return serveError(connection, .bad_request, "Invalid JSON");
    };
    defer parsed.deinit();

    const source_id = PageId.parse(parsed.value.source) catch {
        return serveError(connection, .bad_request, "Invalid source page ID");
    };

    const target_id = PageId.parse(parsed.value.target) catch {
        return serveError(connection, .bad_request, "Invalid target page ID");
    };

    // Perform reorder
    operations.reorderPages(global_state, source_id, target_id) catch {
        return serveError(connection, .internal_server_error, "Reorder failed");
    };

    // Send success response
    try serveJson(connection, "{\"success\":true}");
}

/// Handle update DPI request
fn handleUpdateDPI(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    const allocator = std.heap.page_allocator;

    // Parse JSON: {"dpi": 96}
    const parsed = parseJsonBody(
        struct { dpi: f64 },
        connection,
        allocator,
    ) catch {
        return serveError(connection, .bad_request, "Invalid JSON");
    };
    defer parsed.deinit();

    // Update DPI
    operations.updateDPI(global_state, parsed.value.dpi) catch {
        return serveError(connection, .internal_server_error, "DPI update failed");
    };

    // Send success response
    try serveJson(connection, "{\"success\":true}");
}

/// Handle reset all request
fn handleReset(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    operations.resetAll(global_state) catch {
        return serveError(connection, .internal_server_error, "Reset failed");
    };

    try serveJson(connection, "{\"success\":true}");
}

/// Handle clear all request
fn handleClear(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    operations.clearAll(global_state) catch {
        return serveError(connection, .internal_server_error, "Clear failed");
    };

    try serveJson(connection, "{\"success\":true}");
}

/// Handle file upload request (multipart/form-data)
fn handleUpload(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    // Use arena allocator for upload to ensure cleanup
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Read entire request body (up to 50MB for PDF uploads)
    const max_upload_size = 50 * 1024 * 1024;
    const body_buffer = try allocator.alloc(u8, max_upload_size);

    const bytes_read = try connection.stream.read(body_buffer);
    const body = body_buffer[0..bytes_read];

    // Simple multipart boundary extraction (look for PDF magic bytes)
    const pdf_start = std.mem.indexOf(u8, body, "%PDF-") orelse {
        return serveError(connection, .bad_request, "No PDF data found");
    };

    // Find end of PDF (look for %%EOF)
    const pdf_end_marker = std.mem.lastIndexOf(u8, body, "%%EOF") orelse {
        return serveError(connection, .bad_request, "Invalid PDF data");
    };
    const pdf_end = pdf_end_marker + "%%EOF".len;

    const pdf_data = body[pdf_start..pdf_end];

    // Extract filename from Content-Disposition header in multipart data
    var filename: []const u8 = "uploaded.pdf";
    if (std.mem.indexOf(u8, body[0..pdf_start], "filename=\"")) |fn_start| {
        const fn_data = body[fn_start + "filename=\"".len ..];
        if (std.mem.indexOf(u8, fn_data, "\"")) |fn_end| {
            filename = fn_data[0..fn_end];
        }
    }

    // Save to temporary file
    const temp_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/pdfzig-upload-{d}.pdf",
        .{std.time.milliTimestamp()},
    );
    // No defer needed - arena allocator cleans up automatically

    const file = try std.fs.cwd().createFile(temp_path, .{});
    defer file.close();
    try file.writeAll(pdf_data);

    // Add document to state
    _ = global_state.addDocument(.uploaded, temp_path, filename) catch {
        std.fs.cwd().deleteFile(temp_path) catch {};
        return serveError(connection, .internal_server_error, "Failed to load PDF");
    };

    // Clean up temp file after a delay (document has already read it into memory)
    std.fs.cwd().deleteFile(temp_path) catch {};

    global_state.notifyChange();

    try serveJson(connection, "{\"success\":true}");
}

/// Send a PDF document as download response
fn sendPdfDownload(
    connection: std.net.Server.Connection,
    doc: *state_mod.DocumentState,
    allocator: std.mem.Allocator,
) !void {
    // Save document to temporary file
    const temp_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/pdfzig-download-{d}.pdf",
        .{std.time.milliTimestamp()},
    );
    // Arena allocator cleans up automatically

    // Save with modifications applied
    try doc.doc.saveWithVersion(temp_path, null);
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Read file to serve
    const file = try std.fs.cwd().openFile(temp_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const pdf_data = try file.readToEndAlloc(allocator, file_size);
    // Arena allocator cleans up automatically

    // Send PDF with appropriate headers
    const response_header = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/pdf\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Content-Disposition: attachment; filename=\"{s}\"\r\n" ++
            "\r\n",
        .{ pdf_data.len, doc.filename },
    );
    // Arena allocator cleans up automatically

    try connection.stream.writeAll(response_header);
    try connection.stream.writeAll(pdf_data);
}

/// Handle download all documents request
fn handleDownloadAll(global_state: *GlobalState, connection: std.net.Server.Connection) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    global_state.lock();
    defer global_state.unlock();

    if (global_state.documents.items.len == 0) {
        return serveError(connection, .not_found, "No documents to download");
    }

    // For now, only support single document download
    // TODO: Implement ZIP/tar.gz for multiple documents
    if (global_state.documents.items.len > 1) {
        return serveError(connection, .not_implemented, "Multi-document download not yet supported");
    }

    const doc = global_state.documents.items[0];
    try sendPdfDownload(connection, doc, allocator);
}

/// Handle download single document request
fn handleDownloadDocument(global_state: *GlobalState, connection: std.net.Server.Connection, doc_id: u32) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    global_state.lock();
    defer global_state.unlock();

    const doc = global_state.getDocument(doc_id) orelse {
        return serveError(connection, .not_found, "Document not found");
    };

    try sendPdfDownload(connection, doc, allocator);
}

/// Handle delete all pages in a document
fn handleDeleteAllPages(global_state: *GlobalState, connection: std.net.Server.Connection, doc_id: u32) !void {
    global_state.lock();
    defer global_state.unlock();

    const doc = global_state.getDocument(doc_id) orelse {
        return serveError(connection, .not_found, "Document not found");
    };

    // Mark all pages as deleted
    for (doc.pages.items) |*page| {
        page.modifications.deleted = true;
    }

    doc.modified = true;
    global_state.notifyChange();

    try serveJson(connection, "{\"success\":true}");
}

/// Handle split document at specified page
fn handleSplitDocument(global_state: *GlobalState, connection: std.net.Server.Connection, doc_id: u32, split_after_page_idx: u32) !void {
    // Use arena allocator for proper cleanup
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    global_state.lock();
    defer global_state.unlock();

    const doc = global_state.getDocument(doc_id) orelse {
        return serveError(connection, .not_found, "Document not found");
    };

    if (split_after_page_idx >= doc.pages.items.len - 1) {
        return serveError(connection, .bad_request, "Invalid split position");
    }

    // Save current document to temp file
    const temp_path1 = try std.fmt.allocPrint(
        allocator,
        "/tmp/pdfzig-split1-{d}.pdf",
        .{std.time.milliTimestamp()},
    );
    // Arena allocator cleans up automatically

    try doc.doc.saveWithVersion(temp_path1, null);
    defer std.fs.cwd().deleteFile(temp_path1) catch {};

    // Create two new documents from the split
    const temp_path2 = try std.fmt.allocPrint(
        allocator,
        "/tmp/pdfzig-split2-{d}.pdf",
        .{std.time.milliTimestamp() + 1},
    );
    // Arena allocator cleans up automatically

    // Load first part (pages 0..split_after_page_idx)
    var doc1 = try pdfium.Document.open(temp_path1);
    defer doc1.close();

    // Delete pages after split point in doc1
    var i: u32 = @intCast(doc.pages.items.len - 1);
    while (i > split_after_page_idx) : (i -= 1) {
        try doc1.deletePage(i);
    }
    try doc1.saveWithVersion(temp_path1, null);

    // Load second part (pages split_after_page_idx+1..end)
    var doc2 = try pdfium.Document.open(temp_path1);
    defer doc2.close();

    // Delete pages before split point in doc2
    i = 0;
    while (i <= split_after_page_idx) : (i += 1) {
        try doc2.deletePage(0); // Always delete first page
    }
    try doc2.saveWithVersion(temp_path2, null);
    defer std.fs.cwd().deleteFile(temp_path2) catch {};

    // Generate filenames for split documents
    const filename1 = try std.fmt.allocPrint(
        allocator,
        "{s}_part1.pdf",
        .{doc.filename[0 .. std.mem.lastIndexOf(u8, doc.filename, ".pdf") orelse doc.filename.len]},
    );
    // Arena allocator cleans up automatically

    const filename2 = try std.fmt.allocPrint(
        allocator,
        "{s}_part2.pdf",
        .{doc.filename[0 .. std.mem.lastIndexOf(u8, doc.filename, ".pdf") orelse doc.filename.len]},
    );
    // Arena allocator cleans up automatically

    // Remove original document - find index by ID
    var doc_index: ?usize = null;
    for (global_state.documents.items, 0..) |d, idx| {
        if (d.id == doc_id) {
            doc_index = idx;
            break;
        }
    }

    if (doc_index) |idx| {
        doc.deinit();
        _ = global_state.documents.orderedRemove(idx);
        global_state.allocator.destroy(doc);
    } else {
        return serveError(connection, .internal_server_error, "Document index not found");
    }

    // Add split documents
    _ = try global_state.addDocument(.uploaded, temp_path1, filename1);
    _ = try global_state.addDocument(.uploaded, temp_path2, filename2);

    global_state.notifyChange();

    try serveJson(connection, "{\"success\":true}");
}

/// Send JSON response
fn serveJson(connection: std.net.Server.Connection, json: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const response_str = try std.fmt.bufPrint(&buffer, response, .{json.len});
    _ = try connection.stream.write(response_str);
    _ = try connection.stream.write(json);
}

/// Send error response
fn serveError(connection: std.net.Server.Connection, status: std.http.Status, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});

    var buffer: [256]u8 = undefined;
    const response =
        "HTTP/1.1 {d} {s}\r\n" ++
        "Content-Type: application/json; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const response_str = try std.fmt.bufPrint(&buffer, response, .{ @intFromEnum(status), status.phrase() orelse "Error", json.len });
    _ = try connection.stream.write(response_str);
    _ = try connection.stream.write(json);
}

/// Serve 405 Method Not Allowed
fn serveMethodNotAllowed(connection: std.net.Server.Connection) !void {
    return serveError(connection, .method_not_allowed, "Method not allowed");
}

/// Serve 403 Forbidden
fn serveForbidden(connection: std.net.Server.Connection) !void {
    return serveError(connection, .forbidden, "Forbidden in readonly mode");
}
