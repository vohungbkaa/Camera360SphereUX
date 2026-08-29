from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import cv2 as cv
import numpy as np

try:
    from .quality_gate import evaluate_quality, parse_control_point_graph
except ImportError:  # Direct execution: python backend/stitch_benchmark.py
    from quality_gate import evaluate_quality, parse_control_point_graph


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
    vertical_fovs: list[float] = []
    hugin_input_fovs: list[float] = []
    for index, source in enumerate(source_frames):
        image = cv.imread(str(source), cv.IMREAD_COLOR | cv.IMREAD_IGNORE_ORIENTATION)
        if image is None:
            raise RuntimeError(f"Cannot decode {source}")
        metadata = read_frame_metadata(source)
        orientation = int(
            metadata.get("capture", {}).get("intrinsics", {}).get("exifOrientation", 1)
        )
        oriented = apply_exif_orientation(image, orientation)
        height, width = oriented.shape[:2]
        output = destination / f"sphere-{index:03d}.jpg"
        # Production uses maximum_edge=0. Keep the exact JPEG bytes: decoding,
        # rotating and encoding again would throw away detail before Hugin sees it.
        if maximum_edge <= 0:
            shutil.copy2(source, output)
        elif max(width, height) > maximum_edge:
            scale = maximum_edge / max(width, height)
            oriented = cv.resize(
                oriented,
                (round(width * scale), round(height * scale)),
                interpolation=cv.INTER_AREA,
            )
            if not cv.imwrite(str(output), oriented, [cv.IMWRITE_JPEG_QUALITY, 100]):
                raise RuntimeError(f"Cannot write prepared input {output}")
            height, width = oriented.shape[:2]
            orientation = 1
        else:
            shutil.copy2(source, output)
        intrinsics = metadata.get("capture", {}).get("intrinsics", {})
        if value := intrinsics.get("horizontalFovDegrees"):
            horizontal_fovs.append(float(value))
        if value := intrinsics.get("verticalFovDegrees"):
            vertical_fovs.append(float(value))
        horizontal_fov = intrinsics.get("horizontalFovDegrees")
        vertical_fov = intrinsics.get("verticalFovDegrees")
        input_fov = vertical_fov if orientation in {5, 6, 7, 8} else horizontal_fov
        if input_fov:
            hugin_input_fovs.append(float(input_fov))
        capture_quality = dict(metadata.get("capture", {}).get("quality") or {})
        luma = cv.cvtColor(oriented, cv.COLOR_BGR2GRAY)
        luma_height, luma_width = luma.shape
        center = luma[
            luma_height // 10 : luma_height - luma_height // 10,
            luma_width // 10 : luma_width - luma_width // 10,
        ]
        clipped_ratio = float(np.mean(center > 245))
        dark_ratio = float(np.mean(center < 16))
        mean_luma = float(np.mean(center) / 255.0)
        reasons = list(capture_quality.get("reasons") or [])
        client_sharpness = capture_quality.get("sharpness")
        if client_sharpness is not None and float(client_sharpness) < 0.018:
            reasons.append("blurOrLowTexture")
        if clipped_ratio > 0.18 or mean_luma > 0.96:
            reasons.append("overexposed")
        if dark_ratio > 0.60 or mean_luma < 0.025:
            reasons.append("tooDark")
        capture_quality.update({
            "accepted": capture_quality.get("accepted") is not False and not reasons,
            "reasons": list(dict.fromkeys(reasons)),
            "serverMeanLuma": round(mean_luma, 5),
            "serverDarkPixelRatio": round(dark_ratio, 5),
            "serverClippedHighlightRatio": round(clipped_ratio, 5),
            "minimumAcceptedSharpness": 0.018,
        })
        mapping.append(
            {
                "prepared": output.name,
                "source": source.name,
                "targetId": metadata.get("targetId"),
                "expectedPose": metadata.get("expectedPose"),
                "capturePose": metadata.get("capture", {}).get("pose"),
                "captureQuality": capture_quality,
                "exifOrientation": orientation,
                "preparedWidth": int(width),
                "preparedHeight": int(height),
            }
        )
    manifest_path = session / "manifest.json"
    manifest = (
        json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest_path.exists()
        else {}
    )
    product_type = manifest.get("productType") or "wide-panorama"
    if product_type in {"360", "360-horizontal"} or manifest.get("isClosedLoop"):
        product_type = "horizontal-360"
    result = {
        "sessionId": session.name,
        "productType": product_type,
        "captureMode": manifest.get("captureMode", "horizontal"),
        "isClosedHorizontalLoop": product_type == "horizontal-360",
        "frameCount": len(mapping),
        "maximumInputEdge": maximum_edge,
        "horizontalFovDegrees": float(np.median(horizontal_fovs)) if horizontal_fovs else 53.5,
        "verticalFovDegrees": float(np.median(vertical_fovs)) if vertical_fovs else 72.0,
        "huginInputFovDegrees": float(np.median(hugin_input_fovs)) if hugin_input_fovs else 53.5,
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


def run_hugin(
    inputs: Path,
    output_dir: Path,
    horizontal_fov: float,
    canvas_width: int,
    match_mode: str,
    product_type: str,
) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=False)
    input_mount = str(inputs.resolve())
    output_mount = str(output_dir.resolve())
    mapping = json.loads((inputs / "mapping.json").read_text(encoding="utf-8"))
    if canvas_width <= 0:
        canvas_width = derive_canvas_width(mapping)
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
    # A single closed horizontal ring is 360° around but intentionally retains
    # only the camera's maximum vertical field instead of inventing black poles.
    # A horizontal capture ring must retain all source vertical pixels. Do not
    # synthesize a 180-degree canvas with empty zenith/nadir just because yaw
    # closes at 360 degrees; Photo Sphere Viewer receives the crop geometry.
    geometry = hugin_output_geometry(product_type, canvas_width)
    flat_output = product_type == "horizontal-stitch"
    is_closed_horizontal_loop = product_type == "horizontal-360"
    output_projection = geometry["projection"]
    output_fov = geometry["fov"]
    output_canvas = geometry["canvas"]
    output_crop = "AUTO"
    script = r"""
set -euo pipefail
pto_gen --projection=0 --fov="$HFOV" --sort -o /output/project.pto /input/sphere-*.jpg
python3 /usr/local/bin/hugin_seed_pto.py /output/project.pto /input/mapping.json /output/prealigned.pto
cpfind "$MATCHER" --ransacmode="$RANSAC_MODE" --ransacdist=10 --minmatches=8 \
  --sieve2width=5 --sieve2height=5 --sieve2size=2 \
  -o /output/control-points.pto /output/prealigned.pto
cpclean --max-distance=1.0 -o /output/clean.pto /output/control-points.pto
autooptimiser -a -l -m -s -o /output/optimized.pto /output/clean.pto
pano_modify --straighten --center --projection="$OUTPUT_PROJECTION" --fov="$OUTPUT_FOV" \
  --canvas="$OUTPUT_CANVAS" \
  --crop="$OUTPUT_CROP" \
  --ldr-file=JPG --ldr-compression=100 \
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
        f"OUTPUT_CANVAS={output_canvas}",
        "-e",
        f"MATCHER={matcher}",
        "-e",
        f"RANSAC_MODE={ransac_mode}",
        "-e",
        f"OUTPUT_FOV={output_fov}",
        "-e",
        f"OUTPUT_PROJECTION={output_projection}",
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
        "outputMode": product_type,
        "controlPointRms": parse_hugin_rms(log_path),
        "output": str(output),
        **image_metrics(output),
    }
    used_frame_names = pto_image_names(output_dir / "final.pto")
    result["usedFrameNames"] = used_frame_names
    graph_frame_names = pto_image_names(output_dir / "clean.pto") or used_frame_names
    graph = parse_control_point_graph(output_dir / "clean.pto", graph_frame_names)
    quality = evaluate_quality(result, mapping, graph)
    result["qualityDecision"] = quality
    result["viewerConfig"] = {} if flat_output else panorama_viewer_config(
        output_dir / "final.pto", is_closed_loop=is_closed_horizontal_loop
    )
    write_result(output_dir, result)
    return result


def hugin_output_geometry(product_type: str, canvas_width: int) -> dict[str, Any]:
    if product_type == "horizontal-stitch":
        return {"projection": 1, "fov": "AUTO", "canvas": "AUTO"}
    return {
        "projection": 2,
        "fov": "360xAUTO",
        "canvas": f"{canvas_width}x{canvas_width // 2}",
    }


def derive_canvas_width(mapping: dict[str, Any]) -> int:
    source_height = max(frame["preparedHeight"] for frame in mapping["frames"])
    vertical_fov = max(1.0, float(mapping.get("verticalFovDegrees", 72.0)))
    # A 360 equirectangular canvas at the source pixels/degree preserves every
    # available vertical pixel instead of silently downscaling it.
    width = int(np.ceil(source_height * 360.0 / vertical_fov))
    return width + width % 2


def count_pto_images(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.startswith("i "))


def pto_image_names(path: Path) -> list[str]:
    names = []
    if not path.exists():
        return names
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("i "):
            continue
        match = re.search(r'n"([^"]+)"', line)
        if match:
            names.append(Path(match.group(1)).name)
    return names


def panorama_viewer_config(path: Path, *, is_closed_loop: bool) -> dict[str, Any]:
    """Map Hugin's cropped equirectangular canvas into a full 360x180 sphere."""
    line = next(
        (value for value in path.read_text(encoding="utf-8", errors="replace").splitlines() if value.startswith("p ")),
        "",
    )
    width_match = re.search(r"(?:^|\s)w(\d+)", line)
    height_match = re.search(r"(?:^|\s)h(\d+)", line)
    fov_match = re.search(r"(?:^|\s)v([-+0-9.eE]+)", line)
    crop_match = re.search(r'(?:^|\s)S"?(\d+),(\d+),(\d+),(\d+)"?', line)
    if not (width_match and height_match and fov_match and crop_match):
        return {}
    canvas_width = int(width_match.group(1))
    canvas_height = int(height_match.group(1))
    horizontal_fov = float(fov_match.group(1))
    left, right, top, bottom = (int(crop_match.group(i)) for i in range(1, 5))
    if canvas_width <= 0 or canvas_height <= 0 or horizontal_fov <= 0:
        return {}

    canvas_pixels_per_degree = canvas_width / horizontal_fov
    sphere_width = int(round(canvas_pixels_per_degree * 360.0))
    sphere_height = int(round(canvas_pixels_per_degree * 180.0))
    scale = sphere_width / canvas_width
    vertical_fov = canvas_height / canvas_pixels_per_degree
    sphere_left = int(round((180.0 - horizontal_fov / 2.0) * canvas_pixels_per_degree * scale))
    sphere_top = int(round((90.0 - vertical_fov / 2.0) * canvas_pixels_per_degree * scale))
    cropped_x = sphere_left + int(round(left * scale))
    cropped_y = sphere_top + int(round(top * scale))
    cropped_width = max(1, int(round((right - left) * scale)))
    cropped_height = max(1, int(round((bottom - top) * scale)))
    min_yaw = cropped_x / sphere_width * 360.0 - 180.0
    max_yaw = (cropped_x + cropped_width) / sphere_width * 360.0 - 180.0
    max_pitch = 90.0 - cropped_y / sphere_height * 180.0
    min_pitch = 90.0 - (cropped_y + cropped_height) / sphere_height * 180.0
    config: dict[str, Any] = {
        "panoData": {
            "fullWidth": sphere_width,
            "fullHeight": sphere_height,
            "croppedWidth": cropped_width,
            "croppedHeight": cropped_height,
            "croppedX": cropped_x,
            "croppedY": cropped_y,
        },
        "minimumPitchDegrees": round(min_pitch, 4),
        "maximumPitchDegrees": round(max_pitch, 4),
        "initialPitchDegrees": round((min_pitch + max_pitch) / 2.0, 4),
        "initialYawDegrees": round((min_yaw + max_yaw) / 2.0, 4),
        "horizontalWrap": is_closed_loop,
    }
    if not is_closed_loop:
        config["minimumYawDegrees"] = round(min_yaw, 4)
        config["maximumYawDegrees"] = round(max_yaw, 4)
    return config


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
        description="Run the Hugin production stitcher against one Camera360 session."
    )
    parser.add_argument("session", help="Session id or path to a session directory")
    parser.add_argument("--input-max-edge", type=int, default=0, help="0 keeps original JPEG bytes")
    parser.add_argument("--canvas-width", type=int, default=0, help="0 derives width from source vertical resolution")
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
    print("[hugin] starting", flush=True)
    try:
        result = run_hugin(
            run_dir / "inputs",
            run_dir / "hugin",
            prepared["huginInputFovDegrees"],
            args.canvas_width,
            args.hugin_match,
            prepared["productType"],
        )
        results.append(result)
        print(f"[hugin] completed in {result['seconds']}s: {result['output']}", flush=True)
    except Exception as error:
        failures.append({"engine": "hugin", "error": str(error)})
        print(f"[hugin] failed: {error}", file=sys.stderr, flush=True)
    write_comparison(run_dir, results, failures)
    print(f"Report: {run_dir / 'report.html'}")
    return 0 if results else 1


if __name__ == "__main__":
    raise SystemExit(main())
