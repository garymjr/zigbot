const std = @import("std");

var debug_logging_enabled = std.atomic.Value(bool).init(false);

pub const execution_id_hex_len: usize = 16;
pub const max_execution_id_len: usize = 32;

threadlocal var execution_id_storage: [max_execution_id_len]u8 = undefined;
threadlocal var execution_id_len: usize = 0;

pub const ExecutionContext = struct {
    previous_storage: [max_execution_id_len]u8 = undefined,
    previous_len: usize,

    pub fn restore(self: @This()) void {
        if (self.previous_len > 0) {
            @memcpy(
                execution_id_storage[0..self.previous_len],
                self.previous_storage[0..self.previous_len],
            );
        }
        execution_id_len = self.previous_len;
    }
};

pub fn initFromEnv(allocator: std.mem.Allocator) void {
    const value = std.process.getEnvVarOwned(allocator, "ZIGBOT_DEBUG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return,
    };
    defer allocator.free(value);

    debug_logging_enabled.store(parseDebugFlag(value), .release);
}

pub fn generateExecutionId(buffer: *[execution_id_hex_len]u8) []const u8 {
    var random_bytes: [execution_id_hex_len / 2]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const encoded = std.fmt.bytesToHex(random_bytes, .lower);
    buffer.* = encoded;
    return buffer[0..];
}

pub fn pushExecutionId(execution_id: []const u8) ExecutionContext {
    var context: ExecutionContext = .{
        .previous_len = execution_id_len,
    };

    if (execution_id_len > 0) {
        @memcpy(
            context.previous_storage[0..execution_id_len],
            execution_id_storage[0..execution_id_len],
        );
    }

    const bounded_len: usize = @min(execution_id.len, max_execution_id_len);
    if (bounded_len > 0) {
        @memcpy(execution_id_storage[0..bounded_len], execution_id[0..bounded_len]);
    }
    execution_id_len = bounded_len;
    return context;
}

pub fn currentExecutionId() ?[]const u8 {
    if (execution_id_len == 0) return null;
    return execution_id_storage[0..execution_id_len];
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!shouldEmit(message_level)) return;

    var write_buffer: [1024]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&write_buffer);
    defer std.debug.unlockStderrWriter();

    var timestamp_buffer: [40]u8 = undefined;
    const timestamp = formatUtcTimestamp(std.time.milliTimestamp(), &timestamp_buffer);
    var message_buffer: [2048]u8 = undefined;
    const rendered_message = std.fmt.bufPrint(&message_buffer, format, args) catch "<log-format-error>";
    const parsed = splitOperationPrefix(rendered_message);

    if (currentExecutionId()) |execution_id| {
        if (parsed.operation) |operation| {
            nosuspend stderr.print(
                "time={s} level={s} scope={s} exec_id={f} op={s} msg={f}\n",
                .{
                    timestamp,
                    levelText(message_level),
                    @tagName(scope),
                    std.json.fmt(execution_id, .{}),
                    operation,
                    std.json.fmt(parsed.message, .{}),
                },
            ) catch return;
            return;
        }
        nosuspend stderr.print(
            "time={s} level={s} scope={s} exec_id={f} msg={f}\n",
            .{
                timestamp,
                levelText(message_level),
                @tagName(scope),
                std.json.fmt(execution_id, .{}),
                std.json.fmt(parsed.message, .{}),
            },
        ) catch return;
    } else {
        if (parsed.operation) |operation| {
            nosuspend stderr.print(
                "time={s} level={s} scope={s} op={s} msg={f}\n",
                .{
                    timestamp,
                    levelText(message_level),
                    @tagName(scope),
                    operation,
                    std.json.fmt(parsed.message, .{}),
                },
            ) catch return;
            return;
        }
        nosuspend stderr.print(
            "time={s} level={s} scope={s} msg={f}\n",
            .{
                timestamp,
                levelText(message_level),
                @tagName(scope),
                std.json.fmt(parsed.message, .{}),
            },
        ) catch return;
    }
}

const ParsedOperationMessage = struct {
    operation: ?[]const u8,
    message: []const u8,
};

fn splitOperationPrefix(message: []const u8) ParsedOperationMessage {
    if (!std.mem.startsWith(u8, message, "op=")) {
        return .{ .operation = null, .message = message };
    }

    const op_start = "op=".len;
    if (op_start >= message.len) {
        return .{ .operation = null, .message = message };
    }

    var idx: usize = op_start;
    while (idx < message.len and !isInlineWhitespace(message[idx])) : (idx += 1) {}
    if (idx == op_start) {
        return .{ .operation = null, .message = message };
    }

    const operation = message[op_start..idx];
    while (idx < message.len and isInlineWhitespace(message[idx])) : (idx += 1) {}
    return .{
        .operation = operation,
        .message = message[idx..],
    };
}

fn isInlineWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn shouldEmit(level: std.log.Level) bool {
    const max_level: std.log.Level = if (debug_logging_enabled.load(.acquire))
        .debug
    else
        .info;
    return @intFromEnum(level) <= @intFromEnum(max_level);
}

fn levelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
}

fn parseDebugFlag(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "0")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
    return true;
}

fn formatUtcTimestamp(now_ms: i64, buffer: *[40]u8) []const u8 {
    if (now_ms < 0) {
        return std.fmt.bufPrint(buffer, "unix_ms={d}", .{now_ms}) catch "unix_ms=0";
    }

    const millis: u16 = @intCast(@mod(now_ms, std.time.ms_per_s));
    const epoch_seconds = std.time.epoch.EpochSeconds{
        .secs = @intCast(@divTrunc(now_ms, std.time.ms_per_s)),
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const day: u6 = @intCast(month_day.day_index + 1);

    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            day,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            millis,
        },
    ) catch "1970-01-01T00:00:00.000Z";
}
