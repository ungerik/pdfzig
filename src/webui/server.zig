//! HTTP Server for WebUI
//! Handles incoming HTTP connections and serves the web interface

const std = @import("std");
const state_mod = @import("state.zig");
const GlobalState = state_mod.GlobalState;
const pdfium = @import("../pdfium/pdfium.zig");
const routes = @import("routes.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    readonly: bool,
    state: *GlobalState,

    pub fn init(allocator: std.mem.Allocator, port: u16, readonly: bool) !*Server {
        const server = try allocator.create(Server);
        server.* = .{
            .allocator = allocator,
            .port = port,
            .readonly = readonly,
            .state = try GlobalState.init(allocator),
        };
        return server;
    }

    pub fn deinit(self: *Server) void {
        self.state.deinit();
        self.allocator.destroy(self);
    }

    /// Load initial documents from file paths
    pub fn loadInitialDocuments(self: *Server, paths: []const []const u8) !void {
        for (paths) |path| {
            // Extract filename from path
            const filename = std.fs.path.basename(path);

            // Add to state
            _ = try self.state.addDocument(
                .cli_loaded,
                path,
                filename,
            );
        }
    }

    /// Start the HTTP server (blocks until interrupted)
    pub fn start(self: *Server) !void {
        // Create TCP listener
        const address = try std.net.Address.parseIp4("127.0.0.1", self.port);
        var listener = try address.listen(.{
            .reuse_address = true,
        });
        defer listener.deinit();

        std.debug.print("Server listening on http://127.0.0.1:{d}\n", .{self.port});
        std.debug.print("Press Ctrl+C to stop\n", .{});

        // Accept connections in a loop
        while (true) {
            const connection = try listener.accept();

            // Handle connection (sequentially for now - single-threaded)
            self.handleConnection(connection) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        // Read HTTP request
        var buffer: [8192]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);

        if (bytes_read == 0) return;

        const request_str = buffer[0..bytes_read];

        // Parse first line to get method and path
        var lines = std.mem.splitScalar(u8, request_str, '\n');
        const first_line = lines.next() orelse return;
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;

        // Parse headers to extract X-Session-ID and find body start
        var session_id: ?[]const u8 = null;
        var headers_end_pos: usize = 0;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len == 0) {
                // Empty line marks end of headers
                // Calculate position after this line in original request_str
                const line_start = @intFromPtr(line.ptr) - @intFromPtr(request_str.ptr);
                headers_end_pos = line_start + line.len;
                // Skip past \r\n after empty line
                if (headers_end_pos + 2 <= request_str.len and
                    request_str[headers_end_pos] == '\r' and
                    request_str[headers_end_pos + 1] == '\n')
                {
                    headers_end_pos += 2;
                } else if (headers_end_pos + 1 <= request_str.len and
                    request_str[headers_end_pos] == '\n')
                {
                    headers_end_pos += 1;
                }
                break;
            }

            // Look for X-Session-ID header
            if (std.mem.startsWith(u8, trimmed, "X-Session-ID:") or
                std.mem.startsWith(u8, trimmed, "x-session-id:"))
            {
                const colon_pos = std.mem.indexOf(u8, trimmed, ":") orelse continue;
                session_id = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \r\n");
            }
        }

        // Extract body (data after headers)
        const body = if (headers_end_pos < request_str.len)
            request_str[headers_end_pos..]
        else
            &[_]u8{};

        // Dispatch to route handler
        try routes.dispatch(self.state, connection, method, target, self.readonly, session_id, body);
    }
};
