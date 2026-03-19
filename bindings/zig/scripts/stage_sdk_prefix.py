#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys


def static_library_name() -> str:
    return "turso_sdk_kit.lib" if os.name == "nt" else "libturso_sdk_kit.a"


def detect_target_dir(repo_root: pathlib.Path) -> pathlib.Path:
    env_target_dir = os.environ.get("CARGO_TARGET_DIR")
    if env_target_dir:
        return pathlib.Path(env_target_dir).resolve()

    result = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--no-deps"],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )
    metadata = json.loads(result.stdout)
    return pathlib.Path(metadata["target_directory"]).resolve()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Stage turso.h and the turso_sdk_kit archive into an SDK prefix.",
    )
    parser.add_argument("--repo-root", required=True, help="Path to the Limbo repository root.")
    parser.add_argument(
        "--target-dir",
        help="Path to the Cargo target/debug directory containing the built archive.",
    )
    parser.add_argument("--out-dir", required=True, help="Output directory for the staged SDK prefix.")
    args = parser.parse_args()

    repo_root = pathlib.Path(args.repo_root).resolve()
    target_dir = pathlib.Path(args.target_dir).resolve() if args.target_dir else detect_target_dir(repo_root) / "debug"
    out_dir = pathlib.Path(args.out_dir).resolve()

    header_src = repo_root / "sdk-kit" / "turso.h"
    library_src = target_dir / static_library_name()

    if not header_src.is_file():
        raise FileNotFoundError(f"missing Turso SDK header: {header_src}")
    if not library_src.is_file():
        raise FileNotFoundError(f"missing Turso SDK archive: {library_src}")

    include_dir = out_dir / "include"
    lib_dir = out_dir / "lib"
    include_dir.mkdir(parents=True, exist_ok=True)
    lib_dir.mkdir(parents=True, exist_ok=True)

    shutil.copy2(header_src, include_dir / "turso.h")
    shutil.copy2(library_src, lib_dir / library_src.name)

    print(f"staged SDK prefix: {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
