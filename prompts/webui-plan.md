# WebUI Command Implementation Plan

## Overview

Implement a web-based PDF viewer and editor accessible via `pdfzig webui` command. Serves a single-page application with htmx 2.0 for interactive PDF manipulation (rotate, mirror, delete, reorder, split) with real-time preview.

## User Requirements Summary

**Command Syntax:**
```bash
pdfzig webui [--port 8080] [--readonly] [file1.pdf file2.pdf ...]
```

**Key Features:**
- Dark, minimalistic UI with top bar (no sidebar)
- Display pages as PNG thumbnails in flowing grid layout
- Dynamic DPI calculation based on viewport (target ~5 rows of pages)
- Page operations: rotate, mirror, delete, reorder (drag-drop), revert
- Document operations: upload, download, split, reset, clear
- Modal view for full-screen page display
- Single-user mode, in-memory state management
- CLI-loaded files save to original path; uploaded files stay in memory
- **Readonly mode**: Show status message in top bar, hide all modification UI elements
- **Copyright footer**: "Copyright © 2026 by Erik Unger | github.com/ungerik/pdfzig"

**Tech Stack:**
- htmx 2.0.x from CDN for dynamic updates
- Vanilla JavaScript for drag-drop and DPI calculation
- PNG format only for all rendered images
- Zig std.http.Server for HTTP serving
- Embedded HTML/CSS/JS assets in binary

## File Structure

```
src/cmd/webui.zig                    - CLI entry point and argument parsing
src/webui/server.zig                 - HTTP server implementation
src/webui/state.zig                  - Document/page state management
src/webui/routes.zig                 - Route dispatch and API handlers
src/webui/page_renderer.zig          - Page rendering to PNG with caching
src/webui/operations.zig             - PDF operations (rotate, mirror, etc.)
src/webui/assets/index.html          - Main HTML template
src/webui/assets/style.css           - UI styling
src/webui/assets/app.js              - Client-side JavaScript
src/webui/assets.zig                 - Asset embedding via @embedFile
```

**Files to Modify:**
- `src/cli_parsing.zig` - Add `.webui` to Command enum
- `src/main.zig` - Import cmd_webui, add parsing and dispatch

## Core Architecture

### 1. State Management (`src/webui/state.zig`)

**Data Structures:**

```zig
pub const PageId = struct {
    doc_id: u32,
    page_num: u32,  // 0-based internal index

    pub fn toGlobalId(self: PageId) u64 {
        return (@as(u64, self.doc_id) << 32) | self.page_num;
    }
};

pub const PageModification = struct {
    rotation: i32 = 0,        // cumulative rotation in degrees
    mirror_lr: bool = false,  // left-right mirror
    mirror_ud: bool = false,  // up-down mirror
    deleted: bool = false,

    pub fn isEmpty(self: PageModification) bool;
};

pub const PageState = struct {
    id: PageId,
    original_index: u32,
    current_index: u32,      // for reordering
    modifications: PageModification,
    thumbnail_cache: ?[]u8,  // PNG bytes
    width: f64,
    height: f64,
};

pub const DocumentSource = enum { cli_loaded, uploaded };

pub const DocumentState = struct {
    id: u32,
    source: DocumentSource,
    filepath: ?[]const u8,   // null for uploaded
    filename: []const u8,
    doc: pdfium.Document,
    pages: std.array_list.Managed(PageState),
    color: [3]u8,           // RGB for background
    modified: bool = false,
    original_bytes: ?[]u8,  // For revert functionality
};

pub const GlobalState = struct {
    allocator: std.mem.Allocator,
    documents: std.array_list.Managed(*DocumentState),
    next_doc_id: u32 = 0,
    thumbnail_dpi: f64 = 72,  // Updated dynamically from client
    mutex: std.Thread.Mutex = .{},  // Lock for concurrent browser windows
    change_version: u64 = 0,  // Incremented on every mutation for SSE invalidation

    pub fn init(allocator: std.mem.Allocator) !*GlobalState;
    pub fn addDocument(self: *GlobalState, source: DocumentSource,
                       filepath: ?[]const u8, pdf_bytes: []const u8) !*DocumentState;
    pub fn getDocument(self: *GlobalState, id: u32) ?*DocumentState;
    pub fn getPage(self: *GlobalState, page_id: PageId) ?*PageState;

    // Lock/unlock helpers for mutation operations
    pub fn lock(self: *GlobalState) void { self.mutex.lock(); }
    pub fn unlock(self: *GlobalState) void { self.mutex.unlock(); }

    // Increment change version after any mutation
    pub fn notifyChange(self: *GlobalState) void {
        self.change_version += 1;
    }
};
```

