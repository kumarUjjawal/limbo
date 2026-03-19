const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    ensureNativeTarget(b, target);

    const root_dir = b.path("../..");
    const sdk_include_dir = b.path("../../sdk-kit");
    const cargo_target_dir = b.graph.env_map.get("CARGO_TARGET_DIR") orelse b.pathJoin(&.{ "..", "..", "target" });
    const static_lib_name = staticLibraryName(target.result.os.tag);
    const static_lib_path = b.pathJoin(&.{ cargo_target_dir, "debug", static_lib_name });

    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--locked", "-p", "turso_sdk_kit" });
    cargo_build.setCwd(root_dir);

    const mod = b.addModule("turso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(mod, sdk_include_dir, static_lib_path, target.result.os.tag);

    const check_step = b.step("check", "Compile the Zig binding, demo, examples, and tests");
    b.default_step = check_step;

    const demo = b.addExecutable(.{
        .name = "turso-zig-demo",
        .root_module = createImportingModule(b, target, optimize, "src/main.zig", mod),
    });
    demo.step.dependOn(&cargo_build.step);
    check_step.dependOn(&demo.step);

    const demo_step = b.step("demo", "Build the Zig binding demo");
    demo_step.dependOn(&demo.step);

    const run_step = b.step("run", "Run the Zig binding demo from src/main.zig");
    const run_cmd = b.addRunArtifact(demo);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const examples_step = b.step("examples", "Build all Zig examples");
    addExample(b, &cargo_build.step, mod, target, optimize, check_step, examples_step, "memory", "examples/memory.zig", "Run the in-memory example");
    addExample(b, &cargo_build.step, mod, target, optimize, check_step, examples_step, "file", "examples/file.zig", "Run the file-backed example");
    addExample(b, &cargo_build.step, mod, target, optimize, check_step, examples_step, "prepared", "examples/prepared.zig", "Run the prepared statement example");
    addExample(b, &cargo_build.step, mod, target, optimize, check_step, examples_step, "values", "examples/values.zig", "Run the value decoding example");

    const mod_tests = b.addTest(.{
        .root_module = createImportingModule(b, target, optimize, "src/tests.zig", mod),
    });
    mod_tests.step.dependOn(&cargo_build.step);
    check_step.dependOn(&mod_tests.step);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = demo.root_module,
    });
    exe_tests.step.dependOn(&cargo_build.step);
    check_step.dependOn(&exe_tests.step);

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run Zig binding tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn configureModule(
    module: *std.Build.Module,
    sdk_include_dir: std.Build.LazyPath,
    static_lib_path: []const u8,
    os_tag: std.Target.Os.Tag,
) void {
    module.addIncludePath(sdk_include_dir);
    module.addObjectFile(.{ .cwd_relative = static_lib_path });
    module.linkSystemLibrary("c", .{});

    if (os_tag.isDarwin()) {
        module.linkFramework("CoreFoundation", .{});
    }
}

fn createImportingModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_source_path: []const u8,
    mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "turso", .module = mod },
        },
    });
}

fn addExample(
    b: *std.Build,
    cargo_build_step: *std.Build.Step,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    check_step: *std.Build.Step,
    examples_step: *std.Build.Step,
    name: []const u8,
    root_source_path: []const u8,
    description: []const u8,
) void {
    const exe_name = b.fmt("turso-zig-{s}", .{name});
    const step_name = b.fmt("example-{s}", .{name});

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = createImportingModule(b, target, optimize, root_source_path, mod),
    });
    exe.step.dependOn(cargo_build_step);
    check_step.dependOn(&exe.step);
    examples_step.dependOn(&exe.step);

    const run_step = b.step(step_name, description);
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}

fn ensureNativeTarget(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const requested = target.result;
    const host = b.graph.host.result;

    if (requested.cpu.arch == host.cpu.arch and requested.os.tag == host.os.tag and requested.abi == host.abi) {
        return;
    }

    std.debug.print(
        \\error: bindings/zig currently supports native builds only
        \\requested target: {s}-{s}-{s}
        \\host target: {s}-{s}-{s}
        \\build without -Dtarget until cross-target packaging is added
        \\
    , .{
        @tagName(requested.cpu.arch),
        @tagName(requested.os.tag),
        @tagName(requested.abi),
        @tagName(host.cpu.arch),
        @tagName(host.os.tag),
        @tagName(host.abi),
    });
    std.process.exit(1);
}

fn staticLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "turso_sdk_kit.lib",
        else => "libturso_sdk_kit.a",
    };
}
