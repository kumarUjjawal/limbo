const std = @import("std");

const SdkInputs = struct {
    include_dir: std.Build.LazyPath,
    static_lib: std.Build.LazyPath,
    build_step: ?*std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    ensureNativeTarget(b, target);

    const sdk = resolveSdkInputs(b, b.path("../.."), target.result.os.tag);

    const mod = b.addModule("turso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(mod, sdk.include_dir, sdk.static_lib, target.result.os.tag);

    if (sdk.build_step) |sdk_build_step| {
        const sdk_step = b.step("sdk", "Build the shared Turso SDK archive with Cargo");
        sdk_step.dependOn(sdk_build_step);
    }

    const check_step = b.step("check", "Compile the Zig binding, demo, examples, and tests");
    b.default_step = check_step;

    const demo = b.addExecutable(.{
        .name = "turso-zig-demo",
        .root_module = createImportingModule(b, target, optimize, "src/main.zig", mod),
    });
    dependOnSdkBuild(&demo.step, sdk);
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
    addExample(b, sdk, mod, target, optimize, check_step, examples_step, "memory", "examples/memory.zig", "Run the in-memory example");
    addExample(b, sdk, mod, target, optimize, check_step, examples_step, "file", "examples/file.zig", "Run the file-backed example");
    addExample(b, sdk, mod, target, optimize, check_step, examples_step, "prepared", "examples/prepared.zig", "Run the prepared statement example");
    addExample(b, sdk, mod, target, optimize, check_step, examples_step, "values", "examples/values.zig", "Run the value decoding example");

    const mod_tests = b.addTest(.{
        .root_module = createImportingModule(b, target, optimize, "src/tests.zig", mod),
    });
    dependOnSdkBuild(&mod_tests.step, sdk);
    check_step.dependOn(&mod_tests.step);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = demo.root_module,
    });
    dependOnSdkBuild(&exe_tests.step, sdk);
    check_step.dependOn(&exe_tests.step);

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run Zig binding tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn configureModule(
    module: *std.Build.Module,
    sdk_include_dir: std.Build.LazyPath,
    static_lib: std.Build.LazyPath,
    os_tag: std.Target.Os.Tag,
) void {
    module.addIncludePath(sdk_include_dir);
    module.addObjectFile(static_lib);
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
    sdk: SdkInputs,
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
    dependOnSdkBuild(&exe.step, sdk);
    check_step.dependOn(&exe.step);
    examples_step.dependOn(&exe.step);

    const run_step = b.step(step_name, description);
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}

fn resolveSdkInputs(
    b: *std.Build,
    root_dir: std.Build.LazyPath,
    os_tag: std.Target.Os.Tag,
) SdkInputs {
    const sdk_prefix = b.option(
        []const u8,
        "turso-sdk-prefix",
        "Path to a prebuilt Turso SDK prefix containing include/ and lib/",
    );
    const sdk_include_dir_opt = b.option(
        []const u8,
        "turso-sdk-include-dir",
        "Path to the directory containing turso.h for a prebuilt Turso SDK",
    );
    const sdk_lib_path_opt = b.option(
        []const u8,
        "turso-sdk-lib-path",
        "Path to a prebuilt turso_sdk_kit static library",
    );
    const sdk_use_cargo = b.option(
        bool,
        "turso-sdk-use-cargo",
        "Build turso_sdk_kit from the workspace with Cargo when no prebuilt SDK is provided",
    ) orelse true;

    const sdk_include_dir = sdk_include_dir_opt orelse if (sdk_prefix) |prefix|
        b.pathJoin(&.{ prefix, "include" })
    else
        null;
    const sdk_lib_path = sdk_lib_path_opt orelse if (sdk_prefix) |prefix|
        b.pathJoin(&.{ prefix, "lib", staticLibraryName(os_tag) })
    else
        null;

    if (sdk_include_dir != null or sdk_lib_path != null) {
        if (sdk_include_dir == null or sdk_lib_path == null) {
            failBuild(
                \\error: prebuilt Turso SDK configuration is incomplete
                \\provide both an include directory and a static library path
                \\examples:
                \\  zig build -Dturso-sdk-prefix=/path/to/turso-sdk
                \\  zig build -Dturso-sdk-include-dir=/path/to/include -Dturso-sdk-lib-path=/path/to/libturso_sdk_kit.a
                \\
            , .{});
        }

        ensurePathExists(sdk_include_dir.?, "Turso SDK include directory");
        ensurePathExists(sdk_lib_path.?, "Turso SDK static library");

        return .{
            .include_dir = .{ .cwd_relative = sdk_include_dir.? },
            .static_lib = .{ .cwd_relative = sdk_lib_path.? },
            .build_step = null,
        };
    }

    if (!sdk_use_cargo) {
        failBuild(
            \\error: no Turso SDK input was provided
            \\set -Dturso-sdk-prefix=... or both -Dturso-sdk-include-dir=... and -Dturso-sdk-lib-path=...
            \\or leave -Dturso-sdk-use-cargo enabled for repository development
            \\
        , .{});
    }

    const sdk_include_dir_fallback = b.path("../../sdk-kit");
    const cargo_target_dir = b.graph.env_map.get("CARGO_TARGET_DIR") orelse b.pathJoin(&.{ "..", "..", "target" });
    const static_lib_path = b.pathJoin(&.{ cargo_target_dir, "debug", staticLibraryName(os_tag) });

    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--locked", "-p", "turso_sdk_kit" });
    cargo_build.setCwd(root_dir);

    return .{
        .include_dir = sdk_include_dir_fallback,
        .static_lib = .{ .cwd_relative = static_lib_path },
        .build_step = &cargo_build.step,
    };
}

fn dependOnSdkBuild(step: *std.Build.Step, sdk: SdkInputs) void {
    if (sdk.build_step) |sdk_build_step| {
        step.dependOn(sdk_build_step);
    }
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

fn failBuild(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn ensurePathExists(path: []const u8, kind: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch {
            failBuild("error: {s} not found: {s}\n", .{ kind, path });
        };
        return;
    }

    std.fs.cwd().access(path, .{}) catch {
        failBuild("error: {s} not found: {s}\n", .{ kind, path });
    };
}
