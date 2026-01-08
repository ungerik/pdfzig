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
    } else if (std.mem.startsWith(u8, target, "/api/settings/dpi/")) {
        if (!is_post) return serveMethodNotAllowed(connection);
        const dpi_str = target["/api/settings/dpi/".len..];
        const dpi = std.fmt.parseFloat(f64, dpi_str) catch return serveError(connection, .bad_request, "Invalid DPI");
        return handleUpdateDPI(global_state, connection, dpi);
    } else if (std.mem.startsWith(u8, target, "/api/pages/reorder/")) {
        if (!is_post) return serveMethodNotAllowed(connection);
        if (readonly) return serveForbidden(connection);
        const path_after = target["/api/pages/reorder/".len..];
        var parts = std.mem.splitScalar(u8, path_after, '/');
        const source_str = parts.next() orelse return serveError(connection, .bad_request, "Missing source");
        const target_str = parts.next() orelse return serveError(connection, .bad_request, "Missing target");
        const source_id = PageId.parse(source_str) catch return serveError(connection, .bad_request, "Invalid source page ID");
        const target_id = PageId.parse(target_str) catch return serveError(connection, .bad_request, "Invalid target page ID");
        return handleReorder(global_state, connection, source_id, target_id);
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
        const action_with_query = parts.next() orelse return serve404(connection);

        // Strip query string from action (e.g., "thumbnail?v=123" -> "thumbnail")
        const action = if (std.mem.indexOf(u8, action_with_query, "?")) |query_start|
            action_with_query[0..query_start]
        else
            action_with_query;

        const page_id = PageId.parse(page_id_str) catch return serve404(connection);

        if (std.mem.eql(u8, action, "thumbnail")) {
            return serveThumbnail(global_state, connection, page_id);
        } else if (std.mem.eql(u8, action, "rotate")) {
            if (!is_post) return serveMethodNotAllowed(connection);
            if (readonly) return serveForbidden(connection);
            // Get degrees from next path segment
            const degrees_str = parts.next() orelse return serveError(connection, .bad_request, "Missing degrees parameter");
            const degrees = std.fmt.parseInt(i32, degrees_str, 10) catch return serveError(connection, .bad_request, "Invalid degrees");
            return handleRotate(global_state, connection, page_id, degrees);
        } else if (std.mem.eql(u8, action, "mirror")) {
            if (!is_post) return serveMethodNotAllowed(connection);
            if (readonly) return serveForbidden(connection);
            // Get direction from next path segment
            const direction_str = parts.next() orelse return serveError(connection, .bad_request, "Missing direction parameter");
            const direction: operations.MirrorDirection = blk: {
                if (std.mem.eql(u8, direction_str, "updown")) break :blk .updown;
                if (std.mem.eql(u8, direction_str, "leftright")) break :blk .leftright;
                return serveError(connection, .bad_request, "Invalid direction");
            };
            return handleMirror(global_state, connection, page_id, direction);
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
                    \\  <img class="page-thumbnail" src="/api/pages/{d}-{d}/thumbnail?v={d}" alt="Page {d}">
                    \\  <div class="page-overlay">
                    \\    <button onclick="event.stopPropagation(); rotatePage('{d}-{d}', -90);" class="btn btn-round btn-green btn-top-left" title="Rotate left">
                    \\      <svg class="icon icon-lg" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
                    \\        <path stroke-linecap="round" stroke-linejoin="round" d="M9 15L3 9m0 0l6-6M3 9h12a6 6 0 110 12h-3" />
                    \\      </svg>
                    \\    </button>
                    \\    <button onclick="event.stopPropagation(); rotatePage('{d}-{d}', 90);" class="btn btn-round btn-green btn-top-right" title="Rotate right">
                    \\      <svg class="icon icon-lg" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
                    \\        <path stroke-linecap="round" stroke-linejoin="round" d="M15 15l6-6m0 0l-6-6m6 6H9a6 6 0 100 12h3" />
                    \\      </svg>
                    \\    </button>
                    \\    <button onclick="event.stopPropagation(); mirrorPage('{d}-{d}', 'updown');" class="btn btn-pill btn-yellow btn-middle-left" title="Mirror vertical">
                    \\      <svg class="icon icon-md" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
                    \\        <path stroke-linecap="round" stroke-linejoin="round" d="M12 3l-4 4M12 3l4 4M12 3v8" />
                    \\        <path stroke-linecap="round" stroke-linejoin="round" d="M12 21l-4-4M12 21l4-4M12 21v-8" />
                    \\      </svg>
                    \\    </button>
                    \\    <button onclick="event.stopPropagation(); mirrorPage('{d}-{d}', 'leftright');" class="btn btn-pill btn-yellow btn-middle-right" title="Mirror horizontal">
                    \\      <svg class="icon icon-md" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
                    \\        <path stroke-linecap="round" stroke-linejoin="round" d="M4 12l4-4M4 12l4 4M4 12h7" />
                    \\        <path stroke-linecap="round" stroke-linejoin="round" d="M20 12l-4-4M20 12l-4 4M20 12h-7" />
                    \\      </svg>
                    \\    </button>
                    \\    <button onclick="event.stopPropagation(); deletePage('{d}-{d}');" class="btn btn-round btn-red btn-bottom-left" title="Delete">
                    \\      <svg class="icon icon-lg" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
                    \\        <path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0" />
                    \\      </svg>
                    \\    </button>
                    \\    <button onclick="event.stopPropagation(); window.location.href='/api/pages/{d}-{d}/download';" class="btn btn-round btn-blue btn-bottom-right" title="Download page">
                    \\      <svg class="icon icon-lg" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
                    \\        <path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" />
                    \\      </svg>
                    \\    </button>
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
                    global_state.change_version,
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
                        \\<div class="split-indicator" style="display: inline-flex; flex-direction: column; align-items: center; justify-content: center; width: 30px; max-height: calc((100vh - 120px) / 5 - 40px); min-height: 200px; margin: 0 5px; opacity: 0.3; transition: opacity 0.2s; cursor: pointer;" onmouseover="this.style.opacity='1'" onmouseout="this.style.opacity='0.3'" onclick="if(confirm('Split document after page {d}?')) {{ fetch('/api/documents/{d}/split/{d}', {{method:'POST',headers:{{'X-Client-ID':clientId}}}}).then(()=>htmx.trigger(document.body,'pageUpdate')); }}" title="Split document here">
                        \\  <svg width="30" height="100%" viewBox="0 0 30 100" preserveAspectRatio="xMidYMid meet" style="fill: none; stroke: white; stroke-width: 1.5;">
                        \\    <line x1="15" y1="0" x2="15" y2="38" stroke-dasharray="3,3"/>
                        \\    <g transform="translate(9, 38)">
                        \\      <line x1="6" y1="12" x2="3" y2="6" stroke-linecap="round" stroke-linejoin="round"/>
                        \\      <line x1="6" y1="12" x2="9" y2="6" stroke-linecap="round" stroke-linejoin="round"/>
                        \\      <circle cx="3" cy="19" r="1.5"/>
                        \\      <circle cx="9" cy="19" r="1.5"/>
                        \\      <line x1="3" y1="16" x2="6" y2="12" stroke-linecap="round" stroke-linejoin="round"/>
                        \\      <line x1="9" y1="16" x2="6" y2="12" stroke-linecap="round" stroke-linejoin="round"/>
                        \\      <circle cx="6" cy="12" r="0.5" fill="white"/>
                        \\    </g>
                        \\    <line x1="15" y1="62" x2="15" y2="100" stroke-dasharray="3,3"/>
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
fn parseJsonBody(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, body, .{});
}

/// Handle rotate page request
fn handleRotate(global_state: *GlobalState, connection: std.net.Server.Connection, page_id: PageId, degrees: i32) !void {
    // Perform rotation
    operations.rotatePage(global_state, page_id.doc_id, page_id.page_num, degrees) catch {
        return serveError(connection, .internal_server_error, "Rotation failed");
    };

    // Send success response
    try serveJson(connection, "{\"success\":true}");
}

/// Handle mirror page request
fn handleMirror(global_state: *GlobalState, connection: std.net.Server.Connection, page_id: PageId, direction: operations.MirrorDirection) !void {
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
fn handleReorder(global_state: *GlobalState, connection: std.net.Server.Connection, source_id: PageId, target_id: PageId) !void {
    // Perform reorder
    operations.reorderPages(global_state, source_id, target_id) catch {
        return serveError(connection, .internal_server_error, "Reorder failed");
    };

    // Send success response
    try serveJson(connection, "{\"success\":true}");
}

/// Handle update DPI request
fn handleUpdateDPI(global_state: *GlobalState, connection: std.net.Server.Connection, dpi: f64) !void {
    // Update DPI
    operations.updateDPI(global_state, dpi) catch {
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
