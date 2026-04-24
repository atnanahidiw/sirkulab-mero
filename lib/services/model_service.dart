import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_boot_state.dart';
import 'species_service.dart';

abstract class ModelDownloadBackend {
  Stream<TaskUpdate> get updates;

  Future<void> configure();

  Future<void> start();

  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  });

  Future<Task?> taskForId(String taskId);

  Future<TaskRecord?> recordForId(String taskId);

  Future<bool> enqueue(DownloadTask task);

  Future<bool> pause(DownloadTask task);

  Future<bool> resume(DownloadTask task);

  Future<bool> cancelTaskWithId(String taskId);

  Future<bool> taskCanResume(Task task);

  Future<(List<Task>, List<Task>)> rescheduleKilledTasks();
}

class BackgroundModelDownloadBackend implements ModelDownloadBackend {
  bool _configured = false;
  bool _started = false;

  @override
  Stream<TaskUpdate> get updates => FileDownloader().updates;

  @override
  Future<void> configure() async {
    if (_configured) {
      return;
    }

    await FileDownloader().configure(
      androidConfig: const [
        (Config.useCacheDir, Config.never),
        (Config.runInForegroundIfFileLargerThan, 500),
      ],
    );

    FileDownloader().configureNotification(
      running: const TaskNotification(
        'Downloading model',
        'Picture That is downloading {filename}',
      ),
      paused: const TaskNotification(
        'Download paused',
        'Picture That will resume automatically.',
      ),
      complete: const TaskNotification(
        'Model ready',
        'The Gemma model is ready to use.',
      ),
      error: const TaskNotification(
        'Download failed',
        'Picture That could not finish downloading the model.',
      ),
      canceled: const TaskNotification(
        'Download canceled',
        'The Gemma model download was canceled.',
      ),
      progressBar: true,
      tapOpensFile: false,
    );

    _configured = true;
  }

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }

    await FileDownloader().start();
    _started = true;
  }

  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) {
    return FileDownloader().allTasks(
      group: group,
      includeTasksWaitingToRetry: includeTasksWaitingToRetry,
      allGroups: allGroups,
    );
  }

  @override
  Future<Task?> taskForId(String taskId) => FileDownloader().taskForId(taskId);

  @override
  Future<TaskRecord?> recordForId(String taskId) =>
      FileDownloader().database.recordForId(taskId);

  @override
  Future<bool> enqueue(DownloadTask task) => FileDownloader().enqueue(task);

  @override
  Future<bool> pause(DownloadTask task) => FileDownloader().pause(task);

  @override
  Future<bool> resume(DownloadTask task) => FileDownloader().resume(task);

  @override
  Future<bool> cancelTaskWithId(String taskId) =>
      FileDownloader().cancelTaskWithId(taskId);

  @override
  Future<bool> taskCanResume(Task task) => FileDownloader().taskCanResume(task);

  @override
  Future<(List<Task>, List<Task>)> rescheduleKilledTasks() =>
      FileDownloader().rescheduleKilledTasks();
}

abstract class ModelRuntime {
  Future<InferenceModel> getActiveModel({
    required int maxTokens,
  });

  Future<void> installFromFile(String filePath);
}

class FlutterGemmaModelRuntime implements ModelRuntime {
  final ModelType modelType;

  FlutterGemmaModelRuntime({
    required this.modelType,
  });

  @override
  Future<InferenceModel> getActiveModel({required int maxTokens}) {
    return FlutterGemma.getActiveModel(
      maxTokens: maxTokens,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      maxNumImages: 1,
    );
  }

  @override
  Future<void> installFromFile(String filePath) async {
    await FlutterGemma.installModel(modelType: modelType)
        .fromFile(filePath)
        .install();
  }
}

class ModelService extends ChangeNotifier {
  static const String _downloadGroup = 'picture_that_model_downloads';
  static const String _downloadTaskId = 'picture_that_gemma_model';
  static const String _downloadDirectory = 'models';
  static const String _downloadFileName = 'gemma-4-E2B-it.litertlm';

  final ModelDownloadBackend _downloader;
  final ModelRuntime _runtime;
  final ModelBootStateStore? _stateStoreOverride;

  bool _isBootstrapping = false;
  bool _isDownloading = false;
  bool _speciesLoaded = false;
  bool _downloaderConfigured = false;

