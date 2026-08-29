from __future__ import annotations

import re
import math
from collections import Counter
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


def parse_control_point_graph(path: Path, frame_names: list[str]) -> dict[str, Any]:
    """Build the visual match graph from cleaned Hugin control points."""
    pair_counts: Counter[tuple[int, int]] = Counter()
    if path.exists():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if not line.startswith("c "):
                continue
            first = re.search(r"(?:^|\s)n(\d+)", line)
            second = re.search(r"(?:^|\s)N(\d+)", line)
            if not first or not second:
                continue
            a, b = sorted((int(first.group(1)), int(second.group(1))))
            if a != b:
                pair_counts[(a, b)] += 1

    adjacency = {name: set() for name in frame_names}
    edges: list[dict[str, Any]] = []
    for (first, second), count in sorted(pair_counts.items()):
        if first >= len(frame_names) or second >= len(frame_names):
            continue
        a, b = frame_names[first], frame_names[second]
        edges.append({"a": a, "b": b, "controlPoints": count})
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
    return {
        "edgeCount": len(edges),
        "edges": edges,
        "componentCount": len(components),
        "components": components,
    }


def evaluate_horizontal_chain(
    mapping: dict[str, Any], graph: dict[str, Any] | None
) -> dict[str, Any]:
    """Validate adjacent photographed directions separately from the wrap seam."""
    frames = [
        frame for frame in mapping.get("frames", [])
        if "yaw" in (frame.get("expectedPose") or {})
    ]
    if len(frames) < 2:
        return {
            "captureChainStatus": "insufficient_frames",
            "wrapBoundaryStatus": "open",
            "horizontalCoverageDegrees": 0.0,
            "missingAdjacentPairs": [],
            "wrapBoundaryPair": None,
            "loopCoverageComplete": False,
        }

    ordered = sorted(
        frames,
        key=lambda frame: float(frame["expectedPose"]["yaw"]) % 360.0,
    )
    yaws = [float(frame["expectedPose"]["yaw"]) % 360.0 for frame in ordered]
    gaps = [
        ((yaws[(index + 1) % len(yaws)] - yaw) % 360.0, index)
        for index, yaw in enumerate(yaws)
    ]
    largest_gap, boundary_index = max(gaps)
    hfov = max(1.0, float(mapping.get("horizontalFovDegrees", 55.0)))
    loop_coverage_complete = largest_gap <= hfov * 0.8
    coverage = min(360.0, 360.0 - largest_gap + hfov)

    edge_lookup = {
        frozenset((edge.get("a"), edge.get("b"))): int(
            edge.get("controlPoints", edge.get("inliers", 0)) or 0
        )
        for edge in (graph or {}).get("edges", [])
    }
    adjacent_pairs: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for index, frame in enumerate(ordered):
        if index == boundary_index and not loop_coverage_complete:
            continue
        adjacent_pairs.append((frame, ordered[(index + 1) % len(ordered)]))

    minimum_control_points = 4
    missing = []
    for first, second in adjacent_pairs:
        pair = frozenset((first["prepared"], second["prepared"]))
        count = edge_lookup.get(pair, 0)
        if count < minimum_control_points:
            missing.append({
                "a": first.get("targetId") or first["prepared"],
                "b": second.get("targetId") or second["prepared"],
                "controlPoints": count,
            })

    boundary_first = ordered[boundary_index]
    boundary_second = ordered[(boundary_index + 1) % len(ordered)]
    boundary_pair = frozenset((boundary_first["prepared"], boundary_second["prepared"]))
    boundary_control_points = edge_lookup.get(boundary_pair, 0)
    wrap_closed = loop_coverage_complete and boundary_control_points >= minimum_control_points
    return {
        "captureChainStatus": "connected" if not missing else "disconnected",
        "wrapBoundaryStatus": "closed" if wrap_closed else "open",
        "horizontalCoverageDegrees": round(coverage, 3),
        "missingAdjacentPairs": missing,
        "wrapBoundaryPair": {
            "a": boundary_first.get("targetId") or boundary_first["prepared"],
            "b": boundary_second.get("targetId") or boundary_second["prepared"],
            "controlPoints": boundary_control_points,
        },
        "loopCoverageComplete": loop_coverage_complete,
    }


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

    chain = evaluate_horizontal_chain(mapping, graph)
    blockers, warnings, actions = [], [], []
    if capture_issues:
        blockers.append("captureQualityFailed")
        actions.append("recaptureFlaggedTargets")
    if graph and graph.get("componentCount", 1) > 1:
        blockers.append("disconnectedMatchGraph")
        actions.append("retryWithPosePriorThenRecaptureBridgeTargets")
    if graph and chain["captureChainStatus"] != "connected":
        blockers.append("missingAdjacentVisualMatches")
        actions.append("recaptureMissingAdjacentTargets")
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
        **chain,
    }
