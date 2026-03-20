const std = @import("std");

const SdkInputs = struct {
    include_dir: std.Build.LazyPath,
    sync_include_dir: std.Build.LazyPath,
    static_lib: std.Build.LazyPath,
    build_step: ?*std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    ensureNativeTarget(b, target);

    const sdk = resolveSdkInputs(b, target.result.os.tag);

    const mod = b.addModule("turso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(mod, sdk.include_dir, sdk.sync_include_dir, sdk.static_lib, target.result.os.tag);

    if (sdk.build_step) |sdk_build_step| {
        const sdk_step = b.step("sdk", "Build the shared Turso sync SDK archive with Cargo");
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
        .root_module = createImportingModule(b, target, optimize, "src/tests/root.zig", mod),
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
    sync_sdk_include_dir: std.Build.LazyPath,
    static_lib: std.Build.LazyPath,
    os_tag: std.Target.Os.Tag,
) void {
    module.addIncludePath(sdk_include_dir);
    module.addIncludePath(sync_sdk_include_dir);
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
        "Path to a prebuilt turso_sync_sdk_kit static library",
    );
    const sdk_use_cargo = b.option(
        bool,
        "turso-sdk-use-cargo",
        "Build turso_sync_sdk_kit with Cargo as an explicit repository-development fallback",
    ) orelse false;
    const sdk_cargo_target_dir_opt = b.option(
        []const u8,
        "turso-sdk-cargo-target-dir",
        "Path to the Cargo target directory used with -Dturso-sdk-use-cargo=true",
    );
    const sdk_repo_root_opt = b.option(
        []const u8,
        "turso-sdk-repo-root",
        "Path to the Limbo repository root used with -Dturso-sdk-use-cargo=true",
    );

    const sdk_include_dir = sdk_include_dir_opt orelse if (sdk_prefix) |prefix|
        b.pathJoin(&.{ prefix, "include" })
    else
        null;
    const sdk_sync_lib_path = if (sdk_lib_path_opt) |sdk_lib_path|
        resolveSyncStaticLibraryPath(b, sdk_lib_path, os_tag)
    else if (sdk_prefix) |prefix|
        b.pathJoin(&.{ prefix, "lib", syncStaticLibraryName(os_tag) })
    else
        null;

    if (sdk_include_dir != null or sdk_sync_lib_path != null) {
        if (sdk_include_dir == null or sdk_sync_lib_path == null) {
            failBuild(
                \\error: prebuilt Turso sync SDK configuration is incomplete
                \\provide both an include directory and a static library path
                \\examples:
                \\  zig build -Dturso-sdk-prefix=/path/to/turso-sdk
                \\  zig build -Dturso-sdk-include-dir=/path/to/include -Dturso-sdk-lib-path=/path/to/libturso_sync_sdk_kit.a
                \\
            , .{});
        }

        ensurePathExists(sdk_include_dir.?, "Turso SDK include directory");
        ensurePathExists(b.pathJoin(&.{ sdk_include_dir.?, "turso.h" }), "Turso SDK header");
        ensurePathExists(b.pathJoin(&.{ sdk_include_dir.?, "turso_sync.h" }), "Turso sync SDK header");
        ensurePathExists(sdk_sync_lib_path.?, "Turso sync SDK static library");

        return .{
            .include_dir = .{ .cwd_relative = sdk_include_dir.? },
            .sync_include_dir = .{ .cwd_relative = sdk_include_dir.? },
            .static_lib = .{ .cwd_relative = sdk_sync_lib_path.? },
            .build_step = null,
        };
    }

    if (!sdk_use_cargo) {
        failBuild(
            \\error: no Turso SDK input was provided
            \\published builds require a matching Turso sync SDK prefix or explicit include/lib paths
            \\examples:
            \\  zig build -Dturso-sdk-prefix=/path/to/turso-sdk
            \\  zig build -Dturso-sdk-include-dir=/path/to/include -Dturso-sdk-lib-path=/path/to/libturso_sync_sdk_kit.a
            \\for repository development only, opt into the Cargo fallback explicitly:
            \\  zig build -Dturso-sdk-use-cargo=true
            \\  zig build -Dturso-sdk-use-cargo=true -Dturso-sdk-repo-root=/path/to/limbo
            \\
        , .{});
    }

    const repo_root = if (sdk_repo_root_opt) |repo_root|
        repo_root
    else if (detectRepoRoot(b)) |repo_root|
        repo_root
    else
        failBuild(
            \\error: could not locate the Limbo repository root for -Dturso-sdk-use-cargo=true
            \\provide -Dturso-sdk-repo-root=/path/to/limbo or build against a prebuilt Turso SDK prefix
            \\
        , .{});

    ensurePathExists(repo_root, "Limbo repository root");

    const sdk_include_dir_fallback: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ repo_root, "sdk-kit" }),
    };
    const sync_sdk_include_dir_fallback: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ repo_root, "sync", "sdk-kit" }),
    };
    const cargo_target_dir = sdk_cargo_target_dir_opt orelse detectCargoTargetDir(b, repo_root);
    const static_lib_path = b.pathJoin(&.{ cargo_target_dir, "debug", syncStaticLibraryName(os_tag) });

    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--locked", "-p", "turso_sync_sdk_kit" });
    cargo_build.setCwd(.{ .cwd_relative = repo_root });

    return .{
        .include_dir = sdk_include_dir_fallback,
        .sync_include_dir = sync_sdk_include_dir_fallback,
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

fn syncStaticLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "turso_sync_sdk_kit.lib",
        else => "libturso_sync_sdk_kit.a",
    };
}