**Memory Management:**
- Use persistent allocator (not arena) for long-lived server
- Cache PNG thumbnails in PageState, invalidate on modification
- No caching for full-size modal images (render on-demand)
- Store original PDF bytes for revert functionality

**Concurrency Control:**
- Mutex protects global state from concurrent browser window access
- All mutation operations (rotate, mirror, delete, reorder, upload) acquire lock
- Read-only operations (thumbnail rendering, page lists) don't need locking
- Lock is held only during state modification, not during PDF rendering

**Cross-Window Synchronization:**
- Server-Sent Events (SSE) endpoint `/api/events` streams change notifications
- Each mutation increments `change_version` counter
- Client polls for version changes or uses SSE to trigger UI reload
- Client includes `X-Client-ID` header to identify itself
- Server doesn't notify the client that made the change

### 2. HTTP Server (`src/webui/server.zig`)

**Server Structure:**

```zig
pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    readonly: bool,
    state: *GlobalState,

    pub fn init(allocator: std.mem.Allocator, port: u16, readonly: bool) !*Server;
    pub fn loadInitialDocuments(self: *Server, paths: []const []const u8) !void;
    pub fn start(self: *Server) !void;  // Blocks until interrupted
    pub fn deinit(self: *Server) void;
};
```

**Connection Handling Pattern:**

```zig
fn handleConnection(self: *Server, conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    var buffer: [8192]u8 = undefined;
    var http_server = std.http.Server.init(conn, &buffer);
    var request = try http_server.receiveHead();

    try routes.dispatch(self.state, &request, request.head.method,
                        request.head.target, self.readonly);
}
```

**Note:** Single-threaded event loop processes one request at a time, but multiple browser windows can send concurrent requests. The mutex in GlobalState protects against race conditions.

**Reference:** Zig 0.15 pattern from `/Users/erik/Projects/pdfzig/src/pdfium/downloader.zig`

### 3. API Routes (`src/webui/routes.zig`)

**Endpoint Map:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Main HTML page |
| GET | `/api/documents` | List all documents (JSON) |
| GET | `/api/pages/list` | HTML fragment with all pages (for htmx) |
| GET | `/api/pages/{doc_id}-{page_num}/thumbnail` | Page thumbnail PNG |
| GET | `/api/pages/{doc_id}-{page_num}/fullsize?dpi={dpi}` | Full-size PNG |
| POST | `/api/pages/{doc_id}-{page_num}/rotate` | Rotate: `{"degrees": 90}` |
| POST | `/api/pages/{doc_id}-{page_num}/mirror` | Mirror: `{"direction": "updown"\|"leftright"}` |
| POST | `/api/pages/{doc_id}-{page_num}/delete` | Mark deleted |
| POST | `/api/pages/{doc_id}-{page_num}/revert` | Revert modifications |
| POST | `/api/pages/reorder` | Reorder: `{"source": "1-0", "target": "1-2"}` |
| POST | `/api/documents/upload` | Upload PDF (multipart/form-data) |
| POST | `/api/documents/{id}/split` | Split: `{"after_page": 2}` |
| GET | `/api/documents/{id}/download` | Download modified PDF |
| GET | `/api/pages/{doc_id}-{page_num}/download` | Single-page PDF |
| POST | `/api/reset` | Reset all to original |
| POST | `/api/clear` | Remove all documents |
| POST | `/api/settings/dpi` | Update DPI: `{"dpi": 96}` |
| GET | `/api/events` | Server-Sent Events stream for cross-window updates |

**Response Helpers:**

```zig
fn sendJson(request: *std.http.Server.Request, allocator: std.mem.Allocator,
            data: anytype) !void;
fn sendPng(request: *std.http.Server.Request, png_bytes: []const u8) !void;
fn sendHtml(request: *std.http.Server.Request, html: []const u8) !void;
fn sendError(request: *std.http.Server.Request, status: std.http.Status,
             message: []const u8) !void;
```

