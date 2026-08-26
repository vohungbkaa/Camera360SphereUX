from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import warnings
from datetime import datetime
from pathlib import Path
from typing import Any

import cv2 as cv
import numpy as np

from quality_gate import evaluate_quality, parse_match_graph


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SESSIONS_ROOT = PROJECT_ROOT / "backend" / "data" / "sessions"
HUGIN_IMAGE = "camera360-hugin:2024.0.1"


def natural_frame_key(path: Path) -> tuple[int, str]:
    match = re.search(r"(\d+)$", path.stem)
    return (int(match.group(1)) if match else sys.maxsize, path.name)


def resolve_session(value: str) -> Path:
    candidate = Path(value).expanduser()
    if not candidate.is_absolute():
        project_candidate = PROJECT_ROOT / candidate
        candidate = project_candidate if project_candidate.exists() else DEFAULT_SESSIONS_ROOT / value
    candidate = candidate.resolve()
    frames = candidate / "frames"
    if not frames.is_dir():
        raise SystemExit(f"Session has no frames directory: {candidate}")
    if len(list(frames.glob("*.jpg"))) < 2:
        raise SystemExit(f"Session needs at least two JPEG frames: {frames}")
    return candidate


def read_frame_metadata(frame: Path) -> dict[str, Any]:
    sidecar = frame.with_suffix(".json")
    if not sidecar.exists():
        return {}
    return json.loads(sidecar.read_text(encoding="utf-8"))


