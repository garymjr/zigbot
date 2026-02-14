const std = @import("std");
const logging = @import("logging.zig");
const pi = @import("pi_sdk");
const Config = @import("config.zig").Config;
const log = std.log.scoped(.pi_agent);

const setProcessGroupAndExecScript =
    "import os,sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])";
const waitProgressIntervalSeconds: u64 = 30;

pub const SharedSessionStatus = struct {
    active: bool,
    created_ms: ?i64,
    expires_at_ms: ?i64,
    ttl_remaining_ms: ?i64,
};

pub const SessionCache = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    config_dir: []const u8,
    mutex: std.Thread.Mutex = .{},
    shared_session: ?pi.AgentSession = null,
    shared_session_created_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: *const Config, config_dir: []const u8) SessionCache {
        return .{
            .allocator = allocator,
            .config = config,
            .config_dir = config_dir,
        };
    }

    pub fn deinit(self: *SessionCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.disposeSharedSessionLocked();
    }

    pub fn sharedSessionStatus(self: *SessionCache, now_ms: i64) SharedSessionStatus {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shared_session == null) {
            return .{
                .active = false,
                .created_ms = null,
                .expires_at_ms = null,
                .ttl_remaining_ms = null,
            };
        }

        if (self.shared_session_created_ms <= 0 or !self.reuseEnabled()) {
            return .{
                .active = true,
                .created_ms = if (self.shared_session_created_ms > 0) self.shared_session_created_ms else null,
                .expires_at_ms = null,
                .ttl_remaining_ms = null,
            };
        }

        const ttl_ms = self.ttlMillis();
        const expires_at_ms = std.math.add(i64, self.shared_session_created_ms, ttl_ms) catch std.math.maxInt(i64);
        const ttl_remaining_ms = if (expires_at_ms <= now_ms) 0 else expires_at_ms - now_ms;
        return .{
            .active = true,
            .created_ms = self.shared_session_created_ms,
            .expires_at_ms = expires_at_ms,
            .ttl_remaining_ms = ttl_remaining_ms,
        };
    }

    pub fn expireSharedSession(self: *SessionCache) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const had_shared_session = self.shared_session != null;
        if (had_shared_session) {
            log.info("op=session rotate reason=manual_timeout", .{});
        }
        self.disposeSharedSessionLocked();
        return had_shared_session;
    }

    fn reuseEnabled(self: *const SessionCache) bool {
        return self.config.pi_session_ttl_seconds > 0;
    }

    fn ttlMillis(self: *const SessionCache) i64 {
        return std.math.mul(i64, self.config.pi_session_ttl_seconds, std.time.ms_per_s) catch std.math.maxInt(i64);
    }

    fn shouldRotateSharedSessionLocked(self: *const SessionCache, now_ms: i64) bool {
        if (self.shared_session == null) return false;
        if (!self.reuseEnabled()) return true;
        if (self.shared_session_created_ms <= 0) return true;
        const age_ms = now_ms - self.shared_session_created_ms;
        return age_ms >= self.ttlMillis();
    }

    fn disposeSharedSessionLocked(self: *SessionCache) void {
        if (self.shared_session) |*session| {
            session.dispose();
            self.shared_session = null;
        }
        self.shared_session_created_ms = 0;
    }

    fn acquireSharedSessionLocked(self: *SessionCache) !*pi.AgentSession {
        const now_ms = std.time.milliTimestamp();
        if (self.shouldRotateSharedSessionLocked(now_ms)) {
            const age_ms = if (self.shared_session_created_ms > 0) now_ms - self.shared_session_created_ms else -1;
            log.info(
                "op=session rotate reason=max_age age_ms={d} ttl_s={d}",
                .{ age_ms, self.config.pi_session_ttl_seconds },
            );
            self.disposeSharedSessionLocked();
        }

        if (self.shared_session == null) {
            log.info("op=session create mode=shared ttl_s={d}", .{self.config.pi_session_ttl_seconds});
            const created = try createIsolatedAgentSession(self.allocator, self.config, self.config_dir);
            self.shared_session = created.session;
            self.shared_session_created_ms = now_ms;
        }

        return &self.shared_session.?;
    }
};

