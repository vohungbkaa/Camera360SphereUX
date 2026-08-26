from __future__ import annotations

import re
import math
from pathlib import Path
from typing import Any


EDGE = re.compile(
    r'"(?P<a>[^"]+)" -- "(?P<b>[^"]+)"'
    r'\[label="Nm=(?P<matches>\d+), Ni=(?P<inliers>\d+), C=(?P<confidence>[0-9.eE+-]+)"\]'
)


def parse_match_graph(path: Path, frame_names: list[str]) -> dict[str, Any]:
    adjacency = {name: set() for name in frame_names}
    edges: list[dict[str, Any]] = []
    if path.exists():
        for match in EDGE.finditer(path.read_text(encoding="utf-8", errors="replace")):
            a, b = match.group("a"), match.group("b")
            matches, inliers = int(match.group("matches")), int(match.group("inliers"))
            confidence = float(match.group("confidence"))
            edges.append({
                "a": a, "b": b, "matches": matches, "inliers": inliers,
                "inlierRatio": round(inliers / max(1, matches), 4),
                "confidence": round(confidence, 4),
            })
            if a in adjacency and b in adjacency:
                adjacency[a].add(b)
                adjacency[b].add(a)
    components: list[list[str]] = []
    remaining = set(frame_names)
    while remaining:
        start = min(remaining)
        stack, component = [start], []
        remaining.remove(start)
        while stack:
            node = stack.pop()
            component.append(node)
            for neighbor in adjacency[node] & remaining:
                remaining.remove(neighbor)
                stack.append(neighbor)
        components.append(sorted(component))
    components.sort(key=len, reverse=True)
    return {"edgeCount": len(edges), "edges": edges, "componentCount": len(components), "components": components}


def evaluate_quality(
    result: dict[str, Any], mapping: dict[str, Any], graph: dict[str, Any] | None = None
) -> dict[str, Any]:
    frames = mapping.get("frames", [])
    poses = {frame["prepared"]: frame.get("expectedPose") or {} for frame in frames}
    expected_names = [frame["prepared"] for frame in frames]
    used_names = set(result.get("usedFrameNames") or expected_names[: result.get("usedFrames", 0)])
    dropped = [
        {"prepared": frame["prepared"], "source": frame.get("source"), "targetId": frame.get("targetId")}
        for frame in frames if frame["prepared"] not in used_names
    ]
    capture_issues: list[dict[str, Any]] = []
    for frame in frames:
        quality = frame.get("captureQuality") or {}
        pose = frame.get("capturePose") or {}
        reasons = list(quality.get("reasons") or [])
        if quality.get("accepted") is False or reasons:
            capture_issues.append({"targetId": frame.get("targetId"), "reasons": reasons or ["captureRejected"]})
        if float(pose.get("rotationRate", 0) or 0) > 0.15:
            capture_issues.append({"targetId": frame.get("targetId"), "reasons": ["motionAtExposure"]})

    pose_conflicts: list[dict[str, Any]] = []
    if graph:
        hfov = float(mapping.get("horizontalFovDegrees", 55.0))
        for edge in graph.get("edges", []):
            first, second = poses.get(edge["a"], {}), poses.get(edge["b"], {})
            if "yaw" not in first or "yaw" not in second:
                continue
            pitch_a, pitch_b = math.radians(float(first.get("pitch", 0))), math.radians(float(second.get("pitch", 0)))
            yaw_delta = math.radians(float(first["yaw"]) - float(second["yaw"]))
            cosine = math.sin(pitch_a) * math.sin(pitch_b) + math.cos(pitch_a) * math.cos(pitch_b) * math.cos(yaw_delta)
            delta = math.degrees(math.acos(max(-1.0, min(1.0, cosine))))
            edge["poseDeltaDegrees"] = round(delta, 3)
            edge["poseConsistent"] = delta <= max(75.0, hfov * 1.5)
            if not edge["poseConsistent"]:
                pose_conflicts.append(edge)

    blockers, warnings, actions = [], [], []
    if capture_issues:
        blockers.append("captureQualityFailed")
        actions.append("recaptureFlaggedTargets")
    if graph and graph.get("componentCount", 1) > 1:
        blockers.append("disconnectedMatchGraph")
        actions.append("retryWithPosePriorThenRecaptureBridgeTargets")
    if pose_conflicts:
        blockers.append("matchGraphConflictsWithCapturePose")
        actions.append("rejectFalseVisualMatches")
    if dropped:
        warnings.append("engineDroppedFrames")
        actions.append("retryWithoutDroppingFrames")
    rms = result.get("controlPointRms")
    if rms is not None and float(rms) > 1.5:
        warnings.append("highControlPointRms")
        actions.append("reviewArchitecturalEdges")
    if blockers:
        status = "RECAPTURE"
    elif warnings or result.get("warnings"):
        status = "REVIEW"
    else:
        status = "PASS"
    return {
        "status": status,
        "commercialReady": status == "PASS",
        "blockers": blockers,
        "warnings": warnings,
        "recommendedActions": list(dict.fromkeys(actions)),
        "inputFrames": len(frames),
        "usedFrames": result.get("usedFrames", 0),
        "droppedFrames": dropped,
        "captureIssues": capture_issues,
        "poseConflictEdges": pose_conflicts,
        "matchGraph": graph,
    }