fn resolveSyncStaticLibraryPath(
    b: *std.Build,
    lib_path: []const u8,
    os_tag: std.Target.Os.Tag,
) []const u8 {
    const sync_name = syncStaticLibraryName(os_tag);
    const lib_basename = std.fs.path.basename(lib_path);

    if (std.mem.eql(u8, lib_basename, sync_name)) {
        return lib_path;
    }

    const parent = std.fs.path.dirname(lib_path) orelse {
        return sync_name;
    };
    return b.pathJoin(&.{ parent, sync_name });
}

fn detectRepoRoot(b: *std.Build) ?[]const u8 {
    var current: []const u8 = b.pathFromRoot(".");

    while (true) {
        if (isRepoRoot(b, current)) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) {
            return null;
        }
        current = parent;
    }
}

fn detectCargoTargetDir(b: *std.Build, repo_root: []const u8) []const u8 {
    if (b.graph.env_map.get("CARGO_TARGET_DIR")) |target_dir| {
        return target_dir;
    }

    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "cargo", "metadata", "--format-version", "1", "--no-deps" },
        .cwd = repo_root,
    }) catch |err| {
        failBuild("error: unable to query cargo metadata: {s}\n", .{@errorName(err)});
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        failBuild("error: cargo metadata failed while resolving the Cargo target directory\n{s}\n", .{result.stderr});
    }

    const CargoMetadata = struct {
        target_directory: []const u8,
    };
    const parsed = std.json.parseFromSlice(CargoMetadata, b.allocator, result.stdout, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        failBuild("error: failed to parse cargo metadata: {s}\n", .{@errorName(err)});
    };
    defer parsed.deinit();

    return b.dupePath(parsed.value.target_directory);
}

fn isRepoRoot(b: *std.Build, path: []const u8) bool {
    return pathExists(b.pathJoin(&.{ path, "Cargo.toml" })) and
        pathExists(b.pathJoin(&.{ path, "sdk-kit", "turso.h" })) and
        pathExists(b.pathJoin(&.{ path, "bindings", "zig", "build.zig" }));
}

fn failBuild(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn ensurePathExists(path: []const u8, kind: []const u8) void {
    if (!pathExists(path)) {
        failBuild("error: {s} not found: {s}\n", .{ kind, path });
    }
}
