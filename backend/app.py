from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Any

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel


ROOT = Path(os.environ.get("CAMERA360_DATA_DIR", Path(__file__).parent / "data")).resolve()
SESSIONS = ROOT / "sessions"
ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,120}$")
WRITE_LOCK = Lock()

app = FastAPI(title="Camera360 capture and stitching input server", version="0.1.0")


class SessionCreate(BaseModel):
    id: str | None = None
    schemaVersion: str = "2.0.0"
    platform: str | None = None


class CompleteRequest(BaseModel):
    schemaVersion: str = "2.1.0"
    captureMode: str = "horizontal"
    # Accepted for older mobile clients; output selection now happens after stitch.
    productType: str | None = None
    isClosedLoop: bool | None = None
    frames: list[dict[str, Any]]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def safe_id(value: str, kind: str) -> str:
    if not ID_PATTERN.fullmatch(value):
        raise HTTPException(400, f"Invalid {kind}")
    return value


def session_dir(session_id: str) -> Path:
    return SESSIONS / safe_id(session_id, "session id")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def append_event(directory: Path, event: str, **values: Any) -> None:
    record = {"at": utc_now(), "event": event, **values}
    with (directory / "events.ndjson").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False) + "\n")


def require_session(session_id: str) -> Path:
    directory = session_dir(session_id)
    if not directory.is_dir():
        raise HTTPException(404, "Session not found")
    return directory


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "dataDirectory": str(ROOT)}


@app.post("/v1/sessions")
def create_session(request: SessionCreate | None = None) -> dict[str, Any]:
    requested = request.id if request else None
    session_id = safe_id(requested, "session id") if requested else f"sphere-{uuid.uuid4()}"
    directory = session_dir(session_id)
    with WRITE_LOCK:
        directory.joinpath("frames").mkdir(parents=True, exist_ok=True)
        descriptor = directory / "session.json"
        if not descriptor.exists():
            write_json(descriptor, {
                "id": session_id,
                "schemaVersion": request.schemaVersion if request else "2.0.0",
                "platform": request.platform if request else None,
                "createdAt": utc_now(),
                "status": "capturing",
            })
            append_event(directory, "session.created")
    return {"id": session_id, "storagePath": str(directory)}


@app.post("/v1/sessions/{session_id}/frames")
async def upload_frame(
    session_id: str,
    metadata: str = Form(...),
    image: UploadFile = File(...),
) -> dict[str, Any]:
    directory = require_session(session_id)
    try:
        frame_metadata = json.loads(metadata)
    except json.JSONDecodeError as error:
        raise HTTPException(400, f"Invalid metadata JSON: {error.msg}") from error
    frame_id = safe_id(str(frame_metadata.get("id", "")), "frame id")
    if image.content_type not in {"image/jpeg", "image/jpg", "application/octet-stream"}:
        raise HTTPException(415, "Only original JPEG frames are accepted")
    image_path = directory / "frames" / f"{frame_id}.jpg"
    metadata_path = directory / "frames" / f"{frame_id}.json"
    temporary = image_path.with_suffix(".jpg.upload")
    with temporary.open("wb") as output:
        while chunk := await image.read(1024 * 1024):
            output.write(chunk)
    if temporary.stat().st_size == 0:
        temporary.unlink(missing_ok=True)
        raise HTTPException(400, "Empty JPEG")
    with WRITE_LOCK:
        temporary.replace(image_path)
        write_json(metadata_path, frame_metadata)
        append_event(
            directory,
            "frame.uploaded",
            frameId=frame_id,
            bytes=image_path.stat().st_size,
            targetId=frame_metadata.get("targetId"),
        )
    return {"id": frame_id, "imagePath": str(image_path), "metadataPath": str(metadata_path)}


@app.delete("/v1/sessions/{session_id}/frames/{frame_id}")
def delete_frame(session_id: str, frame_id: str) -> dict[str, bool]:
    directory = require_session(session_id)
    frame_id = safe_id(frame_id, "frame id")
    with WRITE_LOCK:
        (directory / "frames" / f"{frame_id}.jpg").unlink(missing_ok=True)
        (directory / "frames" / f"{frame_id}.json").unlink(missing_ok=True)
        append_event(directory, "frame.deleted", frameId=frame_id)
    return {"deleted": True}


@app.post("/v1/sessions/{session_id}/complete")
def complete_session(session_id: str, request: CompleteRequest) -> dict[str, Any]:
    directory = require_session(session_id)
    manifest = request.model_dump()
    manifest.update({"sessionId": session_id, "completedAt": utc_now()})
    with WRITE_LOCK:
        write_json(directory / "manifest.json", manifest)
        descriptor = json.loads((directory / "session.json").read_text(encoding="utf-8"))
        descriptor.update({"status": "captured", "completedAt": manifest["completedAt"]})
        write_json(directory / "session.json", descriptor)
        append_event(directory, "session.completed", frameCount=len(request.frames))
    return {"id": session_id, "frameCount": len(request.frames), "status": "captured"}


