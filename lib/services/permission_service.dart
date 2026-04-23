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
  
  /// Check and request photo library permission
  static Future<PermissionStatus> requestPhotoLibraryPermission() async {
    // On Android, need to check which permission to request
    if (await Permission.photos.isRestricted) {
      // On iOS, photos permission might be restricted
      return await Permission.photos.request();
    }
    
    final status = await Permission.photos.status;
    
    if (status.isGranted) {
      return status;
    } else if (status.isDenied) {
      return await Permission.photos.request();
    } else if (status.isPermanentlyDenied) {
      await openAppSettings();
      return await Permission.photos.status;
    }
    
    return status;
  }
  
  /// Check and request storage permission (Android)
  static Future<PermissionStatus> requestStoragePermission() async {
    // On Android 13+, need different permissions
    if (await Permission.storage.isRestricted) {
      return await Permission.storage.request();
    }
    
    final status = await Permission.storage.status;
    
    if (status.isGranted) {
      return status;
    } else if (status.isDenied) {
      return await Permission.storage.request();
    } else if (status.isPermanentlyDenied) {
      await openAppSettings();
      return await Permission.storage.status;
    }
    
    return status;
  }
  
  /// Check if camera permission is granted
  static Future<bool> hasCameraPermission() async {
    final status = await Permission.camera.status;
    return status.isGranted;
  }
  
  /// Check if photo library permission is granted
  static Future<bool> hasPhotoLibraryPermission() async {
    final status = await Permission.photos.status;
    return status.isGranted;
  }
  
  /// Check if storage permission is granted (Android)
  static Future<bool> hasStoragePermission() async {
    final status = await Permission.storage.status;
    return status.isGranted;
  }
  
  /// Open app settings for permission management
  static Future<void> openPermissionSettings() async {
    await openAppSettings();
  }
  
  /// Check all required permissions
  static Future<Map<String, bool>> checkAllPermissions() async {
    return {
      'camera': await hasCameraPermission(),
      'photos': await hasPhotoLibraryPermission(),
      'storage': await hasStoragePermission(),
    };
  }
  
  /// Request all required permissions
  static Future<Map<String, PermissionStatus>> requestAllPermissions() async {
    final results = <String, PermissionStatus>{};
    
    results['camera'] = await requestCameraPermission();
    results['photos'] = await requestPhotoLibraryPermission();
    results['storage'] = await requestStoragePermission();
    
    return results;
  }
  
  /// Show permission rationale dialog
  static String getPermissionRationale(String permission) {
    switch (permission) {
      case 'camera':
        return 'Camera access is needed to take photos of wildlife for identification.';
      case 'photos':
        return 'Photo library access is needed to select existing photos for analysis.';
      case 'storage':
        return 'Storage access is needed to save the AI model and analysis results.';
      default:
        return 'This permission is required for the app to function properly.';
    }
  }
  
  /// Check if permission is permanently denied
  static Future<bool> isPermissionPermanentlyDenied(Permission permission) async {
    final status = await permission.status;
    return status.isPermanentlyDenied;
  }
}