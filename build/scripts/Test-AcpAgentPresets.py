#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

"""Check the local ACP presets against an already downloaded, pinned registry.

No agent installation, execution, authentication or runtime network requests.
The optional matrix is generated research evidence, not shipped executable data.
"""

import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

REVISION = "2a27ff18b5816f47d7ec538e22943ff194e05131"


def check_registry_svg(path, id_):
    root = ET.parse(path).getroot()
    assert root.find(".//{http://www.w3.org/2000/svg}text") is None, f"{id_}: native SVG cannot render text"
    if id_ == "codebuddy-code":
        # The pinned source's paths extend beyond its original 16x16 canvas.
        assert root.attrib["viewBox"] == "0 0 21 21", f"{id_}: artwork would be clipped"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--revision", required=True, choices=[REVISION])
    parser.add_argument("--matrix", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    header = (repo / "src/cascadia/inc/AcpAgentPresets.h").read_text(encoding="utf-8")
    assert REVISION in header
    rows = re.findall(
        r'Preset\s*\{\s*L"([^"]+)"\s*,\s*L"([^"]+)"\s*,'
        r'\s*L"([^"]*)"\s*,\s*L"([^"]*)"\s*\}',
        header,
    )
    assert len(rows) == 42 and len({r[0] for r in rows}) == len(rows), "42 distinct active presets required"
    presets = {row[0]: row for row in rows}
    manifests = {
        p.parent.name: json.loads(p.read_text(encoding="utf-8"))
        for p in args.registry.glob("*/agent.json")
    }
    quarantine_data = json.loads((args.registry / "quarantine.json").read_text(encoding="utf-8"))
    # The pinned quarantine file is an array of registry IDs.
    quarantined = set(quarantine_data)
    assert quarantined == {"agoragentic-acp", "deepagents", "minion-code", "vtcode"}
    assert len(manifests) == 46 and set(presets) == set(manifests) - quarantined
    assets = repo / "src/cascadia/CascadiaPackage/AgentIcons"
    matrix = []
    for id_, manifest in sorted(manifests.items()):
        distribution = manifest["distribution"]
        row = presets.get(id_)
        if row:
            _, _, command, builtin_icon = row
            package = distribution.get("npx")
            if command:
                assert package and not package.get("env"), f"{id_}: cannot drop environment"
                expected = "npx --yes " + package["package"]
                if package.get("args"):
                    expected += " " + " ".join(package["args"])
                assert command == expected, f"{id_}: command/argument drift"
                assert re.search(r"@\d+\.\d+\.\d+(?:\s|$)", package["package"]), f"{id_}: version must be pinned"
            icon_root = assets if builtin_icon else assets / "Registry"
            icon_id = builtin_icon or id_
            for path in [icon_root / (icon_id + ".svg"), icon_root / "Masks" / (icon_id + ".png")]:
                assert path.is_file(), f"missing shared choice/profile icon: {path}"
            if not builtin_icon:
                for suffix in [".svg", "-light.svg"]:
                    check_registry_svg(icon_root / (icon_id + suffix), id_)
        binary = distribution.get("binary", {})
        matrix.append({
            "id": id_,
            "name": manifest["name"],
            "version": manifest["version"],
            "registry_revision": REVISION,
            "manifest": f"https://github.com/agentclientprotocol/registry/blob/{REVISION}/{id_}/agent.json",
            "repository": manifest.get("repository"),
            "provider_docs": manifest.get("website"),
            "quarantined": id_ in quarantined,
            "distribution": distribution,
            "windows_binary_targets": [p for p in binary if p.startswith("windows-")],
            "wsl_linux_binary_targets": [p for p in binary if p.startswith("linux-")],
            "package_platform_support": "Provider/runtime requirements must be checked; npx/uvx is not proof of Windows/WSL support.",
            "preset_command": row[2] if row else None,
            "setup": "quarantined" if not row else "editable package command" if row[2] else "manual executable/environment configuration",
            "profile": "Generated for configured valid custom binding; native interactive command/resume configured separately." if row else "not offered",
            "native_resume": "Unknown unless explicitly covered in doc/specs/acp-registry-native-sessions.md; ACP session IDs are not assumed native IDs.",
            "runtime_verified": False,
        })
    if args.matrix:
        args.matrix.parent.mkdir(parents=True, exist_ok=True)
        args.matrix.write_text(json.dumps({"registry_revision": REVISION, "entries": matrix}, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {len(manifests)} manifests = {len(rows)} offered + {len(quarantined)} quarantined; "
          f"{sum(bool(r[2]) for r in rows)} faithful pinned commands; all shared choice/profile icons present.")


if __name__ == "__main__":
    main()
