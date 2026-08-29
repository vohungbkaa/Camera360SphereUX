# Camera360 Sphere UX

Flutter capture client tái hiện luồng Google Street View Photo Sphere dựa trên
phân tích tĩnh APK `com.google.android.street` 2.0.0.484371618 và tài liệu chính
thức của Google.

## Capture hiện có

- Camera preview thật: Camera2 trên Android, AVCaptureSession trên iOS.
- Orientation từ gyroscope/rotation vector hoặc CoreMotion.
- Auto-shutter khi reticle trùng target và máy ổn định; không có shutter thủ công.
- Target là một vòng ngang khép kín 360°, chống chụp lặp, Undo/Done/Cancel.
- Camera lưu JPEG ở kích thước tối đa; app giữ trọn chiều dọc để người dùng chỉ
  cần xoay theo một phương ngang.
- Lưu frame cục bộ trước, upload bất đồng bộ đến Camera360 stitch server nếu có.
- Trước ảnh đầu tiên, iOS chờ AE/AF/AWB ổn định rồi khóa các thông số cho cả
  vòng chụp; ảnh cháy sáng theo tỷ lệ pixel, quá tối, rung hoặc nhòe sẽ bị từ chối.
- Khi chưa đủ vòng, người dùng chọn ảnh ghép ngang hình chữ nhật hoặc panorama
  góc rộng; nếu đủ vòng app tạo panorama 360° ngang. Ảnh chữ nhật dùng image
  viewer phẳng, còn hai loại panorama dùng Photo Sphere Viewer/WebGL với pinch
  zoom, recenter và gyroscope.

## Chạy backend capture mới

### Một lệnh kill server cũ và khởi động server mới

Đi vào thư mục project:

```bash
cd /Users/vvhung/Documents/Projects/Camera360SphereUX
```

Sau đó chạy lệnh restart trên **đúng một dòng**, không xuống dòng giữa đường dẫn
và `scripts/restart-backend.sh`:

```bash
./scripts/restart-backend.sh
```

Lệnh này tìm đúng backend Camera360 của project theo command
`uvicorn backend.app:app` **và working directory**, nên vẫn kill đúng server cũ
kể cả khi nó đang chạy ở một cổng khác. Sau đó script khởi động backend mới tại
`http://0.0.0.0:8080`. Terminal phải được giữ mở trong lúc server hoạt động.
Để dùng cổng khác, chạy một lệnh tương tự:

```bash
CAMERA360_PORT=8081 ./scripts/restart-backend.sh
```

Nếu đang đứng ở thư mục khác, dùng nguyên một dòng có đường dẫn tuyệt đối:

```bash
CAMERA360_PORT=8081 bash "/Users/vvhung/Documents/Projects/Camera360SphereUX/scripts/restart-backend.sh"
```

Khởi tạo môi trường một lần:

```bash
cd /Users/vvhung/Documents/Projects/Camera360SphereUX
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
```

Script không dùng cổng để nhận diện process cần kill. Nếu cổng đích đang thuộc
process khác, script không kill process đó mà dừng, in PID/command và yêu cầu
chọn cổng khác.

Health check và dữ liệu upload:

```bash
curl http://127.0.0.1:8080/health
find backend/data/sessions -maxdepth 3 -type f | sort
```

Nếu server chạy cổng `8081`, health check tương ứng là
`curl http://127.0.0.1:8081/health`.

Mỗi phiên nằm tại `backend/data/sessions/<session-id>/`, gồm JPEG gốc, JSON của
từng frame, `session.json`, `events.ndjson`, manifest và job stitching.

## Chạy Flutter trên iPhone HUNG VAN

Giữ backend ở Terminal 1. Tại Terminal 2, chạy app trên thiết bị thật:

URL backend được cấu hình tập trung tại `lib/app_config.dart`. Khi IP hoặc cổng
thay đổi, chỉ sửa một dòng `AppConfig.camera360ServerUrl`, ví dụ:

```dart
static const String camera360ServerUrl = 'http://192.168.1.7:8080';
```

IP và cổng ở đây phải trùng với máy/cổng backend. Ví dụ backend được chạy bằng
`CAMERA360_PORT=8081`, cấu hình mobile phải là:

```dart
static const String camera360ServerUrl = 'http://192.168.1.7:8081';
```

```bash
cd /Users/vvhung/Documents/Projects/Camera360SphereUX
flutter run -d 00008101-001910882EFA001E
```

Có thể tìm IP Wi-Fi hiện tại bằng `ipconfig getifaddr en1`.

### Build trực tiếp bằng Xcode

Luôn mở CocoaPods workspace, **không mở** `ios/Runner.xcodeproj`:

```bash
open ios/Runner.xcworkspace
```

Trong Xcode chọn scheme `Runner`, chọn iPhone thật rồi Run. Nếu gặp
`Framework 'Pods_Runner' not found`, đóng Xcode và tái tạo workspace:

