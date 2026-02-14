const std = @import("std");

var debug_logging_enabled = std.atomic.Value(bool).init(false);

pub const SpanStatus = enum {
    ok,
    err,
};

pub fn initFromEnv(allocator: std.mem.Allocator) void {
    const value = std.process.getEnvVarOwned(allocator, "ZIGBOT_DEBUG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return,
    };
    defer allocator.free(value);

    debug_logging_enabled.store(parseDebugFlag(value), .release);
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!shouldEmit(message_level)) return;

    var write_buffer: [512]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&write_buffer);
    defer std.debug.unlockStderrWriter();

    var timestamp_buffer: [40]u8 = undefined;
    const timestamp = formatUtcTimestamp(std.time.milliTimestamp(), &timestamp_buffer);

    nosuspend stderr.print(
        "{s} [{s}] ({s}) ",
        .{ timestamp, message_level.asText(), @tagName(scope) },
    ) catch return;
    nosuspend stderr.print(format, args) catch return;
    nosuspend stderr.writeByte('\n') catch return;
}

pub fn startSpan(comptime scope: @TypeOf(.enum_literal), name: []const u8) Span(scope) {
    const span: Span(scope) = .{
        .name = name,
        .started_ms = std.time.milliTimestamp(),
        .level = .info,
    };
    logAtLevel(scope, span.level, "span start: {s}", .{name});
    return span;
}

pub fn startSpanDebug(comptime scope: @TypeOf(.enum_literal), name: []const u8) Span(scope) {
    const span: Span(scope) = .{
        .name = name,
        .started_ms = std.time.milliTimestamp(),
        .level = .debug,
    };
    logAtLevel(scope, span.level, "span start: {s}", .{name});
    return span;
}

pub fn Span(comptime scope: @TypeOf(.enum_literal)) type {
    return struct {
        name: []const u8,
        started_ms: i64,
        level: std.log.Level,

        pub fn end(self: @This(), status: SpanStatus) void {
            const elapsed_ms = std.time.milliTimestamp() - self.started_ms;
            logAtLevel(
                scope,
                self.level,
                "span end: {s} status={s} duration_ms={d}",
                .{ self.name, @tagName(status), elapsed_ms },
            );
        }
    };
}

fn logAtLevel(
    comptime scope: @TypeOf(.enum_literal),
    level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const scoped_log = std.log.scoped(scope);
    switch (level) {
        .err => scoped_log.err(format, args),
        .warn => scoped_log.warn(format, args),
        .info => scoped_log.info(format, args),
        .debug => scoped_log.debug(format, args),
    }
}

fn shouldEmit(level: std.log.Level) bool {
    const max_level: std.log.Level = if (debug_logging_enabled.load(.acquire))
        .debug
    else
        .info;
    return @intFromEnum(level) <= @intFromEnum(max_level);
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
