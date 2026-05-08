import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'model_boot_state.dart';
import 'species_service.dart';
import '../models/chat_prompts.dart';
import '../utils/image_utils.dart';

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
        'Picture That is downloading {filename}',
      ),
      paused: const TaskNotification(
        'Download paused',
        'Picture That will continue automatically.',
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

  // Cleanup resources
  void dispose();
}

/// Optimized model runtime with GPU acceleration and session management
class FlutterGemmaModelRuntime implements ModelRuntime {
  final ModelType modelType;
  InferenceModel? _cachedModel;
  bool _isInitialized = false;

  // Performance tuning constants
  static const bool _useGpu = true; // Enable GPU delegate if available

  FlutterGemmaModelRuntime({
    required this.modelType,
  });

  @override
  Future<InferenceModel> getActiveModel({required int maxTokens}) async {
    try {
      // Use cached model if available and compatible
      if (_cachedModel != null && _isInitialized) {
        return _cachedModel!;
      }

      // Create optimized model with GPU acceleration
      _cachedModel = await FlutterGemma.getActiveModel(
        maxTokens: maxTokens,
        preferredBackend: _useGpu ? PreferredBackend.gpu : PreferredBackend.cpu,
        supportImage: true,
        maxNumImages: 1,
      );

      _isInitialized = true;
      return _cachedModel!;
    } catch (e) {
      debugPrint('Failed to get active model: $e');
      rethrow;
    }
  }

  @override
  Future<void> installFromFile(String filePath) async {
    try {
      // Add timeout to prevent hanging
      await Future.any([
        FlutterGemma.installModel(
                modelType: modelType, fileType: ModelFileType.litertlm)
            .fromFile(filePath)
            .install(),
        Future.delayed(const Duration(minutes: 5), () {
          throw TimeoutException(
              'Model installation timed out after 5 minutes');
        }),
      ]);

      // Clear cached model after installation to ensure fresh loading
      _cachedModel = null;
      _isInitialized = false;
    } catch (e) {
      debugPrint('Model installation failed: $e');
      rethrow;
    }
  }

  /// Generate response with tuned parameters
  Future<String> generateOptimizedResponse(
    InferenceModel model,
    String prompt, {
    String? systemInstruction,
    Uint8List? imageBytes,
    int maxTokens = 2048,
    double temperature = 0.7,
    int topK = 40,
    double topP = 0.9,
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  }) async {
    try {
      onProgress?.call('Preparing session...', 0.15);

      // Use the existing API with optimized parameters
      final session = await model.createSession(
        enableVisionModality: true,
        temperature: temperature,
        topK: topK,
        topP: topP,
        systemInstruction: systemInstruction,
      );

      try {
        onProgress?.call('Sending question...', 0.35);

        if (imageBytes != null) {
          await session.addQueryChunk(Message.withImage(
            text: prompt,
            imageBytes: imageBytes,
            isUser: true,
          ));
        } else {
          await session.addQueryChunk(Message.text(
            text: prompt,
            isUser: true,
          ));
        }

        onProgress?.call('Generating answer...', 0.55);

        final buffer = StringBuffer();
        await for (final token in session.getResponseAsync()) {
          buffer.write(token);
          onToken?.call(token);
        }

        onProgress?.call('Complete', 1.0);
        return buffer.toString();
      } finally {
        await session.close();
      }
    } catch (e) {
      debugPrint('Optimized generation failed: $e');
      rethrow;
    }
  }

  /// Cleanup resources
  @override
  void dispose() {
    _cachedModel?.close();
    _cachedModel = null;
    _isInitialized = false;
  }
}

class ModelService extends ChangeNotifier {
  static const String _downloadGroup = 'picture_that_model_downloads';
  static const String _downloadTaskId = 'picture_that_gemma_model';

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

  // Pending model size for display in confirmation dialog
  String? _pendingModelSize;

  // Model configuration - Gemma 4 2B Instruct (quantized)
  static const String _modelRevision =
      '7fa1d78473894f7e736a21d920c3aa80f950c0db';
  final String modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/$_modelRevision/gemma-4-E2B-it.litertlm';
  final ModelType modelType = ModelType.gemmaIt;
  final int maxTokens = 2048;

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

  String? get pendingModelSize => _pendingModelSize;

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

  /// Fetches the model size from the server using HTTP HEAD request.
  /// Returns human-readable size string (e.g., "1.8 GB") or null if unavailable.
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
          return _formatBytes(contentLength);
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