```bash
flutter pub get
pod install --project-directory=ios
open ios/Runner.xcworkspace
```

File `ios/Runner.xcworkspace/contents.xcworkspacedata` phải có cả hai project
`Runner.xcodeproj` và `Pods/Pods.xcodeproj`; thiếu project Pods sẽ gây linker
error dù thư mục `ios/Pods` đang tồn tại.

Build Release, cài và mở thủ công:

```bash
flutter build ios --release

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

## Ghép production bằng Hugin

Cài dependency một lần bằng lệnh backend ở trên. Chạy Hugin trên một session:

```bash
cd /Users/vvhung/Documents/Projects/Camera360SphereUX
scripts/stitch-session.sh sphere-1787616024522
```

Kết quả nằm trong
`backend/data/sessions/<session-id>/benchmark/<timestamp>/`, gồm:

- `hugin/panorama.jpg`, PTO và log Hugin;
- `report.html` để xem ảnh và chỉ số;
- `report.json` chứa thời gian, số frame được dùng, kích thước, coverage và chỉ
  số sharpness tham khảo.

Mặc định input được sao chép nguyên byte JPEG, không resize/re-encode. Chiều rộng
canvas được suy ra từ chiều cao gốc và vertical FOV để không giảm mật độ pixel.
Chạy nhanh ở độ phân giải thấp chỉ để kiểm tra pipeline:

```bash
scripts/stitch-session.sh sphere-1787616024522 \
  --input-max-edge 768 --canvas-width 2048 --hugin-match prealigned
```

Chạy production full resolution (có thể tốn nhiều RAM, CPU và thời gian):

```bash
scripts/stitch-session.sh sphere-1787616024522 \
  --input-max-edge 0 --canvas-width 0 --hugin-match prealigned
```

`prealigned` là mặc định khuyến nghị: yaw/pitch target trong sidecar được seed
vào PTO trước khi CPFind chạy. `allpairs` bỏ lợi thế pose prior khi matching và
có thể tạo match sai trong phòng nhiều cạnh/lưới lặp; chỉ dùng nó để chẩn đoán.
Hugin chạy thêm photometric optimization (`autooptimiser -m`) trước khi blend để
giảm chênh lệch exposure/white balance giữa các vùng overlap; bước này không
thay thế được chi tiết đã mất trong một frame bị cháy sáng.

Không chọn engine chỉ bằng sharpness/coverage. Cần mở `report.html` và zoom vào
cạnh cửa, cửa sổ, song sắt, đường chân tường, vùng overlap, thiên đỉnh và nadir
để đánh giá ghosting, đường gãy, seam và exposure.

Mỗi kết quả hiện có `qualityDecision` và report HTML hiển thị quality gate:

- `PASS`: đủ điều kiện kỹ thuật tự động;
- `REVIEW`: cần kiểm tra seam/cạnh kiến trúc hoặc engine đã bỏ frame;
- `RECAPTURE`: match graph bị tách hay frame capture không đạt;
- `FAILED`: không tạo được panorama.

Hugin worker thật được khởi chạy từ `POST /v1/sessions/{id}/stitch`.
Không publish ảnh cho khách chỉ vì job đã tạo được JPEG; chỉ publish tự động khi
`commercialReady: true`.

Trên iOS, app chờ camera đo sáng/lấy nét ổn định và khóa
focus/exposure/white balance **trước frame đầu tiên**. Chế độ
`balanced-full-resolution` vẫn dùng `maxPhotoDimensions`, nhưng giảm độ trễ
computational photography để pose/thời điểm sáng không lệch khỏi lúc bấm chụp.
App còn chặn auto-shutter khi rotation hoặc linear acceleration cao, từ chối
frame có trên 18% vùng trung tâm bị clip highlight và lưu camera calibration của AVFoundation
khi thiết bị/cấu hình capture cung cấp dữ liệu này.

Backend đo lại mean luma/dark/clipped-highlight trên JPEG gốc thay vì chỉ tin
metadata từ mobile. Frame cháy sáng/quá tối sẽ làm quality gate trả `RECAPTURE`,
kể cả client khác chưa có native quality gate tương đương.

Hugin trả `viewerConfig.panoData` dựa trên canvas/crop thực tế trong PTO. Vì vậy
viewer biết kích thước sphere đầy đủ và vị trí chính xác của JPEG crop; backend
không resize input (`--input-max-edge 0`), JPEG cuối dùng quality 100 và chiều
cao hữu dụng của vòng chụp ngang được giữ tối đa.

Phân tích APK: [docs/reverse-forensic.md](docs/reverse-forensic.md)  
Nguồn Google/paper/video: [docs/google-sources.md](docs/google-sources.md)  
Trạng thái và giới hạn: [docs/reverse-notes.md](docs/reverse-notes.md)
Contract capture/stitch v2: [docs/capture-contract-v2.md](docs/capture-contract-v2.md)
