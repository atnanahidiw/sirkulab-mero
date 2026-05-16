import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettingsService extends ChangeNotifier {
  static const String _cameraResolutionPresetKey = 'camera_resolution_preset';
  static const String _cameraImageQualityKey = 'camera_image_quality';
  static const String _toolsEnabledKey = 'tools_enabled';
  static const ResolutionPreset _defaultCameraResolutionPreset =
      ResolutionPreset.high;
  static const int _defaultCameraImageQuality = 92;
  static const int _minCameraImageQuality = 50;
  static const int _maxCameraImageQuality = 100;

  ResolutionPreset _cameraResolutionPreset = _defaultCameraResolutionPreset;
  int _cameraImageQuality = _defaultCameraImageQuality;
  bool _toolsEnabled = true;
  bool _isLoaded = false;

  AppSettingsService() {
    _load();
  }

  bool get isLoaded => _isLoaded;

  ResolutionPreset get cameraResolutionPreset => _cameraResolutionPreset;

  int get cameraImageQuality => _cameraImageQuality;

  bool get toolsEnabled => _toolsEnabled;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _cameraResolutionPreset = _resolutionPresetFromName(
      prefs.getString(_cameraResolutionPresetKey),
    );
    _cameraImageQuality =
        prefs.getInt(_cameraImageQualityKey) ?? _defaultCameraImageQuality;
    _toolsEnabled = prefs.getBool(_toolsEnabledKey) ?? true;
    _isLoaded = true;
    notifyListeners();
  }

  ResolutionPreset _resolutionPresetFromName(String? value) {
    switch (value) {
      case 'low':
        return ResolutionPreset.low;
      case 'medium':
        return ResolutionPreset.medium;
      case 'high':
        return ResolutionPreset.high;
      case 'veryHigh':
        return ResolutionPreset.veryHigh;
      case 'ultraHigh':
        return ResolutionPreset.ultraHigh;
      case 'max':
        return ResolutionPreset.max;
      default:
        return _defaultCameraResolutionPreset;
    }
  }

  String _resolutionPresetName(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
        return 'low';
      case ResolutionPreset.medium:
        return 'medium';
      case ResolutionPreset.high:
        return 'high';
      case ResolutionPreset.veryHigh:
        return 'veryHigh';
      case ResolutionPreset.ultraHigh:
        return 'ultraHigh';
      case ResolutionPreset.max:
        return 'max';
    }
  }

  Future<void> setCameraResolutionPreset(ResolutionPreset value) async {
    if (value == _cameraResolutionPreset) {
      return;
    }

    _cameraResolutionPreset = value;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cameraResolutionPresetKey,
      _resolutionPresetName(value),
    );
  }

  int _clampCameraImageQuality(int value) {
    return value.clamp(_minCameraImageQuality, _maxCameraImageQuality);
  }

  Future<void> setCameraImageQuality(int value) async {
    final clamped = _clampCameraImageQuality(value);
    if (clamped == _cameraImageQuality) {
      return;
    }

    _cameraImageQuality = clamped;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_cameraImageQualityKey, clamped);
  }

  Future<void> setToolsEnabled(bool value) async {
    if (value == _toolsEnabled) {
      return;
    }

    _toolsEnabled = value;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_toolsEnabledKey, value);
  }
}
