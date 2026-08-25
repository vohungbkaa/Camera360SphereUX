# Reverse notes — Google Street View Photo Sphere

Nguồn phân tích: APK `com.google.android.street`, version `2.0.0.484371618`.
Phân tích tĩnh bằng `aapt`, `jadx` và `strings`; không sao chép mã nguồn, logo
hoặc resource Google vào project này.

## Pipeline đã xác minh

1. `CaptureActivity` mở `PanoramaCaptureActivity`.
2. Activity kiểm tra camera sau và gyro trước khi bắt đầu.
3. `TextureCameraPreview` hiển thị camera; `SensorReader` đọc accelerometer,
   gyroscope và magnetometer rồi đưa vào orientation filter.
4. `LightCycleView` nối camera, sensor, `IncrementalAligner` và
   `LightCycleRenderer`.
5. Mỗi frame được `VideoFrameProcessor` đánh giá. Chỉ khi hướng trùng target,
   thiết bị không di chuyển quá nhanh và autofocus sẵn sàng thì ảnh mới được
   chụp.
6. Ảnh được thêm vào `PhotoCollection`; target chuyển sang captured và vòng
   progress được cập nhật.
7. Undo xóa đồng bộ PhotoCollection, native image state và target state.
8. Done gọi `FinishCapture`, sau đó chuyển phiên sang `StitchingService`.

## Những gì bản triển khai hiện tại làm

- Màn home tách riêng Photo Sphere với Photo Path.
- Camera preview toàn màn hình thật trên cả Android (Camera2) và iOS
  (AVCaptureSession), không còn backdrop giả.
- Target phủ 360×180 theo các vòng yaw/pitch, dày ở đường chân trời và thưa dần
  gần hai cực; mật độ được tính từ FOV thật của active lens. Một target đã chụp
  bị loại khỏi tập eligible.
- Không có nút shutter. Auto-shutter chỉ chạy khi reticle ở trong hit angle và
  máy giữ ổn định 250 ms; hit angle thay đổi 2°–3.5° theo vận tốc góc.
- Undo ở trái, Done/check kèm vòng tiến độ ở giữa và Cancel ở phải như
  `capture.xml`. Done/Undo xuất hiện sau ảnh đầu tiên.
- Processing state và viewer state tách riêng như flow gốc.
- Trên iOS, pose được lấy theo timestamp exposure thay vì target lý tưởng; mỗi
  JPEG có sidecar JSON chứa quaternion, intrinsics, EXIF exposure và quality.
- Core Image loại frame tối/cháy/rung; Vision homography kiểm tra vùng trùng với
  frame lân cận trước khi target được đánh dấu hoàn tất.
- Preview mosaic trên iOS dùng SceneKit/Metal: mỗi frame là một lưới cong được
  chiếu lên mặt cầu theo pose và FOV. Không còn render JPEG thành thumbnail/card
  phẳng nổi trên camera như prototype ban đầu.
- White balance được khóa sau frame hợp lệ đầu tiên để giảm đường nối màu; AE
  tiếp tục tự động nhằm giữ chi tiết trong phòng có cửa sổ sáng.

`EventChannel('sphere-camera/motion')` nhận yaw/pitch/roll và angular velocity từ
Rotation Vector + Gyroscope trên Android, hoặc CMMotionManager trên iOS. Cần máy
thật để đánh giá camera, sensor stability và chất lượng stitch.

## Phạm vi chưa được gọi là hoàn tất

APK dùng optical-flow/native visual estimate trong `liblightcycle.so` và pipeline
native registration/seam/blending. Project hiện có visual overlap gate trên iOS,
nhưng bundle adjustment, seam optimization và multiband blending vẫn phải nằm ở
server Camera360. Không nên coi progress giả ở `ProcessingScreen` là trạng thái
stitch thật cho đến khi API trả job progress, quality report và file
equirectangular 2:1 có GPano XMP. Contract server được ghi tại
`docs/capture-contract-v2.md`.