pub fn askPi(
    allocator: std.mem.Allocator,
    session_cache: *SessionCache,
    prompt: []const u8,
    replied_message: ?[]const u8,
) ![]u8 {
    const contextual_prompt = if (replied_message) |reply| try std.fmt.allocPrint(
        allocator,
        "Runtime context:\n- Config directory: {s}\n- AGENTS file path (if present): {s}/AGENTS.md\n- Skills directory (if present): {s}/skills\n\nTelegram conversation context:\n- User message:\n{s}\n\n- Message being replied to:\n{s}",
        .{ session_cache.config_dir, session_cache.config_dir, session_cache.config_dir, prompt, reply },
    ) else try std.fmt.allocPrint(
        allocator,
        "Runtime context:\n- Config directory: {s}\n- AGENTS file path (if present): {s}/AGENTS.md\n- Skills directory (if present): {s}/skills\n\nUser message:\n{s}",
        .{ session_cache.config_dir, session_cache.config_dir, session_cache.config_dir, prompt },
    );
    defer allocator.free(contextual_prompt);

    log.info("op=ask_pi prompt_dispatched user_bytes={d} replied_context={s}", .{
        prompt.len,
        if (replied_message != null) "yes" else "no",
    });
    if (!session_cache.reuseEnabled()) {
        log.info("op=ask_pi create_session mode=fresh", .{});
        var created = try createIsolatedAgentSession(allocator, session_cache.config, session_cache.config_dir);
        defer created.session.dispose();
        try created.session.prompt(contextual_prompt, .{});
        try waitForIdleWithProgress(
            &created.session,
            "ask_pi",
            timeoutSecondsOrDisabled(session_cache.config.ask_pi_wait_timeout_seconds),
        );

        if (try created.session.getLastAssistantText()) |text| {
            log.info("op=ask_pi response_received bytes={d}", .{text.len});
            return text;
        }
        log.warn("op=ask_pi no_response", .{});
        return allocator.dupe(u8, "I could not generate a response.");
    }

    session_cache.mutex.lock();
    defer session_cache.mutex.unlock();

    const session = try session_cache.acquireSharedSessionLocked();
    session.prompt(contextual_prompt, .{}) catch |err| {
        session_cache.disposeSharedSessionLocked();
        return err;
    };
    waitForIdleWithProgress(
        session,
        "ask_pi",
        timeoutSecondsOrDisabled(session_cache.config.ask_pi_wait_timeout_seconds),
    ) catch |err| {
        session_cache.disposeSharedSessionLocked();
        return err;
    };

    if (session.getLastAssistantText() catch |err| {
        session_cache.disposeSharedSessionLocked();
        return err;
    }) |text| {
        defer session_cache.allocator.free(text);
        log.info("op=ask_pi response_received bytes={d}", .{text.len});
        return allocator.dupe(u8, text);
    }
    log.warn("op=ask_pi no_response", .{});
    return allocator.dupe(u8, "I could not generate a response.");
}

