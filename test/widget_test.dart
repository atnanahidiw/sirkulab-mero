import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mero/l10n/app_localizations.dart';
import 'package:mero/services/model_boot_state.dart';
import 'package:mero/services/model_service.dart';
import 'package:mero/widgets/startup_gate.dart';

void main() {
  testWidgets('startup gate shows splash while bootstrapping',
      (WidgetTester tester) async {
    final service = FakeModelService(
      isInitialized: false,
      isLoading: true,
      isModelLoaded: false,
      status: 'Downloading: 42%',
      downloadProgress: 0.42,
      phase: ModelBootPhase.downloading,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ModelService>.value(
        value: service,
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const StartupGate(
            readyChild: Placeholder(key: Key('home-ready')),
          ),
        ),
      ),
    );

    expect(find.text('Downloading… 42%'), findsOneWidget);
    expect(find.byKey(const Key('home-ready')), findsNothing);
  });

  testWidgets('startup gate shows ready child after 2 seconds',
      (WidgetTester tester) async {
    final service = FakeModelService(
      isInitialized: false,
      isLoading: false,
      isModelLoaded: false,
      status: 'Model download required',
      phase: ModelBootPhase.needsDownload,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ModelService>.value(
        value: service,
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const StartupGate(
            readyChild: Placeholder(key: Key('home-ready')),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('home-ready')), findsNothing);
    service.markInitialized();
    service.notifyListeners();
    await tester.pump();
    expect(find.byKey(const Key('home-ready')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('home-ready')), findsOneWidget);
  });
}

class FakeModelService extends ModelService {
  FakeModelService({
    required bool isInitialized,
    required bool isLoading,
    required bool isModelLoaded,
    required String status,
    String? error,
    double? downloadProgress,
    ModelBootPhase? phase,
  })  : _isInitialized = isInitialized,
        _isLoading = isLoading,
        _isModelLoaded = isModelLoaded,
        _status = status,
        _error = error,
        _downloadProgress = downloadProgress,
        _phase = phase ?? ModelBootPhase.idle,
        super(autoInitialize: false);

  bool _isInitialized;
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
    _isLoading = true;
    _error = null;
    _status = 'Retrying model setup...';
    _phase = ModelBootPhase.starting;
    notifyListeners();
  }

  void markInitialized() {
    _isInitialized = true;
    _isLoading = false;
    _isModelLoaded = true;
    _status = 'Model ready';
    _downloadProgress = null;
    _phase = ModelBootPhase.ready;
  }
}
