import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

MAX_RESOURCE_BYTES = 4 * 1024 * 1024


def read_revision(revision, path):
    object_name = f"{revision}:{path}"
    size_result = subprocess.run(
        ["git", "cat-file", "-s", object_name],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if size_result.returncode != 0:
        return None
    if int(size_result.stdout) > MAX_RESOURCE_BYTES:
        raise ValueError(f"{path} exceeds the {MAX_RESOURCE_BYTES}-byte classification limit")

    result = subprocess.run(
        ["git", "show", object_name],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.stdout if result.returncode == 0 else None


def xml_element(element):
    if element is None:
        return None
    return (
        element.tag,
        tuple(sorted(element.attrib.items())),
        element.text or "",
        tuple((xml_element(child), child.tail or "") for child in element),
    )


def normalize_comment_text(text):
    return re.sub(r"\s+", " ", text.strip())


def split_inline_comment(value):
    in_single = False
    in_double = False
    escape = False
    for index, character in enumerate(value):
        if escape:
            escape = False
            continue
        if character == "\\" and in_double:
            escape = True
            continue
        if character == "'" and not in_double:
            in_single = not in_single
            continue
        if character == '"' and not in_single:
            in_double = not in_double
            continue
        if character == "#" and not in_single and not in_double:
            if index == 0 or value[index - 1].isspace():
                return value[:index].rstrip(), normalize_comment_text(value[index:])
    return value.rstrip(), None


def resw_snapshot(content):
    if content is None:
        return None
    # The gate decides whether localized entries changed; BOM and line-ending-only
    # rewrites are intentionally left to deterministic validation and normal review.
    if b"\x00" in content:
        raise ValueError(".resw files must use UTF-8 encoding")
    try:
        decoded = content.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise ValueError(".resw files must use UTF-8 encoding") from error
    if "<!doctype" in decoded.lower():
        raise ValueError("DOCTYPE declarations are not allowed in .resw files")
    root = ET.fromstring(content)
    return tuple(
        sorted(
            (
                data.attrib.get("name", ""),
                tuple(sorted(data.attrib.items())),
                xml_element(data.find("value")),
                xml_element(data.find("comment")),
            )
            for data in root.findall("./data")
        )
    )


def yaml_snapshot(content):
    if content is None:
        return None
    # Ignore encoding and formatting churn when the flat localization map is equal.
    bound_entries = []
    unbound_blocks = []
    pending_comments = []
    for raw_line in content.decode("utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line:
            if pending_comments:
                unbound_blocks.append(tuple(pending_comments))
                pending_comments = []
            continue
        if line.startswith("#"):
            pending_comments.append(normalize_comment_text(line))
            continue
        match = re.match(r"^([A-Za-z0-9_.-]+)\s*:\s*(.*)$", line)
        if match:
            value, inline_comment = split_inline_comment(match.group(2))
            bound_entries.append(
                (
                    "entry",
                    match.group(1),
                    value.rstrip(),
                    tuple(pending_comments),
                    inline_comment or "",
                )
            )
            pending_comments = []
        else:
            if pending_comments:
                unbound_blocks.append(tuple(pending_comments))
                pending_comments = []
            unbound_blocks.append((line,))

    if pending_comments:
        unbound_blocks.append(tuple(pending_comments))

    return tuple(sorted(bound_entries)), tuple(unbound_blocks)


def main():
    merge_base, head_sha = sys.argv[1:3]
    raw_paths = subprocess.check_output(
        [
            "git",
            "diff",
            "--name-only",
            "-z",
            merge_base,
            head_sha,
            "--",
            "src/cascadia/**/Resources/*.resw",
            "src/cascadia/**/Resources/**/*.resw",
            "tools/wta/locales/*.yml",
        ],
    )
    paths = [os.fsdecode(path) for path in raw_paths.split(b"\0") if path]

    for path in paths:
        before = read_revision(merge_base, path)
        after = read_revision(head_sha, path)
        if before is None and after is None:
            raise ValueError(f"{path} is unreadable at both revisions")
        snapshot = resw_snapshot if path.endswith(".resw") else yaml_snapshot
        if snapshot(before) != snapshot(after):
            print("true")
            return
    print("false")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Semantic localization classification failed: {error}", file=sys.stderr)
        print("true")
        sys.exit(1)
