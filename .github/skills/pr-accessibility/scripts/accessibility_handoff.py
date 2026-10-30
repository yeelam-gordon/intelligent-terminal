#!/usr/bin/env python3
"""Validate small Markdown routing handoffs; never render a reviewer summary."""
import argparse
from pathlib import Path
import re
import subprocess


SURFACES = ("fre", "agents", "fre-settings")


def triage(text, changed):
    lines = text.strip().splitlines()
    if not lines or lines[0] not in ("# Related", "# None", "# Uncertain"):
        raise ValueError("triage must start with # Related, # None or # Uncertain")
    if len(text.encode("utf-8")) > 16384:
        raise ValueError("triage exceeds 16 KiB")
    candidates = re.findall(r"^- `([^`\r\n]+)`$", text, re.MULTILINE)
    if any(line.startswith("#") for line in lines[1:]):
        raise ValueError("triage has more than one decision heading")
    if any(line.startswith("- ") and not re.fullmatch(r"- `[^`\r\n]+`", line) for line in lines):
        raise ValueError("candidate bullets must contain a backtick-quoted changed path")
    if len(candidates) != len(set(candidates)) or any(p not in changed for p in candidates):
        raise ValueError("candidate paths must be unique changed paths")
    if lines[0] == "# Related" and not candidates:
        raise ValueError("Related requires candidate changed paths")
    if not any(line.strip() and not line.startswith(("#", "- `")) for line in lines[1:]):
        raise ValueError("triage requires a short explanation")
    return lines[0][2:]


def native(text):
    lines = text.strip().splitlines()
    if not lines or lines[0] != "# Native checks" or len(text.encode("utf-8")) > 16384:
        raise ValueError("native selection requires # Native checks and at most 16 KiB")
    if any(line.startswith("#") for line in lines[1:]):
        raise ValueError("native selection has more than one heading")
    selected = [line[2:] for line in lines[1:] if line.startswith("- ")]
    if (not selected or len(selected) != len(set(selected)) or
            any(value not in (*SURFACES, "None") for value in selected) or
            ("None" in selected and len(selected) != 1)):
        raise ValueError("select unique supported native states or None")
    if not any(line.strip() and not line.startswith("- ") for line in lines[1:]):
        raise ValueError("native selection requires an applicability reason")
    return ",".join(value for value in SURFACES if value in selected)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("triage", "native"))
    parser.add_argument("path", type=Path)
    parser.add_argument("--base")
    parser.add_argument("--head")
    args = parser.parse_args()
    if args.path.is_symlink() or not args.path.is_file():
        raise ValueError("handoff must be a regular file")
    text = args.path.read_text(encoding="utf-8")
    if args.kind == "triage":
        if not all(value and re.fullmatch(r"[0-9a-fA-F]{40}", value) for value in (args.base, args.head)):
            raise ValueError("triage requires immutable base/head SHAs")
        data = subprocess.check_output(
            ["git", "--no-replace-objects", "-c", "core.fsmonitor=false", "diff",
             "--no-ext-diff", "--no-renames", "--name-only", "-z", f"{args.base}...{args.head}"],
        ).decode("utf-8")
        result = triage(text, set(data.rstrip("\0").split("\0")))
    else:
        result = native(text)
    print(result)


if __name__ == "__main__":
    main()
