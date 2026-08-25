from __future__ import annotations

import json
import re
import sys
from pathlib import Path


NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


def replace_token(line: str, token: str, value: float) -> str:
    pattern = re.compile(rf"(?<!\S){re.escape(token)}{NUMBER}")
    replacement = f"{token}{value:.8f}"
    if pattern.search(line):
        return pattern.sub(replacement, line, count=1)
    filename = line.find(' n"')
    return f"{line[:filename]} {replacement}{line[filename:]}" if filename >= 0 else f"{line} {replacement}"


def wrap_degrees(value: float) -> float:
    return (value + 180.0) % 360.0 - 180.0


def seed(source: Path, mapping_path: Path, destination: Path) -> None:
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
    poses = {
        frame["prepared"]: frame.get("expectedPose") or {}
        for frame in mapping.get("frames", [])
    }
    matched = 0
    output: list[str] = []
    for line in source.read_text(encoding="utf-8").splitlines():
        if line.startswith("i "):
            filename_match = re.search(r'n"([^"]+)"', line)
            filename = Path(filename_match.group(1)).name if filename_match else ""
            pose = poses.get(filename)
            if pose:
                # Both the iOS capture sequence and Hugin increase yaw in the
                # direction that moves scene content left in the image. Keeping
                # the sign lets cpfind's pose-aware RANSAC validate adjacent frames.
                line = replace_token(line, "y", wrap_degrees(float(pose.get("yaw", 0.0))))
                line = replace_token(line, "p", float(pose.get("pitch", 0.0)))
                line = replace_token(line, "r", 0.0)
                matched += 1
        output.append(line)
    if matched != len(poses):
        raise RuntimeError(f"Pose prior matched {matched}/{len(poses)} frames")
    destination.write_text("\n".join(output) + "\n", encoding="utf-8")
    print(f"Pose prior matched {matched}/{len(poses)} frames")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: hugin_seed_pto.py SOURCE.pto mapping.json DESTINATION.pto")
    seed(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
