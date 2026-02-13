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
        telegram_bot_token: ?[]u8 = null,
        pi_executable: ?[]u8 = null,
        provider: ?[]u8 = null,
        model: ?[]u8 = null,
        polling_timeout_seconds: ?i64 = null,

        fn deinit(self: *ConfigFile, allocator: std.mem.Allocator) void {
            if (self.telegram_bot_token) |value| allocator.free(value);
            if (self.pi_executable) |value| allocator.free(value);
            if (self.provider) |value| allocator.free(value);
            if (self.model) |value| allocator.free(value);
        }
    };

    fn load(allocator: std.mem.Allocator, config_path: []const u8) !Config {
        const config_bytes = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
            if (err != error.FileNotFound) {
                std.log.err("failed reading config file {s}: {}", .{ config_path, err });
            }
            return err;
        };
        defer allocator.free(config_bytes);

        var parsed = parseTomlConfig(allocator, config_bytes) catch |err| {
            std.log.err("failed parsing TOML config file {s}: {}", .{ config_path, err });
            return err;
        };
        defer parsed.deinit(allocator);

        const telegram_bot_token = parsed.telegram_bot_token orelse {
            std.log.err("missing required config field: telegram_bot_token", .{});
            return BotError.MissingRequiredConfigField;
        };
        parsed.telegram_bot_token = null;
        errdefer allocator.free(telegram_bot_token);

        const pi_executable = if (parsed.pi_executable) |value| blk: {
            parsed.pi_executable = null;
            break :blk value;
        } else try allocator.dupe(u8, "pi");
        errdefer allocator.free(pi_executable);

        const provider = if (parsed.provider) |value| blk: {
            parsed.provider = null;
            break :blk value;
        } else null;
        errdefer if (provider) |value| allocator.free(value);

        const model = if (parsed.model) |value| blk: {
            parsed.model = null;
            break :blk value;
        } else null;
        errdefer if (model) |value| allocator.free(value);

        const polling_timeout_seconds = parsed.polling_timeout_seconds orelse 30;

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

const TableContext = enum {
    root,
    zigbot,
    other,
};

const TargetField = enum {
    none,
    telegram_bot_token,
    pi_executable,
    provider,
    model,
    polling_timeout_seconds,
};

fn parseTomlConfig(allocator: std.mem.Allocator, config_bytes: []const u8) !Config.ConfigFile {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();

    var parser: TomlParser = .{
        .allocator = allocator,
        .temp_allocator = temp_arena.allocator(),
        .input = config_bytes,
    };
    return parser.parseConfig();
}

