import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
