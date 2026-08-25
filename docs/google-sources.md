# Nguồn tham chiếu Google Photo Sphere

Các nguồn dưới đây được dùng để kiểm tra chéo với APK, không dùng để sao chép
logo, hình ảnh hay mã độc quyền của Google.

## Nguồn chính thức

- Video Google Maps, **How to create a photo sphere** (2013):
  https://www.youtube.com/watch?v=NPs3eIiWRaw
  - Xác nhận chuỗi ảnh tự động khi căn vào dot và kết quả được ghép thành sphere.
- Google Maps Help, **Create & publish Photo Spheres**:
  https://support.google.com/maps/answer/7012050?hl=en
  - Yêu cầu đầu ra tối thiểu 3840×1920, tỷ lệ 2:1, không hở đường chân trời,
    không lỗi stitch đáng kể và không motion blur.
- Google Developers, **Street View for Mobile**:
  https://developers.google.com/streetview/android
  - Photo Sphere là equirectangular 360° ngang × 180° dọc.
- Google Developers, **Photo Sphere XMP Metadata**:
  https://developers.google.com/streetview/spherical-metadata
  - Đặc tả GPano projection, heading/pitch/roll, kích thước full pano/crop và
    source photo count.
- Google Research, **Robust image stitching using multiple registrations**:
  https://research.google/pubs/robust-image-stitching-using-multiple-registrations/
  - Pipeline stitch gồm registration, seam finding và blending; nhiều
    registration giảm lỗi do chiều sâu, chuyển động và parallax.
- Google source mirror, **Cardboard LightCycle/Photo Sphere code**:
  https://chromium.googlesource.com/external/github.com/googlevr/cardboard/+/4775db6e0a92fdc8bd102a818d741f2bde372876/paperscope/photosphere/lightcycle/
  - Xác nhận quy ước metadata, ảnh nguồn 4:3 và các thành phần viewer LightCycle.

## Chứng cứ từ APK được cung cấp

APK: `com.google.android.street`, version `2.0.0.484371618` (versionCode 66899),
minSdk 24, targetSdk 33.

- `res/layout/capture.xml`: Undo trái, Done + circular progress giữa, Cancel phải.
- `TargetManager`: target màu cam, reticle trắng; hit angle 2°–3.5° theo angular
  velocity 10°/s–40°/s; target chỉ nổi rõ trong khoảng gần 10°–20°.
- `VideoFrameProcessor` + `LightCycleRenderer`: `ProcessFrame` → valid visual
  estimate → target hit/moving-too-fast → autofocus/gyro calibration →
  `TakeNewPhoto`; cảnh báo too-fast có delay 0.25 s.
- `PhotoCollection` + `LightCycleNative`: ảnh hoàn tất mới tăng progress; Undo
  hoàn tác cả collection, native image và target state.
- `PanoramaCaptureActivity`: bắt buộc back camera + gyroscope, khóa wake lock khi
  capture, rồi `FinishCapture` và chuyển sang `StitchingService`.
- `liblightcycle.so`: có native `PhotosphereTargetGenerator`, target manager,
  incremental alignment và stitch pipeline.

## Nguyên tắc triển khai rút ra

1. Capture phải là auto-shutter theo orientation + stability, không phải nút bấm.
2. Coverage phải đủ 360×180, bao gồm zenith/nadir, không chỉ một vòng ngang.
3. Target đã captured không được tự chụp lại; Undo mới trả nó về eligible.
4. Ảnh phải lưu cục bộ trước; mạng/server stitch không được làm mất một lần chụp.
5. Đầu ra cuối phải là equirectangular 2:1 và nhúng GPano XMP hợp lệ.