const TomlParser = struct {
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,
    table_context: TableContext = .root,

    const SeenFields = struct {
        telegram_bot_token: bool = false,
        pi_executable: bool = false,
        provider: bool = false,
        model: bool = false,
        polling_timeout_seconds: bool = false,
    };

    fn parseConfig(self: *TomlParser) !Config.ConfigFile {
        var parsed: Config.ConfigFile = .{};
        errdefer parsed.deinit(self.allocator);

        var seen: SeenFields = .{};
        while (true) {
            self.skipIgnoredTopLevel();
            if (self.isEof()) break;

            if (self.peek() == '[') {
                try self.parseTableHeader();
                continue;
            }

            try self.parseKeyValue(&parsed, &seen);
        }

        return parsed;
    }

    fn parseTableHeader(self: *TomlParser) !void {
        const is_array_table = self.consumeIfString("[[");
        if (!is_array_table) {
            try self.expectByte('[');
        }

        self.skipSpaces();

        var segments: [16][]const u8 = undefined;
        const seg_len = try self.parseKeyPathSegments(&segments);
        if (seg_len == 0) return error.InvalidTomlTableHeader;

        self.skipSpaces();
        if (is_array_table) {
            try self.expectByte(']');
            try self.expectByte(']');
            self.table_context = .other;
        } else {
            try self.expectByte(']');
            self.table_context = if (seg_len == 1 and std.mem.eql(u8, segments[0], "zigbot"))
                .zigbot
            else
                .other;
        }

        try self.expectStatementEnd();
    }

    fn parseKeyValue(self: *TomlParser, parsed: *Config.ConfigFile, seen: *SeenFields) !void {
        var segments: [16][]const u8 = undefined;
        const seg_len = try self.parseKeyPathSegments(&segments);
        if (seg_len == 0) return error.InvalidTomlKey;

        self.skipSpaces();
        try self.expectByte('=');
        self.skipSpaces();

        const field = resolveTargetField(self.table_context, segments[0..seg_len]);
        switch (field) {
            .telegram_bot_token => {
                if (seen.telegram_bot_token) return error.DuplicateTomlKey;
                parsed.telegram_bot_token = try self.parseStringValue(self.allocator);
                seen.telegram_bot_token = true;
            },
            .pi_executable => {
                if (seen.pi_executable) return error.DuplicateTomlKey;
                parsed.pi_executable = try self.parseStringValue(self.allocator);
                seen.pi_executable = true;
            },
            .provider => {
                if (seen.provider) return error.DuplicateTomlKey;
                parsed.provider = try self.parseStringValue(self.allocator);
                seen.provider = true;
            },
            .model => {
                if (seen.model) return error.DuplicateTomlKey;
                parsed.model = try self.parseStringValue(self.allocator);
                seen.model = true;
            },
            .polling_timeout_seconds => {
                if (seen.polling_timeout_seconds) return error.DuplicateTomlKey;
                parsed.polling_timeout_seconds = try self.parseIntegerValue();
                seen.polling_timeout_seconds = true;
            },
            .none => try self.skipTomlValue(),
        }

        try self.expectStatementEnd();
    }

    fn parseKeyPathSegments(self: *TomlParser, segments: *[16][]const u8) !usize {
        var len: usize = 0;
        while (true) {
            self.skipSpaces();

            if (len >= segments.len) return error.TomlPathTooDeep;
            segments[len] = try self.parseKeySegment();
            len += 1;

            self.skipSpaces();
            if (self.consumeIfByte('.')) continue;
            break;
        }
        return len;
    }

    fn parseKeySegment(self: *TomlParser) ![]const u8 {
        if (self.isEof()) return error.InvalidTomlKey;

        return switch (self.peek()) {
            '"' => try self.parseBasicString(self.temp_allocator),
            '\'' => try self.parseLiteralString(self.temp_allocator),
            else => blk: {
                const start = self.index;
                while (!self.isEof() and isBareKeyChar(self.peek())) {
                    self.index += 1;
                }
                if (self.index == start) return error.InvalidTomlKey;
                break :blk self.input[start..self.index];
            },
        };
    }

    fn parseIntegerValue(self: *TomlParser) !i64 {
        const token = try self.parseBareToken();
        return self.parseIntegerToken(token);
    }

    fn parseStringValue(self: *TomlParser, output_allocator: std.mem.Allocator) ![]u8 {
        if (self.consumeIfString("\"\"\"")) return self.parseMultilineBasicString(output_allocator);
        if (self.consumeIfString("'''")) return self.parseMultilineLiteralString(output_allocator);

        if (self.consumeIfByte('"')) return self.parseSingleLineBasicString(output_allocator);
        if (self.consumeIfByte('\'')) return self.parseSingleLineLiteralString(output_allocator);
        return error.ExpectedTomlString;
    }

    fn parseBasicString(self: *TomlParser, output_allocator: std.mem.Allocator) ![]u8 {
        if (self.consumeIfString("\"\"\"")) return error.InvalidTomlKey;
        try self.expectByte('"');
        return self.parseSingleLineBasicString(output_allocator);
    }

    fn parseLiteralString(self: *TomlParser, output_allocator: std.mem.Allocator) ![]u8 {
        if (self.consumeIfString("'''")) return error.InvalidTomlKey;
        try self.expectByte('\'');
        return self.parseSingleLineLiteralString(output_allocator);
    }

    fn parseSingleLineBasicString(self: *TomlParser, output_allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(output_allocator);

        while (true) {
            if (self.isEof()) return error.UnterminatedTomlString;

            const ch = self.peek();
            self.index += 1;
            switch (ch) {
                '"' => break,
                '\n', '\r' => return error.InvalidTomlString,
                '\\' => try self.parseEscapedCodepoint(output_allocator, &out, false),
                else => try out.append(output_allocator, ch),
            }
        }

        return out.toOwnedSlice(output_allocator);
    }

    fn parseSingleLineLiteralString(self: *TomlParser, output_allocator: std.mem.Allocator) ![]u8 {
        const start = self.index;
        while (!self.isEof()) {
            const ch = self.peek();
            if (ch == '\'') {
                const value = self.input[start..self.index];
                self.index += 1;
                return output_allocator.dupe(u8, value);
            }
            if (ch == '\n' or ch == '\r') return error.InvalidTomlString;
            self.index += 1;
        }

        return error.UnterminatedTomlString;
    }

    fn parseMultilineBasicString(self: *TomlParser, output_allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(output_allocator);

        _ = self.consumeLineBreak();

        while (true) {
            if (self.isEof()) return error.UnterminatedTomlString;
            if (self.consumeIfString("\"\"\"")) break;

            const ch = self.peek();
            self.index += 1;
            if (ch == '\\') {
                if (self.consumeLineBreak()) {
                    while (!self.isEof()) {
                        const ws = self.peek();
                        if (ws == ' ' or ws == '\t') {
                            self.index += 1;
                            continue;
                        }
                        if (self.consumeLineBreak()) continue;
                        break;
                    }
                    continue;
                }

                try self.parseEscapedCodepoint(output_allocator, &out, true);
                continue;
            }

            try out.append(output_allocator, ch);
        }

        return out.toOwnedSlice(output_allocator);
    }

    fn parseMultilineLiteralString(self: *TomlParser, output_allocator: std.mem.Allocator) ![]u8 {
        _ = self.consumeLineBreak();

        const start = self.index;
        while (!self.isEof()) {
            if (self.consumeIfString("'''")) {
                const value = self.input[start .. self.index - 3];
                return output_allocator.dupe(u8, value);
            }
            self.index += 1;
        }

        return error.UnterminatedTomlString;
    }

    fn parseEscapedCodepoint(
        self: *TomlParser,
        output_allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        allow_line_trim: bool,
    ) !void {
        _ = allow_line_trim;
        if (self.isEof()) return error.InvalidTomlEscape;

        const esc = self.peek();
        self.index += 1;

        switch (esc) {
            'b' => try out.append(output_allocator, 0x08),
            't' => try out.append(output_allocator, '\t'),
            'n' => try out.append(output_allocator, '\n'),
            'f' => try out.append(output_allocator, 0x0c),
            'r' => try out.append(output_allocator, '\r'),
            '"' => try out.append(output_allocator, '"'),
            '\\' => try out.append(output_allocator, '\\'),
            'u' => try self.appendUnicodeEscape(output_allocator, out, 4),
            'U' => try self.appendUnicodeEscape(output_allocator, out, 8),
            else => return error.InvalidTomlEscape,
        }
    }

    fn appendUnicodeEscape(self: *TomlParser, output_allocator: std.mem.Allocator, out: *std.ArrayList(u8), hex_len: usize) !void {
        if (self.index + hex_len > self.input.len) return error.InvalidTomlEscape;
        const hex = self.input[self.index .. self.index + hex_len];
        self.index += hex_len;

        for (hex) |ch| {
            if (!std.ascii.isHex(ch)) return error.InvalidTomlEscape;
        }

        const codepoint = std.fmt.parseUnsigned(u21, hex, 16) catch return error.InvalidTomlEscape;
        var encoded: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(codepoint, &encoded) catch return error.InvalidTomlEscape;
        try out.appendSlice(output_allocator, encoded[0..utf8_len]);
    }

    fn skipTomlValue(self: *TomlParser) anyerror!void {
        if (self.isEof()) return error.InvalidTomlValue;

        switch (self.peek()) {
            '"', '\'' => {
                _ = try self.parseStringValue(self.temp_allocator);
            },
            '[' => try self.skipTomlArray(),
            '{' => try self.skipTomlInlineTable(),
            else => {
                const token = try self.parseBareToken();
                if (std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "false")) return;
                if (self.parseIntegerToken(token)) |_| return else |_| {}
                if (self.parseFloatToken(token)) |_| return else |_| {}
                if (isDateOrTimeToken(token)) return;
                return error.InvalidTomlValue;
            },
        }
    }

    fn skipTomlArray(self: *TomlParser) anyerror!void {
        try self.expectByte('[');
        self.skipValueWhitespace();
        if (self.consumeIfByte(']')) return;

        while (true) {
            try self.skipTomlValue();
            self.skipValueWhitespace();

            if (self.consumeIfByte(',')) {
                self.skipValueWhitespace();
                if (self.consumeIfByte(']')) return;
                continue;
            }
            if (self.consumeIfByte(']')) return;
            return error.InvalidTomlArray;
        }
    }

    fn skipTomlInlineTable(self: *TomlParser) anyerror!void {
        try self.expectByte('{');
        self.skipValueWhitespace();
        if (self.consumeIfByte('}')) return;

        while (true) {
            var segments: [16][]const u8 = undefined;
            _ = try self.parseKeyPathSegments(&segments);
            self.skipSpaces();
            try self.expectByte('=');
            self.skipSpaces();
            try self.skipTomlValue();
            self.skipValueWhitespace();

            if (self.consumeIfByte(',')) {
                self.skipValueWhitespace();
                if (self.consumeIfByte('}')) return;
                continue;
            }
            if (self.consumeIfByte('}')) return;
            return error.InvalidTomlInlineTable;
        }
    }

    fn parseBareToken(self: *TomlParser) ![]const u8 {
        const start = self.index;
        while (!self.isEof()) {
            const ch = self.peek();
            if (isTomlValueDelimiter(ch)) break;
            self.index += 1;
        }

        if (self.index == start) return error.InvalidTomlValue;
        return self.input[start..self.index];
    }

    fn parseIntegerToken(self: *TomlParser, token: []const u8) !i64 {
        if (token.len == 0) return error.InvalidTomlInteger;

        var idx: usize = 0;
        var negative = false;
        if (token[idx] == '+' or token[idx] == '-') {
            negative = token[idx] == '-';
            idx += 1;
            if (idx >= token.len) return error.InvalidTomlInteger;
        }

        var base: u8 = 10;
        if (idx + 1 < token.len and token[idx] == '0') {
            switch (token[idx + 1]) {
                'x' => {
                    base = 16;
                    idx += 2;
                },
                'o' => {
                    base = 8;
                    idx += 2;
                },
                'b' => {
                    base = 2;
                    idx += 2;
                },
                else => {},
            }
        }

        const digits = token[idx..];
        if (digits.len == 0) return error.InvalidTomlInteger;

        var clean_digits: std.ArrayList(u8) = .empty;
        defer clean_digits.deinit(self.temp_allocator);

        var saw_digit = false;
        var prev_was_digit = false;
        for (digits, 0..) |ch, i| {
            if (ch == '_') {
                if (!prev_was_digit) return error.InvalidTomlInteger;
                if (i + 1 >= digits.len or !isDigitForBase(digits[i + 1], base)) return error.InvalidTomlInteger;
                prev_was_digit = false;
                continue;
            }

            if (!isDigitForBase(ch, base)) return error.InvalidTomlInteger;
            saw_digit = true;
            prev_was_digit = true;
            try clean_digits.append(self.temp_allocator, ch);
        }

        if (!saw_digit) return error.InvalidTomlInteger;
        if (base == 10 and clean_digits.items.len > 1 and clean_digits.items[0] == '0') {
            return error.InvalidTomlInteger;
        }

        const unsigned_value = std.fmt.parseUnsigned(u64, clean_digits.items, base) catch {
            return error.InvalidTomlInteger;
        };

        if (!negative) {
            if (unsigned_value > @as(u64, std.math.maxInt(i64))) return error.InvalidTomlInteger;
            return @as(i64, @intCast(unsigned_value));
        }

        const min_mag = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
        if (unsigned_value > min_mag) return error.InvalidTomlInteger;
        if (unsigned_value == min_mag) return std.math.minInt(i64);
        return -@as(i64, @intCast(unsigned_value));
    }

    fn parseFloatToken(self: *TomlParser, token: []const u8) !void {
        if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf") or std.mem.eql(u8, token, "-inf")) return;
        if (std.mem.eql(u8, token, "nan") or std.mem.eql(u8, token, "+nan") or std.mem.eql(u8, token, "-nan")) return;

        if (std.mem.indexOfAny(u8, token, ".eE") == null) return error.InvalidTomlFloat;

        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.temp_allocator);

        var saw_digit = false;
        var prev_was_digit = false;
        for (token, 0..) |ch, i| {
            if (ch == '_') {
                if (!prev_was_digit) return error.InvalidTomlFloat;
                if (i + 1 >= token.len or !std.ascii.isDigit(token[i + 1])) return error.InvalidTomlFloat;
                prev_was_digit = false;
                continue;
            }

            if (std.ascii.isDigit(ch)) {
                saw_digit = true;
                prev_was_digit = true;
            } else {
                prev_was_digit = false;
            }

            try clean.append(self.temp_allocator, ch);
        }

        if (!saw_digit) return error.InvalidTomlFloat;
        _ = std.fmt.parseFloat(f64, clean.items) catch return error.InvalidTomlFloat;
    }

    fn skipIgnoredTopLevel(self: *TomlParser) void {
        while (true) {
            self.skipSpaces();
            if (self.isEof()) return;

            if (self.peek() == '#') {
                self.skipComment();
                _ = self.consumeLineBreak();
                continue;
            }

            if (self.consumeLineBreak()) continue;
            return;
        }
    }

    fn skipValueWhitespace(self: *TomlParser) void {
        while (true) {
            self.skipSpaces();
            if (self.isEof()) return;

            if (self.peek() == '#') {
                self.skipComment();
                _ = self.consumeLineBreak();
                continue;
            }

            if (self.consumeLineBreak()) continue;
            return;
        }
    }

    fn expectStatementEnd(self: *TomlParser) !void {
        self.skipSpaces();
        if (self.isEof()) return;

        if (self.peek() == '#') {
            self.skipComment();
            if (self.isEof()) return;
        }

        if (self.consumeLineBreak()) return;
        return error.ExpectedTomlLineEnd;
    }

    fn skipComment(self: *TomlParser) void {
        while (!self.isEof()) {
            const ch = self.peek();
            if (ch == '\n' or ch == '\r') return;
            self.index += 1;
        }
    }

    fn skipSpaces(self: *TomlParser) void {
        while (!self.isEof()) {
            const ch = self.peek();
            if (ch == ' ' or ch == '\t') {
                self.index += 1;
                continue;
            }
            return;
        }
    }

    fn consumeLineBreak(self: *TomlParser) bool {
        if (self.isEof()) return false;
        if (self.peek() == '\n') {
            self.index += 1;
            return true;
        }
        if (self.peek() == '\r') {
            self.index += 1;
            if (!self.isEof() and self.peek() == '\n') self.index += 1;
            return true;
        }
        return false;
    }

    fn expectByte(self: *TomlParser, expected: u8) !void {
        if (self.isEof() or self.peek() != expected) return error.UnexpectedTomlToken;
        self.index += 1;
    }

    fn consumeIfByte(self: *TomlParser, expected: u8) bool {
        if (self.isEof() or self.peek() != expected) return false;
        self.index += 1;
        return true;
    }

    fn consumeIfString(self: *TomlParser, expected: []const u8) bool {
        if (self.index + expected.len > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.index .. self.index + expected.len], expected)) return false;
        self.index += expected.len;
        return true;
    }

    fn isEof(self: *TomlParser) bool {
        return self.index >= self.input.len;
    }

    fn peek(self: *TomlParser) u8 {
        return self.input[self.index];
    }
};

