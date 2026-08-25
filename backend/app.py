from __future__ import annotations

import json
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
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
    schemaVersion: str
    productType: str
    isClosedLoop: bool
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


@app.post("/v1/sessions/{session_id}/stitch")
def start_stitch(session_id: str) -> dict[str, Any]:
    directory = require_session(session_id)
    if not (directory / "manifest.json").exists():
        raise HTTPException(409, "Complete the capture before stitching")
    job_id = f"stitch-{uuid.uuid4()}"
    job = {
        "id": job_id,
        "sessionId": session_id,
        "status": "queued",
        "createdAt": utc_now(),
        "message": "Capture inputs are ready; stitching worker is not connected yet.",
    }
    with WRITE_LOCK:
        write_json(directory / "jobs" / f"{job_id}.json", job)
        append_event(directory, "stitch.queued", jobId=job_id)
    return job


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
