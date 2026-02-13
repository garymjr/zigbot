const std = @import("std");
const pi = @import("pi_sdk");
const Config = @import("config.zig").Config;

pub fn askPi(
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
        "Runtime context:\n- Config directory: {s}\n- AGENTS file path (if present): {s}/AGENTS.md\n- Skills directory (if present): {s}/skills\n\nUser message:\n{s}",
        .{ config_dir, config_dir, config_dir, prompt },
    );
    defer allocator.free(contextual_prompt);

    try created.session.prompt(contextual_prompt, .{});
    try created.session.waitForIdle();

    if (try created.session.getLastAssistantText()) |text| {
        return text;
    }

    return allocator.dupe(u8, "I could not generate a response.");
}