fn resolveTargetField(table_context: TableContext, key_segments: []const []const u8) TargetField {
    if (key_segments.len == 0) return .none;

    if (table_context == .root) {
        if (key_segments.len == 1) return keySegmentToField(key_segments[0]);
        if (key_segments.len == 2 and std.mem.eql(u8, key_segments[0], "zigbot")) {
            return keySegmentToField(key_segments[1]);
        }
        return .none;
    }

    if (table_context == .zigbot and key_segments.len == 1) {
        return keySegmentToField(key_segments[0]);
    }

    return .none;
}

fn keySegmentToField(segment: []const u8) TargetField {
    if (std.mem.eql(u8, segment, "telegram_bot_token")) return .telegram_bot_token;
    if (std.mem.eql(u8, segment, "pi_executable")) return .pi_executable;
    if (std.mem.eql(u8, segment, "provider")) return .provider;
    if (std.mem.eql(u8, segment, "model")) return .model;
    if (std.mem.eql(u8, segment, "polling_timeout_seconds")) return .polling_timeout_seconds;
    return .none;
}

fn isTomlValueDelimiter(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == ',' or ch == ']' or ch == '}' or ch == '#';
}

fn isBareKeyChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

fn isDigitForBase(ch: u8, base: u8) bool {
    return switch (base) {
        2 => ch == '0' or ch == '1',
        8 => ch >= '0' and ch <= '7',
        10 => ch >= '0' and ch <= '9',
        16 => std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F'),
        else => false,
    };
}

