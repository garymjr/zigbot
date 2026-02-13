const std = @import("std");
const BotError = @import("errors.zig").BotError;

pub const Config = struct {
    telegram_bot_token: []u8,
    owner_chat_id: ?i64,
    pi_executable: []u8,
    provider: ?[]u8,
    model: ?[]u8,
    polling_timeout_seconds: i64,
    heartbeat_interval_seconds: i64,
    web_enabled: bool,
    web_host: []u8,
    web_port: u16,

    const ConfigFile = struct {
        telegram_bot_token: ?[]u8 = null,
        owner_chat_id: ?i64 = null,
        pi_executable: ?[]u8 = null,
        provider: ?[]u8 = null,
        model: ?[]u8 = null,
        polling_timeout_seconds: ?i64 = null,
        heartbeat_interval_seconds: ?i64 = null,
        web_enabled: ?bool = null,
        web_host: ?[]u8 = null,
        web_port: ?i64 = null,

        fn deinit(self: *ConfigFile, allocator: std.mem.Allocator) void {
            if (self.telegram_bot_token) |value| allocator.free(value);
            if (self.pi_executable) |value| allocator.free(value);
            if (self.provider) |value| allocator.free(value);
            if (self.model) |value| allocator.free(value);
            if (self.web_host) |value| allocator.free(value);
        }
    };

    pub fn load(allocator: std.mem.Allocator, config_path: []const u8) !Config {
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

        const owner_chat_id = parsed.owner_chat_id;

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
        const heartbeat_interval_seconds = parsed.heartbeat_interval_seconds orelse 300;
        const web_enabled = parsed.web_enabled orelse true;

        const web_host = if (parsed.web_host) |value| blk: {
            parsed.web_host = null;
            break :blk value;
        } else try allocator.dupe(u8, "127.0.0.1");
        errdefer allocator.free(web_host);

        const raw_web_port = parsed.web_port orelse 8787;
        if (raw_web_port <= 0 or raw_web_port > std.math.maxInt(u16)) {
            std.log.err("invalid web_port value: {d} (expected 1-65535)", .{raw_web_port});
            return BotError.InvalidConfigValue;
        }
        const web_port: u16 = @intCast(raw_web_port);

        return .{
            .telegram_bot_token = telegram_bot_token,
            .owner_chat_id = owner_chat_id,
            .pi_executable = pi_executable,
            .provider = provider,
            .model = model,
            .polling_timeout_seconds = polling_timeout_seconds,
            .heartbeat_interval_seconds = heartbeat_interval_seconds,
            .web_enabled = web_enabled,
            .web_host = web_host,
            .web_port = web_port,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.telegram_bot_token);
        allocator.free(self.pi_executable);
        if (self.provider) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        allocator.free(self.web_host);
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
    owner_chat_id,
    pi_executable,
    provider,
    model,
    polling_timeout_seconds,
    heartbeat_interval_seconds,
    web_enabled,
    web_host,
    web_port,
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
        owner_chat_id: bool = false,
        pi_executable: bool = false,
        provider: bool = false,
        model: bool = false,
        polling_timeout_seconds: bool = false,
        heartbeat_interval_seconds: bool = false,
        web_enabled: bool = false,
        web_host: bool = false,
        web_port: bool = false,
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
            .owner_chat_id => {
                if (seen.owner_chat_id) return error.DuplicateTomlKey;
                parsed.owner_chat_id = try self.parseIntegerValue();
                seen.owner_chat_id = true;
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
            .heartbeat_interval_seconds => {
                if (seen.heartbeat_interval_seconds) return error.DuplicateTomlKey;
                parsed.heartbeat_interval_seconds = try self.parseIntegerValue();
                seen.heartbeat_interval_seconds = true;
            },
            .web_enabled => {
                if (seen.web_enabled) return error.DuplicateTomlKey;
                parsed.web_enabled = try self.parseBoolValue();
                seen.web_enabled = true;
            },
            .web_host => {
                if (seen.web_host) return error.DuplicateTomlKey;
                parsed.web_host = try self.parseStringValue(self.allocator);
                seen.web_host = true;
            },
            .web_port => {
                if (seen.web_port) return error.DuplicateTomlKey;
                parsed.web_port = try self.parseIntegerValue();
                seen.web_port = true;
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

    fn parseBoolValue(self: *TomlParser) !bool {
        const token = try self.parseBareToken();
        if (std.mem.eql(u8, token, "true")) return true;
        if (std.mem.eql(u8, token, "false")) return false;
        return error.InvalidTomlBoolean;
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
    if (std.mem.eql(u8, segment, "owner_chat_id")) return .owner_chat_id;
    if (std.mem.eql(u8, segment, "pi_executable")) return .pi_executable;
    if (std.mem.eql(u8, segment, "provider")) return .provider;
    if (std.mem.eql(u8, segment, "model")) return .model;
    if (std.mem.eql(u8, segment, "polling_timeout_seconds")) return .polling_timeout_seconds;
    if (std.mem.eql(u8, segment, "heartbeat_interval_seconds")) return .heartbeat_interval_seconds;
    if (std.mem.eql(u8, segment, "web_enabled")) return .web_enabled;
    if (std.mem.eql(u8, segment, "web_host")) return .web_host;
    if (std.mem.eql(u8, segment, "web_port")) return .web_port;
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
        \\owner_chat_id = 8410132204
        \\pi_executable = "pi"
        \\provider = "opencode"
        \\polling_timeout_seconds = 30
        \\heartbeat_interval_seconds = 120
        \\web_enabled = false
        \\web_host = "127.0.0.1"
        \\web_port = 8787
        \\features = [1, 2, { enabled = true }, 2024-01-01T12:30:00Z]
        \\
    ;

    var parsed = try parseTomlConfig(allocator, input);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("123:abc", parsed.telegram_bot_token.?);
    try std.testing.expectEqual(@as(i64, 8410132204), parsed.owner_chat_id.?);
    try std.testing.expectEqualStrings("pi", parsed.pi_executable.?);
    try std.testing.expectEqualStrings("opencode", parsed.provider.?);
    try std.testing.expect(parsed.model == null);
    try std.testing.expectEqual(@as(i64, 30), parsed.polling_timeout_seconds.?);
    try std.testing.expectEqual(@as(i64, 120), parsed.heartbeat_interval_seconds.?);
    try std.testing.expectEqual(false, parsed.web_enabled.?);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.web_host.?);
    try std.testing.expectEqual(@as(i64, 8787), parsed.web_port.?);
}

test "parseTomlConfig supports [zigbot] table and escaped strings" {
    const allocator = std.testing.allocator;
    const input =
        \\[zigbot]
        \\telegram_bot_token = "line1\nline2"
        \\owner_chat_id = 123456
        \\provider = "google"
        \\model = "gemini"
        \\polling_timeout_seconds = 45
        \\heartbeat_interval_seconds = 600
        \\web_enabled = true
        \\web_host = "localhost"
        \\web_port = 9191
        \\
    ;

    var parsed = try parseTomlConfig(allocator, input);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("line1\nline2", parsed.telegram_bot_token.?);
    try std.testing.expectEqual(@as(i64, 123456), parsed.owner_chat_id.?);
    try std.testing.expectEqualStrings("google", parsed.provider.?);
    try std.testing.expectEqualStrings("gemini", parsed.model.?);
    try std.testing.expectEqual(@as(i64, 45), parsed.polling_timeout_seconds.?);
    try std.testing.expectEqual(@as(i64, 600), parsed.heartbeat_interval_seconds.?);
    try std.testing.expectEqual(true, parsed.web_enabled.?);
    try std.testing.expectEqualStrings("localhost", parsed.web_host.?);
    try std.testing.expectEqual(@as(i64, 9191), parsed.web_port.?);
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
