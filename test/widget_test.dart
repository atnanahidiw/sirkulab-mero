import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mero/services/model_boot_state.dart';
import 'package:mero/services/model_download_service.dart';
import 'package:mero/services/model_service.dart';
import 'package:mero/widgets/startup_gate.dart';

void main() {
  testWidgets('startup gate shows splash and transitions to ready child',
      (WidgetTester tester) async {
    final downloadService = FakeModelDownloadService(
      isLoading: true,
      isModelLoaded: false,
      status: 'Downloading: 42%',
      downloadProgress: 0.42,
      phase: ModelBootPhase.downloading,
    );
    final service = ModelService(
      downloadService: downloadService,
      autoInitialize: false,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ModelService>.value(
        value: service,
        child: const MaterialApp(
          home: StartupGate(
            readyChild: Placeholder(key: Key('home-ready')),
          ),
        ),
      ),
    );

    expect(find.text('Downloading… 42%'), findsOneWidget);
    expect(find.byKey(const Key('home-ready')), findsNothing);

    downloadService.markReady();
    await tester.pump();

    expect(find.byKey(const Key('home-ready')), findsOneWidget);
  });

  testWidgets('retry button calls retryInitialization',
      (WidgetTester tester) async {
    final downloadService = FakeModelDownloadService(
      isLoading: false,
      isModelLoaded: false,
      status: 'Error: network failed',
      error: 'network failed',
      phase: ModelBootPhase.downloading,
    );
    final service = ModelService(
      downloadService: downloadService,
      autoInitialize: false,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ModelService>.value(
        value: service,
        child: const MaterialApp(
          home: StartupGate(
            readyChild: Placeholder(key: Key('home-ready')),
          ),
        ),
      ),
    );

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(downloadService.retryCount, 1);
    expect(downloadService.isLoading, true);
  });

  testWidgets('canceled download shows retry action',
      (WidgetTester tester) async {
    final downloadService = FakeModelDownloadService(
      isLoading: false,
      isModelLoaded: false,
      status: 'Download canceled',
      error: 'Download canceled',
      phase: ModelBootPhase.canceled,
    );
    final service = ModelService(
      downloadService: downloadService,
      autoInitialize: false,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ModelService>.value(
        value: service,
        child: const MaterialApp(
          home: StartupGate(
            readyChild: Placeholder(key: Key('home-ready')),
          ),
        ),
      ),
    );

    expect(find.text('Download canceled'), findsWidgets);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(downloadService.retryCount, 1);
    expect(downloadService.isLoading, true);
  });
}

class FakeModelDownloadService extends ModelDownloadService {
  FakeModelDownloadService({
    required bool isLoading,
    required bool isModelLoaded,
    required String status,
    String? error,
    double? downloadProgress,
    ModelBootPhase? phase,
  })  : _isLoading = isLoading,
        _isModelLoaded = isModelLoaded,
        _status = status,
        _error = error,
        _downloadProgress = downloadProgress,
        _phase = phase ?? ModelBootPhase.idle,
        super(
          modelUrl: 'https://example.com/model.litertlm',
          installModel: (_) async {},
          tryActivateExistingModel: () async => false,
          downloader: null,
          stateStore: null,
          speciesService: null,
        );

  final bool _isInitialized = false;
  bool _isLoading;
  bool _isModelLoaded;
  String _status;
  String? _error;
  double? _downloadProgress;
  ModelBootPhase _phase;

  int retryCount = 0;

  @override
  bool get isInitialized => _isInitialized;

  @override
  bool get isLoading => _isLoading;

  @override
  bool get isModelLoaded => _isModelLoaded;

  @override
  String get status => _status;

  @override
  String? get error => _error;

  @override
  double? get downloadProgress => _downloadProgress;

  @override
  ModelBootPhase get phase => _phase;

  @override
  Future<void> clearModel() async {}

  @override
  Future<void> downloadModel({void Function(double)? onProgress}) async {}

  @override
  Future<void> cancelDownload() async {}

  @override
  Future<void> resumeDownload() async {
    retryCount += 1;
    _isLoading = true;
    _error = null;
    _status = 'Resuming model download...';
    _phase = ModelBootPhase.resuming;
    notifyListeners();
  }

  @override
  Future<String> identifySpecies(
      Uint8List imageBytes, String imageFormat) async {
    return '';
  }

  @override
  Future<void> retryInitialization() async {
    retryCount += 1;
    _isLoading = true;
    _error = null;
    _status = 'Retrying model setup...';
    _phase = ModelBootPhase.starting;
    notifyListeners();
  }

  void markReady() {
    _isLoading = false;
    _isModelLoaded = true;
    _status = 'Model ready';
    _downloadProgress = null;
    _phase = ModelBootPhase.ready;
    notifyListeners();
  }
}
