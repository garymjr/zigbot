const std = @import("std");
const logging = @import("logging.zig");
const Config = @import("config.zig").Config;
const RuntimeState = @import("runtime_state.zig").RuntimeState;
const agentTaskName = @import("runtime_state.zig").agentTaskName;

const ui_html = @embedFile("assets/web/index.html");
const request_head_timeout_seconds = 10;

pub const ServeMode = enum {
    full,
    status_only,
};

pub const Server = struct {
    thread: std.Thread,
    config: *const Config,
    shutdown_requested: *std.atomic.Value(bool),

    pub fn stopAndJoin(self: *Server) void {
        self.shutdown_requested.store(true, .seq_cst);
        wakeListener(self.config.web_host, self.config.web_port);
        self.thread.join();
    }
};

const ServerContext = struct {
    status: *RuntimeState,
    config: *const Config,
    config_dir: []const u8,
    mode: ServeMode,
    shutdown_requested: *std.atomic.Value(bool),
};

pub fn spawn(
    status: *RuntimeState,
    config: *const Config,
    config_dir: []const u8,
    mode: ServeMode,
    shutdown_requested: *std.atomic.Value(bool),
) !Server {
    const allocator = std.heap.page_allocator;
    const context = try allocator.create(ServerContext);
    context.* = .{
        .status = status,
        .config = config,
        .config_dir = config_dir,
        .mode = mode,
        .shutdown_requested = shutdown_requested,
    };
    errdefer allocator.destroy(context);

    const thread = try std.Thread.spawn(.{}, serverMain, .{context});
    return .{
        .thread = thread,
        .config = config,
        .shutdown_requested = shutdown_requested,
    };
}

fn serverMain(context: *ServerContext) void {
    const allocator = std.heap.page_allocator;
    defer allocator.destroy(context);

    const service_name = serviceLabel(context.mode);
    const address = std.net.Address.resolveIp(context.config.web_host, context.config.web_port) catch |err| {
        std.log.err("{s}: failed resolving listen address {s}:{d}: {}", .{
            service_name,
            context.config.web_host,
            context.config.web_port,
            err,
        });
        return;
    };

    var listener = address.listen(.{
        .reuse_address = true,
    }) catch |err| {
        std.log.err("{s}: failed to listen on {s}:{d}: {}", .{
            service_name,
            context.config.web_host,
            context.config.web_port,
            err,
        });
        return;
    };
    defer listener.deinit();

    std.log.info("{s} listening at http://{s}:{d}", .{
        service_name,
        context.config.web_host,
        context.config.web_port,
    });

    while (!context.shutdown_requested.load(.acquire)) {
        const connection = listener.accept() catch |err| {
            if (context.shutdown_requested.load(.acquire)) break;
            std.log.err("{s}: accept failed: {}", .{ service_name, err });
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };

        if (context.shutdown_requested.load(.acquire)) {
            connection.stream.close();
            break;
        }

        connectionMain(context, connection);
    }

    std.log.info("{s} stopped", .{service_name});
}

fn connectionMain(context: *ServerContext, connection: std.net.Server.Connection) void {
    defer connection.stream.close();
    configureConnectionTimeout(connection.stream) catch |err| {
        std.log.err("web service: failed configuring socket timeout: {}", .{err});
    };

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var stream_reader = connection.stream.reader(&recv_buffer);
    var stream_writer = connection.stream.writer(&send_buffer);
    var server = std.http.Server.init(stream_reader.interface(), &stream_writer.interface);

    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => {
            std.log.err("web service: failed receiving request: {}", .{err});
            return;
        },
    };

    var execution_id_buffer: [logging.execution_id_hex_len]u8 = undefined;
    const execution_id = logging.generateExecutionId(&execution_id_buffer);
    const execution_scope = logging.pushExecutionId(execution_id);
    defer execution_scope.restore();

    serveRequest(context, &request) catch |err| {
        std.log.err("web service: request handling failed: {}", .{err});
        respondJsonError(&request, .internal_server_error, "internal server error") catch {};
    };
}

fn configureConnectionTimeout(stream: std.net.Stream) !void {
    if (@import("builtin").os.tag == .windows) return;

    const timeout = std.posix.timeval{
        .sec = request_head_timeout_seconds,
        .usec = 0,
    };
    const timeout_bytes = std.mem.asBytes(&timeout);
    try std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        timeout_bytes,
    );
}

fn serveRequest(context: *ServerContext, request: *std.http.Server.Request) !void {
    const path = normalizePath(request.head.target);
    const method = request.head.method;

    if (context.mode == .status_only) {
        return serveStatusOnlyRequest(context, request, path, method);
    }

    if (method == .GET and std.mem.eql(u8, path, "/")) {
        return respondHtml(request, ui_html);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/status")) {
        return serveStatus(context, request);
    }
    if (method == .GET and std.mem.eql(u8, path, "/healthz")) {
        return serveHealth(request);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/skills")) {
        return serveDirectoryNames(context, request, "skills", "skills");
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/extensions")) {
        return serveDirectoryNames(context, request, "extensions", "extensions");
    }

    if (std.mem.eql(u8, path, "/api/status") or
        std.mem.eql(u8, path, "/healthz") or
        std.mem.eql(u8, path, "/api/skills") or
        std.mem.eql(u8, path, "/api/extensions"))
    {
        return respondJsonError(request, .method_not_allowed, "method not allowed");
    }

    return respondJsonError(request, .not_found, "not found");
}

