import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'model_boot_state.dart';
import 'app_settings_service.dart';
import 'species_service.dart';
import '../models/chat_prompts.dart';
import '../models/model_spec.dart';

/// Strip markdown code fences (```json ... ```) around model JSON output.
String _stripJsonFences(String raw) {
  final match = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(raw);
  return match?.group(1)?.trim() ?? raw.trim();
}

/// Returns true when [text] contains a word or short phrase repeated
/// consecutively more than [threshold] times — the hallmark of a
/// degeneration loop (e.g. "Quadri Quadri Quadri...").
bool _isRepetitionLoop(String text, {int threshold = 6}) {
  if (text.isEmpty) return false;
  // Split on whitespace and look for a run of identical tokens.
  final tokens = text.trim().split(RegExp(r'\s+'));
  if (tokens.length < threshold) return false;
  int run = 1;
  for (int i = 1; i < tokens.length; i++) {
    if (tokens[i] == tokens[i - 1]) {
      run++;
      if (run >= threshold) return true;
    } else {
      run = 1;
    }
  }
  return false;
}

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
        enableSpeculativeDecoding: true,
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
                modelType: modelType,
                fileType: ModelFileType.litertlm
            )
            .fromFile(filePath)
            .install(),
        Future.delayed(const Duration(minutes: 5), () {
          throw TimeoutException(
              'Model installation timed out after 5 minutes');
        }),
      ]);

      // Clear cached model after installation. The active model is loaded
      // lazily on first use after startup completes.
      _cachedModel = null;
      _isInitialized = false;
    } catch (e) {
      debugPrint('Model installation failed: $e');
      rethrow;
    }
  }

  /// Generate response with tuned parameters. When [toolSpecs] is provided,
  /// uses InferenceChat with tool calling. Each spec's [subsequentPrompt]
  /// is injected into the chat right after its result is returned.
  Future<String> generateOptimizedResponse(
    InferenceModel model,
    String prompt, {
    String? systemInstruction,
    Uint8List? imageBytes,
    List<ToolSpec>? toolSpecs,
    int maxTokens = 3072,
    double temperature = 0.7,
    int topK = 40,
    double topP = 0.9,
    int seed = 31415926,
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  }) async {
    final resolvedTools =
        toolSpecs != null ? ToolSpec.toTools(toolSpecs) : const <Tool>[];
    final bool useToolCalling = resolvedTools.isNotEmpty;

    try {
      if (!useToolCalling) {
        // ── Standard (no-tool) flow via Session ──
        // Must use createSession, not createChat, for Gemma 4 E2B compatibility.
        // createChat with ToolChoice.none suppresses text generation on this model.
        onProgress?.call('Preparing session...', 0.15);

        final session = await model.createSession(
          enableVisionModality: true,
          randomSeed: seed,
          temperature: temperature,
          topK: topK,
          topP: topP,
          systemInstruction: systemInstruction,
        );

        try {
          onProgress?.call('Sending question...', 0.35);

          if (imageBytes != null) {
            await session.addQueryChunk(Message.withImage(
              text: '',
              imageBytes: imageBytes,
              isUser: true,
            ));
          }
          await session.addQueryChunk(Message.text(
            text: prompt,
            isUser: true,
          ));

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
      }

      // ── Tool-calling flow via InferenceChat ──
      onProgress?.call('Preparing chat...', 0.15);

      final chat = await model.createChat(
        supportImage: imageBytes != null,
        tools: resolvedTools ?? const [],
        supportsFunctionCalls: useToolCalling,
        toolChoice: useToolCalling ? ToolChoice.required : ToolChoice.none,
        randomSeed: seed,
        temperature: temperature,
        topK: topK,
        topP: topP,
        modelType: modelType,
        systemInstruction: systemInstruction,
      );

      try {
        // ── 2. Build message chunks: image first (if any), then prompt text ──
        // Gemma 4 best practice: image content must come BEFORE text in the
        // prompt for optimal multimodal attention.
        // https://huggingface.co/google/gemma-4-31B-it
        if (imageBytes != null) {
          onProgress?.call('Sending image...', 0.30);
          await chat.addQueryChunk(Message.withImage(
            text: '',               // image-only chunk comes first
            imageBytes: imageBytes,
            isUser: true,
          ));
        }

        onProgress?.call('Sending prompt...', 0.35);
        await chat.addQueryChunk(Message.text(
          text: prompt,            // instruction text always follows last
          isUser: true,
        ));

        // ── 3. Agentic loop: generate → dispatch tools → repeat until no more tool calls ──
        onProgress?.call(
          useToolCalling ? 'Identifying species...' : 'Generating answer...',
          0.45
        );
        
        const int maxPasses = 5;  // Maximum agentic passes to prevent runaway loops.
        int pass = 0;
        while (true) {
          pass++;
          debugPrint('── Generation pass $pass ──');

          if (pass > maxPasses) {
            debugPrint('[Pass $pass] Max passes ($maxPasses) exceeded — aborting.');
            onProgress?.call('Complete', 1.0);
            return '';
          }

          final responseBuffer = StringBuffer();
          bool toolWasCalled = false;

          await for (final response in chat.generateChatResponseAsync()) {
            if (response is TextResponse) {
              responseBuffer.write(response.token);
              onToken?.call(response.token);
            } else if (response is ThinkingResponse) {
              debugPrint('[Pass $pass] Thinking: ${response.content}');
            } else if (response is FunctionCallResponse) {
              toolWasCalled = true;
              debugPrint('[Pass $pass] Tool call: ${response.name}(${response.args})');
              onProgress?.call('Running tool: ${response.name}...', 0.55);
              final matchedSpec = toolSpecs!.firstWhere(
                (s) => s.name == response.name,
                orElse: () => throw Exception('No ToolSpec found for: ${response.name}'),
              );
              final result = await matchedSpec.execute(response.args);
              debugPrint('[Pass $pass] Tool result (${response.name}): $result');
              await chat.addQueryChunk(Message.toolResponse(
                toolName: response.name,
                response: {'result': result},
              ));
              if (matchedSpec.subsequentPrompt != null) {
                await chat.addQueryChunk(matchedSpec.subsequentPrompt!);
              }
            } else if (response is ParallelFunctionCallResponse) {
              toolWasCalled = true;
              debugPrint('[Pass $pass] Parallel tool calls: ${response.calls.map((c) => '${c.name}(${c.args})').join(', ')}');
              for (final call in response.calls) {
                final matchedSpec = toolSpecs!.firstWhere(
                  (s) => s.name == call.name,
                  orElse: () => throw Exception('No ToolSpec found for: ${call.name}'),
                );
                final result = await matchedSpec.execute(call.args);
                await chat.addQueryChunk(Message.toolResponse(
                  toolName: call.name,
                  response: {'result': result},
                ));
                if (matchedSpec.subsequentPrompt != null) {
                  await chat.addQueryChunk(matchedSpec.subsequentPrompt!);
                }
              }
            }
          }

          debugPrint('[Pass $pass] Output: ${responseBuffer.toString().trim()}');

          // Guard: detect degenerate repetition output (e.g. "Quadri Quadri Quadri...").
          // The native model returns all tokens as one chunk, so we can't abort
          // mid-stream — but we can catch it here before it corrupts the pipeline.
          final rawOutput = responseBuffer.toString();
          if (_isRepetitionLoop(rawOutput)) {
            debugPrint('[Pass $pass] Repetition loop detected — aborting generation.');
            throw Exception('Model entered a repetition loop. Please try again.');
          }

          // No tool calls this pass — the model is done, return its text response
          if (!toolWasCalled) {
            debugPrint('[Pass $pass] No tool calls — final answer returned after $pass pass(es)');
            onProgress?.call('Complete', 1.0);
            return rawOutput.trim();
          }

          debugPrint('[Pass $pass] Tool(s) dispatched — starting pass ${pass + 1}');
          onProgress?.call('Generating result...', 0.75);
        }
      } finally {
        await chat.close();
      }
    } catch (e) {
      debugPrint('Generation failed: $e');
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
  static const String _downloadGroup = 'mero_model_downloads';
  static const String _downloadTaskId = 'mero_gemma_model';
  static const String noDetectionFallbackJson =
      '{"genus":"","common_name":"","scientific_name":"","confidence":"low","identification_notes":"No confident species detected.","is_endangered":false}';

  final ModelDownloadBackend _downloader;
  final ModelRuntime _runtime;
  final AppSettingsService _settingsService;
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
  static const String _modelRevision = 'main';
  static const ModelType modelType = ModelType.gemma4;
  static const int maxTokens = 3072;

  final String modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/$_modelRevision/gemma-4-E2B-it.litertlm';

  // Species database service
  final SpeciesService _speciesService = SpeciesService();

  ModelService({
    ModelDownloadBackend? downloader,
    ModelRuntime? runtime,
    AppSettingsService? settingsService,
    ModelBootStateStore? stateStore,
    bool autoInitialize = true,
  })  : _downloader = downloader ?? BackgroundModelDownloadBackend(),
        _runtime = runtime ??
            FlutterGemmaModelRuntime(
              modelType: modelType,
            ),
        _settingsService = settingsService ?? AppSettingsService(),
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

  DateTime get updatedAt {
    final path = downloadFilePath;
    if (path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          return file.lastModifiedSync();
        }
      } catch (e) {
        debugPrint('Error getting model file modification date: $e');
      }
    }
    return _state.updatedAt;
  }

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
        if (downloadsDir != null) {
          dirPath = downloadsDir.path;
        } else {
          try {
            dirPath = (await getApplicationDocumentsDirectory()).path;
          } catch (e) {
            debugPrint('Could not get app documents directory: $e');
            dirPath = Directory.systemTemp.path;
          }
        }
      } catch (e) {
        debugPrint('Could not get downloads directory: $e');
        try {
          dirPath = (await getApplicationDocumentsDirectory()).path;
        } catch (inner) {
          debugPrint('Could not get app documents directory: $inner');
          dirPath = Directory.systemTemp.path;
        }
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

    late final BaseDirectory baseDirectory;
    late final String directory;
    late final String filename;
    try {
      (baseDirectory, directory, filename) = await Task.split(
        filePath: persistentPath,
      );
    } catch (e) {
      debugPrint('Falling back to root download task path: $e');
      baseDirectory = BaseDirectory.root;
      directory = p.dirname(persistentPath);
      filename = p.basename(persistentPath);
    }

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
    _state = nextState;
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

  /// Pre-load the genus-indexed species database (warm the cache)
  Future<void> _loadSpeciesData() async {
    if (_speciesLoaded) {
      return;
    }

    try {
      await _speciesService.loadGenusDb();
      _speciesLoaded = true;
      debugPrint('Loaded species genus database');
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
        updatedAt: DateTime.now(),
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

    // Delete the actual model file if it exists
    final filePath = _state.downloadFilePath ?? await _getDownloadDestination();
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('Deleted model file: $filePath');
      }
    } catch (e) {
      debugPrint('Failed to delete model file: $e');
    }

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

  Future<void> deactivateActiveModel() async {
    _runtime.dispose();
    _model = null;
  }

  Future<InferenceModel> _ensureActiveModel() async {
    final currentModel = _model;
    if (currentModel != null) {
      return currentModel;
    }

    final activeModel = await _getActiveVisionModel();
    _model = activeModel;
    return activeModel;
  }

  Future<String> identifySpecies(
    Uint8List imageBytes,
    String imageFormat,
    {
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  }
  ) async {
    try {
      onProgress?.call('Activating model...', 0.05);
      final activeModel = await _ensureActiveModel();
      onProgress?.call('Model activated', 0.12);

      final bool toolsEnabled = _settingsService.toolsEnabled;
      final List<ToolSpec> toolSpecs = toolsEnabled
          ? [
              ToolSpec(
                name: ChatPrompts.speciesSearchToolDef['name'] as String,
                description: ChatPrompts.speciesSearchToolDef['description'] as String,
                parameters: ChatPrompts.speciesSearchToolDef['parameters']
                    as Map<String, dynamic>,
                execute: (args) => _speciesService.searchSpeciesByTaxonomy(
                  args['class'] as String? ?? '',
                  args['order'] as String? ?? '',
                  args['family'] as String? ?? '',
                  args['genus'] as String? ?? '',
                ),
                subsequentPrompt: Message.text(
                  text: ChatPrompts.identifySynthesisPrompt,
                  isUser: true,
                ),
              ),
            ]
          : const [];

      _commitState(
        _state.copyWith(
          status: 'Analyzing image...',
          phase: ModelBootPhase.analyzing,
        ),
      );

      final result = await (_runtime as FlutterGemmaModelRuntime)
          .generateOptimizedResponse(
        activeModel,
        toolsEnabled
            ? ChatPrompts.identifyInputPrompt
            : ChatPrompts.identifyNoToolsInputPrompt,
        systemInstruction: toolsEnabled
            ? ChatPrompts.identifySystemInstruction
            : ChatPrompts.identifyNoToolsSystemInstruction,
        imageBytes: imageBytes,
        toolSpecs: toolsEnabled ? toolSpecs : null,
        temperature: 0.3,
        topK: 64,
        topP: 0.85,
        onProgress: onProgress == null
            ? (phase, progress) {
                debugPrint('Progress: $phase ($progress)');
              }
            : (phase, progress) {
                debugPrint('Progress: $phase ($progress)');
                onProgress(phase, progress);
              },
        onToken: onToken,
      );

      // Strip markdown code fences (```json ... ```) before parsing
      final cleaned = _stripJsonFences(result);

      try {
        jsonDecode(cleaned);
      } catch (e) {
        debugPrint('[identifySpecies] Garbage result detected — treating as no detection: $e');
        _commitState(
          _state.copyWith(
            status: 'No confident species detected',
            phase: ModelBootPhase.ready,
          ),
        );
        return noDetectionFallbackJson;
      }

      _commitState(
        _state.copyWith(
          status: 'Analysis complete',
          phase: ModelBootPhase.ready,
        ),
      );

      return result;
    } catch (e) {
      final errorMessage = 'Identification failed: $e';
      await _markError(errorMessage, phase: ModelBootPhase.failed);
      rethrow;
    }
  }

  /// Ask a question about a previously analyzed species
  Future<String> askQuestion(
    String question, {
    String? systemInstruction,
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  }) async {
    if (_model == null) {
      throw Exception('Model not loaded. Please analyze an image first.');
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
        systemInstruction: systemInstruction ?? ChatPrompts.answerSystemInstruction('English'),
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

  /// Translate [text] to [targetLang] using the on-device Gemma model.
  Future<String> translate(String text, String targetLang) async {
    final prompt = ChatPrompts.translatePrompt(targetLang, text);

    if (_model == null) {
      throw Exception('Model not loaded. Please analyze an image first.');
    }

    try {
      final response = await (_runtime as FlutterGemmaModelRuntime)
          .generateOptimizedResponse(
        _model!,
        prompt,
        systemInstruction: ChatPrompts.translateSystemInstruction,
        temperature: 0.3,
        topK: 16,
        topP: 0.5,
        maxTokens: 1024,
      );

      return response.trim();
    } catch (e) {
      debugPrint('Translation failed: $e');
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