**Readonly Mode Enforcement:**
- Check `readonly` flag before any POST operation (except `/api/settings/dpi`)
- Return 403 Forbidden with error message if modification attempted

**Locking Pattern for Mutations:**
```zig
fn handleRotatePage(state: *GlobalState, request: *std.http.Server.Request,
                    page_id: PageId, allocator: std.mem.Allocator) !void {
    // Parse request body for rotation degrees
    const body = try request.reader().readAllAlloc(allocator, 1024);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(
        struct { degrees: i32 },
        allocator,
        body,
        .{}
    );
    defer parsed.deinit();

    // Get client ID from headers
    const client_id = request.head.headers.getFirstValue("X-Client-ID") orelse "";

    // Operations module handles locking internally
    try operations.rotatePage(state, page_id.doc_id, page_id.page_num,
                              parsed.value.degrees);

    // Notify all other browser windows
    state.notifyChange();

    try sendJson(request, allocator, .{ .success = true });
}

// Server-Sent Events endpoint for cross-window synchronization
fn handleEvents(state: *GlobalState, request: *std.http.Server.Request) !void {
    try request.respond("", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/event-stream" },
            .{ .name = "Cache-Control", .value = "no-cache" },
            .{ .name = "Connection", .value = "keep-alive" },
        },
    });

    const client_id = request.head.headers.getFirstValue("X-Client-ID") orelse "";
    var last_version = state.change_version;

    // Long-polling loop: check for changes every 100ms
    while (true) {
        std.time.sleep(100 * std.time.ns_per_ms);

        const current_version = @atomicLoad(u64, &state.change_version, .seq_cst);
        if (current_version != last_version) {
            last_version = current_version;

            // Send SSE event
            const event = try std.fmt.allocPrint(request.allocator,
                "event: change\ndata: {{\"version\": {d}, \"clientId\": \"{s}\"}}\n\n",
                .{ current_version, client_id });
            defer request.allocator.free(event);

            try request.writer().writeAll(event);
            try request.writer().flush();
        }
    }
}
```

### 4. PDF Operations (`src/webui/operations.zig`)

**Operation Implementations:**

```zig
pub fn rotatePage(state: *GlobalState, doc_id: u32, page_index: u32, degrees: i32) !void {
    // Reference: /Users/erik/Projects/pdfzig/src/cmd/rotate.zig

    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    const page_state = &doc.pages.items[page_index];

    var page = try doc.doc.loadPage(page_state.current_index);
    defer page.close();

    if (!page.rotate(degrees)) return error.InvalidRotation;
    if (!page.generateContent()) return error.GenerateContentFailed;

    page_state.modifications.rotation += degrees;
    invalidateThumbnailCache(page_state);
    doc.modified = true;
}

pub fn mirrorPage(state: *GlobalState, doc_id: u32, page_index: u32,
                  direction: enum { updown, leftright }) !void {
    // Reference: /Users/erik/Projects/pdfzig/src/cmd/mirror.zig

    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    const page_state = &doc.pages.items[page_index];

    var page = try doc.doc.loadPage(page_state.current_index);
    defer page.close();

    var it = page.objects();
    while (it.next()) |obj| {
        switch (direction) {
            .updown => obj.transform(1, 0, 0, -1, 0, page_height),
            .leftright => obj.transform(-1, 0, 0, 1, page_width, 0),
        }
    }

    if (!page.generateContent()) return error.GenerateContentFailed;

    switch (direction) {
        .updown => page_state.modifications.mirror_ud = !page_state.modifications.mirror_ud,
        .leftright => page_state.modifications.mirror_lr = !page_state.modifications.mirror_lr,
    }
    invalidateThumbnailCache(page_state);
    doc.modified = true;
}

pub fn deletePage(state: *GlobalState, doc_id: u32, page_index: u32) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;
    doc.pages.items[page_index].modifications.deleted = true;
    doc.modified = true;
}

pub fn revertPage(state: *GlobalState, doc_id: u32, page_index: u32) !void {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;

    // Reload from original_bytes
    const original_doc = try pdfium.Document.openFromMemory(doc.original_bytes.?);
    defer original_doc.close();

    var original_page = try original_doc.loadPage(page_index);
    defer original_page.close();

    // Copy page content back (implementation detail)
    // For now: clear modifications and regenerate from original
    doc.pages.items[page_index].modifications = .{};
    invalidateThumbnailCache(&doc.pages.items[page_index]);
}

pub fn saveDocumentToBytes(state: *GlobalState, doc_id: u32, allocator: std.mem.Allocator) ![]u8 {
    state.lock();
    defer state.unlock();

    const doc = state.getDocument(doc_id) orelse return error.DocumentNotFound;

    // Apply deletions in reverse order
    var pages_to_delete = std.array_list.Managed(u32).init(allocator);
    defer pages_to_delete.deinit();

    for (doc.pages.items, 0..) |page, i| {
        if (page.modifications.deleted) {
            try pages_to_delete.append(@intCast(i));
        }
    }

    std.mem.reverse(u32, pages_to_delete.items);
    for (pages_to_delete.items) |idx| {
        try doc.doc.deletePage(idx);
    }

    // Save to temp file, read bytes, delete temp
    // Reference: /Users/erik/Projects/pdfzig/src/cmd/rotate.zig
    const temp_path = try std.fmt.allocPrint(allocator, "/tmp/pdfzig-{d}.pdf",
                                             .{std.time.milliTimestamp()});
    defer allocator.free(temp_path);

    try doc.doc.saveWithVersion(temp_path, null);

    const file = try std.fs.openFileAbsolute(temp_path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);

    std.fs.deleteFileAbsolute(temp_path) catch {};
    return bytes;
}
```

