# Camera360 Sphere UX

Flutter capture client tái hiện luồng Google Street View Photo Sphere dựa trên
phân tích tĩnh APK `com.google.android.street` 2.0.0.484371618 và tài liệu chính
thức của Google.

## Capture hiện có

- Camera preview thật: Camera2 trên Android, AVCaptureSession trên iOS.
- Orientation từ gyroscope/rotation vector hoặc CoreMotion.
- Auto-shutter khi reticle trùng target và máy ổn định; không có shutter thủ công.
- Target phủ 360×180, chống chụp lặp, Undo/Done/Cancel và progress theo flow gốc.
- Lưu frame cục bộ trước, upload bất đồng bộ đến Camera360 stitch server nếu có.

## Chạy backend capture mới

Khởi tạo môi trường một lần:

```bash
cd /Users/vvhung/Documents/Projects/Camera360SphereUX
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
```

Kill backend Uvicorn cũ đang giữ cổng `8080`, sau đó chạy backend mới:

```bash
cd /Users/vvhung/Documents/Projects/Camera360SphereUX
bash scripts/restart-backend.sh
```

Script chỉ kill tiến trình trên cổng `8080` khi command của tiến trình chứa
`uvicorn`; nếu một service khác đang dùng cổng, script dừng và báo lỗi. Có thể
đổi cổng bằng `CAMERA360_PORT=8081 bash scripts/restart-backend.sh`.

Health check và dữ liệu upload:

```bash
curl http://127.0.0.1:8080/health
find backend/data/sessions -maxdepth 3 -type f | sort
```

Mỗi phiên nằm tại `backend/data/sessions/<session-id>/`, gồm JPEG gốc, JSON của
từng frame, `session.json`, `events.ndjson`, manifest và job stitching.

## Chạy Flutter trên iPhone HUNG VAN

Giữ backend ở Terminal 1. Tại Terminal 2, chạy app trên thiết bị thật:

```bash
cd /Users/vvhung/Documents/Projects/Camera360SphereUX
flutter run \
  -d 00008101-001910882EFA001E \
  --dart-define=CAMERA360_SERVER_URL=http://192.168.1.6:8080
```

Nếu IP Wi-Fi của Mac thay đổi, thay `192.168.1.6` trong lệnh trên. Có thể tìm IP
hiện tại bằng `ifconfig | grep 'inet 192.168'`.

Build Release, cài và mở thủ công:

```bash
flutter build ios --release \
  --dart-define=CAMERA360_SERVER_URL=http://192.168.1.6:8080

xcrun devicectl device install app \
  --device 39E7CF59-6DBA-5FD0-8483-7E818D4A052C \
  build/ios/iphoneos/Runner.app

xcrun devicectl device process launch --terminate-existing \
  --device 39E7CF59-6DBA-5FD0-8483-7E818D4A052C \
  com.camera360.camera360SphereUx
```

Kiểm tra source:

```bash
flutter analyze
flutter test
```

## So sánh Hugin và OpenStitching

Cài dependency một lần bằng lệnh backend ở trên. Chạy cả hai engine trên cùng
một session, cùng ảnh đã chuẩn hóa EXIF và cùng kích thước input:

```bash
cd /Users/vvhung/Documents/Projects/Camera360SphereUX
scripts/stitch-session.sh compare sphere-1787616024522
```

Kết quả nằm trong
`backend/data/sessions/<session-id>/benchmark/<timestamp>/`, gồm:

- `hugin/panorama.jpg`, PTO và log Hugin;
- `openstitching/panorama.jpg`, settings và match graph;
- `report.html` để xem hai ảnh cạnh nhau;
- `report.json` chứa thời gian, số frame được dùng, kích thước, coverage và chỉ
  số sharpness tham khảo.

Chạy riêng từng engine:

```bash
scripts/stitch-session.sh hugin sphere-1787616024522
scripts/stitch-session.sh openstitching sphere-1787616024522
```

Mặc định ảnh benchmark có cạnh tối đa 1600 px và Hugin xuất 4096×2048. Chạy
nhanh để kiểm tra pipeline:

```bash
scripts/stitch-session.sh compare sphere-1787616024522 \
  --input-max-edge 768 --canvas-width 2048 --hugin-match prealigned
```

Chạy đánh giá chất lượng cao (rất tốn RAM, CPU và thời gian với 42 frame):

```bash
scripts/stitch-session.sh compare sphere-1787616024522 \
  --input-max-edge 0 --canvas-width 8192 --hugin-match prealigned
```

`prealigned` là mặc định khuyến nghị: yaw/pitch target trong sidecar được seed
vào PTO trước khi CPFind chạy. `allpairs` bỏ lợi thế pose prior khi matching và
có thể tạo match sai trong phòng nhiều cạnh/lưới lặp; chỉ dùng nó để chẩn đoán.

Không chọn engine chỉ bằng sharpness/coverage. Cần mở `report.html` và zoom vào
cạnh cửa, cửa sổ, song sắt, đường chân tường, vùng overlap, thiên đỉnh và nadir
để đánh giá ghosting, đường gãy, seam và exposure.

Phân tích APK: [docs/reverse-forensic.md](docs/reverse-forensic.md)  
Nguồn Google/paper/video: [docs/google-sources.md](docs/google-sources.md)  
Trạng thái và giới hạn: [docs/reverse-notes.md](docs/reverse-notes.md)
Contract capture/stitch v2: [docs/capture-contract-v2.md](docs/capture-contract-v2.md)
