import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

final class ServerSessionClient {
  ServerSessionClient({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();
  final Uri baseUrl;
  final http.Client _client;
  String? remoteSessionId;

  Future<void> createSession({required String requestedId}) async {
    final response = await _client.post(
      baseUrl.resolve('/v1/sessions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'id': requestedId,
        'schemaVersion': '2.0.0',
        'platform': Platform.operatingSystem,
      }),
    );
    _check(response);
    remoteSessionId =
        (jsonDecode(response.body) as Map<String, dynamic>)['id'] as String;
  }

  Future<void> uploadFrame({
    required String path,
    required int targetIndex,
    required double expectedYaw,
    required double expectedPitch,
    required Map<String, dynamic> captureMetadata,
  }) async {
    final sessionId = remoteSessionId;
    if (sessionId == null) {
      throw StateError('Session server chưa được tạo.');
    }
    final request = http.MultipartRequest(
      'POST',
      baseUrl.resolve('/v1/sessions/$sessionId/frames'),
    );
    request.fields['metadata'] = jsonEncode({
      'id': 'frame-$targetIndex',
      'targetId': 'sphere-target-$targetIndex',
      'expectedPose': {'yaw': expectedYaw, 'pitch': expectedPitch},
      'capture': captureMetadata,
    });
    request.files.add(
      await http.MultipartFile.fromPath(
        'image',
        path,
        filename: 'frame-$targetIndex.jpg',
      ),
    );
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Upload frame thất bại (${response.statusCode})');
    }
  }

  Future<void> deleteFrame({required int targetIndex}) async {
    final sessionId = remoteSessionId;
    if (sessionId == null) return;
    final response = await _client.delete(
      baseUrl.resolve('/v1/sessions/$sessionId/frames/frame-$targetIndex'),
    );
    if (response.statusCode == 404) return;
    _check(response);
  }

  Future<void> complete({required List<Map<String, dynamic>> frames}) async {
    final sessionId = remoteSessionId;
    if (sessionId == null) return;
    final response = await _client.post(
      baseUrl.resolve('/v1/sessions/$sessionId/complete'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'schemaVersion': '2.0.0',
        'productType': '360',
        'isClosedLoop': true,
        'frames': frames,
      }),
    );
    _check(response);
  }

  Future<String?> startStitch() async {
    final sessionId = remoteSessionId;
    if (sessionId == null) return null;
    final response = await _client.post(
      baseUrl.resolve('/v1/sessions/$sessionId/stitch'),
    );
    _check(response);
    return (jsonDecode(response.body) as Map<String, dynamic>)['id'] as String?;
  }

  void _check(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Server Camera360 trả lỗi ${response.statusCode}: ${response.body}',
      );
    }
  }
}