def prepare_inputs(session: Path, destination: Path, maximum_edge: int) -> dict[str, Any]:
    destination.mkdir(parents=True, exist_ok=False)
    source_frames = sorted((session / "frames").glob("*.jpg"), key=natural_frame_key)
    mapping: list[dict[str, Any]] = []
    horizontal_fovs: list[float] = []
    for index, source in enumerate(source_frames):
        image = cv.imread(str(source), cv.IMREAD_COLOR | cv.IMREAD_IGNORE_ORIENTATION)
        if image is None:
            raise RuntimeError(f"Cannot decode {source}")
        metadata = read_frame_metadata(source)
        orientation = int(
            metadata.get("capture", {}).get("intrinsics", {}).get("exifOrientation", 1)
        )
        image = apply_exif_orientation(image, orientation)
        height, width = image.shape[:2]
        if maximum_edge > 0 and max(width, height) > maximum_edge:
            scale = maximum_edge / max(width, height)
            image = cv.resize(
                image,
                (round(width * scale), round(height * scale)),
                interpolation=cv.INTER_AREA,
            )
        output = destination / f"sphere-{index:03d}.jpg"
        if not cv.imwrite(str(output), image, [cv.IMWRITE_JPEG_QUALITY, 97]):
            raise RuntimeError(f"Cannot write prepared input {output}")
        intrinsics = metadata.get("capture", {}).get("intrinsics", {})
        if value := intrinsics.get("horizontalFovDegrees"):
            horizontal_fovs.append(float(value))
        mapping.append(
            {
                "prepared": output.name,
                "source": source.name,
                "targetId": metadata.get("targetId"),
                "expectedPose": metadata.get("expectedPose"),
                "capturePose": metadata.get("capture", {}).get("pose"),
                "captureQuality": metadata.get("capture", {}).get("quality"),
                "exifOrientation": orientation,
                "preparedWidth": int(image.shape[1]),
                "preparedHeight": int(image.shape[0]),
            }
        )
    manifest_path = session / "manifest.json"
    manifest = (
        json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest_path.exists()
        else {}
    )
    product_type = manifest.get("productType", "360")
    result = {
        "sessionId": session.name,
        "productType": product_type,
        "isFullSphere": product_type == "360",
        "frameCount": len(mapping),
        "maximumInputEdge": maximum_edge,
        "horizontalFovDegrees": float(np.median(horizontal_fovs)) if horizontal_fovs else 53.5,
        "frames": mapping,
    }
    (destination / "mapping.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return result


def apply_exif_orientation(image: np.ndarray, orientation: int) -> np.ndarray:
    # Frames from the current iOS client use orientation 6 (90° clockwise).
    operations = {
        2: lambda value: cv.flip(value, 1),
        3: lambda value: cv.rotate(value, cv.ROTATE_180),
        4: lambda value: cv.flip(value, 0),
        5: lambda value: cv.transpose(value),
        6: lambda value: cv.rotate(value, cv.ROTATE_90_CLOCKWISE),
        7: lambda value: cv.flip(cv.transpose(value), -1),
        8: lambda value: cv.rotate(value, cv.ROTATE_90_COUNTERCLOCKWISE),
    }
    return operations.get(orientation, lambda value: value)(image)


def run_openstitching(
    inputs: Path, output_dir: Path, is_full_sphere: bool
) -> dict[str, Any]:
    from stitching import Stitcher

    output_dir.mkdir(parents=True, exist_ok=False)
    image_paths = [str(path) for path in sorted(inputs.glob("sphere-*.jpg"))]
    graph_path = output_dir / "matches-graph.dot"
    started = time.monotonic()
    settings = {
        "detector": "sift",
        "nfeatures": 2000,
        "matcher_type": "homography",
        "range_width": -1,
        "confidence_threshold": 0.25,
        "matches_graph_dot_file": str(graph_path),
        "estimator": "homography",
        "adjuster": "ray",
        "refinement_mask": "xxxxx",
        "wave_correct_kind": "horiz",
        "warper_type": "spherical",
        "medium_megapix": 0.5,
        "low_megapix": 0.1,
        "final_megapix": -1,
        # Preserve the 2:1 canvas for a complete sphere, but remove unused black
        # space for a deliberately partial/wide panorama.
        "crop": not is_full_sphere,
        "compensator": "gain_blocks",
        "finder": "dp_color",
        "blender_type": "multiband",
        "blend_strength": 5,
    }
    (output_dir / "settings.json").write_text(
        json.dumps(settings, indent=2), encoding="utf-8"
    )
    caught: list[str] = []
    with warnings.catch_warnings(record=True) as warning_records:
        warnings.simplefilter("always")
        stitcher = Stitcher(**settings)
        panorama = stitcher.stitch(image_paths)
        caught = [str(record.message) for record in warning_records]
    output = output_dir / "panorama.jpg"
    if panorama is None or not cv.imwrite(
        str(output), panorama, [cv.IMWRITE_JPEG_QUALITY, 97]
    ):
        raise RuntimeError("OpenStitching did not produce a panorama")
    used = [Path(name).name for name in stitcher.images.names]
    result = {
        "engine": "openstitching-0.6.1",
        "status": "completed",
        "seconds": round(time.monotonic() - started, 3),
        "inputFrames": len(image_paths),
        "usedFrames": len(used),
        "usedFrameNames": used,
        "warnings": caught,
        "output": str(output),
        **image_metrics(output),
    }
    mapping = json.loads((inputs / "mapping.json").read_text(encoding="utf-8"))
    graph = parse_match_graph(graph_path, [Path(path).name for path in image_paths])
    result["qualityDecision"] = evaluate_quality(result, mapping, graph)
    write_result(output_dir, result)
    return result


def run_hugin(
    inputs: Path,
    output_dir: Path,
    horizontal_fov: float,
    canvas_width: int,
    match_mode: str,
    is_full_sphere: bool,
) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=False)
    input_mount = str(inputs.resolve())
    output_mount = str(output_dir.resolve())
    canvas_height = canvas_width // 2
    matcher = {
        "prealigned": "--prealigned",
        "allpairs": "--allpairs",
        "multirow": "--multirow",
    }[match_mode]
    # The iOS pose is reliable for choosing neighboring frames, but its optical
    # axis/FOV is not yet fully calibrated. Homography RANSAC tolerates that
    # calibration error while --prealigned still limits the candidate pairs.
    ransac_mode = "hom"
    output_fov = "360x180" if is_full_sphere else "AUTO"
    output_crop = (
        f"0,{canvas_width},0,{canvas_height}" if is_full_sphere else "AUTO"
    )
    script = r"""
set -euo pipefail
pto_gen --projection=0 --fov="$HFOV" --sort -o /output/project.pto /input/sphere-*.jpg
python3 /usr/local/bin/hugin_seed_pto.py /output/project.pto /input/mapping.json /output/prealigned.pto
cpfind "$MATCHER" --ransacmode="$RANSAC_MODE" --ransacdist=10 --minmatches=8 \
  --sieve2width=5 --sieve2height=5 --sieve2size=2 \
  -o /output/control-points.pto /output/prealigned.pto
cpclean --max-distance=1.0 -o /output/clean.pto /output/control-points.pto
autooptimiser -a -l -s -o /output/optimized.pto /output/clean.pto
pano_modify --straighten --center --projection=2 --fov="$OUTPUT_FOV" \
  --canvas="$CANVAS_WIDTH"x"$CANVAS_HEIGHT" \
  --crop="$OUTPUT_CROP" \
  --ldr-file=JPG --ldr-compression=97 \
  -o /output/final.pto /output/optimized.pto
hugin_executor --stitching --prefix=/output/panorama /output/final.pto
"""
    command = [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{input_mount}:/input:ro",
        "-v",
        f"{output_mount}:/output",
        "-v",
        f"{(PROJECT_ROOT / 'backend' / 'hugin_seed_pto.py').resolve()}:/usr/local/bin/hugin_seed_pto.py:ro",
        "-e",
        f"HFOV={horizontal_fov}",
        "-e",
        f"CANVAS_WIDTH={canvas_width}",
        "-e",
        f"CANVAS_HEIGHT={canvas_height}",
        "-e",
        f"MATCHER={matcher}",
        "-e",
        f"RANSAC_MODE={ransac_mode}",
        "-e",
        f"OUTPUT_FOV={output_fov}",
        "-e",
        f"OUTPUT_CROP={output_crop}",
        HUGIN_IMAGE,
        "bash",
        "-lc",
        script,
    ]
    started = time.monotonic()
    log_path = output_dir / "hugin.log"
    with log_path.open("w", encoding="utf-8") as log:
        completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if completed.returncode != 0:
        result = {
            "engine": "hugin-2024.0.1",
            "status": "failed",
            "seconds": round(time.monotonic() - started, 3),
            "error": tail(log_path),
        }
        write_result(output_dir, result)
        raise RuntimeError(f"Hugin failed. See {log_path}\n{result['error']}")
    output = output_dir / "panorama.jpg"
    if not output.exists():
        candidates = sorted(output_dir.glob("panorama*"))
        raise RuntimeError(f"Hugin output not found; candidates: {candidates}")
    result = {
        "engine": "hugin-2024.0.1",
        "status": "completed",
        "seconds": round(time.monotonic() - started, 3),
        "inputFrames": len(list(inputs.glob("sphere-*.jpg"))),
        "usedFrames": count_pto_images(output_dir / "final.pto"),
        "matchMode": match_mode,
        "outputMode": "full-sphere" if is_full_sphere else "auto-cropped-wide",
        "controlPointRms": parse_hugin_rms(log_path),
        "output": str(output),
        **image_metrics(output),
    }
    mapping = json.loads((inputs / "mapping.json").read_text(encoding="utf-8"))
    result["qualityDecision"] = evaluate_quality(result, mapping)
    write_result(output_dir, result)
    return result


