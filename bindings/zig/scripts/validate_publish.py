#!/usr/bin/env python3

from __future__ import annotations

import argparse
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile

PUBLISHED_PATHS = (
    "LICENSE.md",
    "README.md",
    "build.zig",
    "build.zig.zon",
    "examples",
    "src",
)

CONSUMER_BUILD_ZIG = """const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk_prefix = b.option(
        []const u8,
        "turso-sdk-prefix",
        "Path to the staged Turso SDK prefix used by the turso dependency.",
    ) orelse failBuild(
        \\\\error: provide -Dturso-sdk-prefix=/path/to/turso-sdk when validating the consumer project
        \\\\
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
"""

CONSUMER_BUILD_ZIG_ZON = """.{
    .name = .consumer_smoke,
    .version = "0.0.0",
    .fingerprint = 0x822bb40da41a597d, // Changing this has security and trust implications.
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        .turso = .{
            .path = "../turso",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
"""

CONSUMER_MAIN_ZIG = """const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    try conn.execBatch(
        \\\\CREATE TABLE publish_smoke (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        \\\\INSERT INTO publish_smoke (name) VALUES ('smoke');
        \\\\PRAGMA user_version;
    );

    var stmt = try conn.prepare("SELECT name FROM publish_smoke WHERE name = :name");
    defer stmt.deinit();

    try stmt.bindNamed(":name", .{ .text = "smoke" });
    if (try stmt.step() != .row) {
        return error.ValidationFailed;
    }

    var value = try stmt.readValueAlloc(std.heap.page_allocator, 0);
    defer value.deinit(std.heap.page_allocator);

    switch (value) {
        .text => |text| {
            if (!std.mem.eql(u8, text, "smoke")) {
                return error.ValidationFailed;
            }
        },
        else => return error.ValidationFailed,
    }

    if (try stmt.step() != .done) {
        return error.ValidationFailed;
    }
}
"""


def copy_publish_tree(package_root: pathlib.Path, destination: pathlib.Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)

    for rel_path in PUBLISHED_PATHS:
        source = package_root / rel_path
        target = destination / rel_path
        if not source.exists():
            raise FileNotFoundError(f"missing publish path: {source}")
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)


def write_text(path: pathlib.Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def create_consumer_project(destination: pathlib.Path) -> None:
    write_text(destination / "build.zig", CONSUMER_BUILD_ZIG)
    write_text(destination / "build.zig.zon", CONSUMER_BUILD_ZIG_ZON)
    write_text(destination / "src" / "main.zig", CONSUMER_MAIN_ZIG)


def run(cmd: list[str], cwd: pathlib.Path) -> None:
    print(f"+ {shlex.join(cmd)}")
    subprocess.run(cmd, cwd=cwd, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate the publish-shaped Zig package and a generated clean-room consumer project.",
    )
    parser.add_argument("--package-root", required=True, help="Path to bindings/zig.")
    parser.add_argument("--sdk-prefix", required=True, help="Path to a staged Turso SDK prefix.")
    parser.add_argument("--zig-exe", default="zig", help="Path to the Zig executable.")
    args = parser.parse_args()

    package_root = pathlib.Path(args.package_root).resolve()
    sdk_prefix = pathlib.Path(args.sdk_prefix).resolve()

    if not package_root.is_dir():
        raise NotADirectoryError(f"package root does not exist: {package_root}")
    if not sdk_prefix.is_dir():
        raise NotADirectoryError(f"sdk prefix does not exist: {sdk_prefix}")

    with tempfile.TemporaryDirectory(prefix="turso-zig-publish-") as temp_dir_str:
        temp_dir = pathlib.Path(temp_dir_str)
        global_cache_dir = temp_dir / "global-cache"

        run(
            [
                args.zig_exe,
                "build",
                f"-Dturso-sdk-prefix={sdk_prefix}",
                "-Dturso-sdk-use-cargo=false",
                "--cache-dir",
                str(temp_dir / "package-build-cache"),
                "--global-cache-dir",
                str(global_cache_dir),
            ],
            cwd=package_root,
        )
        run(
            [
                args.zig_exe,
                "build",
                "test",
                f"-Dturso-sdk-prefix={sdk_prefix}",
                "-Dturso-sdk-use-cargo=false",
                "--cache-dir",
                str(temp_dir / "package-test-cache"),
                "--global-cache-dir",
                str(global_cache_dir),
            ],
            cwd=package_root,
        )

        copied_package_root = temp_dir / "turso"
        copied_consumer_root = temp_dir / "consumer"
        copy_publish_tree(package_root, copied_package_root)
        create_consumer_project(copied_consumer_root)

        run(
            [
                args.zig_exe,
                "build",
                "run",
                f"-Dturso-sdk-prefix={sdk_prefix}",
                "--cache-dir",
                str(temp_dir / "consumer-cache"),
                "--global-cache-dir",
                str(global_cache_dir),
            ],
            cwd=copied_consumer_root,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
