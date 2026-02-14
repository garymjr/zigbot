const std = @import("std");

pub const AgentTask = enum {
    none,
    telegram,
    heartbeat,
};

const maxErrorTextLen = 160;

pub const Snapshot = struct {
    captured_ms: i64 = 0,
    started_ms: i64 = 0,
    next_heartbeat_ms: i64 = std.math.maxInt(i64),

    last_poll_ms: i64 = 0,
    last_poll_ok: bool = true,
    poll_error_count: u64 = 0,
    last_poll_error: [maxErrorTextLen]u8 = [_]u8{0} ** maxErrorTextLen,
    last_poll_error_len: usize = 0,

    telegram_message_count: u64 = 0,
    telegram_busy_reject_count: u64 = 0,
    telegram_generation_error_count: u64 = 0,
    telegram_send_error_count: u64 = 0,
    last_telegram_error: [maxErrorTextLen]u8 = [_]u8{0} ** maxErrorTextLen,
    last_telegram_error_len: usize = 0,
    heartbeat_deferred_count: u64 = 0,

    heartbeat_run_count: u64 = 0,
    heartbeat_error_count: u64 = 0,
    last_heartbeat_started_ms: i64 = 0,
    last_heartbeat_finished_ms: i64 = 0,
    last_heartbeat_ok: bool = true,
    last_heartbeat_error: [maxErrorTextLen]u8 = [_]u8{0} ** maxErrorTextLen,
    last_heartbeat_error_len: usize = 0,

    agent_busy: bool = false,
    active_task: AgentTask = .none,
    active_task_started_ms: i64 = 0,

    pub fn pollError(self: *const Snapshot) []const u8 {
        return self.last_poll_error[0..self.last_poll_error_len];
    }

    pub fn heartbeatError(self: *const Snapshot) []const u8 {
        return self.last_heartbeat_error[0..self.last_heartbeat_error_len];
    }

    pub fn telegramError(self: *const Snapshot) []const u8 {
        return self.last_telegram_error[0..self.last_telegram_error_len];
    }
};

