import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mero/services/model_boot_state.dart';
import 'package:mero/services/model_download_service.dart';
import 'package:mero/services/model_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelService', () {
    test('delegates listening to the download service', () async {
      final downloadService = FakeModelDownloadService();
      final modelService = ModelService(
        downloadService: downloadService,
        autoInitialize: false,
      );

      var listenerCount = 0;
      modelService.addListener(() {
        listenerCount++;
      });

      downloadService.updateState(
        downloadService.state.copyWith(
          isInitialized: true,
          isLoading: false,
          isModelLoaded: true,
          status: 'Model ready',
          phase: ModelBootPhase.ready,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(listenerCount, 1);
      expect(modelService.status, 'Model ready');
      expect(modelService.isModelLoaded, true);
    });

    test('bootstrapForTest surfaces download-service state changes', () async {
      final downloadService = FakeModelDownloadService();
      final modelService = ModelService(
        downloadService: downloadService,
        autoInitialize: false,
      );

      await modelService.bootstrapForTest();

      expect(modelService.phase, ModelBootPhase.needsDownload);
      expect(modelService.isInitialized, true);
      expect(modelService.isLoading, false);
    });

    test('confirmDownload and retryInitialization delegate to download service',
        () async {
      final downloadService = FakeModelDownloadService();
      final modelService = ModelService(
        downloadService: downloadService,
        autoInitialize: false,
      );

      await modelService.confirmDownload(customUrl: 'https://example.com/model.litertlm');
      expect(modelService.phase, ModelBootPhase.starting);
      expect(downloadService.confirmCount, 1);

      await modelService.retryInitialization();
      expect(modelService.phase, ModelBootPhase.needsDownload);
      expect(downloadService.retryCount, 1);
    });

    test('clearModel delegates to the download service and resets the runtime',
        () async {
      final downloadService = FakeModelDownloadService();
      final modelService = ModelService(
        downloadService: downloadService,
        autoInitialize: false,
      );

      await modelService.clearModel();

      expect(downloadService.clearCount, 1);
      expect(modelService.phase, ModelBootPhase.idle);
      expect(modelService.isModelLoaded, false);
    });
  });
}

class FakeModelDownloadService extends ModelDownloadService {
  FakeModelDownloadService()
      : super(
          downloader: _FakeBackend(),
          modelUrl: 'https://example.com/model.litertlm',
          installModel: (_) async {},
          tryActivateExistingModel: () async => false,
        );

  int confirmCount = 0;
  int retryCount = 0;
  int clearCount = 0;

  @override
  Future<void> bootstrap({bool loadPersistedState = true}) async {
    updateState(
      state.copyWith(
        isInitialized: true,
        isLoading: false,
        isModelLoaded: false,
        status: 'Model download required',
        phase: ModelBootPhase.needsDownload,
      ),
    );
  }

  @override
  Future<void> confirmDownload({
    String? customUrl,
    bool preferDownloadsFolder = false,
  }) async {
    confirmCount += 1;
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

  @override
  Future<void> retryInitialization() async {
    retryCount += 1;
    updateState(
      state.copyWith(
        isInitialized: false,
        isLoading: false,
        isModelLoaded: false,
        status: 'Model download required',
        phase: ModelBootPhase.needsDownload,
      ),
    );
  }

  @override
  Future<void> clearModel() async {
    clearCount += 1;
    updateState(
      state.copyWith(
        isInitialized: false,
        isLoading: false,
        isModelLoaded: false,
        status: 'Model cleared',
        phase: ModelBootPhase.idle,
      ),
    );
  }
}

class _FakeBackend implements ModelDownloadBackend {
  @override
  Stream<TaskUpdate> get updates => const Stream<TaskUpdate>.empty();

  @override
  Future<void> configure() async {}

  @override
  Future<void> start() async {}

  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async =>
      const [];

  @override
  Future<Task?> taskForId(String taskId) async => null;

  @override
  Future<TaskRecord?> recordForId(String taskId) async => null;

  @override
  Future<bool> enqueue(DownloadTask task) async => true;

  @override
  Future<bool> pause(DownloadTask task) async => true;

  @override
  Future<bool> resume(DownloadTask task) async => true;

  @override
  Future<bool> cancelTaskWithId(String taskId) async => true;

  @override
  Future<bool> taskCanResume(Task task) async => false;

  @override
  Future<(List<Task>, List<Task>)> rescheduleKilledTasks() async =>
      (<Task>[], <Task>[]);
}