def run_stitch_job(directory: Path, job_path: Path, job_id: str) -> None:
    output_dir = directory / "stitches" / job_id
    command = [
        sys.executable,
        str(Path(__file__).with_name("stitch_benchmark.py")),
        str(directory),
        "--input-max-edge", "0",
        "--canvas-width", "0",
        "--output", str(output_dir),
    ]
    completed = subprocess.run(command, capture_output=True, text=True)
    with WRITE_LOCK:
        job = json.loads(job_path.read_text(encoding="utf-8"))
        job["finishedAt"] = utc_now()
        job["log"] = (completed.stdout + completed.stderr)[-12000:]
        report_path = output_dir / "report.json"
        if completed.returncode == 0 and report_path.exists():
            report = json.loads(report_path.read_text(encoding="utf-8"))
            result = report.get("results", [{}])[0]
            quality = result.get("qualityDecision", {})
            job.update({
                "status": "completed" if quality.get("commercialReady") else "needs_review",
                "qualityStatus": quality.get("status", "UNKNOWN"),
                "qualityDecision": quality,
                "viewerConfig": result.get("viewerConfig", {}),
                "captureChainStatus": quality.get("captureChainStatus", "unknown"),
                "wrapBoundaryStatus": quality.get("wrapBoundaryStatus", "unknown"),
                "horizontalCoverageDegrees": quality.get("horizontalCoverageDegrees"),
                "panoramaPath": result.get("output"),
                "reportPath": str(report_path),
            })
            append_event(directory, "stitch.completed", jobId=job_id, qualityStatus=job["qualityStatus"])
        else:
            job.update({"status": "failed", "message": "Stitching worker failed"})
            append_event(directory, "stitch.failed", jobId=job_id)
        write_json(job_path, job)


@app.post("/v1/sessions/{session_id}/stitch")
def start_stitch(session_id: str, background_tasks: BackgroundTasks) -> dict[str, Any]:
    directory = require_session(session_id)
    manifest_path = directory / "manifest.json"
    if not manifest_path.exists():
        raise HTTPException(409, "Complete the capture before stitching")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    frame_ids = {
        str(frame.get("id")) for frame in manifest.get("frames", []) if frame.get("id")
    }
    uploaded = {
        path.stem for path in (directory / "frames").glob("*.jpg")
    }
    if len(frame_ids & uploaded) < 2:
        raise HTTPException(422, "At least two uploaded frames are required for stitching")
    job_id = f"stitch-{uuid.uuid4()}"
    job = {
        "id": job_id,
        "sessionId": session_id,
        "status": "queued",
        "createdAt": utc_now(),
        "engine": "hugin-2024.0.1",
        "message": "Hugin worker queued with full-resolution inputs.",
    }
    with WRITE_LOCK:
        write_json(directory / "jobs" / f"{job_id}.json", job)
        append_event(directory, "stitch.queued", jobId=job_id)
    background_tasks.add_task(run_stitch_job, directory, directory / "jobs" / f"{job_id}.json", job_id)
    return job


@app.get("/v1/sessions/{session_id}/jobs/{job_id}")
def get_stitch_job(session_id: str, job_id: str) -> dict[str, Any]:
    directory = require_session(session_id)
    path = directory / "jobs" / f"{safe_id(job_id, 'job id')}.json"
    if not path.exists():
        raise HTTPException(404, "Stitch job not found")
    job = json.loads(path.read_text(encoding="utf-8"))
    # Backfill geometry for jobs produced before viewerConfig was persisted.
    if job.get("status") in {"completed", "needs_review"} and not job.get("viewerConfig"):
        panorama = Path(job.get("panoramaPath", ""))
        pto = panorama.parent / "final.pto"
        manifest_path = directory / "manifest.json"
        if pto.is_file() and manifest_path.is_file():
            from backend.stitch_benchmark import panorama_viewer_config

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            job["viewerConfig"] = panorama_viewer_config(
                pto, is_closed_loop=bool(manifest.get("isClosedLoop"))
            )
    return job


@app.get("/v1/sessions/{session_id}/jobs/{job_id}/panorama")
def get_stitch_panorama(session_id: str, job_id: str) -> FileResponse:
    directory = require_session(session_id)
    job_path = directory / "jobs" / f"{safe_id(job_id, 'job id')}.json"
    if not job_path.exists():
        raise HTTPException(404, "Stitch job not found")
    job = json.loads(job_path.read_text(encoding="utf-8"))
    panorama = Path(job.get("panoramaPath", ""))
    if not panorama.is_file() or directory not in panorama.resolve().parents:
        raise HTTPException(409, "Panorama is not ready")
    return FileResponse(
        panorama,
        media_type="image/jpeg",
        headers={"Access-Control-Allow-Origin": "*", "Cache-Control": "no-transform"},
    )


@app.get("/v1/sessions")
def list_sessions() -> dict[str, Any]:
    SESSIONS.mkdir(parents=True, exist_ok=True)
    sessions = []
    for descriptor in sorted(SESSIONS.glob("*/session.json"), reverse=True):
        sessions.append(json.loads(descriptor.read_text(encoding="utf-8")))
    return {"items": sessions}


@app.get("/v1/sessions/{session_id}")
def get_session(session_id: str) -> dict[str, Any]:
    directory = require_session(session_id)
    descriptor = json.loads((directory / "session.json").read_text(encoding="utf-8"))
    frames = []
    for metadata_path in sorted((directory / "frames").glob("*.json")):
        value = json.loads(metadata_path.read_text(encoding="utf-8"))
        value["imageFile"] = metadata_path.with_suffix(".jpg").name
        frames.append(value)
    descriptor["frames"] = frames
    return descriptor


@app.get("/v1/sessions/{session_id}/frames/{frame_id}/image")
def get_frame_image(session_id: str, frame_id: str) -> FileResponse:
    directory = require_session(session_id)
    path = directory / "frames" / f"{safe_id(frame_id, 'frame id')}.jpg"
    if not path.is_file():
        raise HTTPException(404, "Frame not found")
    return FileResponse(path, media_type="image/jpeg")
