import 'package:flutter_test/flutter_test.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mero/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads defaults when nothing is stored', () async {
    final service = AppSettingsService();

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(service.isLoaded, isTrue);
    expect(service.cameraImageQuality, 92);
    expect(service.toolsEnabled, isTrue);
  });

  test('persists camera quality and clamps out-of-range values', () async {
    final service = AppSettingsService();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await service.setCameraImageQuality(120);

    expect(service.cameraImageQuality, 100);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('camera_image_quality'), 100);
  });

  test('persists camera resolution preset', () async {
    final service = AppSettingsService();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await service.setCameraResolutionPreset(ResolutionPreset.veryHigh);

    expect(service.cameraResolutionPreset, ResolutionPreset.veryHigh);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('camera_resolution_preset'), 'veryHigh');
  });

  test('persists tool toggle', () async {
    final service = AppSettingsService();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await service.setToolsEnabled(false);

    expect(service.toolsEnabled, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tools_enabled'), isFalse);
  });
}