  ModelBootState _state = ModelBootState.initial();
  ModelBootStateStore? _stateStore;
  InferenceModel? _model;
  StreamSubscription<TaskUpdate>? _downloadUpdatesSubscription;

  // Model configuration - Gemma 4 2B Instruct (quantized)
  final String modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
  final ModelType modelType = ModelType.gemmaIt;
  final int maxTokens = 1024;

  // Species database
  final SpeciesService _speciesService = SpeciesService();
  List<Species> _speciesList = [];

  ModelService({
    ModelDownloadBackend? downloader,
    ModelRuntime? runtime,
    ModelBootStateStore? stateStore,
    bool autoInitialize = true,
  })  : _downloader = downloader ?? BackgroundModelDownloadBackend(),
        _runtime = runtime ??
            FlutterGemmaModelRuntime(
              modelType: ModelType.gemmaIt,
            ),
        _stateStoreOverride = stateStore {
    if (autoInitialize) {
      unawaited(_bootstrap());
    }
  }

  bool get isInitialized => _state.isInitialized;

  bool get isLoading => _state.isLoading;

  bool get isModelLoaded => _state.isModelLoaded;

  String get status => _state.status;

  String? get error => _state.error;

  double? get downloadProgress => _state.downloadProgress;

  ModelBootPhase get phase => _state.phase;

  String? get downloadTaskId => _state.downloadTaskId;

  String? get downloadFilePath => _state.downloadFilePath;

  String? get downloadPhase => _state.downloadPhase;

  InferenceModel? get model => _model;

  Future<InferenceModel> _getActiveVisionModel() {
    return _runtime.getActiveModel(maxTokens: maxTokens);
  }

  Future<ModelBootStateStore> _resolveStateStore() async {
    return _stateStoreOverride ?? await ModelBootStateStore.create();
  }

  Future<void> _ensureDownloaderReady() async {
    _downloadUpdatesSubscription ??= _downloader.updates.listen(
      _handleDownloadUpdate,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Model download update stream error: $error');
      },
    );

