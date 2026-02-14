const std = @import("std");
const BotError = @import("errors.zig").BotError;

const poll_request_timeout_min_seconds: i64 = 20;
const poll_request_timeout_buffer_seconds: i64 = 10;
const message_request_timeout_seconds: i64 = 15;

const TelegramGetUpdatesResponse = struct {
    ok: bool = false,
    result: []TelegramUpdate = &.{},
    description: ?[]const u8 = null,
};

const TelegramUpdate = struct {
    update_id: i64,
    message: ?TelegramMessage = null,
};

const TelegramMessage = struct {
    chat: TelegramChat,
    text: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    reply_to_message: ?TelegramReplyMessage = null,
};

const TelegramReplyMessage = struct {
    text: ?[]const u8 = null,
    caption: ?[]const u8 = null,
};

const TelegramChat = struct {
    id: i64,
};

const TelegramAck = struct {
    ok: bool = false,
    description: ?[]const u8 = null,
};

pub const TelegramClient = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, token: []const u8) TelegramClient {
        return .{
            .allocator = allocator,
            .token = token,
            .http_client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *TelegramClient) void {
        self.http_client.deinit();
    }

    pub fn getUpdates(self: *TelegramClient, offset: i64, timeout_seconds: i64) !std.json.Parsed(TelegramGetUpdatesResponse) {
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{f}",
            .{std.json.fmt(struct {
                offset: i64,
                timeout: i64,
                allowed_updates: []const []const u8,
            }{
                .offset = offset,
                .timeout = timeout_seconds,
                .allowed_updates = &.{"message"},
            }, .{})},
        );
        defer self.allocator.free(payload);

        const request_timeout_seconds = pollRequestTimeoutSeconds(timeout_seconds);
        const body = try self.postJson("getUpdates", payload, request_timeout_seconds);
        defer self.allocator.free(body);

        const parsed = try std.json.parseFromSlice(TelegramGetUpdatesResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });

        if (!parsed.value.ok) {
            std.log.err("Telegram getUpdates failed: {s}", .{parsed.value.description orelse "unknown error"});
            parsed.deinit();
            return BotError.TelegramApiError;
        }

        return parsed;
    }

    pub fn sendMessage(self: *TelegramClient, chat_id: i64, text: []const u8) !void {
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{f}",
            .{std.json.fmt(struct {
                chat_id: i64,
                text: []const u8,
            }{
                .chat_id = chat_id,
                .text = text,
            }, .{})},
        );
        defer self.allocator.free(payload);

        const body = try self.postJson("sendMessage", payload, message_request_timeout_seconds);
        defer self.allocator.free(body);

        const parsed = try std.json.parseFromSlice(TelegramAck, self.allocator, body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        if (!parsed.value.ok) {
            std.log.err("Telegram sendMessage failed: {s}", .{parsed.value.description orelse "unknown error"});
            return BotError.TelegramApiError;
        }
    }

    fn postJson(self: *TelegramClient, method: []const u8, payload: []const u8, timeout_seconds: i64) ![]u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://api.telegram.org/bot{s}/{s}",
            .{ self.token, method },
        );
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);

        var request = try self.http_client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
        });
        defer request.deinit();
        errdefer markConnectionClosing(&request);

        try configureRequestTimeout(&request, timeout_seconds);

        request.transfer_encoding = .{ .content_length = payload.len };
        var request_body = try request.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(payload);
        try request_body.end();
        try request.connection.?.flush();

        var response = try request.receiveHead(&.{});

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        const decompress_buffer: []u8, const decompress_buffer_allocated = switch (response.head.content_encoding) {
            .identity => .{ &.{}, false },
            .zstd => .{ try self.allocator.alloc(u8, std.compress.zstd.default_window_len), true },
            .deflate, .gzip => .{ try self.allocator.alloc(u8, std.compress.flate.max_window_len), true },
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer_allocated) self.allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const response_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = response_reader.streamRemaining(&output.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |read_err| return read_err,
        };

        if (response.head.status != .ok) {
            std.log.err(
                "Telegram {s} request failed with status {d}: {s}",
                .{ method, @intFromEnum(response.head.status), output.written() },
            );
            return BotError.TelegramApiError;
        }

        return try self.allocator.dupe(u8, output.written());
    }
};

fn configureRequestTimeout(request: *std.http.Client.Request, timeout_seconds: i64) !void {
    if (@import("builtin").os.tag == .windows) return;

    const connection = request.connection orelse return;
    const stream = connection.stream_reader.getStream();

    const timeout = std.posix.timeval{
        .sec = clampTimeoutSeconds(timeout_seconds),
        .usec = 0,
    };
    const timeout_bytes = std.mem.asBytes(&timeout);

    try setSocketTimeout(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        timeout_bytes,
    );
    try setSocketTimeout(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        timeout_bytes,
    );
}

fn setSocketTimeout(
    socket: std.posix.socket_t,
    level: i32,
    optname: u32,
    opt: []const u8,
) !void {
    const rc = std.posix.system.setsockopt(
        socket,
        level,
        optname,
        @ptrCast(opt.ptr),
        @intCast(opt.len),
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        // Zig 0.15.2 may treat EINVAL as unreachable in std.posix.setsockopt.
        // Handle it safely here and treat unsupported timeout opts as no-op.
        .INVAL, .NOPROTOOPT => {},
        else => return error.SocketTimeoutConfigurationFailed,
    }
}

fn markConnectionClosing(request: *std.http.Client.Request) void {
    const connection = request.connection orelse return;
    connection.closing = true;
}

fn pollRequestTimeoutSeconds(poll_timeout_seconds: i64) i64 {
    const bounded_poll_timeout = clampTimeoutSeconds(poll_timeout_seconds);
    const with_buffer = std.math.add(i64, bounded_poll_timeout, poll_request_timeout_buffer_seconds) catch std.math.maxInt(i64);
    if (with_buffer < poll_request_timeout_min_seconds) return poll_request_timeout_min_seconds;
    return with_buffer;
}

fn clampTimeoutSeconds(timeout_seconds: i64) i64 {
    return if (timeout_seconds <= 0) 1 else timeout_seconds;
}

test "poll request timeout adds safety buffer" {
    try std.testing.expectEqual(@as(i64, 40), pollRequestTimeoutSeconds(30));
}

test "poll request timeout enforces minimum floor" {
    try std.testing.expectEqual(@as(i64, 20), pollRequestTimeoutSeconds(1));
}
