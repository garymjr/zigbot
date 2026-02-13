const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pi_sdk_dep = b.dependency("pi_sdk_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zigbot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("pi_sdk", pi_sdk_dep.module("pi_sdk"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Telegram Pi bot");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("pi_sdk", pi_sdk_dep.module("pi_sdk"));
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const fmt_check = b.addFmt(.{
        .paths = &.{ "build.zig", "src" },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check Zig formatting");
    fmt_step.dependOn(&fmt_check.step);

    const check_step = b.step("check", "Run formatting and unit tests");
    check_step.dependOn(&fmt_check.step);
    check_step.dependOn(&run_unit_tests.step);
}
