const std = @import("std");
const app = @import("app.zig");
const logging = @import("logging.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

pub fn main() !void {
    logging.initFromEnv(std.heap.page_allocator);
    try app.run();
}