fn isDateOrTimeToken(token: []const u8) bool {
    return isLocalDate(token) or isLocalTime(token) or isLocalDateTime(token) or isOffsetDateTime(token);
}

fn isLocalDate(token: []const u8) bool {
    if (token.len != 10) return false;
    if (token[4] != '-' or token[7] != '-') return false;

    const year = parseFixedDecimal(token[0..4]) orelse return false;
    const month = parseFixedDecimal(token[5..7]) orelse return false;
    const day = parseFixedDecimal(token[8..10]) orelse return false;
    _ = year;
    if (month == 0 or month > 12) return false;
    if (day == 0 or day > 31) return false;
    return true;
}

fn isLocalTime(token: []const u8) bool {
    const consumed = parseLocalTimePrefix(token) orelse return false;
    return consumed == token.len;
}

fn isLocalDateTime(token: []const u8) bool {
    const sep_idx = std.mem.indexOfAny(u8, token, "Tt ") orelse return false;
    if (!isLocalDate(token[0..sep_idx])) return false;
    const time = token[sep_idx + 1 ..];
    return isLocalTime(time);
}

fn isOffsetDateTime(token: []const u8) bool {
    const sep_idx = std.mem.indexOfAny(u8, token, "Tt ") orelse return false;
    if (!isLocalDate(token[0..sep_idx])) return false;

    const rest = token[sep_idx + 1 ..];
    const time_len = parseLocalTimePrefix(rest) orelse return false;
    if (time_len >= rest.len) return false;

    const offset = rest[time_len..];
    if (std.mem.eql(u8, offset, "Z") or std.mem.eql(u8, offset, "z")) return true;
    if (offset.len != 6) return false;
    if (offset[0] != '+' and offset[0] != '-') return false;
    if (offset[3] != ':') return false;

    const off_hour = parseFixedDecimal(offset[1..3]) orelse return false;
    const off_min = parseFixedDecimal(offset[4..6]) orelse return false;
    return off_hour <= 23 and off_min <= 59;
}

