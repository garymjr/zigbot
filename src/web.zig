const std = @import("std");
const Config = @import("config.zig").Config;
const askPi = @import("pi_agent.zig").askPi;
const RuntimeState = @import("runtime_state.zig").RuntimeState;
const agentTaskName = @import("runtime_state.zig").agentTaskName;

const ui_html = @embedFile("assets/web/index.html");
const request_body_limit_bytes = 32 * 1024;
const request_head_timeout_seconds = 10;

const ServerContext = struct {
    status: *RuntimeState,
    config: *const Config,
    config_dir: []const u8,
};

pub fn spawn(status: *RuntimeState, config: *const Config, config_dir: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const context = try allocator.create(ServerContext);
    context.* = .{
        .status = status,
        .config = config,
        .config_dir = config_dir,
    };
    errdefer allocator.destroy(context);

    const thread = try std.Thread.spawn(.{}, serverMain, .{context});
    thread.detach();
}

fn serverMain(context: *ServerContext) void {
    const allocator = std.heap.page_allocator;
    defer allocator.destroy(context);

    const address = std.net.Address.resolveIp(context.config.web_host, context.config.web_port) catch |err| {
        std.log.err("web ui: failed resolving listen address {s}:{d}: {}", .{
            context.config.web_host,
            context.config.web_port,
            err,
        });
        return;
    };

    var listener = address.listen(.{
        .reuse_address = true,
    }) catch |err| {
        std.log.err("web ui: failed to listen on {s}:{d}: {}", .{
            context.config.web_host,
            context.config.web_port,
            err,
        });
        return;
    };
    defer listener.deinit();

    std.log.info("web ui listening at http://{s}:{d}", .{
        context.config.web_host,
        context.config.web_port,
    });

    while (true) {
        const connection = listener.accept() catch |err| {
            std.log.err("web ui: accept failed: {}", .{err});
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        connectionMain(context, connection);
    }
}

fn connectionMain(context: *ServerContext, connection: std.net.Server.Connection) void {
    defer connection.stream.close();
    configureConnectionTimeout(connection.stream) catch |err| {
        std.log.err("web ui: failed configuring socket timeout: {}", .{err});
    };

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var stream_reader = connection.stream.reader(&recv_buffer);
    var stream_writer = connection.stream.writer(&send_buffer);
    var server = std.http.Server.init(stream_reader.interface(), &stream_writer.interface);

    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => {
            std.log.err("web ui: failed receiving request: {}", .{err});
            return;
        },
    };

    serveRequest(context, &request) catch |err| {
        std.log.err("web ui: request handling failed: {}", .{err});
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

    if (method == .GET and std.mem.eql(u8, path, "/")) {
        return respondHtml(request, ui_html);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/status")) {
        return serveStatus(context, request);
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/skills")) {
        return serveDirectoryNames(context, request, "skills", "skills");
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/extensions")) {
        return serveDirectoryNames(context, request, "extensions", "extensions");
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/chat")) {
        return serveChat(context, request);
    }

    if (std.mem.eql(u8, path, "/api/status") or
        std.mem.eql(u8, path, "/api/skills") or
        std.mem.eql(u8, path, "/api/extensions") or
        std.mem.eql(u8, path, "/api/chat"))
    {
        return respondJsonError(request, .method_not_allowed, "method not allowed");
    }

    return respondJsonError(request, .not_found, "not found");
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
    const payload_data = .{
        .now_ms = snapshot.captured_ms,
        .started_ms = snapshot.started_ms,
        .uptime_seconds = uptime_seconds,
        .next_heartbeat_ms = next_heartbeat_ms,
        .last_poll_ms = snapshot.last_poll_ms,
        .last_poll_ok = snapshot.last_poll_ok,
        .poll_error_count = snapshot.poll_error_count,
        .last_poll_error = snapshot.pollError(),
        .telegram_message_count = snapshot.telegram_message_count,
        .web_chat_count = snapshot.web_chat_count,
        .heartbeat_run_count = snapshot.heartbeat_run_count,
        .heartbeat_error_count = snapshot.heartbeat_error_count,
        .last_heartbeat_started_ms = snapshot.last_heartbeat_started_ms,
        .last_heartbeat_finished_ms = snapshot.last_heartbeat_finished_ms,
        .last_heartbeat_ok = snapshot.last_heartbeat_ok,
        .last_heartbeat_error = snapshot.heartbeatError(),
        .agent_busy = snapshot.agent_busy,
        .active_task = agentTaskName(snapshot.active_task),
        .active_task_started_ms = snapshot.active_task_started_ms,
        .last_web_chat_ms = snapshot.last_web_chat_ms,
        .last_web_chat_duration_ms = snapshot.last_web_chat_duration_ms,
        .last_web_chat_ok = snapshot.last_web_chat_ok,
        .last_web_prompt = snapshot.webPrompt(),
        .last_web_response = snapshot.webResponse(),
        .last_web_error = snapshot.webError(),
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

fn serveChat(context: *ServerContext, request: *std.http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (request.head.expect != null) {
        return respondJsonError(request, .expectation_failed, "expect headers are not supported");
    }

    const body = readRequestBody(arena, request) catch |err| switch (err) {
        error.MissingContentLength => return respondJsonError(request, .length_required, "content-length is required"),
        error.RequestBodyTooLarge => return respondJsonError(request, .payload_too_large, "request body too large"),
        error.EndOfStream => return respondJsonError(request, .bad_request, "unexpected end of request body"),
        else => return respondJsonError(request, .bad_request, "failed reading request body"),
    };

    const ChatInput = struct {
        message: []const u8,
    };

    const parsed = std.json.parseFromSlice(ChatInput, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return respondJsonError(request, .bad_request, "expected JSON body with field `message`");
    };
    defer parsed.deinit();

    const prompt = std.mem.trim(u8, parsed.value.message, " \t\r\n");
    if (prompt.len == 0) {
        return respondJsonError(request, .bad_request, "message cannot be empty");
    }

    if (!context.status.tryBeginAgentTask(.web_chat)) {
        const snapshot = context.status.snapshot();
        const payload = try std.fmt.allocPrint(arena, "{f}", .{
            std.json.fmt(struct {
                @"error": []const u8,
                active_task: []const u8,
            }{
                .@"error" = "agent is busy",
                .active_task = agentTaskName(snapshot.active_task),
            }, .{}),
        });
        return respondJson(request, .conflict, payload);
    }
    defer context.status.finishAgentTask(.web_chat);

    const started_ms = std.time.milliTimestamp();
    const response_text = askPi(arena, context.config, context.config_dir, prompt, null) catch |err| {
        const duration_ms = std.time.milliTimestamp() - started_ms;
        const err_name = @errorName(err);
        context.status.recordWebChatError(prompt, err_name, duration_ms);
        return respondJsonError(request, .internal_server_error, "agent request failed");
    };

    const duration_ms = std.time.milliTimestamp() - started_ms;
    context.status.recordWebChatSuccess(prompt, response_text, duration_ms);

    const payload = try std.fmt.allocPrint(arena, "{f}", .{
        std.json.fmt(struct {
            response: []const u8,
            duration_ms: i64,
        }{
            .response = response_text,
            .duration_ms = duration_ms,
        }, .{}),
    });
    try respondJson(request, .ok, payload);
}

fn readRequestBody(allocator: std.mem.Allocator, request: *std.http.Server.Request) ![]u8 {
    const length_u64 = request.head.content_length orelse return error.MissingContentLength;
    if (length_u64 > request_body_limit_bytes) return error.RequestBodyTooLarge;

    const length = std.math.cast(usize, length_u64) orelse return error.RequestBodyTooLarge;
    const reader = request.readerExpectNone(&.{});
    return reader.readAlloc(allocator, length);
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