pub fn runHeartbeat(
    allocator: std.mem.Allocator,
    session_cache: *SessionCache,
) !void {
    const heartbeat_prompt = try std.fmt.allocPrint(
        allocator,
        "Heartbeat event:\n- This is an automated heartbeat from zigbot.\n- Follow instructions in HEARTBEAT.md at {s}/HEARTBEAT.md if present.\n- Timestamp (unix): {d}\n\nRespond with a short status update about this heartbeat.",
        .{ session_cache.config_dir, std.time.timestamp() },
    );
    defer allocator.free(heartbeat_prompt);

    log.info("op=heartbeat prompt_dispatched", .{});
    if (!session_cache.reuseEnabled()) {
        log.info("op=heartbeat create_session mode=fresh", .{});
        var created = try createIsolatedAgentSession(allocator, session_cache.config, session_cache.config_dir);
        defer created.session.dispose();
        try created.session.prompt(heartbeat_prompt, .{});
        try waitForIdleWithProgress(
            &created.session,
            "heartbeat",
            timeoutSecondsOrDisabled(session_cache.config.heartbeat_wait_timeout_seconds),
        );

        if (try created.session.getLastAssistantText()) |text| {
            log.info("op=heartbeat response_received bytes={d}", .{text.len});
            allocator.free(text);
        } else {
            log.warn("op=heartbeat no_response", .{});
        }
        return;
    }

    session_cache.mutex.lock();
    defer session_cache.mutex.unlock();

    const session = try session_cache.acquireSharedSessionLocked();
    session.prompt(heartbeat_prompt, .{}) catch |err| {
        session_cache.disposeSharedSessionLocked();
        return err;
    };
    waitForIdleWithProgress(
        session,
        "heartbeat",
        timeoutSecondsOrDisabled(session_cache.config.heartbeat_wait_timeout_seconds),
    ) catch |err| {
        session_cache.disposeSharedSessionLocked();
        return err;
    };

    if (session.getLastAssistantText() catch |err| {
        session_cache.disposeSharedSessionLocked();
        return err;
    }) |text| {
        log.info("op=heartbeat response_received bytes={d}", .{text.len});
        session_cache.allocator.free(text);
    } else {
        log.warn("op=heartbeat no_response", .{});
    }
}

fn createIsolatedAgentSession(
    allocator: std.mem.Allocator,
    config: *const Config,
    config_dir: []const u8,
) !pi.CreateAgentSessionResult {
    var raw_spawn_args = std.array_list.Managed([]const u8).init(allocator);
    defer raw_spawn_args.deinit();

    try raw_spawn_args.appendSlice(&.{
        "-c",
        setProcessGroupAndExecScript,
        config.pi_executable,
        "--mode",
        "rpc",
        "--no-session",
    });

    if (config.provider) |provider| {
        try raw_spawn_args.append("--provider");
        try raw_spawn_args.append(provider);
    }

    if (config.model) |model| {
        try raw_spawn_args.append("--model");
        try raw_spawn_args.append(model);
    }

    // Run `pi` from a new process group so signal handling inside the agent
    // cannot terminate zigbot's own process group.
    return try pi.createAgentSession(.{
        .allocator = allocator,
        .pi_executable = "python3",
        .raw_spawn_args = raw_spawn_args.items,
        .cwd = config_dir,
        .agent_dir = config_dir,
        .session_manager = pi.SessionManager.inMemory(),
    });
}