fn parseLocalTimePrefix(token: []const u8) ?usize {
    if (token.len < 8) return null;
    if (token[2] != ':' or token[5] != ':') return null;

    const hour = parseFixedDecimal(token[0..2]) orelse return null;
    const minute = parseFixedDecimal(token[3..5]) orelse return null;
    const second = parseFixedDecimal(token[6..8]) orelse return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var idx: usize = 8;
    if (idx < token.len and token[idx] == '.') {
        idx += 1;
        const frac_start = idx;
        while (idx < token.len and std.ascii.isDigit(token[idx])) : (idx += 1) {}
        if (idx == frac_start) return null;
    }

    return idx;
}

fn parseFixedDecimal(slice: []const u8) ?u32 {
    if (slice.len == 0) return null;
    var value: u32 = 0;
    for (slice) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        value = value * 10 + (ch - '0');
    }
    return value;
}

test "parseTomlConfig parses root keys and ignores unrelated TOML values" {
    const allocator = std.testing.allocator;
    const input =
        \\telegram_bot_token = "123:abc"
        \\pi_executable = "pi"
        \\provider = "opencode"
        \\polling_timeout_seconds = 30
        \\features = [1, 2, { enabled = true }, 2024-01-01T12:30:00Z]
        \\
    ;

    var parsed = try parseTomlConfig(allocator, input);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("123:abc", parsed.telegram_bot_token.?);
    try std.testing.expectEqualStrings("pi", parsed.pi_executable.?);
    try std.testing.expectEqualStrings("opencode", parsed.provider.?);
    try std.testing.expect(parsed.model == null);
    try std.testing.expectEqual(@as(i64, 30), parsed.polling_timeout_seconds.?);
}