def count_pto_images(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.startswith("i "))


def parse_hugin_rms(path: Path) -> float | None:
    content = path.read_text(encoding="utf-8", errors="replace")
    values = re.findall(
        r"Average \(rms\) distance between Controlpoints\s*\n"
        r"after \d+ iteration\(s\):\s*(" + r"[-+0-9.eE]+" + r") units",
        content,
    )
    return round(float(values[-1]), 4) if values else None


def image_metrics(path: Path) -> dict[str, Any]:
    image = cv.imread(str(path), cv.IMREAD_COLOR)
    if image is None:
        return {}
    height, width = image.shape[:2]
    gray = cv.cvtColor(image, cv.COLOR_BGR2GRAY)
    non_black = np.any(image > 5, axis=2)
    return {
        "width": int(width),
        "height": int(height),
        "megapixels": round(width * height / 1_000_000, 3),
        "aspectRatio": round(width / height, 4),
        "nonBlackCoverage": round(float(np.mean(non_black)), 5),
        "laplacianVariance": round(float(cv.Laplacian(gray, cv.CV_64F).var()), 3),
        "bytes": path.stat().st_size,
    }


def tail(path: Path, lines: int = 35) -> str:
    content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(content[-lines:])


def write_result(directory: Path, result: dict[str, Any]) -> None:
    (directory / "result.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def write_comparison(run_dir: Path, results: list[dict[str, Any]], failures: list[dict[str, str]]) -> None:
    report = {
        "createdAt": datetime.now().astimezone().isoformat(),
        "results": results,
        "failures": failures,
        "commercialDecision": {
            result["engine"]: result.get("qualityDecision", {}).get("status", "UNKNOWN")
            for result in results
        },
        "interpretation": {
            "nonBlackCoverage": "Coverage only; a higher value does not prove better seams.",
            "laplacianVariance": "Sharpness proxy; compare only outputs with similar resolution.",
            "visualReview": "Inspect duplicated edges, doors/windows, horizon, zenith/nadir and exposure seams.",
        },
    }
    (run_dir / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    cards = []
    for result in results:
        relative = Path(result["output"]).relative_to(run_dir)
        metrics = "".join(
            f"<li><b>{html.escape(str(key))}</b>: {html.escape(str(value))}</li>"
            for key, value in result.items()
            if key not in {"output", "usedFrameNames", "warnings", "qualityDecision"}
        )
        cards.append(
            f"<section><h2>{html.escape(result['engine'])}</h2>"
            f"<h3>Quality gate: {html.escape(result.get('qualityDecision', {}).get('status', 'UNKNOWN'))}</h3>"
            f"<img src='{html.escape(str(relative))}'><ul>{metrics}</ul></section>"
        )
    failure_html = "".join(
        f"<li><b>{html.escape(item['engine'])}</b>: {html.escape(item['error'])}</li>"
        for item in failures
    )
    document = f"""<!doctype html>
<meta charset="utf-8"><title>Camera360 stitch comparison</title>
<style>body{{font:14px system-ui;margin:24px;background:#111;color:#eee}}main{{display:grid;grid-template-columns:1fr 1fr;gap:20px}}section{{background:#222;padding:14px;border-radius:10px}}img{{width:100%;background:#000}}code{{color:#ffd166}}@media(max-width:900px){{main{{grid-template-columns:1fr}}}}</style>
<h1>Camera360 stitch comparison</h1>
<p>Không chọn winner chỉ bằng số đo. Hãy zoom cạnh cửa, song sắt, cửa sổ, đường chân tường và hai cực.</p>
<main>{''.join(cards)}</main><ul>{failure_html}</ul>
"""
    (run_dir / "report.html").write_text(document, encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run Hugin and/or OpenStitching against one Camera360 session."
    )
    parser.add_argument("engine", choices=("hugin", "openstitching", "compare"))
    parser.add_argument("session", help="Session id or path to a session directory")
    parser.add_argument("--input-max-edge", type=int, default=1600, help="0 keeps full resolution")
    parser.add_argument("--canvas-width", type=int, default=4096, help="Hugin 2:1 output width")
    parser.add_argument(
        "--hugin-match",
        choices=("prealigned", "allpairs", "multirow"),
        default="prealigned",
        help="prealigned uses session yaw/pitch and is recommended",
    )
    parser.add_argument("--output", type=Path, help="New output directory; must not already exist")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    session = resolve_session(args.session)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = (args.output or session / "benchmark" / timestamp).resolve()
    run_dir.mkdir(parents=True, exist_ok=False)
    prepared = prepare_inputs(session, run_dir / "inputs", args.input_max_edge)
    results: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []
    engines = ("hugin", "openstitching") if args.engine == "compare" else (args.engine,)
    for engine in engines:
        print(f"[{engine}] starting", flush=True)
        try:
            if engine == "hugin":
                result = run_hugin(
                    run_dir / "inputs",
                    run_dir / "hugin",
                    prepared["horizontalFovDegrees"],
                    args.canvas_width,
                    args.hugin_match,
                    prepared["isFullSphere"],
                )
            else:
                result = run_openstitching(
                    run_dir / "inputs",
                    run_dir / "openstitching",
                    prepared["isFullSphere"],
                )
            results.append(result)
            print(f"[{engine}] completed in {result['seconds']}s: {result['output']}", flush=True)
        except Exception as error:  # Keep compare mode useful if one engine fails.
            failures.append({"engine": engine, "error": str(error)})
            print(f"[{engine}] failed: {error}", file=sys.stderr, flush=True)
    write_comparison(run_dir, results, failures)
    print(f"Report: {run_dir / 'report.html'}")
    return 0 if results else 1


if __name__ == "__main__":
    raise SystemExit(main())
