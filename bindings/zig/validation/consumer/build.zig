const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk_prefix = b.option(
        []const u8,
        "turso-sdk-prefix",
        "Path to the staged Turso SDK prefix used by the turso dependency.",
    ) orelse failBuild(
        \\error: provide -Dturso-sdk-prefix=/path/to/turso-sdk when validating the consumer project
        \\
    , .{});

    const turso_dep = b.dependency("turso", .{
        .target = target,
        .optimize = optimize,
        .@"turso-sdk-prefix" = sdk_prefix,
        .@"turso-sdk-use-cargo" = false,
    });

    const exe = b.addExecutable(.{
        .name = "consumer-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "turso", .module = turso_dep.module("turso") },
            },
        }),
    });

    const check_step = b.step("check", "Build the clean-room consumer project");
    b.default_step = check_step;
    check_step.dependOn(&exe.step);

    const run_step = b.step("run", "Run the clean-room consumer smoke test");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}

fn failBuild(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
