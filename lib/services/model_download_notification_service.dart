import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class ModelDownloadNotificationService {
  static const int _notificationId = 4242;
  static const String _channelId = 'model_download_progress';
  static const String _channelName = 'Model download';
  static const String _channelDescription =
      'Shows Gemma model download progress';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized || defaultTargetPlatform != TargetPlatform.android) {
      _initialized = true;
      return;
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings);

    final androidImplementation =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.requestNotificationsPermission();

    _initialized = true;
  }

  /// Request notification permission with UI handling - call this from UI layer before download
  static Future<bool> requestPermission(BuildContext context) async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;

    final status = await Permission.notification.status;

    if (status.isGranted) return true;

    if (!status.isPermanentlyDenied) {
      final shouldRequest = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Download Notifications'),
          content: const Text(
            'Notifications are used to show the AI model download progress in the background. '
            'You can disable this later in settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Skip'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );

      if (shouldRequest == true) {
        final result = await Permission.notification.request();
        return result.isGranted;
      }
    } else {
      // Permanently denied - open settings
      final shouldOpenSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Notification Permission Required'),
          content: const Text(
            'Notification permission has been disabled. '
            'Enable it in settings to see download progress.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Skip'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );

      if (shouldOpenSettings == true) {
        await openAppSettings();
      }
    }

    return false;
  }

  Future<void> showProgress({
    required String title,
    required String body,
    required int progress,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await initialize();

    final details = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: 100,
      progress: progress.clamp(0, 100),
      indeterminate: false,
      playSound: false,
      enableVibration: false,
      channelShowBadge: false,
    );

    await _plugin.show(
      _notificationId,
      title,
      body,
      NotificationDetails(android: details),
    );
  }

  Future<void> showCompleted({
    String title = 'Model ready',
    String body = 'The Gemma model is ready to use.',
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await initialize();

    await _plugin.show(
      _notificationId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.low,
          priority: Priority.low,
          ongoing: false,
          onlyAlertOnce: true,
          playSound: false,
          enableVibration: false,
          channelShowBadge: false,
        ),
      ),
    );

    await Future<void>.delayed(const Duration(seconds: 1));
    await cancel();
  }

  Future<void> showError({
    required String title,
    required String body,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await initialize();

    await _plugin.show(
      _notificationId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          ongoing: false,
          onlyAlertOnce: true,
          playSound: false,
          enableVibration: false,
          channelShowBadge: false,
          autoCancel: true,
        ),
      ),
    );
  }

  Future<void> cancel() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    await initialize();
    await _plugin.cancel(_notificationId);
  }
}
