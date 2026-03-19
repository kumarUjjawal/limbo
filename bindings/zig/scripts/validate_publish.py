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


def run(cmd: list[str], cwd: pathlib.Path) -> None:
    print(f"+ {shlex.join(cmd)}")
    subprocess.run(cmd, cwd=cwd, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate the publish-shaped Zig package and a clean-room consumer project.",
    )
    parser.add_argument("--package-root", required=True, help="Path to bindings/zig.")
    parser.add_argument("--consumer-root", required=True, help="Path to the clean-room consumer template.")
    parser.add_argument("--sdk-prefix", required=True, help="Path to a staged Turso SDK prefix.")
    parser.add_argument("--zig-exe", default="zig", help="Path to the Zig executable.")
    args = parser.parse_args()

    package_root = pathlib.Path(args.package_root).resolve()
    consumer_root = pathlib.Path(args.consumer_root).resolve()
    sdk_prefix = pathlib.Path(args.sdk_prefix).resolve()

    if not package_root.is_dir():
        raise NotADirectoryError(f"package root does not exist: {package_root}")
    if not consumer_root.is_dir():
        raise NotADirectoryError(f"consumer root does not exist: {consumer_root}")
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
        shutil.copytree(consumer_root, copied_consumer_root)

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
