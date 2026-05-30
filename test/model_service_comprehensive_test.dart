import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mero/services/model_boot_state.dart';
import 'package:mero/services/model_download_service.dart';
import 'package:mero/services/model_service.dart';

// Mocks
class MockModelDownloadBackend extends Mock implements ModelDownloadBackend {}

class MockModelRuntime extends Mock implements ModelRuntime {}

class MockModelBootStateStore extends Mock implements ModelBootStateStore {}

class MockInferenceModel extends Mock implements InferenceModel {
  @override
  Future<void> close() async {}
}

// Stub class for mocktail's any() matcher
class StubDownloadTask extends Fake {
  String get taskId => '';
  String get url => '';
  String get filename => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelService', () {
    late MockModelDownloadBackend mockDownloader;
    late MockModelRuntime mockRuntime;
    late MockModelBootStateStore mockStore;
    late ModelService modelService;

    setUp(() {
      mockDownloader = MockModelDownloadBackend();
      mockRuntime = MockModelRuntime();
      mockStore = MockModelBootStateStore();

      registerFallbackValue(StubDownloadTask());
    });

    tearDown(() {
      modelService.dispose();
    });

    group('bootstrap flow', () {
      test('enters needsDownload state when no model exists', () async {
        when(() => mockStore.read()).thenAnswer((_) async => null);
        when(() => mockDownloader.updates).thenAnswer(
          (_) => Stream<TaskUpdate>.empty(),
        );
        when(() => mockDownloader.configure()).thenAnswer((_) async {});
        when(() => mockDownloader.start()).thenAnswer((_) async {});
        when(() => mockRuntime.getActiveModel(maxTokens: any(named: 'maxTokens')))
            .thenThrow(Exception('No model installed'));

        final phases = <ModelBootPhase>[];
        modelService = ModelService(
          downloader: mockDownloader,
          runtime: mockRuntime,
          stateStore: mockStore,
          autoInitialize: false,
        );
        modelService.addListener(() => phases.add(modelService.phase));

        await modelService.bootstrapForTest();
        await Future.delayed(const Duration(milliseconds: 100));

        expect(phases.last, ModelBootPhase.needsDownload);
        expect(modelService.isInitialized, true);
        expect(modelService.isLoading, false);
        expect(modelService.isModelLoaded, false);
        expect(modelService.status, 'Model download required');
      });

      test('skips to ready when model already exists', () async {
        final mockModel = MockInferenceModel();
        when(() => mockStore.read()).thenAnswer((_) async => null);
        when(() => mockDownloader.updates).thenAnswer(
          (_) => Stream<TaskUpdate>.empty(),
        );
        when(() => mockDownloader.configure()).thenAnswer((_) async {});
        when(() => mockDownloader.start()).thenAnswer((_) async {});
        when(() => mockRuntime.getActiveModel(maxTokens: any(named: 'maxTokens')))
            .thenAnswer((_) async => mockModel);

        final phases = <ModelBootPhase>[];
        modelService = ModelService(
          downloader: mockDownloader,
          runtime: mockRuntime,
          stateStore: mockStore,
          autoInitialize: false,
        );
        modelService.addListener(() => phases.add(modelService.phase));

        await modelService.bootstrapForTest();
        await Future.delayed(const Duration(milliseconds: 100));

        expect(phases.last, ModelBootPhase.ready);
        expect(modelService.isModelLoaded, true);
      });
    });

    group('confirmDownload', () {
      test('transitions from needsDownload to starting', () async {
        when(() => mockStore.read()).thenAnswer((_) async => null);
        when(() => mockDownloader.updates).thenAnswer(
          (_) => Stream<TaskUpdate>.empty(),
        );
        when(() => mockDownloader.configure()).thenAnswer((_) async {});
        when(() => mockDownloader.start()).thenAnswer((_) async {});
        when(() => mockRuntime.getActiveModel(maxTokens: any(named: 'maxTokens')))
            .thenThrow(Exception('No model installed'));
        when(() => mockDownloader.enqueue(any(that: isA<DownloadTask>()))).thenAnswer((_) async => true);

        final phases = <ModelBootPhase>[];
        modelService = ModelService(
          downloader: mockDownloader,
          runtime: mockRuntime,
          stateStore: mockStore,
          autoInitialize: false,
        );
        modelService.addListener(() => phases.add(modelService.phase));

        await modelService.bootstrapForTest();
        await Future.delayed(const Duration(milliseconds: 100));

        expect(modelService.phase, ModelBootPhase.needsDownload);

        await modelService.confirmDownload();

        expect(phases.last, ModelBootPhase.starting);
        expect(modelService.isLoading, true);
      });

      test('accepts custom URL and passes to download task', () async {
        const customUrl = 'https://internal-server.com/model.litertlm';

        when(() => mockStore.read()).thenAnswer((_) async => null);
        when(() => mockDownloader.updates).thenAnswer(
          (_) => Stream<TaskUpdate>.empty(),
        );
        when(() => mockDownloader.configure()).thenAnswer((_) async {});
        when(() => mockDownloader.start()).thenAnswer((_) async {});
        when(() => mockRuntime.getActiveModel(maxTokens: any(named: 'maxTokens')))
            .thenThrow(Exception('No model installed'));
        when(() => mockDownloader.enqueue(any(that: isA<DownloadTask>()))).thenAnswer((_) async => true);

        modelService = ModelService(
          downloader: mockDownloader,
          runtime: mockRuntime,
          stateStore: mockStore,
          autoInitialize: false,
        );

        await modelService.bootstrapForTest();
        await Future.delayed(const Duration(milliseconds: 100));

        await modelService.confirmDownload(customUrl: customUrl);

        final captured = verify(() => mockDownloader.enqueue(captureAny())).captured;
        final task = captured.first as DownloadTask;
        expect(task.url, customUrl);
      });
    });

