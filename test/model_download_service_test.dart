import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mero/services/model_boot_state.dart';
import 'package:mero/services/model_download_service.dart';

class MockModelDownloadBackend extends Mock implements ModelDownloadBackend {}

class TestModelDownloadService extends ModelDownloadService {
  TestModelDownloadService({
    required super.downloader,
    required super.modelUrl,
    required super.installModel,
    required super.tryActivateExistingModel,
  });

  @override
  Future<String?> fetchModelSize([String? url]) async => '1 MB';

  @override
  Future<String> getDownloadDestination({
    bool preferDownloadsFolder = false,
  }) async {
    return '/tmp/fallback-model.litertlm';
  }

  @override
  Future<DownloadTask> buildDownloadTask({
    String? customUrl,
    bool preferDownloadsFolder = false,
  }) async {
    return DownloadTask(
      taskId: downloadTaskIdValue,
      url: customUrl ?? modelUrl,
      filename: 'fallback-model.litertlm',
    );
  }

  @override
  Future<void> confirmDownload({
    String? customUrl,
    bool preferDownloadsFolder = false,
  }) async {
    updateState(
      state.copyWith(
        isInitialized: false,
        isLoading: true,
        isModelLoaded: false,
        status: 'Downloading model...',
        phase: ModelBootPhase.starting,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(
      DownloadTask(url: 'https://example.com/fallback', filename: 'fallback'),
    );
  });

  group('ModelDownloadService', () {
    late MockModelDownloadBackend backend;
    late ModelDownloadService service;

    setUp(() {
      backend = MockModelDownloadBackend();
      when(() => backend.updates).thenAnswer((_) => Stream<TaskUpdate>.empty());
      when(() => backend.configure()).thenAnswer((_) async {});
      when(() => backend.start()).thenAnswer((_) async {});
      when(() => backend.enqueue(any(that: isA<DownloadTask>())))
          .thenAnswer((_) async => true);
      when(() => backend.cancelTaskWithId(any()))
          .thenAnswer((_) async => true);

      service = TestModelDownloadService(
        downloader: backend,
        modelUrl: 'https://example.com/model.litertlm',
        installModel: (_) async {},
        tryActivateExistingModel: () async => false,
      );
    });

    test('updateState notifies listeners', () async {
      var notifyCount = 0;
      service.addListener(() {
        notifyCount++;
      });

      service.updateState(
        service.state.copyWith(
          isInitialized: true,
          isLoading: false,
          isModelLoaded: true,
          status: 'Ready',
          phase: ModelBootPhase.ready,
        ),
      );

      expect(service.isModelLoaded, true);
      expect(service.status, 'Ready');
      expect(notifyCount, 1);
    });

    test('confirmDownload enqueues custom url and enters starting phase',
        () async {
      service.updateState(
        service.state.copyWith(
          isInitialized: true,
          isLoading: false,
          isModelLoaded: false,
          status: 'Model download required',
          phase: ModelBootPhase.needsDownload,
        ),
      );

      await service.confirmDownload(
        customUrl: 'https://internal.example/model.litertlm',
      );

      expect(service.phase, ModelBootPhase.starting);
      expect(service.isLoading, true);
    });

    test('retryInitialization cancels the active task and resets state',
        () async {
      service.updateState(
        service.state.copyWith(
          isInitialized: false,
          isLoading: true,
          isModelLoaded: false,
          status: 'Download failed',
          error: 'Download failed',
          phase: ModelBootPhase.failed,
          downloadTaskId: 'task-123',
        ),
      );

      await service.retryInitialization();

      verify(() => backend.cancelTaskWithId('task-123')).called(1);
      expect(service.phase, ModelBootPhase.needsDownload);
      expect(service.status, 'Model download required');
      expect(service.isLoading, false);
    });
  });
}
