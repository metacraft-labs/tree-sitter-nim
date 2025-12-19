#!/usr/bin/env python3
"""Bump version in all package files, commit, and tag."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def get_repo_root() -> Path:
    """Get the repository root directory."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(result.stdout.strip())


def read_json(path: Path) -> dict:
    """Read a JSON file."""
    return json.loads(path.read_text())


def write_json(path: Path, data: dict) -> None:
    """Write a JSON file with consistent formatting."""
    path.write_text(json.dumps(data, indent=2) + "\n")


def get_current_version(repo_root: Path) -> str:
    """Get current version from package.json."""
    package_json = read_json(repo_root / "package.json")
    return package_json["version"]


def parse_version(version: str) -> tuple[int, int, int]:
    """Parse a semver string into (major, minor, patch)."""
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version)
    if not match:
        raise ValueError(f"Invalid version format: {version}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def bump_version(version: str, bump_type: str) -> str:
    """Bump version according to bump_type (major, minor, patch)."""
    major, minor, patch = parse_version(version)

    if bump_type == "major":
        return f"{major + 1}.0.0"
    elif bump_type == "minor":
        return f"{major}.{minor + 1}.0"
    elif bump_type == "patch":
        return f"{major}.{minor}.{patch + 1}"
    else:
        raise ValueError(f"Unknown bump type: {bump_type}")


def update_package_json(repo_root: Path, new_version: str) -> None:
    """Update version in package.json."""
    path = repo_root / "package.json"
    data = read_json(path)
    data["version"] = new_version
    write_json(path, data)


def update_tree_sitter_json(repo_root: Path, new_version: str) -> None:
    """Update version in tree-sitter.json."""
    path = repo_root / "tree-sitter.json"
    data = read_json(path)
    data["metadata"]["version"] = new_version
    write_json(path, data)


def update_cargo_toml(repo_root: Path, new_version: str) -> None:
    """Update version in bindings/rust/Cargo.toml."""
    path = repo_root / "bindings" / "rust" / "Cargo.toml"
    content = path.read_text()
    content = re.sub(
        r'^version = ".*"',
        f'version = "{new_version}"',
        content,
        count=1,
        flags=re.MULTILINE,
    )
    path.write_text(content)


def git_commit_and_tag(repo_root: Path, new_version: str) -> None:
    """Stage changes, commit, and create a tag."""
    files = [
        "package.json",
        "tree-sitter.json",
        "bindings/rust/Cargo.toml",
    ]

    subprocess.run(["git", "add"] + files, cwd=repo_root, check=True)
    subprocess.run(
        ["git", "commit", "-m", f"Bump version to {new_version}"],
        cwd=repo_root,
        check=True,
    )
    subprocess.run(
        ["git", "tag", f"v{new_version}"],
        cwd=repo_root,
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Bump version and create release tag")
    parser.add_argument(
        "bump_type",
        choices=["major", "minor", "patch", "current"],
        help="Type of version bump (or 'current' to show current version)",
    )
    parser.add_argument(
        "--no-commit",
        action="store_true",
        help="Only update files, don't commit or tag",
    )

    args = parser.parse_args()
    repo_root = get_repo_root()
    current = get_current_version(repo_root)

    if args.bump_type == "current":
        print(current)
        return 0

    new_version = bump_version(current, args.bump_type)
    print(f"Bumping version: {current} -> {new_version}")

    update_package_json(repo_root, new_version)
    update_tree_sitter_json(repo_root, new_version)
    update_cargo_toml(repo_root, new_version)

    if not args.no_commit:
        git_commit_and_tag(repo_root, new_version)
        print(f"Created commit and tag v{new_version}")
        print("Run 'git push && git push --tags' to publish")
    else:
        print("Files updated (no commit created)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
