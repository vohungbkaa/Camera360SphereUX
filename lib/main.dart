import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_config.dart';
import 'panorama_viewer.dart';
import 'server_session_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  runApp(const SphereUxApp());
}

class SphereUxApp extends StatelessWidget {
  const SphereUxApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Sphere Capture',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF07111F),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF67D5FF),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: const HomeScreen(),
  );
}

// Kept as a compatibility alias for the template widget test.
class MyApp extends SphereUxApp {
  const MyApp({super.key});
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Sphere',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: () => _showHelp(context),
                icon: const Icon(Icons.help_outline_rounded),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: const LinearGradient(
                colors: [Color(0xFF12365E), Color(0xFF146C8C)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.panorama_photosphere_rounded,
                  size: 38,
                  color: Color(0xFFB9F1FF),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Tạo ảnh Sphere',
                  style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 7),
                const Text(
                  'Đứng tại một điểm và ghi lại toàn bộ không gian 360°.',
                  style: TextStyle(color: Color(0xD9FFFFFF), height: 1.35),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CaptureScreen()),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF0A4965),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                  ),
                  icon: const Icon(Icons.camera_alt_rounded),
                  label: const Text('Bắt đầu chụp'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'Cách hoạt động',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          const _Step(
            icon: Icons.center_focus_strong_rounded,
            title: 'Căn chấm mục tiêu',
            body: 'Xoay điện thoại đến khi vòng tròn trùng với chấm sáng.',
          ),
          const _Step(
            icon: Icons.panorama_horizontal_rounded,
            title: 'Xoay quanh camera',
            body:
                'Giữ vị trí ống kính cố định; xoay người quanh điện thoại để giảm lỗi parallax.',
          ),
          const _Step(
            icon: Icons.auto_awesome_rounded,
            title: 'Xem Sphere tương tác',
            body: 'Ứng dụng ghép các khung hình và mở ảnh 360°.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Sphere gần đây',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF101E30),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Row(
              children: [
                CircleAvatar(
                  backgroundColor: Color(0xFF1B3850),
                  child: Icon(Icons.panorama, color: Color(0xFF9BE8FF)),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Chưa có Sphere nào\nTạo Sphere đầu tiên của bạn',
                    style: TextStyle(color: Color(0xFFB7C5D8), height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  void _showHelp(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const Padding(
      padding: EdgeInsets.fromLTRB(24, 4, 24, 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mẹo chụp Sphere',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 14),
          Text(
            '• Đảm bảo đủ ánh sáng và tránh vật thể chuyển động gần camera.\n• Giữ ống kính tại một điểm cố định, xoay người quanh máy và không bước chân.\n• Tránh đứng quá gần cạnh tủ, cửa hoặc cửa sổ; nên cách ít nhất 1–1,5 m.\n• Nếu frame bị từ chối, giữ yên và quay lại đúng chấm để chụp lại.',
          ),
        ],
      ),
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: const Color(0xFF122B40),
          foregroundColor: const Color(0xFF7CE2FF),
          child: Icon(icon, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(
                body,
                style: const TextStyle(color: Color(0xFF93A4B9), height: 1.3),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  StreamSubscription<dynamic>? motionSubscription;
  final Set<int> capturedTargets = <int>{};
  final Map<int, String> capturedPhotoPaths = <int, String>{};
  final Map<int, Map<String, dynamic>> capturedFrameMetadata =
      <int, Map<String, dynamic>>{};
  final Map<int, Future<void>> pendingUploads = <int, Future<void>>{};
  final Map<int, int> qualityRejectCounts = <int, int>{};
  bool isCapturing = false;
  bool movingTooFast = false;
  bool translationRisk = false;
  bool motionAvailable = true;
  double? originYaw;
  double? originPitch;
  int? activeTarget;
  double currentYaw = 0;
  double currentPitch = 0;
  double currentRoll = 0;
  DateTime? alignedSince;
  DateTime? tooFastSince;
  bool showTooFast = false;
  String? captureIssue;
  DateTime? captureRetryAfter;
  final String localSessionId =
      'sphere-${DateTime.now().millisecondsSinceEpoch}';
  late final ServerSessionClient server;
  List<SphereTarget> targets = buildSphereTargets();
  Map<String, dynamic> cameraInfo = const <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    server = ServerSessionClient(
      baseUrl: Uri.parse(AppConfig.camera360ServerUrl),
    );
    server.createSession(requestedId: localSessionId).catchError((_) {});
    motionSubscription = const EventChannel('sphere-camera/motion')
        .receiveBroadcastStream()
        .listen(_onMotion, onError: (_) => _setMotionUnavailable());
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCameraInfo());
  }

  Future<void> _loadCameraInfo({int attempt = 0}) async {
    try {
      final raw = await const MethodChannel(
        'sphere-camera/methods',
      ).invokeMethod<Map<Object?, Object?>>('getCameraInfo');
      final info = _stringKeyedMap(raw);
      final horizontal = (info['horizontalFovDegrees'] as num?)?.toDouble();
      final vertical = (info['verticalFovDegrees'] as num?)?.toDouble();
      if (!mounted || horizontal == null || vertical == null) return;
      setState(() {
        cameraInfo = info;
        if (capturedTargets.isEmpty) {
          targets = buildSphereTargets(
            horizontalFovDegrees: horizontal,
            verticalFovDegrees: vertical,
          );
        }
      });
    } catch (_) {
      if (attempt < 6 && mounted) {
        Future<void>.delayed(
          const Duration(milliseconds: 300),
          () => _loadCameraInfo(attempt: attempt + 1),
        );
      }
    }
  }

  @override
  void dispose() {
    motionSubscription?.cancel();
    super.dispose();
  }

  void _setMotionUnavailable() {
    if (mounted) setState(() => motionAvailable = false);
  }

  void _onMotion(dynamic event) {
    if (!mounted || event is! Map) return;
    if (event['available'] == false) {
      _setMotionUnavailable();
      return;
    }
    final rate = (event['rotationRate'] as num?)?.toDouble() ?? 0;
    final acceleration =
        (event['linearAccelerationG'] as num?)?.toDouble() ?? 0;
    var yaw = (event['yaw'] as num?)?.toDouble();
    var pitch = (event['pitch'] as num?)?.toDouble();
    var roll = (event['roll'] as num?)?.toDouble() ?? 0;
    if (yaw == null || pitch == null) {
      final w = (event['w'] as num?)?.toDouble() ?? 1;
      final x = (event['x'] as num?)?.toDouble() ?? 0;
      final y = (event['y'] as num?)?.toDouble() ?? 0;
      final z = (event['z'] as num?)?.toDouble() ?? 0;
      yaw =
          math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) *
          180 /
          math.pi;
      pitch = math.asin((2 * (w * y - z * x)).clamp(-1, 1)) * 180 / math.pi;
      roll =
          math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) *
          180 /
          math.pi;
    }
    originYaw ??= yaw;
    originPitch ??= pitch;
    final relativeYaw = _wrapDegrees(yaw - originYaw!);
    final relativePitch = (pitch - originPitch!).clamp(-90.0, 90.0);
    final nearest = _nearestUncapturedTarget(relativeYaw, relativePitch);
    final now = DateTime.now();
    final translating = acceleration > .10;
    final tooFast = rate > .70 || translating;
    final hitAngle =
        2 + ((rate.clamp(.1745, .6981) - .1745) / (.6981 - .1745)) * 1.5;
    final distance = nearest == null
        ? double.infinity
        : angularDistance(
            relativeYaw,
            relativePitch,
            nearest.yaw,
            nearest.pitch,
          );

    if (tooFast) {
      tooFastSince ??= now;
      alignedSince = null;
    } else {
      tooFastSince = null;
      if (distance <= hitAngle) {
        alignedSince ??= now;
      } else {
        alignedSince = null;
      }
    }
    final shouldCapture =
        !tooFast &&
        nearest != null &&
        distance <= hitAngle &&
        alignedSince != null &&
        (captureRetryAfter == null || now.isAfter(captureRetryAfter!)) &&
        now.difference(alignedSince!) >= const Duration(milliseconds: 250);
    setState(() {
      motionAvailable = true;
      movingTooFast = tooFast;
      translationRisk = translating;
      showTooFast =
          tooFastSince != null &&
          now.difference(tooFastSince!) >= const Duration(milliseconds: 250);
      currentYaw = relativeYaw;
      currentPitch = relativePitch;
      currentRoll = roll;
      activeTarget = nearest?.id;
      if (distance > 8) captureIssue = null;
    });
    if (shouldCapture) {
      alignedSince = null;
      capture(nearest.id);
    }
  }

  SphereTarget? _nearestUncapturedTarget(double yaw, double pitch) {
    SphereTarget? result;
    var best = double.infinity;
    for (final target in targets) {
      if (capturedTargets.contains(target.id)) continue;
      final distance = angularDistance(yaw, pitch, target.yaw, target.pitch);
      if (distance < best) {
        best = distance;
        result = target;
      }
    }
    return result;
  }

  Future<void> capture(int targetId) async {
    if (isCapturing ||
        capturedTargets.length >= targets.length ||
        capturedTargets.contains(targetId) ||
        movingTooFast) {
      return;
    }
    setState(() => isCapturing = true);
    try {
      final photo = await const MethodChannel('sphere-camera/methods')
          .invokeMethod<Map<Object?, Object?>>('capturePhoto', {
            'sessionId': localSessionId,
            'targetId': targetId,
            'expectedYaw': targets[targetId].yaw,
            'expectedPitch': targets[targetId].pitch,
            'allowImuFallback': (qualityRejectCounts[targetId] ?? 0) >= 2,
          });
      final path = photo?['path'] as String?;
      if (path == null) throw StateError('Camera không trả về đường dẫn ảnh.');
      final metadata = _stringKeyedMap(photo);
      metadata.putIfAbsent('schemaVersion', () => '2.0.0');
      metadata.putIfAbsent(
        'capturedAtMs',
        () => DateTime.now().millisecondsSinceEpoch,
      );
      metadata.putIfAbsent(
        'pose',
        () => <String, dynamic>{
          'yaw': currentYaw,
          'pitch': currentPitch,
          'roll': currentRoll,
        },
      );
      metadata.putIfAbsent('intrinsics', () => cameraInfo);
      metadata.putIfAbsent(
        'quality',
        () => <String, dynamic>{
          'accepted': true,
          'validation': 'nativeUnavailable',
        },
      );
      if (!mounted) return;
      setState(() {
        capturedTargets.add(targetId);
        capturedPhotoPaths[targetId] = path;
        capturedFrameMetadata[targetId] = metadata;
        isCapturing = false;
        captureIssue = null;
        qualityRejectCounts.remove(targetId);
      });
      final target = targets[targetId];
      final upload = _uploadFrame(path, target, metadata);
      pendingUploads[targetId] = upload;
      unawaited(upload.whenComplete(() => pendingUploads.remove(targetId)));
    } catch (error) {
      if (!mounted) return;
      final message = error is PlatformException
          ? (error.message ?? 'Frame chưa đạt chất lượng để ghép.')
          : 'Chưa lưu được ảnh: $error';
      setState(() {
        isCapturing = false;
        captureIssue = message;
        captureRetryAfter = DateTime.now().add(const Duration(seconds: 1));
        if (error is PlatformException && error.code == 'qualityRejected') {
          qualityRejectCounts[targetId] =
              (qualityRejectCounts[targetId] ?? 0) + 1;
        }
      });
    }
  }

  Future<void> _uploadFrame(
    String path,
    SphereTarget target,
    Map<String, dynamic> metadata,
  ) async {
    try {
      if (server.remoteSessionId == null) {
        await server.createSession(requestedId: localSessionId);
      }
      await server.uploadFrame(
        path: path,
        targetIndex: target.id,
        expectedYaw: target.yaw,
        expectedPitch: target.pitch,
        captureMetadata: metadata,
      );
    } catch (_) {
      // Local capture remains usable when the optional stitching server is away.
    }
  }

  Future<void> finishCapture() async {
    if (capturedTargets.length < 2 || isCapturing) return;
    final isClosedLoop = capturedTargets.length == targets.length;
    var productType = 'horizontal-360';
    if (!isClosedLoop) {
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Chọn kiểu ghép'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                'Bạn đã chụp ${capturedTargets.length}/${targets.length} điểm. '
                'Có thể ghép ngay hoặc tiếp tục chụp để hoàn thành vòng 360°.',
                style: const TextStyle(color: Color(0xFF9AAEC3)),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'horizontal-stitch'),
              child: const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.photo_size_select_large_rounded),
                title: Text('Ghép hình chữ nhật'),
                subtitle: Text('Ảnh phẳng để xem toàn bộ vật thể dài'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'wide-panorama'),
              child: const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.panorama_horizontal_rounded),
                title: Text('Ghép góc rộng'),
                subtitle: Text('Panorama tương tác trong vùng đã chụp'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.add_a_photo_rounded),
                title: Text('Tiếp tục chụp'),
              ),
            ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      productType = selected;
    }
    String? jobId;
    String? submitError;
    try {
      await Future.wait(pendingUploads.values.toList(), eagerError: false);
      await server.complete(
        frames: capturedTargets
            .map(
              (id) => <String, dynamic>{
                'id': 'frame-$id',
                'targetId': 'sphere-target-$id',
                'expectedPose': <String, double>{
                  'yaw': targets[id].yaw,
                  'pitch': targets[id].pitch,
                },
                'capture': capturedFrameMetadata[id],
              },
            )
            .toList(),
        productType: productType,
        isClosedLoop: isClosedLoop,
      );
      jobId = await server.startStitch();
      if (jobId == null) throw StateError('Backend không trả về mã xử lý.');
    } catch (error) {
      submitError = error.toString();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã lưu ảnh cục bộ; chưa gửi được bước ghép: $error'),
          ),
        );
      }
    }
    if (mounted) {
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ProcessingScreen(
            productType: productType,
            server: server,
            jobId: jobId,
            initialError: submitError,
          ),
        ),
      );
    }
  }

  Future<void> _cancelCapture() async {
    if (capturedTargets.isEmpty) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hủy phiên chụp?'),
        content: const Text(
          'Các ảnh đã chụp trong phiên này sẽ không được ghép.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Tiếp tục chụp'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hủy ảnh'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  void _undo() {
    if (capturedTargets.isEmpty || isCapturing) return;
    final last = capturedTargets.last;
    final path = capturedPhotoPaths[last];
    setState(() {
      capturedTargets.remove(last);
      capturedPhotoPaths.remove(last);
      capturedFrameMetadata.remove(last);
    });
    if (path != null) unawaited(_deleteLocalFrame(path));
    unawaited(
      const MethodChannel(
        'sphere-camera/methods',
      ).invokeMethod<void>('undoLastPatch').catchError((_) {}),
    );
    unawaited(server.deleteFrame(targetIndex: last).catchError((_) {}));
  }

  Future<void> _deleteLocalFrame(String path) async {
    final image = File(path);
    final metadata = File('${path.substring(0, path.lastIndexOf('.'))}.json');
    if (await image.exists()) await image.delete();
    if (await metadata.exists()) await metadata.delete();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    resizeToAvoidBottomInset: false,
    body: Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        const _LiveCameraSurface(),
        CustomPaint(
          painter: _TargetPainter(
            targets: targets,
            currentYaw: currentYaw,
            currentPitch: currentPitch,
            captured: capturedTargets,
            active: activeTarget,
            photoInFlight: isCapturing,
            horizontalFov:
                (cameraInfo['horizontalFovDegrees'] as num?)?.toDouble() ?? 55,
            verticalFov:
                (cameraInfo['verticalFovDegrees'] as num?)?.toDouble() ?? 72,
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 28),
              if (!motionAvailable)
                const _CaptureMessage(
                  'Thiết bị cần cảm biến con quay hồi chuyển',
                )
              else if (showTooFast)
                _CaptureMessage(
                  translationRisk
                      ? 'Không dịch chuyển máy — giữ ống kính tại một điểm'
                      : 'Quá nhanh — hãy giữ yên',
                )
              else if (isCapturing)
                const _CaptureMessage('Đang chụp…')
              else if (captureIssue != null)
                _CaptureMessage(captureIssue!),
              const Spacer(),
              if (capturedTargets.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 22),
                  child: Text(
                    'Căn vòng tròn vào chấm màu cam',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                    ),
                  ),
                ),
              SizedBox(
                height: 88,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (capturedTargets.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: IconButton(
                            onPressed: isCapturing ? null : _undo,
                            iconSize: 36,
                            icon: const Icon(Icons.undo_rounded),
                            tooltip: 'Hoàn tác ảnh cuối',
                          ),
                        ),
                      ),
                    if (capturedTargets.isNotEmpty)
                      _DoneProgressButton(
                        progress: capturedTargets.length / targets.length,
                        enabled: !isCapturing && capturedTargets.length >= 2,
                        onPressed: finishCapture,
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: IconButton(
                          onPressed: _cancelCapture,
                          iconSize: 38,
                          icon: const Icon(Icons.close_rounded),
                          tooltip: 'Hủy',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ],
    ),
  );
}

