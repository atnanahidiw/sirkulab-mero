import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum ModelBootPhase {
  idle,
  checking,
  starting,
  downloading,
  resuming,
  paused,
  canceled,
  installing,
  failed,
  ready,
  analyzing,
}

class ModelBootState {
  static const Object _unset = Object();

  final bool isInitialized;
  final bool isLoading;
  final bool isModelLoaded;
  final String status;
  final String? error;
  final double? downloadProgress;
  final ModelBootPhase phase;
  final String? downloadTaskId;
  final String? downloadFilePath;
  final DateTime updatedAt;

  const ModelBootState({
    required this.isInitialized,
    required this.isLoading,
    required this.isModelLoaded,
    required this.status,
    required this.error,
    required this.downloadProgress,
    required this.phase,
    required this.downloadTaskId,
    required this.downloadFilePath,
    required this.updatedAt,
  });

  factory ModelBootState.initial() {
    return ModelBootState(
      isInitialized: false,
      isLoading: true,
      isModelLoaded: false,
      status: 'Starting up...',
      error: null,
      downloadProgress: null,
      phase: ModelBootPhase.idle,
      downloadTaskId: null,
      downloadFilePath: null,
      updatedAt: DateTime.now(),
    );
  }

  String get downloadPhase => phase.name;
  bool get isDownloading =>
      phase == ModelBootPhase.starting ||
      phase == ModelBootPhase.downloading ||
      phase == ModelBootPhase.resuming ||
      phase == ModelBootPhase.installing;
  bool get canRetry => phase == ModelBootPhase.failed;

  ModelBootState copyWith({
    bool? isInitialized,
    bool? isLoading,
    bool? isModelLoaded,
    String? status,
    Object? error = _unset,
    Object? downloadProgress = _unset,
    ModelBootPhase? phase,
    Object? downloadTaskId = _unset,
    Object? downloadFilePath = _unset,
    DateTime? updatedAt,
  }) {
    return ModelBootState(
      isInitialized: isInitialized ?? this.isInitialized,
      isLoading: isLoading ?? this.isLoading,
      isModelLoaded: isModelLoaded ?? this.isModelLoaded,
      status: status ?? this.status,
      error: error == _unset ? this.error : error as String?,
      downloadProgress: downloadProgress == _unset
          ? this.downloadProgress
          : downloadProgress as double?,
      phase: phase ?? this.phase,
      downloadTaskId: downloadTaskId == _unset
          ? this.downloadTaskId
          : downloadTaskId as String?,
      downloadFilePath: downloadFilePath == _unset
          ? this.downloadFilePath
          : downloadFilePath as String?,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'isInitialized': isInitialized,
      'isLoading': isLoading,
      'isModelLoaded': isModelLoaded,
      'status': status,
      'error': error,
      'downloadProgress': downloadProgress,
      'phase': phase.name,
      'downloadTaskId': downloadTaskId,
      'downloadFilePath': downloadFilePath,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory ModelBootState.fromJson(Map<String, dynamic> json) {
    final phaseName = json['phase'] as String? ?? json['downloadPhase'] as String?;
    return ModelBootState(
      isInitialized: json['isInitialized'] as bool? ?? false,
      isLoading: json['isLoading'] as bool? ?? false,
      isModelLoaded: json['isModelLoaded'] as bool? ?? false,
      status: json['status'] as String? ?? 'Starting up...',
      error: json['error'] as String?,
      downloadProgress: (json['downloadProgress'] as num?)?.toDouble(),
      phase: ModelBootPhase.values.firstWhere(
        (value) => value.name == phaseName,
        orElse: () => ModelBootPhase.idle,
      ),
      downloadTaskId: json['downloadTaskId'] as String?,
      downloadFilePath: json['downloadFilePath'] as String?,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class ModelBootStateStore {
  static const String _fileName = 'model_boot_state.json';
  final File file;

  ModelBootStateStore(this.file);

  static Future<ModelBootStateStore> create() async {
    final supportDir = await getApplicationSupportDirectory();
    final storeDir = Directory('${supportDir.path}/picture_that');
    await storeDir.create(recursive: true);
    return ModelBootStateStore(File('${storeDir.path}/$_fileName'));
  }

  Future<ModelBootState?> read() async {
    try {
      if (!await file.exists()) {
        return null;
      }

      final contents = await file.readAsString();
      if (contents.trim().isEmpty) {
        return null;
      }

      final decoded = jsonDecode(contents);
      if (decoded is Map<String, dynamic>) {
        return ModelBootState.fromJson(decoded);
      }
    } catch (e) {
      debugPrint('Failed to read boot state: $e');
    }
    return null;
  }

  Future<void> write(ModelBootState state) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(state.toJson()));
  }

  Future<void> clear() async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}
