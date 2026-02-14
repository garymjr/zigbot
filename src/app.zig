const std = @import("std");
const logging = @import("logging.zig");
const Config = @import("config.zig").Config;
const TelegramClient = @import("telegram.zig").TelegramClient;
const askPi = @import("pi_agent.zig").askPi;
const runHeartbeat = @import("pi_agent.zig").runHeartbeat;
const ensureSecretsExtensionInstalled = @import("secret_extension.zig").ensureInstalled;
const RuntimeState = @import("runtime_state.zig").RuntimeState;
const agentTaskName = @import("runtime_state.zig").agentTaskName;
const web = @import("web.zig");
const log = std.log.scoped(.app);

const RunMode = enum {
    serve,
    beat,
};

const HeartbeatWorkerContext = struct {
    runtime_state: *RuntimeState,
    config: *const Config,
    config_dir: []const u8,
    shutdown: *std.atomic.Value(bool),
};

var shutdown_requested = std.atomic.Value(bool).init(false);

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
            log.err("usage: zigbot [beat] [config_path]", .{});
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
            log.err("config file not found: {s}", .{config_path});
            std.process.exit(1);
        },
        else => return err,
    };
    defer config.deinit(allocator);

    log.info("config path: {s}", .{config_path});
    log.info("agent dir: {s}", .{config_dir});
    log.info("heartbeat interval (seconds): {d}", .{config.heartbeat_interval_seconds});
    log.info("heartbeat wait timeout (seconds): {d}", .{config.heartbeat_wait_timeout_seconds});
    log.info("askPi wait timeout (seconds): {d}", .{config.ask_pi_wait_timeout_seconds});
    if (config.owner_chat_id) |owner_chat_id| {
        log.info("owner chat restriction enabled for chat_id={d}", .{owner_chat_id});
    } else {
        log.info("owner chat restriction disabled", .{});
    }

    try ensureSecretsExtensionInstalled(allocator, config_dir);

    if (mode == .beat) {
        const execution_scope = pushNewExecutionId();
        defer execution_scope.restore();

        log.info("running manual heartbeat", .{});

        runHeartbeat(allocator, &config, config_dir) catch |err| {
            log.err("manual heartbeat failed: {}", .{err});
            return err;
        };
        log.info("manual heartbeat finished", .{});
        return;
    }

    installSignalHandlers();
    shutdown_requested.store(false, .seq_cst);

    var telegram = TelegramClient.init(allocator, config.telegram_bot_token);
    defer telegram.deinit();

    var runtime_state = RuntimeState.init();
    var heartbeat_thread: ?std.Thread = null;
    defer if (heartbeat_thread) |*thread| {
        thread.join();
    };

    const heartbeat_interval_ms = heartbeatIntervalMillis(&config);
    if (heartbeat_interval_ms) |interval_ms| {
        const now_ms = std.time.milliTimestamp();
        const first_heartbeat_ms = std.math.add(i64, now_ms, interval_ms) catch std.math.maxInt(i64);
        runtime_state.setNextHeartbeatMillis(first_heartbeat_ms);
        heartbeat_thread = std.Thread.spawn(.{}, heartbeatWorkerMain, .{HeartbeatWorkerContext{
            .runtime_state = &runtime_state,
            .config = &config,
            .config_dir = config_dir,
            .shutdown = &shutdown_requested,
        }}) catch |err| blk: {
            log.err("failed to start heartbeat worker: {}", .{err});
            runtime_state.setNextHeartbeatMillis(std.math.maxInt(i64));
            break :blk null;
        };
    } else {
        runtime_state.setNextHeartbeatMillis(std.math.maxInt(i64));
    }

    var web_server: ?web.Server = null;

    const web_mode: web.ServeMode = if (config.web_enabled) .full else .status_only;
    web_server = blk: {
        const spawned = web.spawn(
            &runtime_state,
            &config,
            config_dir,
            web_mode,
            &shutdown_requested,
        ) catch |err| {
            if (config.web_enabled) {
                log.err("failed starting web ui: {}", .{err});
            } else {
                log.err("failed starting status api: {}", .{err});
            }
            break :blk null;
        };
        break :blk spawned;
    };

    if (config.web_enabled) {
        log.info("web ui enabled", .{});
    } else {
        log.info("web ui disabled via config, status api remains enabled", .{});
    }

    log.info("zigbot started", .{});

    var next_update_offset: i64 = 0;
    log.info("waiting for Telegram messages...", .{});
    while (!shutdown_requested.load(.acquire)) {
        const poll_timeout_seconds = clampNonNegative(config.polling_timeout_seconds);
        handlePollCycle(allocator, &runtime_state, &config, config_dir, &telegram, &next_update_offset, poll_timeout_seconds) catch |err| {
            if (shutdown_requested.load(.acquire)) break;
            runtime_state.recordPollError(err);
            log.err("poll loop error: {}", .{err});
            if (shutdown_requested.load(.acquire)) break;
            std.Thread.sleep(2 * std.time.ns_per_s);
        };
    }

    log.info("shutdown requested, stopping zigbot", .{});
    shutdown_requested.store(true, .seq_cst);
    if (web_server) |*server| {
        server.stopAndJoin();
    }
    log.info("zigbot stopped", .{});
}

