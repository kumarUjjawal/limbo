const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const root_dir = b.path("../..");
    const sdk_include_dir = b.path("../../sdk-kit");
    const cargo_target_dir = b.graph.env_map.get("CARGO_TARGET_DIR") orelse b.pathJoin(&.{ "..", "..", "target" });
    const static_lib_name = switch (b.graph.host.result.os.tag) {
        .windows => "turso_sdk_kit.lib",
        else => "libturso_sdk_kit.a",
    };
    const static_lib_path = b.pathJoin(&.{ cargo_target_dir, "debug", static_lib_name });

    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "-p", "turso_sdk_kit" });
    cargo_build.setCwd(root_dir);

    const mod = b.addModule("turso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    configureModule(mod, b, sdk_include_dir, static_lib_path);

    const exe = b.addExecutable(.{
        .name = "turso-zig-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "turso", .module = mod },
            },
        }),
    });
    exe.step.dependOn(&cargo_build.step);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the Zig binding demo");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "turso", .module = mod },
            },
        }),
    });
    mod_tests.step.dependOn(&cargo_build.step);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.step.dependOn(&cargo_build.step);

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run Zig binding tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn configureModule(
    module: *std.Build.Module,
    b: *std.Build,
    sdk_include_dir: std.Build.LazyPath,
    static_lib_path: []const u8,
) void {
    module.addIncludePath(sdk_include_dir);
    module.addObjectFile(.{ .cwd_relative = static_lib_path });
    module.linkSystemLibrary("c", .{});

    if (b.graph.host.result.os.tag.isDarwin()) {
        module.linkFramework("CoreFoundation", .{});
    }
}