test "parseTomlConfig supports [zigbot] table and escaped strings" {
    const allocator = std.testing.allocator;
    const input =
        \\[zigbot]
        \\telegram_bot_token = "line1\nline2"
        \\provider = "google"
        \\model = "gemini"
        \\polling_timeout_seconds = 45
        \\
    ;

    var parsed = try parseTomlConfig(allocator, input);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("line1\nline2", parsed.telegram_bot_token.?);
    try std.testing.expectEqualStrings("google", parsed.provider.?);
    try std.testing.expectEqualStrings("gemini", parsed.model.?);
    try std.testing.expectEqual(@as(i64, 45), parsed.polling_timeout_seconds.?);
}

test "parseTomlConfig rejects duplicate configured keys" {
    const allocator = std.testing.allocator;
    const input =
        \\telegram_bot_token = "first"
        \\telegram_bot_token = "second"
        \\
    ;

    try std.testing.expectError(error.DuplicateTomlKey, parseTomlConfig(allocator, input));
}

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

    const config_path = if (args.next()) |path|
        try allocator.dupe(u8, path)
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

    var telegram = TelegramClient.init(allocator, config.telegram_bot_token);
    defer telegram.deinit();

    std.log.info(
        "zigbot started with config {s}, agent dir {s}, waiting for Telegram messages...",
        .{ config_path, config_dir },
    );

    var next_update_offset: i64 = 0;
    while (true) {
        handlePollCycle(allocator, &config, config_dir, &telegram, &next_update_offset) catch |err| {
            std.log.err("poll loop error: {}", .{err});
            std.Thread.sleep(2 * std.time.ns_per_s);
        };
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

fn askPi(
    allocator: std.mem.Allocator,
    config: *const Config,
    config_dir: []const u8,
    prompt: []const u8,
) ![]u8 {
    var created = try pi.createAgentSession(.{
        .allocator = allocator,
        .pi_executable = config.pi_executable,
        .agent_dir = config_dir,
        .provider = config.provider,
        .model = config.model,
        .session_manager = pi.SessionManager.inMemory(),
    });
    defer created.session.dispose();

    const contextual_prompt = try std.fmt.allocPrint(
        allocator,
        "Runtime context:\n- Config directory: {s}\n- AGENTS file path (if present): {s}/AGENTS.md\n\nUser message:\n{s}",
        .{ config_dir, config_dir, prompt },
    );
    defer allocator.free(contextual_prompt);

    try created.session.prompt(contextual_prompt, .{});
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