final class SphereTarget {
  const SphereTarget(this.id, this.yaw, this.pitch);
  final int id;
  final double yaw;
  final double pitch;
}

List<SphereTarget> buildSphereTargets({
  double horizontalFovDegrees = 55,
  double verticalFovDegrees = 72,
}) {
  final targets = <SphereTarget>[];
  void addRing(double pitch, int count, {double offset = 0}) {
    for (var i = 0; i < count; i++) {
      targets.add(
        SphereTarget(targets.length, offset + i * 360 / count, pitch),
      );
    }
  }

  // Keep roughly 42% horizontal and 50% vertical overlap. Target density is
  // derived from the active lens FOV and decreases with latitude, matching the
  // geometry expected by a spherical stitcher instead of assuming one device.
  final yawStep = (horizontalFovDegrees * .58).clamp(24.0, 40.0);
  final horizonCount = (360 / yawStep).ceil().clamp(9, 16);
  addRing(0, horizonCount);
  // Capture one closed horizontal ring. Each native camera keeps its maximum
  // portrait height, so users only rotate in one direction and Hugin retains
  // the complete vertical field of every original frame.
  return targets;
}

Map<String, dynamic> _stringKeyedMap(Map<Object?, Object?>? source) {
  if (source == null) return <String, dynamic>{};
  dynamic convert(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          if (entry.key != null) entry.key.toString(): convert(entry.value),
      };
    }
    if (value is List) return value.map(convert).toList();
    return value;
  }

  return convert(source) as Map<String, dynamic>;
}

