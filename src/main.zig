const std = @import("std");
const pi = @import("pi_sdk");

const BotError = error{
    MissingRequiredConfigField,
    TelegramApiError,
};

const Config = struct {
    telegram_bot_token: []u8,
    pi_executable: []u8,
    provider: ?[]u8,
    model: ?[]u8,
    polling_timeout_seconds: i64,

    const ConfigFile = struct {
        telegram_bot_token: ?[]const u8 = null,
        pi_executable: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        model: ?[]const u8 = null,
        polling_timeout_seconds: ?i64 = null,
    };

    fn load(allocator: std.mem.Allocator, config_path: []const u8) !Config {
        const config_bytes = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
            std.log.err("failed reading config file {s}: {}", .{ config_path, err });
            return err;
        };
        defer allocator.free(config_bytes);

        const parsed = std.json.parseFromSlice(ConfigFile, allocator, config_bytes, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("failed parsing config file {s}: {}", .{ config_path, err });
            return err;
        };
        defer parsed.deinit();

        const telegram_bot_token_value = parsed.value.telegram_bot_token orelse {
            std.log.err("missing required config field: telegram_bot_token", .{});
            return BotError.MissingRequiredConfigField;
        };
        const telegram_bot_token = try allocator.dupe(u8, telegram_bot_token_value);
        errdefer allocator.free(telegram_bot_token);

        const pi_executable = if (parsed.value.pi_executable) |value|
            try allocator.dupe(u8, value)
        else
            try allocator.dupe(u8, "pi");
        errdefer allocator.free(pi_executable);

        const provider = if (parsed.value.provider) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (provider) |value| allocator.free(value);

        const model = if (parsed.value.model) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (model) |value| allocator.free(value);

        const polling_timeout_seconds = parsed.value.polling_timeout_seconds orelse 30;

        return .{
            .telegram_bot_token = telegram_bot_token,
            .pi_executable = pi_executable,
            .provider = provider,
            .model = model,
            .polling_timeout_seconds = polling_timeout_seconds,
        };
    }

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.telegram_bot_token);
        allocator.free(self.pi_executable);
        if (self.provider) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
    }
};

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

const TelegramClient = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    http_client: std.http.Client,

    fn init(allocator: std.mem.Allocator, token: []const u8) TelegramClient {
        return .{
            .allocator = allocator,
            .token = token,
            .http_client = .{ .allocator = allocator },
        };
    }

    fn deinit(self: *TelegramClient) void {
        self.http_client.deinit();
    }

    fn getUpdates(self: *TelegramClient, offset: i64, timeout_seconds: i64) !std.json.Parsed(TelegramGetUpdatesResponse) {
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

    fn sendMessage(self: *TelegramClient, chat_id: i64, text: []const u8) !void {
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

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const config_path = try allocator.dupe(u8, args.next() orelse "zigbot.config.json");
    defer allocator.free(config_path);

    var config = try Config.load(allocator, config_path);
    defer config.deinit(allocator);

    var telegram = TelegramClient.init(allocator, config.telegram_bot_token);
    defer telegram.deinit();

    std.log.info("zigbot started with config {s}, waiting for Telegram messages...", .{config_path});

    var next_update_offset: i64 = 0;
    while (true) {
        handlePollCycle(allocator, &config, &telegram, &next_update_offset) catch |err| {
            std.log.err("poll loop error: {}", .{err});
            std.Thread.sleep(2 * std.time.ns_per_s);
        };
    }
}

fn handlePollCycle(
    allocator: std.mem.Allocator,
    config: *const Config,
    telegram: *TelegramClient,
    next_update_offset: *i64,
) !void {
    var updates = try telegram.getUpdates(next_update_offset.*, config.polling_timeout_seconds);
    defer updates.deinit();

    for (updates.value.result) |update| {
        if (update.update_id >= next_update_offset.*) {
            next_update_offset.* = update.update_id + 1;
        }

        const message = update.message orelse continue;
        const user_text = message.text orelse continue;
        if (user_text.len == 0) continue;

        std.log.info("incoming message chat_id={d}, update_id={d}", .{ message.chat.id, update.update_id });

        const response_text = askPi(allocator, config, user_text) catch |err| blk: {
            std.log.err("pi request failed: {}", .{err});
            break :blk try allocator.dupe(
                u8,
                "I hit an error while generating a reply. Please try again in a moment.",
            );
        };
        defer allocator.free(response_text);

        try telegram.sendMessage(message.chat.id, trimForTelegram(response_text));
    }
}

fn askPi(allocator: std.mem.Allocator, config: *const Config, prompt: []const u8) ![]u8 {
    var created = try pi.createAgentSession(.{
        .allocator = allocator,
        .pi_executable = config.pi_executable,
        .provider = config.provider,
        .model = config.model,
        .session_manager = pi.SessionManager.inMemory(),
    });
    defer created.session.dispose();

    try created.session.prompt(prompt, .{});
    try created.session.waitForIdle();

    if (try created.session.getLastAssistantText()) |text| {
        return text;
    }

    return allocator.dupe(u8, "I could not generate a response.");
}

fn trimForTelegram(text: []const u8) []const u8 {
    const max_len = 4000;
    if (text.len <= max_len) return text;
    return text[0..max_len];
}