  /// Formats bytes to human-readable string (MB or GB)
  String _formatBytes(int bytes) {
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

  bool _isAndroidDownloadPath(String filePath) {
    if (!Platform.isAndroid) {
      return false;
    }

    final normalized = filePath.replaceAll('\\', '/').toLowerCase();
    return normalized.startsWith('/storage/emulated/0/download') ||
        normalized.startsWith('/sdcard/download');
  }

  Future<bool> _hasDownloadFolderAccess() async {
    return await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted;
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

  /// Get the destination path for persistent model storage.
  /// On Android, the model must live in the public Downloads folder so it can
  /// be reused across launches and loaded when storage access is granted.
  Future<String> _getDownloadDestination({
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

    // Ensure directory exists
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return '$dirPath/.gemma-4-E2B-it.litertlm';
  }

  Future<DownloadTask> _buildDownloadTask({
    String? customUrl,
    bool preferDownloadsFolder = false,
  }) async {
    final persistentPath = await _getDownloadDestination(
      preferDownloadsFolder: preferDownloadsFolder,
    );

    // Ensure the persistent directory exists
    final persistentDir = Directory(persistentPath).parent;
    if (!await persistentDir.exists()) {
      await persistentDir.create(recursive: true);
    }

    final (baseDirectory, directory, filename) = await Task.split(
      filePath: persistentPath,
    );

    return DownloadTask(
      taskId: _downloadTaskId,
      url: customUrl ?? modelUrl,
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
      retries: 3, // Allow retries for rural/uncertain connections
      updates: Updates.statusAndProgress,
    );
  }

  Future<bool> _isDownloadedModelPresent([String? filePath]) async {
    final resolvedPath = filePath ?? await _getDownloadDestination();
    return File(resolvedPath).exists();
  }

  Future<void> _installDownloadedModel(String filePath) async {
    if (await _deferModelSetupUntilDownloadPermission(
      filePath,
    )) {
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
      // Install with timeout to prevent hanging
      await _runtime.installFromFile(filePath);
      _model = await _getActiveVisionModel();
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
            await _markError('Model file not found on server.',
                phase: ModelBootPhase.failed);
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

  /// Exposed for testing purposes only.
  @visibleForTesting
  Future<void> bootstrapForTest({bool loadPersistedState = true}) async {
    return _bootstrap(loadPersistedState: loadPersistedState);
  }

  Future<void> _reconcileStartupState() async {
    final activeModel = await _tryActivateExistingModel();
    if (activeModel) {
      return;
    }

    final filePath = _state.downloadFilePath ?? await _getDownloadDestination();
    final fileExists = await _isDownloadedModelPresent(filePath);
    if (fileExists) {
      if (await _deferModelSetupUntilDownloadPermission(
        filePath,
      )) {
        return;
      }

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

    // Don't auto-download - show confirmation dialog first
    // Fetch model size for display
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
          if (await _deferModelSetupUntilDownloadPermission(
            filePath,
          )) {
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
          if (await _deferModelSetupUntilDownloadPermission(
            filePath,
          )) {
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
      // Install with timeout to prevent hanging
      await _runtime.installFromFile(filePath);
      _model = await _getActiveVisionModel();
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

    // If custom URL provided, try to fetch its size for display/logging
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

    await _ensureDownloaderReady();
    final taskId = _state.downloadTaskId ?? _downloadTaskId;
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
      final task = await _buildDownloadTask(
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

  Future<void> downloadModel({void Function(double)? onProgress}) async {
    if (_state.isModelLoaded || _isBootstrapping) {
      return;
    }

    await _ensureDownloaderReady();

    // First check if model exists at the expected location
    final expectedFilePath = await _getDownloadDestination();
    if (await _isDownloadedModelPresent(expectedFilePath)) {
      if (await _deferModelSetupUntilDownloadPermission(
        expectedFilePath,
      )) {
        return;
      }

      await _installDownloadedModel(expectedFilePath);
      return;
    }

    // If not found at expected location, search all other possible locations
    final foundModelPath = await _checkForLocalModel();
    if (foundModelPath != null) {
      await _commitLocalModel(foundModelPath);
      return;
    }

    // No existing model found - clean up thoroughly and start download
    await clearModel();

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
      debugPrint('Searching for existing model files...');
      final List<String> searchPaths = [];

      // 1. Downloads directory
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          searchPaths.add(downloadsDir.path);
          debugPrint('Added downloads directory: ${downloadsDir.path}');
        }
      } catch (e) {
        debugPrint('Could not get downloads directory: $e');
      }

      // 2. Common Android download path
      if (Platform.isAndroid) {
        searchPaths.add('/storage/emulated/0/Download');
        debugPrint('Added Android download path');
      } else {
        // 3. App-specific documents directory for non-Android platforms
        try {
          final appDocDir = await getApplicationDocumentsDirectory();
          searchPaths.add(appDocDir.path);
          debugPrint('Added app documents directory: ${appDocDir.path}');
        } catch (e) {
          debugPrint('Could not get app documents directory: $e');
        }
      }

      debugPrint(
          'Searching ${searchPaths.length} locations for model files...');

      int filesChecked = 0;
      for (final basePath in searchPaths) {
        try {
          final directory = Directory(basePath);
          if (await directory.exists()) {
            debugPrint('Searching directory: $basePath');
            final files = await directory.list(recursive: false).toList();
            for (final file in files) {
              filesChecked++;
              if (file is File) {
                final fileName = file.path.toLowerCase();
                if (fileName.endsWith('.litertlm') &&
                    fileName.contains('gemma')) {
                  debugPrint('✓ Found model file: ${file.path}');
                  return file.path;
                }
              }
            }
            debugPrint('✗ No model files found in: $basePath');
          } else {
            debugPrint('Directory does not exist: $basePath');
          }
        } catch (e) {
          debugPrint('Error searching path $basePath: $e');
          continue;
        }
      }
      debugPrint(
          'Model search complete. Checked $filesChecked files across ${searchPaths.length} locations.');
    } catch (e) {
      debugPrint('Error checking local model: $e');
    }
    return null;
  }

  Future<void> clearModel() async {
    if (_model != null) {
      // Use optimized cleanup for FlutterGemmaModelRuntime
      if (_model is FlutterGemmaModelRuntime) {
        (_model as FlutterGemmaModelRuntime).dispose();
      } else {
        await _model!.close();
      }
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

      // Compress image with memory-aware processing
      final compressedBytes = await ImageUtils.compressImage(
        imageBytes,
        maxWidth: 336,
        maxHeight: 336,
        quality: 85,
      );

      final speciesLatinNames = _speciesList.map((s) => s.latinName).toList();

      final systemInstruction =
          ChatPrompts.buildIdentifySystemInstruction(speciesLatinNames);

      const inputPrompt = ChatPrompts.identifyInputPrompt;

      _commitState(
        _state.copyWith(
          status: 'Generating analysis...',
          phase: ModelBootPhase.analyzing,
        ),
      );

      // Use optimized generation method
      final response = await (_runtime as FlutterGemmaModelRuntime)
          .generateOptimizedResponse(
        _model!,
        inputPrompt,
        systemInstruction: systemInstruction,
        imageBytes: compressedBytes,
        temperature: 0.7,
        topK: 32,
        topP: 0.9,
      );

      _commitState(
        _state.copyWith(
          status: 'Analysis complete',
          phase: ModelBootPhase.ready,
        ),
      );

      final cleanedResponse = response.trim();
      return await _speciesService.parseLatinName(cleanedResponse) ?? '';
    } catch (e) {
      final errorMessage = 'Identification failed: $e';
      await _markError(errorMessage, phase: ModelBootPhase.failed);
      rethrow;
    }
  }

  /// Ask a question about a previously analyzed species
  Future<String> askQuestion(
    String question, {
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  }) async {
    if (_model == null) {
      throw Exception('Model not loaded. Please wait for model to download.');
    }

    try {
      _commitState(
        _state.copyWith(
          status: 'Answering question...',
          phase: ModelBootPhase.analyzing,
        ),
      );

      onProgress?.call('Starting...', 0.0);

      // Use optimized generation method for text-based question
      final response = await (_runtime as FlutterGemmaModelRuntime)
          .generateOptimizedResponse(
        _model!,
        question,
        systemInstruction: ChatPrompts.answerSystemInstruction,
        temperature: 0.7,
        topK: 32,
        topP: 0.9,
        onProgress: onProgress,
        onToken: onToken,
      );

      _commitState(
        _state.copyWith(
          status: 'Question answered',
          phase: ModelBootPhase.ready,
        ),
      );

      return response.trim();
    } catch (e) {
      final errorMessage = 'Question answering failed: $e';
      _commitState(
        _state.copyWith(
          status: errorMessage,
          phase: ModelBootPhase.failed,
          error: errorMessage,
        ),
      );
      rethrow;
    }
  }

  @override
  void dispose() {
    // Use optimized cleanup for FlutterGemmaModelRuntime
    if (_model is FlutterGemmaModelRuntime) {
      (_model as FlutterGemmaModelRuntime).dispose();
    } else {
      unawaited(_model?.close());
    }
    unawaited(_downloadUpdatesSubscription?.cancel());
    super.dispose();
  }
}
