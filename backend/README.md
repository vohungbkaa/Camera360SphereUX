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
      hugin/panorama.jpg
      report.json
```

Chạy local trên máy Mac:

```bash
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
.venv/bin/uvicorn backend.app:app --host 0.0.0.0 --port 8080
```

`POST /v1/sessions/{sessionId}/stitch` chạy Hugin 2024.0.1 trong background và
ghi trạng thái thực vào `jobs/<jobId>.json`. Theo dõi và tải kết quả bằng:

```text
GET /v1/sessions/{sessionId}/jobs/{jobId}
GET /v1/sessions/{sessionId}/jobs/{jobId}/panorama
```

Job chỉ có `status: completed` khi quality gate trả `PASS`. Kết quả có graph
matching bị tách, bỏ frame, frame rung/mờ hoặc metadata capture lỗi sẽ trả
`needs_review`, `RECAPTURE` hoặc `failed`; backend không coi việc sinh được JPEG
là thành công thương mại.

Manifest chọn một trong ba output: `horizontal-stitch` dùng projection
cylindrical auto-crop và image viewer phẳng; `wide-panorama` dùng projection panorama với
hai mép yaw; `horizontal-360` dành cho vòng target ngang đã hoàn thành. Dù chọn
output nào, các ảnh liền kề phải tạo thành `captureChainStatus: connected`.
`wrapBoundaryStatus` chỉ mô tả visual match giữa ảnh cuối và ảnh đầu.

Worker production truyền `--input-max-edge 0`: JPEG upload được sao chép nguyên
byte vào Hugin, không resize hoặc re-encode. `--canvas-width 0` tự suy ra canvas
từ chiều cao ảnh nguồn/vertical FOV; vòng chụp ngang 360° được auto-crop theo
chiều dọc thật thay vì thêm vùng cực đen.