pub const RuntimeState = struct {
    mutex: std.Thread.Mutex = .{},

    started_ms: i64 = 0,
    next_heartbeat_ms: i64 = std.math.maxInt(i64),

    last_poll_ms: i64 = 0,
    last_poll_ok: bool = true,
    poll_error_count: u64 = 0,
    last_poll_error: [maxErrorTextLen]u8 = [_]u8{0} ** maxErrorTextLen,
    last_poll_error_len: usize = 0,

    telegram_message_count: u64 = 0,
    telegram_busy_reject_count: u64 = 0,
    telegram_generation_error_count: u64 = 0,
    telegram_send_error_count: u64 = 0,
    last_telegram_error: [maxErrorTextLen]u8 = [_]u8{0} ** maxErrorTextLen,
    last_telegram_error_len: usize = 0,
    heartbeat_deferred_count: u64 = 0,

    heartbeat_run_count: u64 = 0,
    heartbeat_error_count: u64 = 0,
    last_heartbeat_started_ms: i64 = 0,
    last_heartbeat_finished_ms: i64 = 0,
    last_heartbeat_ok: bool = true,
    last_heartbeat_error: [maxErrorTextLen]u8 = [_]u8{0} ** maxErrorTextLen,
    last_heartbeat_error_len: usize = 0,

    agent_busy: bool = false,
    active_task: AgentTask = .none,
    active_task_started_ms: i64 = 0,

    pub fn init() RuntimeState {
        return .{
            .started_ms = std.time.milliTimestamp(),
        };
    }

    pub fn setNextHeartbeatMillis(self: *RuntimeState, next_heartbeat_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.next_heartbeat_ms = next_heartbeat_ms;
    }

    pub fn recordPollSuccess(self: *RuntimeState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_poll_ms = std.time.milliTimestamp();
        self.last_poll_ok = true;
        self.last_poll_error_len = 0;
    }

    pub fn recordPollError(self: *RuntimeState, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_poll_ms = std.time.milliTimestamp();
        self.last_poll_ok = false;
        self.poll_error_count += 1;
        writeErrorName(&self.last_poll_error, &self.last_poll_error_len, err);
    }

    pub fn recordTelegramMessage(self: *RuntimeState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.telegram_message_count += 1;
    }

    pub fn recordTelegramBusyReject(self: *RuntimeState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.telegram_busy_reject_count += 1;
    }

    pub fn recordTelegramGenerationError(self: *RuntimeState, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.telegram_generation_error_count += 1;
        writeErrorName(&self.last_telegram_error, &self.last_telegram_error_len, err);
    }

    pub fn recordTelegramSendError(self: *RuntimeState, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.telegram_send_error_count += 1;
        writeErrorName(&self.last_telegram_error, &self.last_telegram_error_len, err);
    }

    pub fn clearTelegramError(self: *RuntimeState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_telegram_error_len = 0;
    }

    pub fn tryBeginAgentTask(self: *RuntimeState, task: AgentTask) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.agent_busy) return false;
        self.agent_busy = true;
        self.active_task = task;
        self.active_task_started_ms = std.time.milliTimestamp();
        return true;
    }

    pub fn finishAgentTask(self: *RuntimeState, task: AgentTask) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.agent_busy) return;
        if (self.active_task != task) return;

        self.agent_busy = false;
        self.active_task = .none;
        self.active_task_started_ms = 0;
    }

    pub fn recordHeartbeatStarted(self: *RuntimeState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.heartbeat_run_count += 1;
        self.last_heartbeat_started_ms = std.time.milliTimestamp();
    }

    pub fn recordHeartbeatSuccess(self: *RuntimeState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_heartbeat_finished_ms = std.time.milliTimestamp();
        self.last_heartbeat_ok = true;
        self.last_heartbeat_error_len = 0;
    }

    pub fn recordHeartbeatError(self: *RuntimeState, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_heartbeat_finished_ms = std.time.milliTimestamp();
        self.last_heartbeat_ok = false;
        self.heartbeat_error_count += 1;
        writeErrorName(&self.last_heartbeat_error, &self.last_heartbeat_error_len, err);
    }

    pub fn recordHeartbeatDeferred(self: *RuntimeState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.heartbeat_deferred_count += 1;
    }

    pub fn snapshot(self: *RuntimeState) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .captured_ms = std.time.milliTimestamp(),
            .started_ms = self.started_ms,
            .next_heartbeat_ms = self.next_heartbeat_ms,
            .last_poll_ms = self.last_poll_ms,
            .last_poll_ok = self.last_poll_ok,
            .poll_error_count = self.poll_error_count,
            .last_poll_error = self.last_poll_error,
            .last_poll_error_len = self.last_poll_error_len,
            .telegram_message_count = self.telegram_message_count,
            .telegram_busy_reject_count = self.telegram_busy_reject_count,
            .telegram_generation_error_count = self.telegram_generation_error_count,
            .telegram_send_error_count = self.telegram_send_error_count,
            .last_telegram_error = self.last_telegram_error,
            .last_telegram_error_len = self.last_telegram_error_len,
            .heartbeat_deferred_count = self.heartbeat_deferred_count,
            .heartbeat_run_count = self.heartbeat_run_count,
            .heartbeat_error_count = self.heartbeat_error_count,
            .last_heartbeat_started_ms = self.last_heartbeat_started_ms,
            .last_heartbeat_finished_ms = self.last_heartbeat_finished_ms,
            .last_heartbeat_ok = self.last_heartbeat_ok,
            .last_heartbeat_error = self.last_heartbeat_error,
            .last_heartbeat_error_len = self.last_heartbeat_error_len,
            .agent_busy = self.agent_busy,
            .active_task = self.active_task,
            .active_task_started_ms = self.active_task_started_ms,
        };
    }
};

pub fn agentTaskName(task: AgentTask) []const u8 {
    return switch (task) {
        .none => "none",
        .telegram => "telegram",
        .heartbeat => "heartbeat",
    };
}

fn writeErrorName(buffer: *[maxErrorTextLen]u8, len: *usize, err: anyerror) void {
    const name = @errorName(err);
    writeTruncated(buffer, len, name);
}

fn writeTruncated(buffer: anytype, len: *usize, input: []const u8) void {
    const max_len = buffer.len;
    const copy_len = @min(input.len, max_len);
    if (copy_len > 0) {
        @memcpy(buffer[0..copy_len], input[0..copy_len]);
    }
    len.* = copy_len;
}