    if (!_downloaderConfigured) {
      await _downloader.configure();
      await _downloader.start();
      _downloaderConfigured = true;
    }
  }

  Future<String> _resolveDownloadFilePath() async {
    final supportDir = await getApplicationSupportDirectory();
    return p.join(
      supportDir.path,
      'picture_that',
      _downloadDirectory,
      _downloadFileName,
    );
  }

  Future<DownloadTask> _buildDownloadTask() async {
    final supportDir = await getApplicationSupportDirectory();
    final modelDir = Directory(p.join(
      supportDir.path,
      'picture_that',
      _downloadDirectory,
    ));
    await modelDir.create(recursive: true);

    final (baseDirectory, directory, filename) = await Task.split(
      filePath: p.join(modelDir.path, _downloadFileName),
    );

    return DownloadTask(
      taskId: _downloadTaskId,
      url: modelUrl,
      group: _downloadGroup,
      headers: const {
        'Connection': 'keep-alive',
        'Cache-Control': 'no-cache, no-store',
        'Pragma': 'no-cache',
      },
      baseDirectory: baseDirectory,
      directory: directory,
      filename: filename,
      requiresWiFi: false,
      allowPause: true,
      priority: 0,
      retries: 0,
      updates: Updates.statusAndProgress,
    );
  }

  Future<bool> _isDownloadedModelPresent([String? filePath]) async {
    final resolvedPath = filePath ?? await _resolveDownloadFilePath();
    return File(resolvedPath).exists();
  }

  Future<void> _installDownloadedModel(String filePath) async {
    _commitState(
      _state.copyWith(
        isInitialized: false,
        isLoading: true,
        isModelLoaded: false,
        status: 'Installing downloaded model...',
        phase: ModelBootPhase.installing,
        downloadFilePath: filePath,
      ),
    );

    await _runtime.installFromFile(filePath);
    _model = await _getActiveVisionModel();
    await _markReady(status: 'Model ready');
  }

  Future<void> _handleDownloadUpdate(TaskUpdate update) async {
    if (update.task.taskId != _downloadTaskId) {
      return;
    }

    switch (update) {
      case TaskProgressUpdate(:final progress):
        final percent = (progress * 100).round().clamp(0, 100);
        final phase = _state.phase == ModelBootPhase.resuming
            ? ModelBootPhase.resuming
            : ModelBootPhase.downloading;

        _commitState(
          _state.copyWith(
            isInitialized: false,
            isLoading: true,
            isModelLoaded: false,
            status: phase == ModelBootPhase.resuming
                ? 'Resumed download: $percent%'
                : 'Downloading: $percent%',
            phase: phase,
            downloadProgress: progress.clamp(0.0, 1.0).toDouble(),
            error: null,
            downloadTaskId: update.task.taskId,
            downloadFilePath: await update.task.filePath(),
          ),
        );
        break;

      case TaskStatusUpdate(:final status, :final exception, :final responseStatusCode):
        final taskPath = await update.task.filePath();
        switch (status) {
          case TaskStatus.enqueued:
            _commitState(
              _state.copyWith(
                isInitialized: false,
                isLoading: true,
                isModelLoaded: false,
                status: _state.phase == ModelBootPhase.resuming
                    ? 'Resuming model download...'
                    : 'Starting model download...',
                phase: _state.phase == ModelBootPhase.resuming
                    ? ModelBootPhase.resuming
                    : ModelBootPhase.starting,
                error: null,
                downloadTaskId: update.task.taskId,
                downloadFilePath: taskPath,
              ),
            );
            break;

          case TaskStatus.running:
            _commitState(
              _state.copyWith(
                isInitialized: false,
                isLoading: true,
                isModelLoaded: false,
                status: _state.phase == ModelBootPhase.resuming
                    ? 'Resumed model download...'
                    : 'Downloading model...',
                phase: _state.phase == ModelBootPhase.resuming
                    ? ModelBootPhase.resuming
                    : ModelBootPhase.downloading,
                error: null,
                downloadTaskId: update.task.taskId,
                downloadFilePath: taskPath,
              ),
            );
            break;

          case TaskStatus.paused:
            _commitState(
              _state.copyWith(
                isInitialized: false,
                isLoading: true,
                isModelLoaded: false,
                status: 'Download paused',
                phase: ModelBootPhase.paused,
                error: null,
                downloadTaskId: update.task.taskId,
                downloadFilePath: taskPath,
              ),
            );
            break;

          case TaskStatus.waitingToRetry:
            _commitState(
              _state.copyWith(
                isInitialized: false,
                isLoading: true,
                isModelLoaded: false,
                status: 'Waiting to retry model download...',
                phase: ModelBootPhase.resuming,
                error: null,
                downloadTaskId: update.task.taskId,
                downloadFilePath: taskPath,
              ),
            );
            break;

          case TaskStatus.complete:
            if (taskPath.isNotEmpty && await File(taskPath).exists()) {
              await _installDownloadedModel(taskPath);
            } else {
              await _markError(
                'Model download finished, but the file was not found.',
                phase: ModelBootPhase.failed,
              );
            }
            break;

          case TaskStatus.failed:
            final message = exception?.description ??
                'Background download failed${responseStatusCode == null ? '' : ' (HTTP $responseStatusCode)'}';
            await _markError(message, phase: ModelBootPhase.failed);
            break;

          case TaskStatus.notFound:
            await _markError('Model file not found on server.', phase: ModelBootPhase.failed);
            break;

          case TaskStatus.canceled:
            _commitState(
              _state.copyWith(
                isInitialized: false,
                isLoading: false,
                isModelLoaded: false,
                status: 'Download canceled',
                phase: ModelBootPhase.canceled,
                error: 'Download canceled',
                downloadProgress: null,
                downloadTaskId: null,
                downloadFilePath: null,
              ),
            );
            break;
        }
        break;
    }
  }

  void _commitState(ModelBootState nextState) {
    _state = nextState.copyWith(updatedAt: DateTime.now());
    notifyListeners();
    unawaited(_persistState());
  }

  Future<void> _persistState() async {
    final store = _stateStore;
    if (store == null) {
      return;
    }

    try {
      await store.write(_state);
    } catch (e) {
      debugPrint('Failed to persist model boot state: $e');
    }
  }

  Future<void> _bootstrap({bool loadPersistedState = true}) async {
    if (_isBootstrapping) {
      return;
    }

    _isBootstrapping = true;

    try {
      _stateStore ??= await _resolveStateStore();
      await _ensureDownloaderReady();

      if (loadPersistedState) {
        final persisted = await _stateStore!.read();
        _state = persisted?.copyWith(
              isLoading: persisted.isModelLoaded ? false : persisted.isLoading,
              isInitialized: persisted.isInitialized,
              updatedAt: persisted.updatedAt,
            ) ??
            ModelBootState.initial();
        notifyListeners();
      } else {
        _commitState(
          _state.copyWith(
            isInitialized: false,
            isLoading: true,
            isModelLoaded: false,
            error: null,
            status: 'Retrying model setup...',
            phase: ModelBootPhase.starting,
            downloadProgress: null,
            downloadTaskId: null,
          ),
        );
      }

      await _loadSpeciesData();

      await _reconcileStartupState();
    } catch (e) {
      await _markError(
        'Initialization failed: $e',
        phase: ModelBootPhase.failed,
      );
    } finally {
      _isBootstrapping = false;
    }
  }

  Future<void> _reconcileStartupState() async {
    final activeModel = await _tryActivateExistingModel();
    if (activeModel) {
      return;
    }

    final filePath = _state.downloadFilePath ?? await _resolveDownloadFilePath();
    final fileExists = await _isDownloadedModelPresent(filePath);
    if (fileExists) {
      await _installDownloadedModel(filePath);
      return;
    }

    final taskId = _state.downloadTaskId ?? _downloadTaskId;
    final activeTask = await _downloader.taskForId(taskId);
    final record = await _downloader.recordForId(taskId);

    if (activeTask != null) {
      await _syncFromTask(activeTask, record, filePath);
      return;
    }

    if (record != null) {
      await _syncFromRecord(record, filePath);
      return;
    }

    final legacyModelPath = await _checkForLocalModel();
    if (legacyModelPath != null) {
      await _commitLocalModel(legacyModelPath);
      return;
    }

    if (_state.phase == ModelBootPhase.failed) {
      _commitState(
        _state.copyWith(
          isInitialized: true,
          isLoading: false,
          isModelLoaded: false,
          phase: ModelBootPhase.failed,
          status: _state.error ?? 'Model download failed',
        ),
      );
      return;
    }

    if (_state.phase == ModelBootPhase.canceled) {
      _commitState(
        _state.copyWith(
          isInitialized: true,
          isLoading: false,
          isModelLoaded: false,
          status: 'Download canceled',
          error: 'Download canceled',
          phase: ModelBootPhase.canceled,
        ),
      );
      return;
    }

    await _startModelDownload(resumed: _state.phase == ModelBootPhase.paused);
  }

  Future<bool> _tryActivateExistingModel() async {
    try {
      _model = await _getActiveVisionModel();
      await _markReady(status: 'Model ready');
      return true;
    } catch (e) {
      debugPrint('No active model found: $e');
      return false;
    }
  }

  Future<void> _syncFromTask(
    Task task,
    TaskRecord? record,
    String filePath,
  ) async {
    final taskStatus = record?.status;
    switch (taskStatus) {
      case TaskStatus.paused:
        _commitState(
          _state.copyWith(
            isInitialized: false,
            isLoading: true,
            isModelLoaded: false,
            status: 'Download paused',
            phase: ModelBootPhase.paused,
            downloadTaskId: task.taskId,
            downloadFilePath: filePath,
            downloadProgress: record?.progress == null || record!.progress < 0
                ? _state.downloadProgress
                : record.progress,
          ),
        );
        return;
      case TaskStatus.running:
      case TaskStatus.enqueued:
      case TaskStatus.waitingToRetry:
        _commitState(
          _state.copyWith(
            isInitialized: false,
            isLoading: true,
            isModelLoaded: false,
            status: taskStatus == TaskStatus.waitingToRetry
                ? 'Waiting to retry model download...'
                : 'Resuming model download...',
            phase: ModelBootPhase.resuming,
            downloadTaskId: task.taskId,
            downloadFilePath: filePath,
            downloadProgress: record?.progress == null || record!.progress < 0
                ? _state.downloadProgress
                : record.progress,
          ),
        );
        await _downloader.rescheduleKilledTasks();
        return;
      case TaskStatus.complete:
        if (await File(filePath).exists()) {
          await _installDownloadedModel(filePath);
          return;
        }
        break;
      case TaskStatus.failed:
      case TaskStatus.notFound:
        await _markError(
          record?.exception?.description ?? 'Background download failed.',
          phase: ModelBootPhase.failed,
        );
        return;
      case TaskStatus.canceled:
        _commitState(
          _state.copyWith(
            isInitialized: true,
            isLoading: false,
            isModelLoaded: false,
            status: 'Download canceled',
            phase: ModelBootPhase.canceled,
            error: 'Download canceled',
            downloadTaskId: null,
            downloadFilePath: filePath,
            downloadProgress: null,
          ),
        );
        return;
      case null:
        _commitState(
          _state.copyWith(
            isInitialized: false,
            isLoading: true,
            isModelLoaded: false,
            status: 'Continuing model download...',
            phase: ModelBootPhase.downloading,
            downloadTaskId: task.taskId,
            downloadFilePath: filePath,
          ),
        );
        return;
    }

    await _startModelDownload(resumed: false);
  }

  Future<void> _syncFromRecord(TaskRecord record, String filePath) async {
    switch (record.status) {
      case TaskStatus.paused:
        _commitState(
          _state.copyWith(
            isInitialized: false,
            isLoading: true,
            isModelLoaded: false,
            status: 'Download paused',
            phase: ModelBootPhase.paused,
            downloadTaskId: record.taskId,
            downloadFilePath: filePath,
            downloadProgress: record.progress < 0 ? null : record.progress,
          ),
        );
        return;
      case TaskStatus.running:
      case TaskStatus.enqueued:
      case TaskStatus.waitingToRetry:
        _commitState(
          _state.copyWith(
            isInitialized: false,
            isLoading: true,
            isModelLoaded: false,
            status: record.status == TaskStatus.waitingToRetry
                ? 'Waiting to retry model download...'
                : 'Resuming model download...',
            phase: ModelBootPhase.resuming,
            downloadTaskId: record.taskId,
            downloadFilePath: filePath,
            downloadProgress: record.progress < 0 ? null : record.progress,
          ),
        );
        await _downloader.rescheduleKilledTasks();
        return;
      case TaskStatus.complete:
        if (await File(filePath).exists()) {
          await _installDownloadedModel(filePath);
          return;
        }
        break;
      case TaskStatus.failed:
      case TaskStatus.notFound:
        await _markError(
          record.exception?.description ?? 'Background download failed.',
          phase: ModelBootPhase.failed,
        );
        return;
      case TaskStatus.canceled:
        _commitState(
          _state.copyWith(
            isInitialized: true,
            isLoading: false,
            isModelLoaded: false,
            status: 'Download canceled',
            phase: ModelBootPhase.canceled,
            error: 'Download canceled',
            downloadTaskId: null,
            downloadFilePath: filePath,
            downloadProgress: null,
          ),
        );
        return;
    }

    await _startModelDownload(resumed: false);
  }

  Future<void> _commitLocalModel(String filePath) async {
    _commitState(
      _state.copyWith(
        isInitialized: false,
        isLoading: true,
        isModelLoaded: false,
        error: null,
        status: 'Installing existing model...',
        phase: ModelBootPhase.installing,
        downloadFilePath: filePath,
      ),
    );

    await _runtime.installFromFile(filePath);
    _model = await _getActiveVisionModel();
    await _markReady(status: 'Model ready');
  }

  Future<void> _loadSpeciesData() async {
    if (_speciesLoaded) {
      return;
    }

    try {
      final speciesList = await _speciesService.loadSpecies();
      _speciesList = speciesList;
      _speciesLoaded = true;
      debugPrint('Loaded ${_speciesList.length} species');
    } catch (e) {
      debugPrint('Failed to load species data: $e');
    }
  }

  Future<void> _markReady({required String status}) async {
    _commitState(
      _state.copyWith(
        isInitialized: true,
        isLoading: false,
        isModelLoaded: true,
        status: status,
        error: null,
        downloadProgress: null,
        phase: ModelBootPhase.ready,
      ),
    );
  }

  Future<void> _markError(
    String message, {
    ModelBootPhase? phase,
  }) async {
    _commitState(
      _state.copyWith(
        isInitialized: true,
        isLoading: false,
        isModelLoaded: false,
        status: 'Error: $message',
        error: message,
        phase: phase ?? ModelBootPhase.failed,
      ),
    );
  }

  Future<void> retryInitialization() async {
    if (_isBootstrapping) {
      return;
    }

    await cancelDownload();

    _commitState(
      _state.copyWith(
        isInitialized: false,
        isLoading: true,
        isModelLoaded: false,
        error: null,
        status: 'Retrying model setup...',
        phase: ModelBootPhase.starting,
        downloadProgress: null,
      ),
    );

    await downloadModel();
  }

  Future<void> cancelDownload() async {
    final taskId = _state.downloadTaskId;
    if (taskId != null) {
      try {
        await _downloader.cancelTaskWithId(taskId);
      } catch (e) {
        debugPrint('Failed to cancel model download: $e');
      }
    }

    _isDownloading = false;
    _commitState(
      _state.copyWith(
        isInitialized: false,
        isLoading: false,
        isModelLoaded: false,
        status: 'Download canceled',
        error: 'Download canceled',
        downloadProgress: null,
        phase: ModelBootPhase.canceled,
        downloadTaskId: null,
        downloadFilePath: null,
      ),
    );
  }

  Future<void> resumeDownload() async {
    if (_state.isModelLoaded) {
      return;
    }

    await _ensureDownloaderReady();
    final taskId = _state.downloadTaskId ?? _downloadTaskId;
    final task = await _downloader.taskForId(taskId);
    if (task is DownloadTask && await _downloader.resume(task)) {
      _commitState(
        _state.copyWith(
          isInitialized: false,
          isLoading: true,
          isModelLoaded: false,
          status: 'Resuming model download...',
          phase: ModelBootPhase.resuming,
        ),
      );
      return;
    }

    await _startModelDownload(resumed: true);
  }

  Future<void> _startModelDownload({required bool resumed}) async {
    if (_isDownloading || _state.isModelLoaded) {
      return;
    }

    _isDownloading = true;
    try {
      final task = await _buildDownloadTask();
      final filePath = await task.filePath();
      _commitState(
        _state.copyWith(
          isInitialized: false,
          isLoading: true,
          isModelLoaded: false,
          error: null,
          status: resumed
              ? 'Resuming model download...'
              : 'Starting model download...',
          phase: resumed ? ModelBootPhase.resuming : ModelBootPhase.starting,
          downloadTaskId: task.taskId,
          downloadFilePath: filePath,
          downloadProgress: _state.downloadProgress,
        ),
      );

      final enqueued = await _downloader.enqueue(task);
      if (!enqueued) {
        throw Exception('Unable to enqueue model download task');
      }
    } catch (e) {
      await _markError(
        'Failed to start model download: $e',
        phase: ModelBootPhase.failed,
      );
    } finally {
      _isDownloading = false;
    }
  }

  Future<void> downloadModel({void Function(double)? onProgress}) async {
    if (_state.isModelLoaded || _isBootstrapping) {
      return;
    }

    await _ensureDownloaderReady();

    final filePath = await _resolveDownloadFilePath();
    if (await _isDownloadedModelPresent(filePath)) {
      await _installDownloadedModel(filePath);
      return;
    }

    final activeTask = await _downloader.taskForId(_downloadTaskId);
    if (activeTask != null) {
      final record = await _downloader.recordForId(_downloadTaskId);
      if (activeTask is DownloadTask && record?.status == TaskStatus.paused) {
        await _downloader.resume(activeTask);
      }
      return;
    }

    await _startModelDownload(resumed: _state.phase == ModelBootPhase.paused);
  }

  Future<String?> _checkForLocalModel() async {
    try {
      final List<String> searchPaths = [];

      // 1. Downloads directory
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          searchPaths.add(downloadsDir.path);
        }
      } catch (e) {
        debugPrint('Could not get downloads directory: $e');
      }

      // 2. Common Android download path
      searchPaths.add('/storage/emulated/0/Download');

      // 3. AI Edge Gallery paths
      searchPaths.add('/Android/media/com.google.ai.gallery/files/');
      searchPaths.add(
        '/storage/emulated/0/Android/media/com.google.ai.gallery/files/',
      );

      // 4. App-specific documents directory
      try {
        final appDocDir = await getApplicationDocumentsDirectory();
        searchPaths.add(appDocDir.path);
      } catch (e) {
        debugPrint('Could not get app documents directory: $e');
      }

      for (final basePath in searchPaths) {
        try {
          final directory = Directory(basePath);
          if (await directory.exists()) {
            final files = await directory.list(recursive: false).toList();
            for (final file in files) {
              if (file is File &&
                  file.path.endsWith('.litertlm') &&
                  file.path.toLowerCase().contains('gemma')) {
                debugPrint('Found local model at: ${file.path}');
                return file.path;
              }
            }
          }
        } catch (e) {
          debugPrint('Error searching path $basePath: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('Error checking local model: $e');
    }
    return null;
  }

  static Uint8List _compressImageIsolate(Uint8List imageBytes) {
    try {
      final img.Image? originalImage = img.decodeImage(imageBytes);
      if (originalImage == null) {
        return imageBytes;
      }

      int? targetWidth;
      int? targetHeight;
      if (originalImage.width > originalImage.height) {
        targetWidth = 800;
      } else {
        targetHeight = 800;
      }

      final img.Image resizedImage = img.copyResize(
        originalImage,
        width: targetWidth,
        height: targetHeight,
      );

      return Uint8List.fromList(img.encodeJpg(resizedImage, quality: 85));
    } catch (e) {
      return imageBytes;
    }
  }

  /// Compress and resize image to prevent OOM errors and avoid blocking UI
  Future<Uint8List> _compressImage(Uint8List imageBytes) async {
    debugPrint('Original image size: ${imageBytes.length} bytes');
    final compressedBytes = await compute(_compressImageIsolate, imageBytes);
    debugPrint('Compressed image size: ${compressedBytes.length} bytes');
    return compressedBytes;
  }

  Future<String> identifySpecies(
    Uint8List imageBytes,
    String imageFormat,
  ) async {
    if (_model == null) {
      throw Exception('Model not loaded. Please wait for model to download.');
    }

    try {
      _commitState(
        _state.copyWith(
          status: 'Analyzing image...',
          phase: ModelBootPhase.analyzing,
        ),
      );

      // Compress image before processing
      final compressedBytes = await _compressImage(imageBytes);

      final speciesNames = _speciesList.map((s) => s.name).toList();
      final speciesListString = speciesNames.isNotEmpty
          ? speciesNames.join(', ')
          : 'endangered Indonesian species';

      final session = await _model!.createSession(
        enableVisionModality: true,
        systemInstruction: '''
You are an expert wildlife biologist specializing in endangered Indonesian species identification.
Your task is to analyze images and identify if they contain endangered species from the following list:
$speciesListString.

If the species is in the list, respond with ONLY the exact common name as shown in the list.
If the species is not in the list or you are unsure, respond with "Not recognized".
Do not add any additional text, explanations, or formatting.
''',
      );

      await session.addQueryChunk(Message.withImage(
        text: 'Identify the endangered Indonesian species in this image.',
        imageBytes: compressedBytes,
        isUser: true,
      ));

      _commitState(
        _state.copyWith(
          status: 'Generating analysis...',
          phase: ModelBootPhase.analyzing,
        ),
      );

      final response = await session.getResponse();
      final cleanedResponse = response.trim();

      _commitState(
        _state.copyWith(
          status: 'Analysis complete',
          phase: ModelBootPhase.ready,
        ),
      );

      Species? matchedSpecies;
      for (final species in _speciesList) {
        if (cleanedResponse.toLowerCase().contains(species.name.toLowerCase())) {
          matchedSpecies = species;
          break;
        }
      }

      if (matchedSpecies != null) {
        return matchedSpecies.name;
      }

      if (!cleanedResponse.toLowerCase().contains('not recognized')) {
        return cleanedResponse;
      }

      return '';
    } catch (e) {
      final errorMessage = 'Identification failed: $e';
      await _markError(errorMessage, phase: ModelBootPhase.failed);
      rethrow;
    }
  }

  Future<void> clearModel() async {
    if (_model != null) {
      await _model!.close();
      _model = null;
    }

    await cancelDownload();
    await _stateStore?.clear();

    _commitState(
      _state.copyWith(
        isInitialized: false,
        isLoading: false,
        isModelLoaded: false,
        status: 'Model cleared',
        error: null,
        downloadProgress: null,
        phase: ModelBootPhase.idle,
        downloadTaskId: null,
        downloadFilePath: null,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_model?.close());
    unawaited(_downloadUpdatesSubscription?.cancel());
    super.dispose();
  }
}
