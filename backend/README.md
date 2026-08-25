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
```

Chạy local trên máy Mac:

```bash
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
.venv/bin/uvicorn backend.app:app --host 0.0.0.0 --port 8080
```

Kiểm tra bằng `http://localhost:8080/health` và
`http://localhost:8080/v1/sessions`. Endpoint stitch hiện tạo job `queued`; worker
feature matching/bundle adjustment/blending sẽ được nối vào job này ở bước sau.