### 5. Image Rendering (`src/webui/page_renderer.zig`)

**Thumbnail Rendering:**

```zig
pub fn renderThumbnail(
    allocator: std.mem.Allocator,
    page_state: *PageState,
    doc: pdfium.Document,
    dpi: f64,
) ![]u8 {
    // Check cache first
    if (page_state.thumbnail_cache) |cache| {
        return cache;
    }

    var page = try doc.loadPage(page_state.current_index);
    defer page.close();

    const dims = page.getDimensionsAtDpi(dpi);

    var bitmap = try pdfium.Bitmap.create(dims.width, dims.height, .bgra);
    defer bitmap.destroy();

    bitmap.fillWhite();
    try page.render(&bitmap, .{});

    const png_bytes = try convertBitmapToPngBytes(allocator, bitmap);
    page_state.thumbnail_cache = png_bytes;

    return png_bytes;
}

fn convertBitmapToPngBytes(allocator: std.mem.Allocator,
                           bitmap: pdfium.Bitmap) ![]u8 {
    // Reference: /Users/erik/Projects/pdfzig/src/pdfcontent/images.zig
    const data = bitmap.getData() orelse return error.BufferEmpty;

    const pixels = try convertBgraToRgba(data, bitmap.width, bitmap.height,
                                        bitmap.stride);
    defer allocator.free(pixels);

    const pixel_count = bitmap.width * bitmap.height;
    const rgba_pixels: []zigimg.color.Rgba32 =
        @as([*]zigimg.color.Rgba32, @ptrCast(@alignCast(pixels.ptr)))[0..pixel_count];

    const image = zigimg.Image{
        .width = bitmap.width,
        .height = bitmap.height,
        .pixels = .{ .rgba32 = rgba_pixels },
    };

    // Encode to bytes in memory
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();

    var write_buf: [4096]u8 = undefined;
    try image.writeToWriter(allocator, buffer.writer(), &write_buf,
                           .{ .png = .{} });

    return try buffer.toOwnedSlice();
}
```

**DPI Calculation (Client-Side):**

```javascript
function calculateOptimalDPI() {
    const viewportHeight = window.innerHeight;
    const topBarHeight = 60;
    const rowCount = 5;  // Target 5 rows
    const pageMargin = 20;

    const availableHeight = viewportHeight - topBarHeight;
    const pageHeight = (availableHeight / rowCount) - (pageMargin * 2);

    // Assume average page is US Letter (11 inches height)
    const targetDPI = (pageHeight / 11) * 72;

    return Math.max(50, Math.min(150, targetDPI));  // Clamp 50-150
}
```

### 6. Frontend Assets