double _wrapDegrees(double value) {
  var wrapped = value % 360;
  if (wrapped > 180) wrapped -= 360;
  if (wrapped < -180) wrapped += 360;
  return wrapped;
}

double angularDistance(double yawA, double pitchA, double yawB, double pitchB) {
  final latA = pitchA * math.pi / 180;
  final latB = pitchB * math.pi / 180;
  final deltaYaw = _wrapDegrees(yawA - yawB) * math.pi / 180;
  final cosine =
      (math.sin(latA) * math.sin(latB) +
              math.cos(latA) * math.cos(latB) * math.cos(deltaYaw))
          .clamp(-1.0, 1.0);
  return math.acos(cosine) * 180 / math.pi;
}

final class TargetGuideDirection {
  const TargetGuideDirection({
    required this.direction,
    required this.isOnScreen,
  });

  /// Screen-space direction from the reticle: +x is right, +y is down.
  final Offset direction;
  final bool isOnScreen;
}

TargetGuideDirection targetGuideDirection({
  required double currentYaw,
  required double currentPitch,
  required double targetYaw,
  required double targetPitch,
  required double horizontalFov,
  required double verticalFov,
}) {
  final currentPitchRadians = currentPitch * math.pi / 180;
  final targetPitchRadians = targetPitch * math.pi / 180;
  final relativeYaw = _wrapDegrees(targetYaw - currentYaw);
  final relativeYawRadians = relativeYaw * math.pi / 180;

  // Target ray expressed in the current camera's right/up/forward basis.
  final right = math.cos(targetPitchRadians) * math.sin(relativeYawRadians);
  final up =
      math.sin(targetPitchRadians) * math.cos(currentPitchRadians) -
      math.cos(targetPitchRadians) *
          math.cos(relativeYawRadians) *
          math.sin(currentPitchRadians);
  final forward =
      math.sin(targetPitchRadians) * math.sin(currentPitchRadians) +
      math.cos(targetPitchRadians) *
          math.cos(relativeYawRadians) *
          math.cos(currentPitchRadians);

  final halfHorizontalTangent = math.tan(horizontalFov * math.pi / 360);
  final halfVerticalTangent = math.tan(verticalFov * math.pi / 360);
  if (forward > 0.001) {
    final projected = Offset(
      right / forward / halfHorizontalTangent,
      -up / forward / halfVerticalTangent,
    );
    return TargetGuideDirection(
      direction: projected,
      isOnScreen: projected.dx.abs() <= .9 && projected.dy.abs() <= .78,
    );
  }

  // Projection is undefined behind the camera. Keep the shortest yaw turn;
  // an exact 180° target consistently points right instead of flickering.
  var horizontal = right;
  if (horizontal.abs() < .001) horizontal = relativeYaw >= 0 ? 1 : -1;
  final behindDirection = Offset(horizontal, -up);
  return TargetGuideDirection(
    direction: behindDirection.distanceSquared > .000001
        ? behindDirection
        : const Offset(1, 0),
    isOnScreen: false,
  );
}