const WaitProgressState = struct {
    session: *pi.AgentSession,
    label: []const u8,
    timeout_seconds: ?u64,
    started_ms: i64,
    execution_id_len: usize,
    execution_id: [logging.max_execution_id_len]u8,
    last_event_ms: std.atomic.Value(i64),
    agent_start_events: std.atomic.Value(u32),
    toolcall_start_events: std.atomic.Value(u32),
    toolcall_end_events: std.atomic.Value(u32),
    error_events: std.atomic.Value(u32),
    other_typed_events: std.atomic.Value(u32),
    untyped_events: std.atomic.Value(u32),
    total_events: std.atomic.Value(u32),
    done: std.atomic.Value(bool),
    timed_out: std.atomic.Value(bool),

    fn init(session: *pi.AgentSession, label: []const u8, timeout_seconds: ?u64) WaitProgressState {
        const now_ms = std.time.milliTimestamp();
        var state: WaitProgressState = .{
            .session = session,
            .label = label,
            .timeout_seconds = timeout_seconds,
            .started_ms = now_ms,
            .execution_id_len = 0,
            .execution_id = undefined,
            .last_event_ms = std.atomic.Value(i64).init(now_ms),
            .agent_start_events = std.atomic.Value(u32).init(0),
            .toolcall_start_events = std.atomic.Value(u32).init(0),
            .toolcall_end_events = std.atomic.Value(u32).init(0),
            .error_events = std.atomic.Value(u32).init(0),
            .other_typed_events = std.atomic.Value(u32).init(0),
            .untyped_events = std.atomic.Value(u32).init(0),
            .total_events = std.atomic.Value(u32).init(0),
            .done = std.atomic.Value(bool).init(false),
            .timed_out = std.atomic.Value(bool).init(false),
        };
        if (logging.currentExecutionId()) |execution_id| {
            const bounded_len: usize = @min(execution_id.len, state.execution_id.len);
            if (bounded_len > 0) {
                @memcpy(state.execution_id[0..bounded_len], execution_id[0..bounded_len]);
            }
            state.execution_id_len = bounded_len;
        }
        return state;
    }

    fn executionId(self: *const WaitProgressState) ?[]const u8 {
        if (self.execution_id_len == 0) return null;
        return self.execution_id[0..self.execution_id_len];
    }
};

fn waitForIdleWithProgress(session: *pi.AgentSession, label: []const u8, timeout_seconds: ?u64) !void {
    var state = WaitProgressState.init(session, label, timeout_seconds);
    session.subscribe(.{
        .callback = onWaitProgressEvent,
        .context = &state,
    });
    defer session.unsubscribe();

    var logger_thread: ?std.Thread = std.Thread.spawn(.{}, waitProgressLoggerMain, .{&state}) catch |err| blk: {
        log.err("op={s} progress_logger_start_failed err={}", .{ label, err });
        break :blk null;
    };
    defer {
        state.done.store(true, .release);
        if (logger_thread) |*thread| {
            thread.join();
        }
    }

    log.info("op={s} wait_start", .{label});
    session.waitForIdle() catch |err| {
        if (state.timed_out.load(.acquire)) return error.AgentWaitTimeout;
        return err;
    };
    if (state.timed_out.load(.acquire)) return error.AgentWaitTimeout;
    const elapsed_seconds = @divFloor(std.time.milliTimestamp() - state.started_ms, std.time.ms_per_s);
    const parse_misses = state.untyped_events.load(.acquire);
    log.info(
        "op={s} completed elapsed_s={d} events={d} toolcalls_started={d} toolcalls_finished={d} errors={d} non_core_events={d}",
        .{
            label,
            elapsed_seconds,
            state.total_events.load(.acquire),
            state.toolcall_start_events.load(.acquire),
            state.toolcall_end_events.load(.acquire),
            state.error_events.load(.acquire),
            state.other_typed_events.load(.acquire),
        },
    );
    if (parse_misses > 0) {
        log.warn("op={s} event_parse_misses={d}", .{ label, parse_misses });
    }
}

fn waitProgressLoggerMain(state: *WaitProgressState) void {
    const execution_scope = if (state.executionId()) |execution_id|
        logging.pushExecutionId(execution_id)
    else
        null;
    defer if (execution_scope) |scope| {
        scope.restore();
    };

    var previous_total_events: u32 = 0;
    while (true) {
        var waited_seconds: u64 = 0;
        while (waited_seconds < waitProgressIntervalSeconds) : (waited_seconds += 1) {
            std.Thread.sleep(std.time.ns_per_s);
            if (state.done.load(.acquire)) return;
        }

        const now_ms = std.time.milliTimestamp();
        const elapsed_seconds = @divFloor(now_ms - state.started_ms, std.time.ms_per_s);
        const last_event_ms = state.last_event_ms.load(.acquire);
        const idle_seconds = @divFloor(now_ms - last_event_ms, std.time.ms_per_s);

        if (state.timeout_seconds) |timeout_seconds| {
            if (!state.timed_out.load(.acquire) and elapsed_seconds >= timeout_seconds) {
                state.timed_out.store(true, .release);
                log.err(
                    "op={s} timeout elapsed_s={d} action=terminate_process",
                    .{ state.label, elapsed_seconds },
                );
                terminateSessionProcess(state.session, state.label);
                continue;
            }
        }

        const total_events = state.total_events.load(.acquire);
        const new_events = total_events - previous_total_events;
        previous_total_events = total_events;
        if (idle_seconds >= waitProgressIntervalSeconds or new_events == 0) {
            log.info(
                "op={s} waiting elapsed_s={d} idle_s={d} events={d} new_events={d}",
                .{ state.label, elapsed_seconds, idle_seconds, total_events, new_events },
            );
        }
    }
}