**HTML Structure (`src/webui/assets/index.html`):**

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>pdfzig WebUI</title>
    <script src="https://cdn.jsdelivr.net/npm/htmx.org@2.0.8/dist/htmx.min.js"
            integrity="sha384-..." crossorigin="anonymous"></script>
    <link rel="stylesheet" href="/style.css">
</head>
<body data-readonly="{{READONLY}}">
    <!-- Top Bar -->
    <div id="top-bar">
        <h1>pdfzig</h1>
        {{#if READONLY}}
        <div class="readonly-indicator">READ-ONLY MODE</div>
        {{else}}
        <div class="controls">
            <button onclick="document.getElementById('file-input').click()">
                📁 Upload PDF
            </button>
            <input type="file" id="file-input" multiple accept=".pdf" hidden>
            <button hx-get="/api/documents/download-all">💾 Download All</button>
            <button hx-post="/api/reset" hx-confirm="Reset all?" id="reset-btn">
                🔄 Reset
            </button>
            <button hx-post="/api/clear" hx-confirm="Remove all?">🗑 Clear</button>
        </div>
        {{/if}}
    </div>

    <!-- Page Container -->
    <div id="page-container"
         hx-get="/api/pages/list"
         hx-trigger="load, pageUpdate from:body"
         hx-swap="innerHTML">
    </div>

    <!-- Bottom Bar (Copyright) -->
    <div id="bottom-bar">
        Copyright &copy; 2026 by Erik Unger |
        <a href="https://github.com/ungerik/pdfzig" target="_blank">github.com/ungerik/pdfzig</a>
    </div>

    <!-- Modal -->
    <div id="modal" class="modal" style="display:none">
        <span class="close">&times;</span>
        <img id="modal-img">
    </div>

    <script src="/app.js"></script>
</body>
</html>
```

**Note:** Use template replacement for `{{READONLY}}` in server-side rendering.

**CSS (`src/webui/assets/style.css`):**

```css
:root {
    --bg-dark: #1a1a1a;
    --bg-card: #2a2a2a;
    --text-primary: #e0e0e0;
    --accent: #4a9eff;
    --readonly-warning: #ff9800;
}

body {
    margin: 0;
    background: var(--bg-dark);
    color: var(--text-primary);
    font-family: system-ui, -apple-system, sans-serif;
    padding-bottom: 50px;  /* Space for bottom bar */
}

#top-bar {
    position: sticky;
    top: 0;
    background: var(--bg-card);
    padding: 12px 20px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.5);
    display: flex;
    justify-content: space-between;
    align-items: center;
    z-index: 100;
}

#bottom-bar {
    position: fixed;
    bottom: 0;
    left: 0;
    right: 0;
    background: var(--bg-card);
    padding: 10px 20px;
    text-align: center;
    font-size: 0.9em;
    color: var(--text-primary);
    opacity: 0.8;
    z-index: 50;
}

#bottom-bar a {
    color: var(--accent);
    text-decoration: none;
}

#bottom-bar a:hover {
    text-decoration: underline;
}

.readonly-indicator {
    background: var(--readonly-warning);
    color: #000;
    padding: 8px 16px;
    border-radius: 4px;
    font-weight: bold;
}

/* Hide modification UI in readonly mode */
body[data-readonly="true"] .page-overlay,
body[data-readonly="true"] .btn-revert,
body[data-readonly="true"] .split-indicator {
    display: none !important;
}

.pages-row {
    display: flex;
    flex-wrap: wrap;
    gap: 20px;
    padding: 10px;
}

.page-card {
    position: relative;
    background: white;
    border-radius: 4px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.3);
    cursor: pointer;
    transition: transform 0.2s;
}

.page-card:hover {
    transform: translateY(-4px);
}

.page-thumbnail {
    display: block;
    max-height: calc((100vh - 120px) / 5 - 40px);
    width: auto;
}

.page-overlay {
    position: absolute;
    inset: 0;
    opacity: 0;
    transition: opacity 0.2s;
}

.page-card:hover .page-overlay {
    opacity: 1;
}

.page-card[data-deleted="true"] .page-thumbnail {
    opacity: 0.3;
    text-decoration: line-through;
}

