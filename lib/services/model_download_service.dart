import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'model_boot_state.dart';
import 'species_service.dart';

typedef ModelInstallCallback = Future<void> Function(String filePath);
typedef ModelActivationCallback = Future<bool> Function();

@visibleForTesting
bool isCancellationErrorDescription(String? description) {
  if (description == null || description.isEmpty) {
    return false;
  }

  final normalized = description.toLowerCase();
  return normalized.contains('cancel');
}

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
        (Config.runInForegroundIfFileLargerThan, 1),
      ],
    );

    FileDownloader().configureNotification(
      running: const TaskNotification(
        'Downloading model',
        'Mero is downloading {filename}',
      ),
      paused: const TaskNotification(
        'Download paused',
        'Mero will continue automatically.',
      ),
      complete: const TaskNotification(
        'Model ready',
        'The Gemma model is ready to use.',
      ),
      error: const TaskNotification(
        'Download failed',
        'Mero could not finish downloading the model.',
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

class ModelDownloadService extends ChangeNotifier {
  static const String downloadGroup = 'mero_model_downloads';
  static const String downloadTaskId = 'mero_gemma_model';

  final ModelDownloadBackend _downloader;
  final ModelBootStateStore? _stateStoreOverride;
  final SpeciesService _speciesService;
  final String modelUrl;
  final ModelInstallCallback _installModel;
  final ModelActivationCallback _tryActivateExistingModel;

  bool _isBootstrapping = false;
  bool _isDownloading = false;
  bool _speciesLoaded = false;
  bool _configured = false;

  ModelBootState _state = ModelBootState.initial();
  ModelBootStateStore? _stateStore;
  StreamSubscription<TaskUpdate>? _updatesSubscription;
  String? _pendingModelSize;

  ModelDownloadService({
    ModelDownloadBackend? downloader,
    ModelBootStateStore? stateStore,
    SpeciesService? speciesService,
    required this.modelUrl,
    required ModelInstallCallback installModel,
    required ModelActivationCallback tryActivateExistingModel,
  })  : _downloader = downloader ?? BackgroundModelDownloadBackend(),
        _stateStoreOverride = stateStore,
        _speciesService = speciesService ?? SpeciesService(),
        _installModel = installModel,
        _tryActivateExistingModel = tryActivateExistingModel;

  ModelBootState get state => _state;
  bool get isInitialized => _state.isInitialized;
  bool get isLoading => _state.isLoading;
  bool get isModelLoaded => _state.isModelLoaded;
  String get status => _state.status;
  String? get error => _state.error;
  double? get downloadProgress => _state.downloadProgress;
  ModelBootPhase get phase => _state.phase;
  String? get downloadTaskIdValue => _state.downloadTaskId;
  String? get downloadFilePath => _state.downloadFilePath;
  String? get downloadPhase => _state.downloadPhase;
  String? get pendingModelSize => _pendingModelSize;

  Future<ModelBootStateStore> _resolveStateStore() async {
    return _stateStoreOverride ?? await ModelBootStateStore.create();
  }

  void updateState(ModelBootState nextState) {
    _commitState(nextState);
  }

  Future<void> ensureReady() async {
    _updatesSubscription ??= _downloader.updates.listen(
      (update) {
        unawaited(_handleDownloadUpdate(update));
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Model download update stream error: $error');
      },
    );

    if (!_configured) {
      await _downloader.configure();
      await _downloader.start();
      _configured = true;
    }
  }

  Future<String?> fetchModelSize([String? url]) async {
    HttpClient? client;
    try {
      final targetUrl = url ?? modelUrl;
      client = HttpClient();
      final request = await client.headUrl(Uri.parse(targetUrl));
      final response = await request.close();

      if (response.statusCode == 200) {
        final contentLength = response.headers.contentLength;
        if (contentLength > 0) {
          return formatBytes(contentLength);
        }
      }
      return null;
    } catch (e) {
      debugPrint('Failed to fetch model size: $e');
      return null;
    } finally {
      client?.close();
    }
  }

  String formatBytes(int bytes) {
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;

    if (bytes >= gb) {
      final gbValue = bytes / gb;
      return '${gbValue.toStringAsFixed(1)} GB';
    } else {
      final mbValue = bytes / mb;
      return '${mbValue.toStringAsFixed(0)} MB';
    }
  }

  Future<String> getDownloadDestination({
    bool preferDownloadsFolder = false,
  }) async {
    String dirPath;
    if (Platform.isAndroid) {
      dirPath = '/storage/emulated/0/Download';
    } else {
      try {
        final downloadsDir = await getDownloadsDirectory();
        dirPath = downloadsDir?.path ??
            (await getApplicationDocumentsDirectory()).path;
      } catch (e) {
        dirPath = (await getApplicationDocumentsDirectory()).path;
      }
    }

    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return '$dirPath/.gemma-4-E2B-it.litertlm';
  }

  Future<DownloadTask> buildDownloadTask({
    String? customUrl,
    bool preferDownloadsFolder = false,
  }) async {
    final persistentPath = await getDownloadDestination(
      preferDownloadsFolder: preferDownloadsFolder,
    );

    final persistentDir = Directory(persistentPath).parent;
    if (!await persistentDir.exists()) {
      await persistentDir.create(recursive: true);
    }

    final (baseDirectory, directory, filename) = await Task.split(
      filePath: persistentPath,
    );

    return DownloadTask(
      taskId: downloadTaskId,
      url: customUrl ?? modelUrl,
      group: downloadGroup,
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
      retries: 3,
      updates: Updates.statusAndProgress,
    );
  }

  Future<bool> isDownloadedModelPresent([String? filePath]) async {
    final resolvedPath = filePath ?? await getDownloadDestination();
    return File(resolvedPath).exists();
  }

  bool isAndroidDownloadPath(String filePath) {
    if (!Platform.isAndroid) {
      return false;
    }

    final normalized = filePath.replaceAll('\\', '/').toLowerCase();
    return normalized.startsWith('/storage/emulated/0/download') ||
        normalized.startsWith('/sdcard/download');
  }

  Future<bool> hasDownloadFolderAccess() async {
    return await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted;
  }

  Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    while (true) {
      if (await Permission.manageExternalStorage.isGranted) return true;
      if (await Permission.storage.isGranted) return true;

      final status = await Permission.storage.request();
      if (status.isGranted) return true;

      final manageStatus = await Permission.manageExternalStorage.request();
      if (manageStatus.isGranted) return true;

      if (status.isPermanentlyDenied || manageStatus.isPermanentlyDenied) {
        await openAppSettings();
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }

      if (status.isDenied || manageStatus.isDenied) {
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }

      break;
    }

    return false;
  }

  Future<String?> checkForLocalModel() async {
    try {
      final List<String> searchPaths = [];

      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          searchPaths.add(downloadsDir.path);
        }
      } catch (_) {}

      if (Platform.isAndroid) {
        searchPaths.add('/storage/emulated/0/Download');
      } else {
        try {
          final appDocDir = await getApplicationDocumentsDirectory();
          searchPaths.add(appDocDir.path);
        } catch (_) {}
      }

      for (final basePath in searchPaths) {
        try {
          final directory = Directory(basePath);
          if (await directory.exists()) {
            final files = await directory.list(recursive: false).toList();
            for (final file in files) {
              if (file is File) {
                final fileName = file.path.toLowerCase();
                if (fileName.endsWith('.litertlm') && fileName.contains('gemma')) {
                  return file.path;
                }
              }
            }
          }
        } catch (_) {
          continue;
        }
      }
    } catch (e) {
      debugPrint('Error checking local model: $e');
    }
    return null;
  }

  Future<void> bootstrap({
    bool loadPersistedState = true,
  }) async {
    if (_isBootstrapping) {
      return;
    }

    _isBootstrapping = true;

    try {
      _stateStore ??= await _resolveStateStore();
      await ensureReady();

      if (loadPersistedState) {
        final persisted = await _stateStore!.read();
        if (persisted != null) {
          _state = persisted.copyWith(
            isLoading: persisted.isModelLoaded ? false : persisted.isLoading,
            isInitialized: persisted.isInitialized,
            updatedAt: persisted.updatedAt,
          );
        } else {
          _state = ModelBootState.initial();
        }
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

  @visibleForTesting
  Future<void> bootstrapForTest({bool loadPersistedState = true}) {
    return bootstrap(loadPersistedState: loadPersistedState);
  }

  Future<void> retryInitialization() async {
    if (_isBootstrapping) {
      return;
    }

    await cancelDownload();

    _commitState(
      _state.copyWith(
        isInitialized: false,
        isLoading: false,
        isModelLoaded: false,
        error: null,
        status: 'Model download required',
        phase: ModelBootPhase.needsDownload,
        downloadProgress: null,
      ),
    );
  }

  Future<void> confirmDownload({
    String? customUrl,
    bool preferDownloadsFolder = false,
  }) async {
    if (_state.phase != ModelBootPhase.needsDownload &&
        _state.phase != ModelBootPhase.canceled) {
      return;
    }

    if (customUrl != null && customUrl.isNotEmpty) {
      _pendingModelSize = await fetchModelSize(customUrl);
      notifyListeners();
    }

    await _startModelDownload(
      resumed: false,
      customUrl: customUrl,
      preferDownloadsFolder: preferDownloadsFolder,
    );
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

    await ensureReady();
    final taskId = _state.downloadTaskId ?? downloadTaskId;
    final task = await _downloader.taskForId(taskId);
    if (task is DownloadTask && await _downloader.resume(task)) {
      _commitState(
        _state.copyWith(
          isInitialized: false,
          isLoading: true,
          isModelLoaded: false,
          status: 'Downloading model...',
          phase: ModelBootPhase.resuming,
        ),
      );
      return;
    }

    await _startModelDownload(resumed: true);
  }

  Future<void> downloadModel({void Function(double)? onProgress}) async {
    if (_state.isModelLoaded || _isBootstrapping) {
      return;
    }

    await ensureReady();

    final expectedFilePath = await getDownloadDestination();
    if (await isDownloadedModelPresent(expectedFilePath)) {
      if (await _deferModelSetupUntilDownloadPermission(expectedFilePath)) {
        return;
      }

      await _installDownloadedModel(expectedFilePath);
      return;
    }

    final foundModelPath = await checkForLocalModel();
    if (foundModelPath != null) {
      await _commitLocalModel(foundModelPath);
      return;
    }

    await clearModel();

    final activeTask = await _downloader.taskForId(downloadTaskId);
    if (activeTask != null) {
      final record = await _downloader.recordForId(downloadTaskId);
      if (activeTask is DownloadTask && record?.status == TaskStatus.paused) {
        await _downloader.resume(activeTask);
      }
      return;
    }

    await _startModelDownload(resumed: _state.phase == ModelBootPhase.paused);
  }

  Future<void> clearModel() async {
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

  Future<bool> _deferModelSetupUntilDownloadPermission(
    String filePath, {
    String? status,
  }) async {
    if (!_isAndroidDownloadPath(filePath)) {
      return false;
    }

    if (await _hasDownloadFolderAccess()) {
      return false;
    }

    _commitState(
      _state.copyWith(
        isInitialized: true,
        isLoading: false,
        isModelLoaded: false,
        status: status ?? 'Model download required',
        error: null,
        phase: ModelBootPhase.needsDownload,
        downloadProgress: null,
        downloadFilePath: filePath,
      ),
    );
    return true;
  }

  bool _isAndroidDownloadPath(String filePath) {
    return isAndroidDownloadPath(filePath);
  }

  Future<bool> _hasDownloadFolderAccess() {
    return hasDownloadFolderAccess();
  }

  Future<void> _installDownloadedModel(String filePath) async {
    if (await _deferModelSetupUntilDownloadPermission(filePath)) {
      return;
    }

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

    try {
      await _installModel(filePath);
      await _markReady(status: 'Model ready');
    } catch (e) {
      debugPrint('Model installation failed: $e');
      await _markError(
        'Failed to install model: $e',
        phase: ModelBootPhase.failed,
      );
      rethrow;
    }
  }

  Future<void> _handleDownloadUpdate(TaskUpdate update) async {
    if (update.task.taskId != downloadTaskId) {
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
            status: 'Downloading: $percent%',
            phase: phase,
            downloadProgress: progress.clamp(0.0, 1.0).toDouble(),
            error: null,
            downloadTaskId: update.task.taskId,
            downloadFilePath: await update.task.filePath(),
          ),
        );
        break;

      case TaskStatusUpdate(
          :final status,
          :final exception,
          :final responseStatusCode
        ):
        final taskPath = await update.task.filePath();
        switch (status) {
          case TaskStatus.enqueued:
            _commitState(
              _state.copyWith(
                isInitialized: false,
                isLoading: true,
                isModelLoaded: false,
                status: 'Downloading model...',
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
                status: 'Downloading model...',
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
            if (isCancellationErrorDescription(message)) {
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
            await _markError(message, phase: ModelBootPhase.failed);
            break;

          case TaskStatus.notFound:
            await _markError(
              'Model file not found on server.',
              phase: ModelBootPhase.failed,
            );
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

  Future<void> _loadSpeciesData() async {
    if (_speciesLoaded) {
      return;
    }

    try {
      await _speciesService.preloadAll();
      _speciesLoaded = true;
      debugPrint('Loaded species genus database');
    } catch (e) {
      debugPrint('Failed to load species DB: $e');
    }
  }

  Future<void> _reconcileStartupState() async {
    final activeModel = await _tryActivateExistingModel();
    if (activeModel) {
      return;
    }

    final filePath = _state.downloadFilePath ?? await getDownloadDestination();
    final fileExists = await isDownloadedModelPresent(filePath);
    if (fileExists) {
      if (await _deferModelSetupUntilDownloadPermission(filePath)) {
        return;
      }

      await _installDownloadedModel(filePath);
      return;
    }

    final taskId = _state.downloadTaskId ?? downloadTaskId;
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

    final legacyModelPath = await checkForLocalModel();
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

    _pendingModelSize = await fetchModelSize();
    _commitState(
      _state.copyWith(
        isInitialized: true,
        isLoading: false,
        isModelLoaded: false,
        status: 'Model download required',
        phase: ModelBootPhase.needsDownload,
      ),
    );
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
                : 'Downloading model...',
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
          if (await _deferModelSetupUntilDownloadPermission(filePath)) {
            return;
          }

          await _installDownloadedModel(filePath);
          return;
        }
        break;
      case TaskStatus.failed:
      case TaskStatus.notFound:
        final failureMessage =
            record?.exception?.description ?? 'Background download failed.';
        if (isCancellationErrorDescription(failureMessage)) {
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
        await _markError(
          failureMessage,
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
                : 'Downloading model...',
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
          if (await _deferModelSetupUntilDownloadPermission(filePath)) {
            return;
          }

          await _installDownloadedModel(filePath);
          return;
        }
        break;
      case TaskStatus.failed:
      case TaskStatus.notFound:
        final failureMessage =
            record.exception?.description ?? 'Background download failed.';
        if (isCancellationErrorDescription(failureMessage)) {
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
        await _markError(
          failureMessage,
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

    try {
      await _installModel(filePath);
      await _markReady(status: 'Model ready');
    } catch (e) {
      debugPrint('Existing model installation failed: $e');
      await _markError(
        'Failed to install existing model: $e',
        phase: ModelBootPhase.failed,
      );
      rethrow;
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

  Future<void> _startModelDownload({
    required bool resumed,
    String? customUrl,
    bool preferDownloadsFolder = false,
  }) async {
    if (_isDownloading || _state.isModelLoaded) {
      return;
    }

    _isDownloading = true;
    try {
      final task = await buildDownloadTask(
        customUrl: customUrl,
        preferDownloadsFolder: preferDownloadsFolder,
      );
      final filePath = await task.filePath();
      _commitState(
        _state.copyWith(
          isInitialized: false,
          isLoading: true,
          isModelLoaded: false,
          error: null,
          status: 'Downloading model...',
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

  @override
  void dispose() {
    _updatesSubscription?.cancel();
    _updatesSubscription = null;
    super.dispose();
  }
}