class _LiveCameraSurface extends StatelessWidget {
  const _LiveCameraSurface();
  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return const UiKitView(viewType: 'sphere-camera-preview');
    }
    if (Platform.isAndroid) {
      return const AndroidView(viewType: 'sphere-camera-preview');
    }
    return const ColoredBox(color: Colors.black);
  }
}

class _CaptureMessage extends StatelessWidget {
  const _CaptureMessage(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
    ),
  );
}

class _DoneProgressButton extends StatelessWidget {
  const _DoneProgressButton({
    required this.progress,
    required this.enabled,
    required this.onPressed,
  });
  final double progress;
  final bool enabled;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 76,
    child: Stack(
      fit: StackFit.expand,
      children: [
        CircularProgressIndicator(
          value: progress,
          strokeWidth: 7,
          backgroundColor: Colors.white30,
          color: progress >= 1
              ? const Color(0xFF34A853)
              : const Color(0xFFFFA000),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: IconButton.filled(
            onPressed: enabled ? onPressed : null,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFFFA000),
              disabledBackgroundColor: const Color(0xAAFFA000),
            ),
            iconSize: 36,
            tooltip: enabled ? 'Hoàn thành chụp' : 'Cần ít nhất 2 ảnh để ghép',
            icon: const Icon(Icons.check_rounded, color: Colors.white),
          ),
        ),
      ],
    ),
  );
}

