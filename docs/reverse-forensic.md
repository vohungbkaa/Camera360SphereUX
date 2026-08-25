# Reverse forensic specification — Photo Sphere capture

Phân tích trên APK đã cung cấp: `com.google.android.street`, version
`2.0.0.484371618`, arm64-v8a. Mục này là đặc tả trước khi triển khai, không phải
đoán từ video.

## 1. Mô hình target thật

APK không dùng bộ đếm tuần tự đơn giản. Native `liblightcycle.so` tạo target
theo `PhotosphereTargetGenerator`, trả ra `NewTarget[]` qua
`LightCycleNative.InitTargets()`. Mỗi target có orientation 3x3 và key.

`TargetManager` giữ các target chưa hoàn tất trong `mTargets`. Khi native báo
ảnh đã được thêm, `finalizeHitTargets()` gọi `GetTargets()` lại và thay toàn bộ
map bằng target còn lại. Vì target đã chụp bị loại khỏi map, quay về hướng cũ
không thể chụp lại target đó.

Đây là invariant bắt buộc của bản triển khai:

```text
eligible = target chưa captured
          AND angular distance(camera, target) <= hit angle
          AND valid visual estimate
          AND device orientation hợp lệ
          AND movingTooFast == false
          AND autofocus/gyro calibration không bận
```

## 2. Vùng hit thay đổi theo tốc độ

`TargetManager.setTargetHitAngle()` gọi native mỗi frame. Hit angle được clamp
từ 2° đến 3.5° theo angular velocity 10°/s–40°/s. Xoay càng nhanh thì vùng hit
cho phép rộng hơn, nhưng `VideoFrameProcessor` vẫn báo `PhotoSkippedTooFast`
và không chụp nếu chuyển động vượt giới hạn.

## 3. Shutter không phải timer độc lập

Trong `LightCycleRenderer.processFrame()`:

1. `ProcessFrame(...)` cập nhật visual rotation estimate.
2. Native tính `TargetHit()`, `MovingTooFast()` và `TakeNewPhoto()`.
3. Chỉ khi cả estimate hợp lệ và `TakeNewPhoto()` true mới gọi `takePhoto()`.
4. `takePhoto()` đặt photo-in-flight, báo target màu trắng và khóa Undo trong
   lúc camera/native đang lấy dữ liệu.
5. Khi callback hoàn tất, `PhotoCollection.addNewPhoto()` và native target state
   cùng được finalize.

Vì vậy việc “quay một vòng rồi quay về điểm cũ vẫn chụp” chỉ được phép nếu đó là
một target khác; cùng orientation/key đã captured thì không hợp lệ.

## 4. Hold-still và lỗi màu đen

Renderer gọi `glClear` mỗi frame nên nền ban đầu là đen. Camera frame chỉ phủ lên
với alpha 0.7 sau khi visual estimate hợp lệ và panorama không còn empty. Đây
là lý do video có thể thấy không gian nền đen trước khi frame/estimate ổn định;
không nên thay bằng gradient cảnh giả trong bản demo fidelity cao.

Khi target bị `PhotoSkippedTooFast`, app chờ 0.25 giây rồi mới hiện thông báo
“Hold still”/“too fast”; không bật cảnh báo ngay ở mỗi sensor tick.

## 5. UI capture thật

`capture.xml` gồm:

- camera/GL surface chiếm toàn màn hình;
- target/reticle do OpenGL renderer vẽ;
- Undo góc trái dưới, ẩn khi không thể undo;
- Done ở giữa dưới, bao quanh bởi progress ring;
- Cancel góc phải dưới;
- thông báo căn chấm, xoay sai hướng và quá nhanh ở vùng trên/dưới.

Done/Undo/Cancel là các event độc lập trong `RenderedGui`, không phải một hàng
nút Flutter tùy ý. Undo gọi cả `PhotoCollection.undoAddPhoto()` và
`LightCycleNative.UndoAddImage()`.

## 6. Test cases bắt buộc trước khi gọi đạt

1. Chụp target A → quay đúng lại A → không tăng số ảnh.
2. Chụp A → quay sang B → chỉ B mới được auto-shutter.
3. Đúng target nhưng xoay nhanh → không chụp; hiển thị hold-still sau delay.
4. Đang ghi ảnh → Undo disabled; callback xong mới enabled.
5. Undo ảnh cuối → target quay lại eligible và progress giảm đúng.
6. Không có gyro → không vào capture.
7. Estimate visual invalid → không chụp dù hướng sensor đúng.

