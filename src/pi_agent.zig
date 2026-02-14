const std = @import("std");
const pi = @import("pi_sdk");
const Config = @import("config.zig").Config;

const setProcessGroupAndExecScript =
    "import os,sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])";
const waitProgressIntervalSeconds: u64 = 30;

pub fn askPi(
    allocator: std.mem.Allocator,
    config: *const Config,
    config_dir: []const u8,
    prompt: []const u8,
    replied_message: ?[]const u8,
) ![]u8 {
    std.log.info("askPi: creating agent session", .{});

    var created = try createIsolatedAgentSession(allocator, config, config_dir);
    defer created.session.dispose();

    const contextual_prompt = if (replied_message) |reply| try std.fmt.allocPrint(
        allocator,
        "Runtime context:\n- Config directory: {s}\n- AGENTS file path (if present): {s}/AGENTS.md\n- Skills directory (if present): {s}/skills\n\nTelegram conversation context:\n- User message:\n{s}\n\n- Message being replied to:\n{s}",
        .{ config_dir, config_dir, config_dir, prompt, reply },
    ) else try std.fmt.allocPrint(
        allocator,
        "Runtime context:\n- Config directory: {s}\n- AGENTS file path (if present): {s}/AGENTS.md\n- Skills directory (if present): {s}/skills\n\nUser message:\n{s}",
        .{ config_dir, config_dir, config_dir, prompt },
    );
    defer allocator.free(contextual_prompt);

    try created.session.prompt(contextual_prompt, .{});
    try waitForIdleWithProgress(&created.session, "askPi");

    if (try created.session.getLastAssistantText()) |text| {
        return text;
    }

    return allocator.dupe(u8, "I could not generate a response.");
}

pub fn runHeartbeat(
    allocator: std.mem.Allocator,
    config: *const Config,
    config_dir: []const u8,
) !void {
    var created = try createIsolatedAgentSession(allocator, config, config_dir);
    defer created.session.dispose();

    const heartbeat_prompt = try std.fmt.allocPrint(
        allocator,
        "Heartbeat event:\n- This is an automated heartbeat from zigbot.\n- Follow instructions in HEARTBEAT.md at {s}/HEARTBEAT.md if present.\n- Timestamp (unix): {d}\n\nRespond with a short status update about this heartbeat.",
        .{ config_dir, std.time.timestamp() },
    );
    defer allocator.free(heartbeat_prompt);

    try created.session.prompt(heartbeat_prompt, .{});
    try waitForIdleWithProgress(&created.session, "heartbeat");

    if (try created.session.getLastAssistantText()) |text| {
        defer allocator.free(text);
        std.log.info("heartbeat response: {s}", .{trimForLog(text)});
    } else {
        std.log.info("heartbeat completed with no text response", .{});
    }
}

fn trimForLog(text: []const u8) []const u8 {
    const max_len = 280;
    if (text.len <= max_len) return text;
    return text[0..max_len];
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
    label: []const u8,
    started_ms: i64,
    last_event_ms: std.atomic.Value(i64),
    done: std.atomic.Value(bool),

    fn init(label: []const u8) WaitProgressState {
        const now_ms = std.time.milliTimestamp();
        return .{
            .label = label,
            .started_ms = now_ms,
            .last_event_ms = std.atomic.Value(i64).init(now_ms),
            .done = std.atomic.Value(bool).init(false),
        };
    }
};

fn waitForIdleWithProgress(session: *pi.AgentSession, label: []const u8) !void {
    var state = WaitProgressState.init(label);
    session.subscribe(.{
        .callback = onWaitProgressEvent,
        .context = &state,
    });
    defer session.unsubscribe();

    var logger_thread: ?std.Thread = std.Thread.spawn(.{}, waitProgressLoggerMain, .{&state}) catch |err| blk: {
        std.log.err("{s}: failed to start progress logger thread: {}", .{ label, err });
        break :blk null;
    };
    defer {
        state.done.store(true, .release);
        if (logger_thread) |*thread| {
            thread.join();
        }
    }

    std.log.info("{s}: waiting for agent completion", .{label});
    try session.waitForIdle();
    std.log.info("{s}: agent completed", .{label});
}

fn waitProgressLoggerMain(state: *WaitProgressState) void {
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
        std.log.info(
            "{s}: still running (elapsed={d}s, since last event={d}s)",
            .{ state.label, elapsed_seconds, idle_seconds },
        );
    }
}

fn onWaitProgressEvent(context: ?*anyopaque, event_json: []const u8) void {
    const state = @as(*WaitProgressState, @ptrCast(@alignCast(context orelse return)));
    const now_ms = std.time.milliTimestamp();
    state.last_event_ms.store(now_ms, .release);

    const event_type = topLevelEventType(event_json) orelse return;
    if (std.mem.eql(u8, event_type, "agent_start")) {
        std.log.info("{s}: agent started", .{state.label});
    } else if (std.mem.eql(u8, event_type, "toolcall_start")) {
        std.log.info("{s}: tool call started", .{state.label});
    } else if (std.mem.eql(u8, event_type, "toolcall_end")) {
        std.log.info("{s}: tool call finished", .{state.label});
    } else if (std.mem.eql(u8, event_type, "agent_end")) {
        std.log.info("{s}: agent end event received", .{state.label});
    } else if (std.mem.eql(u8, event_type, "error")) {
        std.log.err("{s}: error event received", .{state.label});
    }
}

fn topLevelEventType(event_json: []const u8) ?[]const u8 {
    const marker = "\"type\":\"";
    const type_start_idx = std.mem.indexOf(u8, event_json, marker) orelse return null;
    const value_start = type_start_idx + marker.len;
    if (value_start >= event_json.len) return null;

    const rest = event_json[value_start..];
    const value_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..value_end];
}