fn defaultConfigDir(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        log.err("failed resolving HOME for default config path: {}", .{err});
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
    runtime_state: *RuntimeState,
    config: *const Config,
    config_dir: []const u8,
    telegram: *TelegramClient,
    next_update_offset: *i64,
    poll_timeout_seconds: i64,
) !void {
    var updates = try telegram.getUpdates(next_update_offset.*, poll_timeout_seconds);
    defer updates.deinit();
    runtime_state.recordPollSuccess();

    for (updates.value.result) |update| {
        if (update.update_id >= next_update_offset.*) {
            next_update_offset.* = update.update_id + 1;
        }

        const message = update.message orelse continue;
        const execution_scope = pushNewExecutionId();
        defer execution_scope.restore();

        if (config.owner_chat_id) |owner_chat_id| {
            if (message.chat.id != owner_chat_id) {
                log.info(
                    "ignoring message from unauthorized chat_id={d}, expected owner_chat_id={d}",
                    .{ message.chat.id, owner_chat_id },
                );
                continue;
            }
        }
        const user_text = message.text orelse continue;
        if (user_text.len == 0) continue;
        const replied_text = if (message.reply_to_message) |reply|
            reply.text orelse reply.caption
        else
            null;
        runtime_state.recordTelegramMessage();

        log.info("incoming message chat_id={d}, update_id={d}", .{ message.chat.id, update.update_id });

        var telegram_generation_failed = false;
        const response_text = response: {
            if (!runtime_state.tryBeginAgentTask(.telegram)) {
                runtime_state.recordTelegramBusyReject();
                const snapshot = runtime_state.snapshot();
                log.info(
                    "telegram request skipped, agent busy with task={s}",
                    .{agentTaskName(snapshot.active_task)},
                );
                break :response try allocator.dupe(
                    u8,
                    "I am currently busy with another request. Please try again in a moment.",
                );
            }
            defer runtime_state.finishAgentTask(.telegram);

            break :response askPi(allocator, config, config_dir, user_text, replied_text) catch |err| blk: {
                telegram_generation_failed = true;
                runtime_state.recordTelegramGenerationError(err);
                log.err("pi request failed: {}", .{err});
                break :blk try allocator.dupe(
                    u8,
                    "I hit an error while generating a reply. Please try again in a moment.",
                );
            };
        };
        defer allocator.free(response_text);

        telegram.sendMessage(message.chat.id, trimForTelegram(response_text)) catch |err| {
            runtime_state.recordTelegramSendError(err);
            return err;
        };
        if (!telegram_generation_failed) {
            runtime_state.clearTelegramError();
        }
    }
}

fn trimForTelegram(text: []const u8) []const u8 {
    const max_len = 4000;
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

fn heartbeatWorkerMain(context: HeartbeatWorkerContext) void {
    const interval_ms = heartbeatIntervalMillis(context.config) orelse {
        context.runtime_state.setNextHeartbeatMillis(std.math.maxInt(i64));
        return;
    };

    const now_ms = std.time.milliTimestamp();
    var next_heartbeat_ms = std.math.add(i64, now_ms, interval_ms) catch std.math.maxInt(i64);
    context.runtime_state.setNextHeartbeatMillis(next_heartbeat_ms);

    while (!context.shutdown.load(.acquire)) {
        waitUntilDueOrShutdown(context.shutdown, next_heartbeat_ms);
        if (context.shutdown.load(.acquire)) break;

        {
            const execution_scope = pushNewExecutionId();
            defer execution_scope.restore();

            log.info("triggering heartbeat", .{});
            context.runtime_state.recordHeartbeatStarted();
            runHeartbeat(std.heap.page_allocator, context.config, context.config_dir) catch |err| {
                context.runtime_state.recordHeartbeatError(err);
                log.err("heartbeat error: {}", .{err});
                const after_run_ms = std.time.milliTimestamp();
                next_heartbeat_ms = std.math.add(i64, after_run_ms, interval_ms) catch std.math.maxInt(i64);
                context.runtime_state.setNextHeartbeatMillis(next_heartbeat_ms);
                continue;
            };
            context.runtime_state.recordHeartbeatSuccess();

            const after_run_ms = std.time.milliTimestamp();
            next_heartbeat_ms = std.math.add(i64, after_run_ms, interval_ms) catch std.math.maxInt(i64);
            context.runtime_state.setNextHeartbeatMillis(next_heartbeat_ms);
        }
    }
}

fn waitUntilDueOrShutdown(shutdown: *std.atomic.Value(bool), due_ms: i64) void {
    while (!shutdown.load(.acquire)) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= due_ms) return;

        const remaining_ms = due_ms - now_ms;
        const sleep_ms: i64 = @min(remaining_ms, 250);
        const sleep_ns = std.math.mul(u64, @as(u64, @intCast(sleep_ms)), std.time.ns_per_ms) catch std.time.ns_per_ms;
        std.Thread.sleep(sleep_ns);
    }
}

fn heartbeatIntervalMillis(config: *const Config) ?i64 {
    const interval_seconds = config.heartbeat_interval_seconds;
    if (interval_seconds <= 0) return null;
    return std.math.mul(i64, interval_seconds, std.time.ms_per_s) catch null;
}

fn clampNonNegative(value: i64) i64 {
    return if (value < 0) 0 else value;
}

fn installSignalHandlers() void {
    if (@import("builtin").os.tag == .windows) return;

    const signal_action = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &signal_action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &signal_action, null);
}

fn handleShutdownSignal(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn pushNewExecutionId() logging.ExecutionContext {
    var execution_id_buffer: [logging.execution_id_hex_len]u8 = undefined;
    const execution_id = logging.generateExecutionId(&execution_id_buffer);
    return logging.pushExecutionId(execution_id);
}