.modal {
    position: fixed;
    inset: 0;
    background: rgba(0,0,0,0.95);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
}
```

**JavaScript (`src/webui/assets/app.js`):**

```javascript
// DPI calculation and update
function calculateOptimalDPI() {
    const viewportHeight = window.innerHeight;
    const topBarHeight = 60;
    const rowCount = 5;
    const pageMargin = 20;
    const availableHeight = viewportHeight - topBarHeight;
    const pageHeight = (availableHeight / rowCount) - (pageMargin * 2);
    const targetDPI = (pageHeight / 11) * 72;
    return Math.max(50, Math.min(150, targetDPI));
}

function updateDPI() {
    const dpi = calculateOptimalDPI();
    fetch('/api/settings/dpi', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({dpi})
    }).then(() => htmx.trigger(document.body, 'pageUpdate'));
}

window.addEventListener('load', updateDPI);
window.addEventListener('resize', debounce(updateDPI, 500));

// Drag and drop for reordering
let draggedElement = null;

document.addEventListener('dragstart', (e) => {
    if (e.target.classList.contains('page-card')) {
        draggedElement = e.target;
    }
});

document.addEventListener('drop', (e) => {
    e.preventDefault();
    const target = e.target.closest('.page-card');
    if (target && draggedElement && target !== draggedElement) {
        fetch('/api/pages/reorder', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({
                source: draggedElement.dataset.pageId,
                target: target.dataset.pageId
            })
        }).then(() => htmx.trigger(document.body, 'pageUpdate'));
    }
});

// File upload
document.getElementById('file-input')?.addEventListener('change', async (e) => {
    for (const file of e.target.files) {
        const formData = new FormData();
        formData.append('pdf', file);
        await fetch('/api/documents/upload', {method: 'POST', body: formData});
    }
    htmx.trigger(document.body, 'pageUpdate');
    e.target.value = '';
});

// Modal
function openModal(imgSrc) {
    document.getElementById('modal').style.display = 'flex';
    document.getElementById('modal-img').src = imgSrc;
}

document.querySelector('.close')?.addEventListener('click', () => {
    document.getElementById('modal').style.display = 'none';
});

// Cross-window synchronization via Server-Sent Events
const clientId = crypto.randomUUID();

// Set client ID header for all requests
document.body.addEventListener('htmx:configRequest', (e) => {
    e.detail.headers['X-Client-ID'] = clientId;
});

// Listen for changes from other browser windows
const eventSource = new EventSource('/api/events');
eventSource.addEventListener('change', (e) => {
    const data = JSON.parse(e.data);
    // Don't reload if this client triggered the change
    if (data.clientId !== clientId) {
        htmx.trigger(document.body, 'pageUpdate');
    }
});

// Utility
function debounce(func, wait) {
    let timeout;
    return (...args) => {
        clearTimeout(timeout);
        timeout = setTimeout(() => func(...args), wait);
    };
}
```

### 7. CLI Integration

**Changes to `src/cli_parsing.zig`:**

Add to Command enum (around line 8):
```zig
pub const Command = enum {
    // ... existing commands ...
    webui,
    // ...
};
```

**Changes to `src/main.zig`:**

1. Add import (after line 44):
```zig
const cmd_webui = @import("cmd/webui.zig");
```

2. Add to command parsing (around line 175):
```zig
else if (std.mem.eql(u8, cmd_str, "webui"))
    .webui
```

3. Add to switch dispatch (around line 218):
```zig
.webui => try cmd_webui.run(allocator, &cmd_arg_it, stdout, stderr),
```

4. Update help text (around line 287):
```
\\  webui               Serve web interface for PDF editing
```

**Main Command (`src/cmd/webui.zig`):**

```zig
const std = @import("std");
const main = @import("../main.zig");
const server = @import("../webui/server.zig");

