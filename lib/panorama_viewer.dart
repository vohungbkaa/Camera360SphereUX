import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

class PanoramaViewer extends StatefulWidget {
  const PanoramaViewer({
    required this.uri,
    required this.viewerConfig,
    super.key,
  });

  final Uri uri;
  final Map<String, dynamic> viewerConfig;

  @override
  State<PanoramaViewer> createState() => _PanoramaViewerState();
}

class _PanoramaViewerState extends State<PanoramaViewer> {
  WebViewController? _webView;
  Directory? _workspace;
  String? _error;
  bool _ready = false;
  bool _gyroAvailable = false;
  bool _gyroEnabled = false;
  Timer? _timeout;

  static const _assets = <String, String>{
    'assets/viewer/viewer.css': 'viewer.css',
    'assets/viewer/viewer_runtime.js': 'viewer_runtime.js',
    'assets/viewer/vendor/photo_sphere_viewer.bundle.js':
        'photo_sphere_viewer.bundle.js',
    'assets/viewer/vendor/photo_sphere_viewer.css': 'photo_sphere_viewer.css',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    _timeout?.cancel();
    final previous = _workspace;
    _workspace = null;
    if (previous != null && await previous.exists()) {
      await previous.delete(recursive: true);
    }
    if (mounted) {
      setState(() {
        _error = null;
        _ready = false;
        _webView = null;
      });
    }
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory('${support.path}/camera360_viewer');
      await root.create(recursive: true);
      final workspace = Directory(
        '${root.path}/${DateTime.now().microsecondsSinceEpoch}',
      );
      await workspace.create();
      _workspace = workspace;
      for (final asset in _assets.entries) {
        final data = await rootBundle.load(asset.key);
        await File('${workspace.path}/${asset.value}').writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      final template = await rootBundle.loadString(
        'assets/viewer/index.template.html',
      );
      final html = template
          .replaceAll('__PANORAMA_FILE__', jsonEncode(widget.uri.toString()))
          .replaceAll('__PANORAMA_CONFIG__', jsonEncode(widget.viewerConfig));
      final index = File('${workspace.path}/index.html');
      await index.writeAsString(html, flush: true);
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF07111F))
        ..enableZoom(false)
        ..addJavaScriptChannel('Camera360Bridge', onMessageReceived: _onMessage)
        ..setNavigationDelegate(
          NavigationDelegate(
            onWebResourceError: (event) {
              if (event.isForMainFrame == true) {
                _fail('Không thể mở trình xem panorama.');
              }
            },
            onNavigationRequest: (request) {
              final scheme = Uri.tryParse(request.url)?.scheme;
              return {'file', 'about', 'data', 'blob'}.contains(scheme)
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
          ),
        );
      if (!mounted) return;
      setState(() => _webView = controller);
      await controller.loadFile(index.path);
      _timeout = Timer(const Duration(seconds: 30), () {
        if (!_ready) {
          _fail('Tải ảnh panorama quá lâu. Kiểm tra kết nối tới backend.');
        }
      });
    } catch (error) {
      _fail('Không thể chuẩn bị viewer 360: $error');
    }
  }

  void _onMessage(JavaScriptMessage message) {
    try {
      final value = jsonDecode(message.message) as Map<String, dynamic>;
      final payload =
          (value['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
      switch (value['type']) {
        case 'ready':
          _timeout?.cancel();
          if (mounted) setState(() => _ready = true);
        case 'capabilities':
          if (mounted) {
            setState(
              () => _gyroAvailable = payload['gyroscopeAvailable'] == true,
            );
          }
        case 'gyroscope':
          if (mounted) {
            setState(() {
              _gyroAvailable = payload['available'] == true;
              _gyroEnabled = payload['enabled'] == true;
            });
          }
        case 'error':
          _fail(
            payload['message'] as String? ?? 'Không thể hiển thị panorama.',
          );
      }
    } catch (_) {
      _fail('Viewer trả về dữ liệu không hợp lệ.');
    }
  }

  void _fail(String message) {
    _timeout?.cancel();
    if (mounted) setState(() => _error = message);
  }

  Future<void> _run(String script) async => _webView?.runJavaScript(script);

  @override
  void dispose() {
    _timeout?.cancel();
    unawaited(_run('window.Camera360Viewer.destroy();'));
    final workspace = _workspace;
    if (workspace != null) unawaited(workspace.delete(recursive: true));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF07111F),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (_webView != null) WebViewWidget(controller: _webView!),
        if (!_ready && _error == null)
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Đang mở không gian panorama…'),
              ],
            ),
          ),
        if (_error != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.broken_image_outlined, size: 56),
                  const SizedBox(height: 14),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _initialize,
                    child: const Text('Thử lại'),
                  ),
                ],
              ),
            ),
          ),
        if (_ready)
          Positioned(
            right: 16,
            bottom: 24,
            child: Column(
              children: [
                IconButton.filledTonal(
                  tooltip: 'Đưa góc nhìn về giữa',
                  onPressed: () => _run('window.Camera360Viewer.recenter();'),
                  icon: const Icon(Icons.my_location),
                ),
                const SizedBox(height: 8),
                IconButton.filledTonal(
                  tooltip: 'Điều khiển bằng chuyển động',
                  onPressed: _gyroAvailable
                      ? () => _run(
                          'window.Camera360Viewer.setGyroscopeEnabled(${!_gyroEnabled});',
                        )
                      : null,
                  icon: Icon(
                    _gyroEnabled
                        ? Icons.screen_rotation_alt
                        : Icons.screen_rotation,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