fn timeoutSecondsOrDisabled(value_seconds: i64) ?u64 {
    if (value_seconds <= 0) return null;
    return @intCast(value_seconds);
}

fn terminateSessionProcess(session: *pi.AgentSession, label: []const u8) void {
    _ = session.process.kill() catch |err| switch (err) {
        error.AlreadyTerminated => {
            _ = session.process.wait() catch {};
        },
        else => {
            log.err("op={s} terminate_failed err={}", .{ label, err });
        },
    };
}

fn onWaitProgressEvent(context: ?*anyopaque, event_json: []const u8) void {
    const state = @as(*WaitProgressState, @ptrCast(@alignCast(context orelse return)));
    const execution_scope = if (state.executionId()) |execution_id|
        logging.pushExecutionId(execution_id)
    else
        null;
    defer if (execution_scope) |scope| {
        scope.restore();
    };

    const now_ms = std.time.milliTimestamp();
    state.last_event_ms.store(now_ms, .release);
    _ = state.total_events.fetchAdd(1, .monotonic);

    const event_type = topLevelEventType(event_json) orelse {
        _ = state.untyped_events.fetchAdd(1, .monotonic);
        return;
    };
    if (std.mem.eql(u8, event_type, "agent_start")) {
        _ = state.agent_start_events.fetchAdd(1, .monotonic);
    } else if (std.mem.eql(u8, event_type, "toolcall_start")) {
        _ = state.toolcall_start_events.fetchAdd(1, .monotonic);
    } else if (std.mem.eql(u8, event_type, "toolcall_end")) {
        _ = state.toolcall_end_events.fetchAdd(1, .monotonic);
    } else if (std.mem.eql(u8, event_type, "agent_end")) {
        _ = state.other_typed_events.fetchAdd(1, .monotonic);
    } else if (std.mem.eql(u8, event_type, "error")) {
        const previous_count = state.error_events.fetchAdd(1, .monotonic);
        log.err("op={s} agent_error_event count={d}", .{ state.label, previous_count + 1 });
    } else {
        _ = state.other_typed_events.fetchAdd(1, .monotonic);
    }
}

fn topLevelEventType(event_json: []const u8) ?[]const u8 {
    const key_marker = "\"type\"";
    const key_idx = std.mem.indexOf(u8, event_json, key_marker) orelse return null;
    var idx = key_idx + key_marker.len;

    while (idx < event_json.len and isJsonWhitespace(event_json[idx])) : (idx += 1) {}
    if (idx >= event_json.len or event_json[idx] != ':') return null;
    idx += 1;

    while (idx < event_json.len and isJsonWhitespace(event_json[idx])) : (idx += 1) {}
    if (idx >= event_json.len or event_json[idx] != '"') return null;
    idx += 1;
    const value_start = idx;

    while (idx < event_json.len) {
        const ch = event_json[idx];
        if (ch == '\\') {
            idx += 2;
            continue;
        }
        if (ch == '"') return event_json[value_start..idx];
        idx += 1;
    }

    return null;
}

fn isJsonWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t';
}