    group('fetchModelSize', () {
      test('method exists and is callable', () async {
        // Note: Actual HTTP testing would require mocking HttpClient
        // This test verifies the method signature and graceful error handling

        when(() => mockStore.read()).thenAnswer((_) async => null);
        when(() => mockDownloader.updates).thenAnswer(
          (_) => Stream<TaskUpdate>.empty(),
        );
        when(() => mockDownloader.configure()).thenAnswer((_) async {});
        when(() => mockDownloader.start()).thenAnswer((_) async {});
        when(() => mockRuntime.getActiveModel(maxTokens: any(named: 'maxTokens')))
            .thenThrow(Exception('No model installed'));

        modelService = ModelService(
          downloader: mockDownloader,
          runtime: mockRuntime,
          stateStore: mockStore,
          autoInitialize: false,
        );

        // Method exists and returns null on network failure (graceful handling)
        final result = await modelService.fetchModelSize('https://invalid-url-for-testing.com');
        expect(result, isNull);
      });
    });

    group('resumed states', () {
      test('resumed paused state skips confirmation dialog', () async {
        final persistedState = ModelBootState(
          isInitialized: true,
          isLoading: false,
          isModelLoaded: false,
          status: 'Download paused',
          error: null,
          downloadProgress: 0.5,
          phase: ModelBootPhase.paused,
          downloadTaskId: 'test-task-id',
          downloadFilePath: '/tmp/model.litertlm',
          updatedAt: DateTime.now(),
        );

        when(() => mockStore.read()).thenAnswer((_) async => persistedState);
        when(() => mockDownloader.updates).thenAnswer(
          (_) => Stream<TaskUpdate>.empty(),
        );
        when(() => mockDownloader.configure()).thenAnswer((_) async {});
        when(() => mockDownloader.start()).thenAnswer((_) async {});
        when(() => mockRuntime.getActiveModel(maxTokens: any(named: 'maxTokens')))
            .thenThrow(Exception('No model installed'));
        when(() => mockDownloader.taskForId(any())).thenAnswer(
          (_) async => null,
        );
        when(() => mockDownloader.recordForId(any())).thenAnswer(
          (_) async => null,
        );

        final phases = <ModelBootPhase>[];
        modelService = ModelService(
          downloader: mockDownloader,
          runtime: mockRuntime,
          stateStore: mockStore,
          autoInitialize: false,
        );
        modelService.addListener(() => phases.add(modelService.phase));

        await modelService.bootstrapForTest();
        await Future.delayed(const Duration(milliseconds: 100));

        // Should restore to paused state, not needsDownload
        expect(phases.contains(ModelBootPhase.needsDownload), false);
        expect(phases.last, ModelBootPhase.paused);
      });
    });

    group('delegation', () {
      test('forwards listeners and state from the download service', () async {
        final downloadBackend = MockModelDownloadBackend();
        when(() => downloadBackend.updates).thenAnswer(
          (_) => Stream<TaskUpdate>.empty(),
        );
        when(() => downloadBackend.configure()).thenAnswer((_) async {});
        when(() => downloadBackend.start()).thenAnswer((_) async {});

        final downloadService = ModelDownloadService(
          downloader: downloadBackend,
          modelUrl:
              'https://example.com/model.litertlm',
          installModel: (_) async {},
          tryActivateExistingModel: () async => false,
        );

        modelService = ModelService(
          downloadService: downloadService,
          runtime: mockRuntime,
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

        await Future.delayed(const Duration(milliseconds: 10));

        expect(listenerCount, 1);
        expect(modelService.status, 'Model ready');
        expect(modelService.isModelLoaded, true);
      });
    });
  });
}