class _TargetPainter extends CustomPainter {
  const _TargetPainter({
    required this.targets,
    required this.currentYaw,
    required this.currentPitch,
    required this.captured,
    required this.active,
    required this.photoInFlight,
    required this.horizontalFov,
    required this.verticalFov,
  });
  final List<SphereTarget> targets;
  final double currentYaw;
  final double currentPitch;
  final Set<int> captured;
  final int? active;
  final bool photoInFlight;
  final double horizontalFov;
  final double verticalFov;
  @override
  void paint(Canvas canvas, Size size) {
    final pnt = Paint();
    final center = Offset(size.width / 2, size.height * .48);
    for (final target in targets) {
      if (captured.contains(target.id)) continue;
      final guide = targetGuideDirection(
        currentYaw: currentYaw,
        currentPitch: currentPitch,
        targetYaw: target.yaw,
        targetPitch: target.pitch,
        horizontalFov: horizontalFov,
        verticalFov: verticalFov,
      );
      if (!guide.isOnScreen) continue;
      final distance = angularDistance(
        currentYaw,
        currentPitch,
        target.yaw,
        target.pitch,
      );
      final proximity = distance <= 10
          ? 1.0
          : distance >= 20
          ? .08
          : 1 - (distance - 10) / 10;
      final p = Offset(
        center.dx + guide.direction.dx * size.width / 2,
        center.dy + guide.direction.dy * size.height / 2,
      );
      final isActive = target.id == active;
      pnt.color =
          (isActive
                  ? (photoInFlight ? Colors.white : const Color(0xFFFFA000))
                  : const Color(0xFFFFA000))
              .withValues(alpha: isActive ? 1 : proximity * .65);
      canvas.drawCircle(p, isActive ? 12 : 7, pnt);
      if (isActive) {
        pnt
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = photoInFlight ? Colors.white70 : const Color(0xCCFFA000);
        canvas.drawCircle(p, 20, pnt);
        pnt.style = PaintingStyle.fill;
      }
    }
    final activeTarget = active == null
        ? null
        : targets.cast<SphereTarget?>().firstWhere(
            (target) => target?.id == active,
            orElse: () => null,
          );
    if (activeTarget != null && !captured.contains(activeTarget.id)) {
      final guide = targetGuideDirection(
        currentYaw: currentYaw,
        currentPitch: currentPitch,
        targetYaw: activeTarget.yaw,
        targetPitch: activeTarget.pitch,
        horizontalFov: horizontalFov,
        verticalFov: verticalFov,
      );
      _paintNavigationArrow(canvas, size, guide);
    }
    pnt
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white;
    canvas.drawCircle(center, 22, pnt);
    pnt.style = PaintingStyle.fill;
    canvas.drawCircle(center, 3, pnt);
  }

