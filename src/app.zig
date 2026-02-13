const std = @import("std");
const Config = @import("config.zig").Config;
const TelegramClient = @import("telegram.zig").TelegramClient;
const askPi = @import("pi_agent.zig").askPi;
const runHeartbeat = @import("pi_agent.zig").runHeartbeat;
const ensureSecretsExtensionInstalled = @import("secret_extension.zig").ensureInstalled;

const RunMode = enum {
    serve,
    beat,
};

pub fn run() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var mode: RunMode = .serve;
    var config_path_override: ?[]u8 = null;

    if (args.next()) |arg1| {
        if (std.mem.eql(u8, arg1, "beat")) {
            mode = .beat;
            if (args.next()) |path| {
                config_path_override = try allocator.dupe(u8, path);
            }
        } else {
            config_path_override = try allocator.dupe(u8, arg1);
        }

        if (args.next() != null) {
            std.log.err("usage: zigbot [beat] [config_path]", .{});
            std.process.exit(1);
        }
    }

    const config_path = if (config_path_override) |path|
        path
    else
        try defaultConfigPath(allocator);
    defer allocator.free(config_path);

    const config_dir = try configDirFromConfigPath(allocator, config_path);
    defer allocator.free(config_dir);

    var config = Config.load(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("config file not found: {s}", .{config_path});
            std.process.exit(1);
        },
        else => return err,
    };
    defer config.deinit(allocator);

    std.log.info("config path: {s}", .{config_path});
    std.log.info("agent dir: {s}", .{config_dir});
    std.log.info("heartbeat interval (seconds): {d}", .{config.heartbeat_interval_seconds});

    try ensureSecretsExtensionInstalled(allocator, config_dir);

    if (mode == .beat) {
        std.log.info("running manual heartbeat", .{});
        try runHeartbeat(allocator, &config, config_dir);
        std.log.info("manual heartbeat finished", .{});
        return;
    }

    var telegram = TelegramClient.init(allocator, config.telegram_bot_token);
    defer telegram.deinit();

    std.log.info("zigbot started", .{});
    std.log.info("waiting for Telegram messages...", .{});

    var next_update_offset: i64 = 0;
    var next_heartbeat_ms = initialNextHeartbeatMillis(&config);
    while (true) {
        const poll_timeout_seconds = effectivePollingTimeoutSeconds(&config, next_heartbeat_ms);
        handlePollCycle(allocator, &config, config_dir, &telegram, &next_update_offset, poll_timeout_seconds) catch |err| {
            std.log.err("poll loop error: {}", .{err});
            std.Thread.sleep(2 * std.time.ns_per_s);
        };

        triggerHeartbeatIfDue(allocator, &config, config_dir, &next_heartbeat_ms);
    }
}

fn defaultConfigDir(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        std.log.err("failed resolving HOME for default config path: {}", .{err});
        return err;
    };
    defer allocator.free(home);

    return std.fs.path.join(allocator, &.{ home, ".config", "zigbot" });
}

fn defaultConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const config_dir = try defaultConfigDir(allocator);
    defer allocator.free(config_dir);

    return std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
}

fn configDirFromConfigPath(allocator: std.mem.Allocator, config_path: []const u8) ![]u8 {
    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    if (std.fs.path.isAbsolute(config_dir)) {
        return allocator.dupe(u8, config_dir);
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return std.fs.path.join(allocator, &.{ cwd, config_dir });
}

fn handlePollCycle(
    allocator: std.mem.Allocator,
    config: *const Config,
    config_dir: []const u8,
    telegram: *TelegramClient,
    next_update_offset: *i64,
    poll_timeout_seconds: i64,
) !void {
    var updates = try telegram.getUpdates(next_update_offset.*, poll_timeout_seconds);
    defer updates.deinit();

    for (updates.value.result) |update| {
        if (update.update_id >= next_update_offset.*) {
            next_update_offset.* = update.update_id + 1;
        }

        const message = update.message orelse continue;
        const user_text = message.text orelse continue;
        if (user_text.len == 0) continue;

        std.log.info("incoming message chat_id={d}, update_id={d}", .{ message.chat.id, update.update_id });

        const response_text = askPi(allocator, config, config_dir, user_text) catch |err| blk: {
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

fn trimForTelegram(text: []const u8) []const u8 {
    const max_len = 4000;
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

fn initialNextHeartbeatMillis(config: *const Config) i64 {
    const interval_ms = heartbeatIntervalMillis(config) orelse return std.math.maxInt(i64);
    const now_ms = std.time.milliTimestamp();
    return std.math.add(i64, now_ms, interval_ms) catch std.math.maxInt(i64);
}

fn effectivePollingTimeoutSeconds(config: *const Config, next_heartbeat_ms: i64) i64 {
    const poll_timeout = clampNonNegative(config.polling_timeout_seconds);
    if (next_heartbeat_ms == std.math.maxInt(i64)) return poll_timeout;

    const now_ms = std.time.milliTimestamp();
    if (now_ms >= next_heartbeat_ms) return 0;

    const remaining_ms = next_heartbeat_ms - now_ms;
    const ms_per_second: i64 = std.time.ms_per_s;
    const heartbeat_timeout = @divFloor(remaining_ms + ms_per_second - 1, ms_per_second);
    return @min(poll_timeout, heartbeat_timeout);
}

fn triggerHeartbeatIfDue(
    allocator: std.mem.Allocator,
    config: *const Config,
    config_dir: []const u8,
    next_heartbeat_ms: *i64,
) void {
    const interval_ms = heartbeatIntervalMillis(config) orelse return;
    const now_ms = std.time.milliTimestamp();
    if (now_ms < next_heartbeat_ms.*) return;

    std.log.info("triggering heartbeat", .{});
    runHeartbeat(allocator, config, config_dir) catch |err| {
        std.log.err("heartbeat error: {}", .{err});
    };

    next_heartbeat_ms.* = std.math.add(i64, now_ms, interval_ms) catch std.math.maxInt(i64);
}

fn heartbeatIntervalMillis(config: *const Config) ?i64 {
    const interval_seconds = config.heartbeat_interval_seconds;
    if (interval_seconds <= 0) return null;
    return std.math.mul(i64, interval_seconds, std.time.ms_per_s) catch null;
}

fn clampNonNegative(value: i64) i64 {
    return if (value < 0) 0 else value;
}
