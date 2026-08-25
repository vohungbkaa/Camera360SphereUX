import 'package:flutter_test/flutter_test.dart';
import 'package:camera360_sphere_ux/main.dart';

void main() {
  testWidgets('Sphere home presents the capture CTA', (tester) async {
    await tester.pumpWidget(const SphereUxApp());
    expect(find.text('Tạo ảnh Sphere'), findsOneWidget);
    expect(find.text('Bắt đầu chụp'), findsOneWidget);
  });

  test(
    'target generator covers the complete sphere with stable identifiers',
    () {
      final targets = buildSphereTargets(
        horizontalFovDegrees: 55,
        verticalFovDegrees: 72,
      );
      expect(targets.length, greaterThan(30));
      expect(targets.map((target) => target.id).toSet().length, targets.length);
      expect(targets.any((target) => target.pitch == 90), isTrue);
      expect(targets.any((target) => target.pitch == -90), isTrue);
      expect(
        targets.where((target) => target.pitch == 0).length,
        greaterThan(8),
      );
    },
  );

  test('target density adapts to active camera field of view', () {
    final narrow = buildSphereTargets(
      horizontalFovDegrees: 45,
      verticalFovDegrees: 60,
    );
    final wide = buildSphereTargets(
      horizontalFovDegrees: 70,
      verticalFovDegrees: 85,
    );
    expect(narrow.length, greaterThan(wide.length));
  });

  test('spherical angular distance wraps cleanly at 360 degrees', () {
    expect(angularDistance(359, 0, 1, 0), closeTo(2, 0.0001));
    expect(angularDistance(0, 0, 0, 90), closeTo(90, 0.0001));
  });

  test(
    'off-screen target guide points along the shortest useful direction',
    () {
      final right = targetGuideDirection(
        currentYaw: 0,
        currentPitch: 0,
        targetYaw: 90,
        targetPitch: 0,
        horizontalFov: 55,
        verticalFov: 72,
      );
      final left = targetGuideDirection(
        currentYaw: 0,
        currentPitch: 0,
        targetYaw: -90,
        targetPitch: 0,
        horizontalFov: 55,
        verticalFov: 72,
      );
      final up = targetGuideDirection(
        currentYaw: 0,
        currentPitch: 0,
        targetYaw: 0,
        targetPitch: 70,
        horizontalFov: 55,
        verticalFov: 72,
      );

      expect(right.isOnScreen, isFalse);
      expect(right.direction.dx, greaterThan(0));
      expect(left.direction.dx, lessThan(0));
      expect(up.direction.dy, lessThan(0));
    },
  );

  test('target guide detects when target enters the capture viewport', () {
    final guide = targetGuideDirection(
      currentYaw: 10,
      currentPitch: 5,
      targetYaw: 13,
      targetPitch: 7,
      horizontalFov: 55,
      verticalFov: 72,
    );
    expect(guide.isOnScreen, isTrue);
  });
}
