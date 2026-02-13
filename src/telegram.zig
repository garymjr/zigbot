const std = @import("std");
const BotError = @import("errors.zig").BotError;

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

        const body = try self.postJson("getUpdates", payload);
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

        const body = try self.postJson("sendMessage", payload);
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

    fn postJson(self: *TelegramClient, method: []const u8, payload: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://api.telegram.org/bot{s}/{s}",
            .{ self.token, method },
        );
        defer self.allocator.free(url);

        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        const result = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .extra_headers = &headers,
            .response_writer = &output.writer,
        });

        if (result.status != .ok) {
            std.log.err(
                "Telegram {s} request failed with status {d}: {s}",
                .{ method, @intFromEnum(result.status), output.written() },
            );
            return BotError.TelegramApiError;
        }

        return try self.allocator.dupe(u8, output.written());
    }
};
