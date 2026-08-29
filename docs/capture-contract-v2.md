# Camera360 capture contract v2

Contract này là đầu vào tối thiểu cho stitch server dùng cho homestay, hotel và
bất động sản. Server không nên chỉ đọc thứ tự file hoặc yaw/pitch mục tiêu.

## Multipart frame

`POST /v1/sessions/{sessionId}/frames`

- Part `image`: JPEG nguyên bản, không resize/re-encode ở client.
- Part `metadata`: JSON dạng sau:

```json
{
  "id": "frame-12",
  "targetId": "sphere-target-12",
  "expectedPose": { "yaw": 108.0, "pitch": 36.0 },
  "capture": {
    "schemaVersion": "2.0.0",
    "capturedAtMs": 1787587200000,
    "coordinateFrame": "coreMotionReferenceZUpRearCameraV2",
    "pose": {
      "monotonicTimestampSec": 12345.67,
      "yaw": 107.82,
      "pitch": 35.91,
      "roll": 0.42,
      "rotationRate": 0.03,
      "quaternion": { "w": 0.9, "x": 0.1, "y": 0.2, "z": 0.3 }
    },
    "intrinsics": {
      "pixelWidth": 4032,
      "pixelHeight": 3024,
      "fxPixels": 2900.0,
      "fyPixels": 2900.0,
      "principalPointX": 2016.0,
      "principalPointY": 1512.0,
      "focalLengthMm": 6.86,
      "focalLength35mm": 24.0,
      "horizontalFovDegrees": 55.0,
      "verticalFovDegrees": 72.0
    },
    "exposure": {
      "iso": 125.0,
      "exposureTimeSeconds": 0.01,
      "fNumber": 1.78,
      "whiteBalanceLocked": true,
      "exposureLockUsed": false
    },
    "quality": {
      "accepted": true,
      "sharpness": 0.08,
      "brightness": 0.46,
      "visualRegistration": "homographyValidated",
      "reasons": []
    }
  }
}
```

`expectedPose` chỉ dùng để kiểm tra coverage/UI. Stitcher phải ưu tiên quaternion
và intrinsics thật trong `capture` làm initial estimate cho bundle adjustment.

## Undo và complete

- `DELETE /v1/sessions/{sessionId}/frames/{frameId}` phải loại frame khỏi object
  storage, database và graph registration.
- `POST /v1/sessions/{sessionId}/complete` nhận manifest `schemaVersion: 2.0.0`
  chứa các frame còn hiệu lực.
- Server phải idempotent theo `frameId`; retry upload không được tạo frame trùng.

Từ schema `2.1.0`, capture ngang ghi rõ kiểu output trước khi stitch:

```json
{
  "schemaVersion": "2.1.0",
  "captureMode": "horizontal",
  "productType": "horizontal-stitch",
  "isClosedLoop": false,
  "frames": []
}
```

Các output được hỗ trợ:

- `horizontal-stitch`: projection cylindrical auto-crop, xuất JPEG hình chữ nhật và xem
  bằng image viewer phẳng;
- `wide-panorama`: projection panorama, xem tương tác với yaw giới hạn tại hai
  mép coverage;
- `horizontal-360`: panorama đã hoàn thành vòng ngang, yaw quay vòng 360°.

Mọi cặp ảnh liền kề trong dải đã chụp phải có visual match sau `cpclean`.
`captureChainStatus` mô tả seam nội bộ; `wrapBoundaryStatus` chỉ mô tả điểm
chuyển từ ảnh cuối về ảnh đầu. Khi chưa hoàn thành vòng, người dùng chọn
`horizontal-stitch`, `wide-panorama` hoặc tiếp tục chụp. `horizontal-360` chỉ
được chọn tự động khi đã chụp đủ vòng target ngang.

## Pipeline stitch yêu cầu

1. Decode JPEG và chuẩn hóa EXIF orientation, nhưng giữ ảnh gốc để render cuối.
2. Lens model từ intrinsics; hiệu chỉnh radial/tangential distortion nếu có
   calibration profile của model iPhone.
3. Feature extraction và matching ưu tiên cặp target lân cận; dùng IMU quaternion
   làm prior, không dùng nó thay cho visual registration.
4. Reject match bằng ratio test + geometric RANSAC; xây connected match graph.
5. Spherical bundle adjustment tối ưu rotation và focal parameters. Cảnh báo nếu
   graph không kín hoặc reprojection error vượt ngưỡng.
6. Exposure/color compensation, seam optimization tránh cạnh kiến trúc và
   multiband blending.
7. Với vòng ngang 360°, xuất equirectangular 360° và giữ toàn bộ vertical FOV
   thật (không ép 2:1 có cực đen); canvas lấy theo mật độ pixel/độ của chiều cao
   ảnh gốc. Nhúng GPano XMP và tạo quality report gồm coverage, reprojection
   error, seam energy và rejected frames.

## Điều kiện thương mại trước khi phát hành

- Test trên các đời iPhone/lens được hỗ trợ bằng bộ scene chuẩn: phòng nhỏ, cửa
  sổ sáng, tường trắng, cạnh tủ gần, gương, người di chuyển và ngoại cảnh.
- Không tự chuyển ultra-wide/wide/tele giữa phiên; toàn bộ frame phải cùng lens.
- Mã hóa khi truyền/lưu, consent rõ ràng và cơ chế xóa dữ liệu tài sản của khách.
- Theo dõi crash, capture rejection, upload retry, stitch failure và thời gian
  xử lý; không upload log chứa ảnh hoặc vị trí nếu chưa được đồng ý.