fn serveStatusOnlyRequest(
    context: *ServerContext,
    request: *std.http.Server.Request,
    path: []const u8,
    method: std.http.Method,
) !void {
    if (method == .GET and std.mem.eql(u8, path, "/api/status")) {
        return serveStatus(context, request);
    }
    if (method == .GET and std.mem.eql(u8, path, "/healthz")) {
        return serveHealth(request);
    }
    if (std.mem.eql(u8, path, "/api/status") or std.mem.eql(u8, path, "/healthz")) {
        return respondJsonError(request, .method_not_allowed, "method not allowed");
    }
    return respondJsonError(request, .not_found, "not found");
}

fn serveHealth(request: *std.http.Server.Request) !void {
    try respondJson(request, .ok, "{\"ok\":true}");
}

fn serveStatus(context: *ServerContext, request: *std.http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snapshot = context.status.snapshot();
    const next_heartbeat_ms: ?i64 = if (snapshot.next_heartbeat_ms == std.math.maxInt(i64))
        null
    else
        snapshot.next_heartbeat_ms;
    const uptime_seconds = @divFloor(snapshot.captured_ms - snapshot.started_ms, std.time.ms_per_s);
    const heartbeat_enabled = context.config.heartbeat_interval_seconds > 0;
    const last_heartbeat_duration_ms: ?i64 = if (snapshot.last_heartbeat_started_ms > 0 and
        snapshot.last_heartbeat_finished_ms >= snapshot.last_heartbeat_started_ms)
        snapshot.last_heartbeat_finished_ms - snapshot.last_heartbeat_started_ms
    else
        null;
    const payload_data = .{
        .now_ms = snapshot.captured_ms,
        .started_ms = snapshot.started_ms,
        .uptime_seconds = uptime_seconds,
        .polling_timeout_seconds = context.config.polling_timeout_seconds,
        .heartbeat_execution_mode = "threaded",
        .heartbeat_interval_seconds = context.config.heartbeat_interval_seconds,
        .heartbeat_enabled = heartbeat_enabled,
        .pi_session_ttl_seconds = context.config.pi_session_ttl_seconds,
        .web_enabled = context.config.web_enabled,
        .owner_chat_restricted = context.config.owner_chat_id != null,
        .provider = context.config.provider,
        .model = context.config.model,
        .next_heartbeat_ms = next_heartbeat_ms,
        .last_poll_ms = snapshot.last_poll_ms,
        .last_poll_ok = snapshot.last_poll_ok,
        .poll_error_count = snapshot.poll_error_count,
        .last_poll_error = snapshot.pollError(),
        .telegram_message_count = snapshot.telegram_message_count,
        .telegram_busy_reject_count = snapshot.telegram_busy_reject_count,
        .telegram_generation_error_count = snapshot.telegram_generation_error_count,
        .telegram_send_error_count = snapshot.telegram_send_error_count,
        .last_telegram_error = snapshot.telegramError(),
        .heartbeat_deferred_count = snapshot.heartbeat_deferred_count,
        .heartbeat_run_count = snapshot.heartbeat_run_count,
        .heartbeat_error_count = snapshot.heartbeat_error_count,
        .last_heartbeat_started_ms = snapshot.last_heartbeat_started_ms,
        .last_heartbeat_finished_ms = snapshot.last_heartbeat_finished_ms,
        .last_heartbeat_duration_ms = last_heartbeat_duration_ms,
        .last_heartbeat_ok = snapshot.last_heartbeat_ok,
        .last_heartbeat_error = snapshot.heartbeatError(),
        .agent_busy = snapshot.agent_busy,
        .active_task = agentTaskName(snapshot.active_task),
        .active_task_started_ms = snapshot.active_task_started_ms,
    };

    const payload = try std.fmt.allocPrint(arena, "{f}", .{
        std.json.fmt(payload_data, .{}),
    });

    try respondJson(request, .ok, payload);
}

fn serveDirectoryNames(
    context: *ServerContext,
    request: *std.http.Server.Request,
    comptime directory_name: []const u8,
    comptime response_field_name: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const names = try readDirectoryNames(arena, context.config_dir, directory_name);

    const payload = if (comptime std.mem.eql(u8, response_field_name, "skills"))
        try std.fmt.allocPrint(arena, "{f}", .{
            std.json.fmt(struct {
                skills: []const []const u8,
            }{
                .skills = names,
            }, .{}),
        })
    else
        try std.fmt.allocPrint(arena, "{f}", .{
            std.json.fmt(struct {
                extensions: []const []const u8,
            }{
                .extensions = names,
            }, .{}),
        });

    try respondJson(request, .ok, payload);
}

fn readDirectoryNames(allocator: std.mem.Allocator, base_dir: []const u8, child_dir: []const u8) ![]const []const u8 {
    const target_dir = try std.fs.path.join(allocator, &.{ base_dir, child_dir });
    defer allocator.free(target_dir);

    var dir = std.fs.openDirAbsolute(target_dir, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer dir.close();

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.sort.pdq([]const u8, names.items, {}, lessThanString);
    return try names.toOwnedSlice(allocator);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn normalizePath(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..query_start];
}

fn respondHtml(request: *std.http.Server.Request, body: []const u8) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(body, .{
        .status = status,
        .extra_headers = &headers,
    });
}

fn respondJsonError(request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try std.fmt.allocPrint(arena, "{f}", .{
        std.json.fmt(struct {
            @"error": []const u8,
        }{
            .@"error" = message,
        }, .{}),
    });

    try respondJson(request, status, body);
}

fn serviceLabel(mode: ServeMode) []const u8 {
    return switch (mode) {
        .full => "web ui",
        .status_only => "status api",
    };
}

fn wakeListener(host: []const u8, port: u16) void {
    const wake_host = if (std.mem.eql(u8, host, "0.0.0.0"))
        "127.0.0.1"
    else if (std.mem.eql(u8, host, "::"))
        "::1"
    else
        host;

    const stream = std.net.tcpConnectToHost(std.heap.page_allocator, wake_host, port) catch return;
    stream.close();
}
