const std = @import("std");

const extension_index_ts = @embedFile("extensions/secrets/index.ts");
const extension_script_py = @embedFile("extensions/secrets/secrets_store.py");
const skill_md = @embedFile("skills/secrets/SKILL.md");

pub fn ensureInstalled(allocator: std.mem.Allocator, config_dir: []const u8) !void {
    const extension_dir = try std.fs.path.join(allocator, &.{ config_dir, "extensions", "secrets" });
    defer allocator.free(extension_dir);

    try std.fs.cwd().makePath(extension_dir);

    const index_path = try std.fs.path.join(allocator, &.{ extension_dir, "index.ts" });
    defer allocator.free(index_path);
    const index_written = try writeFileIfMissing(index_path, extension_index_ts);

    const script_path = try std.fs.path.join(allocator, &.{ extension_dir, "secrets_store.py" });
    defer allocator.free(script_path);
    const script_written = try writeFileIfMissing(script_path, extension_script_py);

    const skill_dir = try std.fs.path.join(allocator, &.{ config_dir, "skills", "secrets" });
    defer allocator.free(skill_dir);
    try std.fs.cwd().makePath(skill_dir);

    const skill_path = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
    defer allocator.free(skill_path);
    const skill_written = try writeFileIfMissing(skill_path, skill_md);

    if (index_written or script_written or skill_written) {
        std.log.info("installed secrets extension in {s}", .{extension_dir});
    }
}

fn writeFileIfMissing(path: []const u8, content: []const u8) !bool {
    const file = std.fs.createFileAbsolute(path, .{
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    defer file.close();

    try file.writeAll(content);
    return true;
}