  void _paintNavigationArrow(
    Canvas canvas,
    Size size,
    TargetGuideDirection guide,
  ) {
    final center = Offset(size.width / 2, size.height * .48);
    final pixelDirection = Offset(
      guide.direction.dx * size.width / 2,
      guide.direction.dy * size.height / 2,
    );
    final direction = pixelDirection.distanceSquared > .000001
        ? pixelDirection / pixelDirection.distance
        : const Offset(1, 0);
    final safeRect = Rect.fromLTRB(42, 82, size.width - 42, size.height - 142);
    final horizontalDistance = direction.dx > 0
        ? (safeRect.right - center.dx) / direction.dx
        : direction.dx < 0
        ? (safeRect.left - center.dx) / direction.dx
        : double.infinity;
    final verticalDistance = direction.dy > 0
        ? (safeRect.bottom - center.dy) / direction.dy
        : direction.dy < 0
        ? (safeRect.top - center.dy) / direction.dy
        : double.infinity;
    final edgeDistance = math.min(horizontalDistance, verticalDistance);
    final targetPosition = guide.isOnScreen
        ? center + pixelDirection
        : center + direction * edgeDistance;
    final guideLength = (targetPosition - center).distance;
    if (guideLength <= 38) return;
    final start = center + direction * 29;
    final tip = targetPosition - direction * (guide.isOnScreen ? 22 : 7);
    if ((tip - start).distance <= 10) return;
    final angle = math.atan2(direction.dy, direction.dx);
    final arrowPaint = Paint()
      ..color = photoInFlight ? Colors.white : const Color(0xFFFFA000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final shadowPaint = Paint()
      ..color = const Color(0xB3000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(start, tip, shadowPaint);
    canvas.drawLine(start, tip, arrowPaint);

    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(angle);
    final head = Path()
      ..moveTo(-12, -10)
      ..lineTo(0, 0)
      ..lineTo(-12, 10);
    canvas.drawPath(head, shadowPaint);
    canvas.drawPath(head, arrowPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TargetPainter old) =>
      old.targets.length != targets.length ||
      old.currentYaw != currentYaw ||
      old.currentPitch != currentPitch ||
      old.captured.length != captured.length ||
      !old.captured.containsAll(captured) ||
      old.active != active ||
      old.photoInFlight != photoInFlight ||
      old.horizontalFov != horizontalFov ||
      old.verticalFov != verticalFov;
}

class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({
    required this.productType,
    required this.server,
    required this.jobId,
    this.initialError,
    super.key,
  });

  final String productType;
  final ServerSessionClient server;
  final String? jobId;
  final String? initialError;
  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  Timer? timer;
  String status = 'queued';
  String? error;
  Map<String, dynamic>? qualityDecision;
  Map<String, dynamic> viewerConfig = const {};

  @override
  void initState() {
    super.initState();
    error = widget.initialError;
    if (widget.jobId != null && error == null) {
      _poll();
      timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    }
  }

  Future<void> _poll() async {
    final jobId = widget.jobId;
    if (jobId == null || !mounted) return;
    try {
      final job = await widget.server.getStitchJob(jobId);
      if (!mounted) return;
      final nextStatus = job['status'] as String? ?? 'queued';
      setState(() {
        status = nextStatus;
        qualityDecision = job['qualityDecision'] as Map<String, dynamic>?;
        viewerConfig =
            (job['viewerConfig'] as Map?)?.cast<String, dynamic>() ?? const {};
        error = null;
        if (nextStatus == 'failed') {
          error = (job['message'] as String?) ?? 'Hugin không ghép được ảnh.';
        }
      });
      if (nextStatus == 'completed' ||
          nextStatus == 'needs_review' ||
          nextStatus == 'failed') {
        timer?.cancel();
      }
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.auto_awesome_rounded,
              size: 54,
              color: Color(0xFF7CE2FF),
            ),
            const SizedBox(height: 24),
            const Text(
              'Đang ghép ảnh',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Đang căn chỉnh và ghép các khung hình…',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF9AAEC3)),
            ),
            const SizedBox(height: 28),
            if (error == null &&
                status != 'completed' &&
                status != 'needs_review')
              const LinearProgressIndicator(minHeight: 8),
            const SizedBox(height: 12),
            Text(
              error != null
                  ? 'Không thể xử lý: $error'
                  : status == 'queued'
                  ? 'Đang chờ Hugin…'
                  : status == 'needs_review'
                  ? (qualityDecision?['status'] == 'RECAPTURE'
                        ? 'Đã ghép — có ảnh nguồn cần chụp lại'
                        : 'Đã ghép — cần kiểm tra chất lượng')
                  : status == 'completed'
                  ? 'Hoàn thành'
                  : 'Hugin đang căn chỉnh và hòa trộn ảnh…',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF7CE2FF),
                fontWeight: FontWeight.w700,
              ),
            ),
            if (status == 'completed' || status == 'needs_review') ...[
              const SizedBox(height: 26),
              FilledButton.icon(
                onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ViewerScreen(
                      productType: widget.productType,
                      panoramaUri: widget.server.panoramaUri(widget.jobId!),
                      viewerConfig: viewerConfig,
                      qualityWarning: status == 'needs_review'
                          ? _qualityWarning(qualityDecision)
                          : null,
                    ),
                  ),
                ),
                icon: Icon(
                  widget.productType == 'horizontal-stitch'
                      ? Icons.photo_size_select_large_rounded
                      : widget.productType == 'wide-panorama'
                      ? Icons.panorama_horizontal_rounded
                      : Icons.threesixty_rounded,
                ),
                label: Text(
                  widget.productType == 'horizontal-stitch'
                      ? 'Mở ảnh ghép ngang'
                      : widget.productType == 'wide-panorama'
                      ? 'Mở panorama góc rộng'
                      : 'Mở panorama 360°',
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

String? _qualityWarning(Map<String, dynamic>? decision) {
  final qualityStatus = decision?['status'] as String?;
  if (qualityStatus == null) return null;
  if (qualityStatus != 'RECAPTURE') return qualityStatus;
  final issues = decision?['captureIssues'] as List? ?? const [];
  if (issues.isEmpty) return 'RECAPTURE — cần chụp lại ảnh nguồn';
  final issue = (issues.first as Map).cast<String, dynamic>();
  final target = issue['targetId']?.toString() ?? 'frame';
  final reasons = (issue['reasons'] as List? ?? const []).join(', ');
  return 'RECAPTURE — $target: $reasons';
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    required this.productType,
    required this.panoramaUri,
    required this.viewerConfig,
    this.qualityWarning,
    super.key,
  });

  final String productType;
  final Uri panoramaUri;
  final Map<String, dynamic> viewerConfig;
  final String? qualityWarning;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.productType == 'horizontal-stitch') {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
  }

  @override
  void dispose() {
    if (widget.productType == 'horizontal-stitch') {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      title: Text(
        widget.productType == 'horizontal-stitch'
            ? 'Ảnh ghép ngang'
            : widget.productType == 'horizontal-360'
            ? 'Panorama 360° ngang'
            : 'Panorama góc rộng',
      ),
      actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.ios_share_rounded)),
      ],
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (widget.productType == 'horizontal-stitch')
          _FlatHorizontalImage(uri: widget.panoramaUri)
        else
          PanoramaViewer(
            uri: widget.panoramaUri,
            viewerConfig: widget.viewerConfig,
          ),
        if (widget.qualityWarning != null)
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xDD7A4D00),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Cần kiểm tra chất lượng: ${widget.qualityWarning}',
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _FlatHorizontalImage extends StatelessWidget {
  const _FlatHorizontalImage({required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => InteractiveViewer(
    minScale: 0.8,
    maxScale: 5,
    boundaryMargin: const EdgeInsets.all(80),
    child: Center(
      child: Image.network(
        uri.toString(),
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error, stackTrace) =>
            const Center(child: Text('Không thể mở ảnh ghép ngang.')),
      ),
    ),
  );
}
