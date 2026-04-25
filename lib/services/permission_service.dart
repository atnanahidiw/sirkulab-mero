import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  /// Check and request camera permission
  static Future<PermissionStatus> requestCameraPermission() async {
    final status = await Permission.camera.status;

    if (status.isGranted) {
      return status;
    } else if (status.isDenied) {
      return await Permission.camera.request();
    } else if (status.isPermanentlyDenied) {
      // User permanently denied, need to open app settings
      await openAppSettings();
      return await Permission.camera.status;
    }

    return status;
  }

  /// Check if camera permission is granted
  static Future<bool> hasCameraPermission() async {
    final status = await Permission.camera.status;
    return status.isGranted;
  }

  /// Open app settings for permission management
  static Future<void> openPermissionSettings() async {
    await openAppSettings();
  }

  /// Show permission rationale dialog
  static String getPermissionRationale(String permission) {
    switch (permission) {
      case 'camera':
        return 'Camera access is needed to take photos of wildlife for identification.';
      default:
        return 'This permission is required for the app to function properly.';
    }
  }

  /// Check if permission is permanently denied
  static Future<bool> isPermissionPermanentlyDenied(
      Permission permission) async {
    final status = await permission.status;
    return status.isPermanentlyDenied;
  }
}