const Args = struct {
    port: u16 = 8080,
    readonly: bool = false,
    pdf_paths: std.array_list.Managed([]const u8) = .{},
    show_help: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    arg_it: *main.SliceArgIterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var args = Args{};
    args.pdf_paths = std.array_list.Managed([]const u8).init(allocator);
    defer args.pdf_paths.deinit();

    // Parse arguments (--port, --readonly, file paths)
    // Create server
    // Load initial documents
    // Print "Starting on http://127.0.0.1:{port}"
    // server.start() - blocks until Ctrl+C
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.writeAll(
        \\Usage: pdfzig webui [options] [file1.pdf file2.pdf ...]
        \\
        \\Serve web interface for PDF viewing and editing.
        \\
        \\Options:
        \\  --port <number>     Port to listen on (default: 8080)
        \\  --readonly          Read-only mode (no modifications)
        \\  -h, --help          Show this help
        \\
    ) catch {};
}
```

## Implementation Sequence

**Phase 1: Foundation**
1. Create `src/webui/state.zig` - All data structures
2. Create `src/webui/server.zig` - HTTP server skeleton
3. Create `src/cmd/webui.zig` - CLI integration
4. Modify `src/cli_parsing.zig` and `src/main.zig`
5. Test: Server starts and listens

**Phase 2: Static UI**
6. Create `src/webui/assets/index.html`, `style.css`, `app.js`
7. Create `src/webui/assets.zig` with `@embedFile`
8. Create `src/webui/routes.zig` - Serve main page only
9. Test: UI loads in browser with htmx

**Phase 3: Read Operations**
10. Implement document loading in `server.zig`
11. Create `src/webui/page_renderer.zig` - Thumbnail rendering
12. Implement `/api/documents` and `/api/pages/list` in `routes.zig`
13. Implement `/api/pages/{id}/thumbnail` endpoint
14. Test: Pages display for CLI-loaded files

**Phase 4: Modifications**
15. Create `src/webui/operations.zig` - rotate, mirror, delete
16. Implement POST endpoints in `routes.zig`
17. Implement cache invalidation
18. Test: All operations work and update UI

**Phase 5: Advanced Features**
19. Implement file upload (multipart parsing)
20. Implement reordering API
21. Implement split, download endpoints
22. Test: Full workflow

**Phase 6: Polish**
23. Add readonly mode enforcement and UI
24. Add error handling throughout
25. Add modification indicators
26. Test: End-to-end scenarios

## Critical Implementation Notes

**Zig 0.15 Conventions:**
- Use `std.Io.Writer` (not `std.io.Writer`)
- Use `std.fs.File.stdout()` (not `std.io.getStdOut()`)
- Use `std.array_list.Managed(T).init(allocator)` (not deprecated `std.ArrayList`)
- PDFium uses `.c` calling convention

**Reference Commands:**
- `/Users/erik/Projects/pdfzig/src/cmd/render.zig` - DPI, bitmap rendering
- `/Users/erik/Projects/pdfzig/src/cmd/rotate.zig` - Temp file pattern for saving
- `/Users/erik/Projects/pdfzig/src/cmd/mirror.zig` - Transform matrix operations
- `/Users/erik/Projects/pdfzig/src/pdfcontent/images.zig` - BGRA→PNG conversion
- `/Users/erik/Projects/pdfzig/src/pdfium/downloader.zig` - HTTP client pattern

**Thread Safety:**
- Single-threaded HTTP server event loop
- Multiple browser windows can send concurrent requests (same user, different tabs)
- Mutex in GlobalState protects document modifications from race conditions
- Read operations (thumbnail rendering, page lists) don't require locking
- PDFium operations are serialized through the request handling loop

**Memory Management:**
- Use persistent allocator (not arena) for server
- Thumbnail cache: owned by PageState
- Full-size renders: allocate, send, free immediately
- Original PDF bytes: store for revert functionality

**Performance:**
- Cache thumbnails, regenerate on modification
- Don't cache full-size images (memory intensive)
- Dynamic DPI: client calculates, sends to server
- Typical 72 DPI: ~600KB PNG per page

## Testing Checklist

- [ ] Server starts with no files - empty state message
- [ ] Server starts with CLI files - displays correctly
- [ ] Upload PDF via UI - displays in separate container
- [ ] Rotate left/right - updates thumbnail
- [ ] Mirror up/down, left/right - updates thumbnail
- [ ] Delete page - shows strikethrough, deletable flag
- [ ] Revert page - restores original
- [ ] Drag-drop within document - reorders
- [ ] Drag-drop between documents - moves page
- [ ] Split document - creates two documents
- [ ] Download single page - single-page PDF
- [ ] Download document - applies modifications
- [ ] Reset all - reverts to original
- [ ] Clear all - removes all documents
- [ ] Modal view - full-screen page display
- [ ] Readonly mode - shows indicator, hides modification buttons
- [ ] Dynamic DPI - adjusts on window resize
- [ ] Cross-window sync - rotate in window 1, updates in window 2
