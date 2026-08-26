# Camera360 capture backend

Backend lưu nguyên liệu chụp theo từng session để kiểm tra và làm đầu vào cho
stitching:

```text
backend/data/sessions/<session-id>/
  session.json
  events.ndjson
  manifest.json
  frames/
    frame-0.jpg
    frame-0.json
  jobs/
    stitch-<uuid>.json
  stitches/
    stitch-<uuid>/
      openstitching/panorama.jpg
      report.json
```

Chạy local trên máy Mac:

```bash
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
.venv/bin/uvicorn backend.app:app --host 0.0.0.0 --port 8080
```

`POST /v1/sessions/{sessionId}/stitch` chạy OpenStitching trong background và
ghi trạng thái thực vào `jobs/<jobId>.json`. Theo dõi và tải kết quả bằng:

```text
GET /v1/sessions/{sessionId}/jobs/{jobId}
GET /v1/sessions/{sessionId}/jobs/{jobId}/panorama
```

Job chỉ có `status: completed` khi quality gate trả `PASS`. Kết quả có graph
matching bị tách, bỏ frame, frame rung/mờ hoặc metadata capture lỗi sẽ trả
`needs_review`, `RECAPTURE` hoặc `failed`; backend không coi việc sinh được JPEG
là thành công thương mại.
