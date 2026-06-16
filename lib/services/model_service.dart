import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'analysis_story_formatter.dart';
import 'model_boot_state.dart';
import 'model_download_service.dart';
import 'model_runtime.dart';
import 'species_service.dart';
import '../models/chat_prompts.dart';
import '../models/model_spec.dart';

// Re-export so callers (and tests) importing model_service.dart can reach the
// download-layer cancellation helper without a second import.
export 'model_download_service.dart' show isCancellationErrorDescription;

/// Strips ```json / ``` fences from a model response.
String _stripJsonFences(String s) {
  var t = s.trim();

  // Remove opening fence
  t = t.replaceFirst(
    RegExp(r'^```(?:json|JSON)?\s*'),
    '',
  );

  // Remove closing fence
  t = t.replaceFirst(
    RegExp(r'\s*```$'),
    '',
  );

  return t.trim();
}

/// Attempts to repair malformed JSON from LLM output.
String _sanitizeBrokenJson(String raw) {
  var s = _stripJsonFences(raw);

  // Normalize line breaks
  s = s.replaceAll('\r\n', '\n');

  final lines = s.split('\n');

  final buffer = StringBuffer();
  buffer.writeln('{');

  final keyValue = RegExp(
    r'"([^"]+)"\s*:\s*(.+?)(,)?\s*$',
  );

  bool first = true;

  for (final line in lines) {
    final trimmed = line.trim();

    // Skip empty lines, braces, and broken commas
    if (trimmed.isEmpty) continue;
    if (trimmed == '{' || trimmed == '}') continue;
    if (trimmed == ',' || trimmed == ',,') continue;

    final match = keyValue.firstMatch(trimmed);

    if (match == null) {
      // ❌ junk like "," or standalone quotes → drop
      continue;
    }

    final key = match.group(1)!;
    var value = match.group(2)!.trim();

    // Remove trailing commas safely
    if (value.endsWith(',')) {
      value = value.substring(0, value.length - 1).trim();
    }

    // Ensure valid JSON string values
    if (!value.startsWith('"') &&
        !value.startsWith('{') &&
        !value.startsWith('[') &&
        value != 'true' &&
        value != 'false' &&
        double.tryParse(value) == null) {
      value = '"$value"';
    }

    if (!first) buffer.writeln(',');
    buffer.write('  "$key": $value');
    first = false;
  }

  buffer.writeln();
  buffer.write('}');

  return buffer.toString();
}

void _emitProgress(
  void Function(String phase, double progress)? onProgress,
  String message,
  double progress, {
  void Function(String trace)? onTrace,
  String? traceMessage,
}) {
  onProgress?.call(message, progress);
  if (onTrace != null) {
    onTrace('${traceMessage ?? message}\n\n');
  }
}

class ModelService extends ChangeNotifier {
  static const String _modelRevision = 'main';
  static const ModelType modelType = ModelType.general;

  static const int _fastVlmMaxTokens = 2048;
  static const int _gemmaMaxTokens = 4096;
  static int get maxTokens =>
      modelType == ModelType.gemma4 ? _gemmaMaxTokens : _fastVlmMaxTokens;

  late final ModelRuntime _runtime;
  late final ModelDownloadService _downloadService;
  late final bool _ownsDownloadService;
  final SpeciesService _speciesService = SpeciesService();
  InferenceModel? _model;

  final String modelUrl =
      'https://huggingface.co/litert-community/FastVLM-0.5B/resolve/$_modelRevision/FastVLM-0.5B.litertlm';

  ModelService({
    ModelDownloadBackend? downloader,
    ModelRuntime? runtime,
    ModelBootStateStore? stateStore,
    ModelDownloadService? downloadService,
    bool autoInitialize = true,
  }) {
    _runtime = runtime ??
        FlutterGemmaModelRuntime(
          modelType: modelType,
        );
    if (downloadService != null) {
      _downloadService = downloadService;
      _ownsDownloadService = false;
    } else {
      _downloadService = ModelDownloadService(
        downloader: downloader,
        stateStore: stateStore,
        modelUrl: modelUrl,
        installModel: _installDownloadedModel,
        tryActivateExistingModel: _tryActivateExistingModel,
      );
      _ownsDownloadService = true;
    }

    if (autoInitialize) {
      unawaited(_downloadService.bootstrap());
    }
  }

  bool get isInitialized => _downloadService.isInitialized;
  bool get isLoading => _downloadService.isLoading;
  bool get isModelLoaded => _downloadService.isModelLoaded;
  String get status => _downloadService.status;
  String? get error => _downloadService.error;
  double? get downloadProgress => _downloadService.downloadProgress;
  ModelBootPhase get phase => _downloadService.phase;
  String? get downloadTaskId => _downloadService.downloadTaskIdValue;
  String? get downloadFilePath => _downloadService.downloadFilePath;
  String? get downloadPhase => _downloadService.downloadPhase;
  InferenceModel? get model => _model;
  String? get pendingModelSize => _downloadService.pendingModelSize;
  String get modelDisplayName {
    final uri = Uri.parse(modelUrl);
    final lastSegment = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final baseName = lastSegment.replaceFirst(RegExp(r'\.litertlm$'), '');
    return baseName.replaceAll('-', ' ');
  }

  @override
  void addListener(VoidCallback listener) {
    _downloadService.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _downloadService.removeListener(listener);
  }

  Future<bool> _tryActivateExistingModel() async {
    try {
      _model = await _runtime.getActiveModel(maxTokens: maxTokens);
      return true;
    } catch (e) {
      debugPrint('No active model found: $e');
      return false;
    }
  }

  Future<void> _installDownloadedModel(String filePath) async {
    try {
      await _runtime.installFromFile(filePath);
      _model = await _runtime.getActiveModel(maxTokens: maxTokens);
    } catch (e) {
      debugPrint('Model installation failed: $e');
      rethrow;
    }
  }

  @visibleForTesting
  Future<void> bootstrapForTest({bool loadPersistedState = true}) {
    return _downloadService.bootstrap(loadPersistedState: loadPersistedState);
  }

  Future<String?> fetchModelSize([String? url]) async {
    return _downloadService.fetchModelSize(url);
  }

  Future<void> retryInitialization() async {
    await _downloadService.retryInitialization();
  }

  Future<void> confirmDownload({
    String? customUrl,
    bool preferDownloadsFolder = false,
  }) async {
    await _downloadService.confirmDownload(
      customUrl: customUrl,
      preferDownloadsFolder: preferDownloadsFolder,
    );
  }

  Future<void> cancelDownload() async {
    await _downloadService.cancelDownload();
  }

  Future<void> resumeDownload() async {
    await _downloadService.resumeDownload();
  }

  Future<void> downloadModel({void Function(double)? onProgress}) async {
    await _downloadService.downloadModel(onProgress: onProgress);
  }

  Future<void> clearModel() async {
    _runtime.dispose();
    _model = null;
    await _downloadService.clearModel();
  }

  Future<String> identifySpecies(
    Uint8List imageBytes,
    String imageFormat, {
    required String languageName,
    void Function(String phase, double progress)? onProgress,
    void Function(String trace)? onTrace,
  }) async {
    if (_model == null) {
      throw Exception('Model not loaded. Please wait for model to download.');
    }

    try {
      final searchSpec = ToolSpec(
        name: ChatPrompts.speciesSearchToolDef['name'] as String,
        description: ChatPrompts.speciesSearchToolDef['description'] as String,
        parameters: ChatPrompts.speciesSearchToolDef['parameters']
            as Map<String, dynamic>,
        execute: (args) async {
          final results = await _speciesService.searchSimilarByFeatures(
            color: args['color'] as String? ?? '',
            bodyShape: args['body_shape'] as String? ?? '',
            distinctiveMarks: args['distinctive_marks'] as String? ?? '',
            texture: args['texture'] as String? ?? '',
            sizeClass: args['size_class'] as String? ?? '',
            pattern: args['pattern'] as String? ?? '',
            visualGroup: args['visualGroup'] as String? ?? '',
            taxClass: args['taxClass'] as String? ?? '',
            taxOrder: args['taxOrder'] as String? ?? '',
            taxFamily: args['taxFamily'] as String? ?? '',
            taxGenus: args['taxGenus'] as String? ?? '',
            topK: 5,
          );
          if (results.isEmpty) {
            return 'No matching endangered species found. Try different traits.';
          }
          final candidates = results.map((r) {
            Map<String, dynamic> features;
            try {
              features = jsonDecode(r.detail.visualFeatures) as Map<String, dynamic>;
            } catch (_) {
              features = {'raw': r.detail.visualFeatures};
            }
            return {
              'scientific_name': r.detail.scientificName,
              'common_name': r.detail.commonName,
              'score': double.parse(r.score.toStringAsFixed(1)),
              'confidence': double.parse(r.confidence.toStringAsFixed(2)),
              'visual_features': features,
            };
          }).toList();
          return jsonEncode(candidates);
        },
        subsequentPrompt: Message.text(
          text: ChatPrompts.identifySynthesisPrompt,
          isUser: true,
        ),
      );

      _downloadService.updateState(
        _downloadService.state.copyWith(
          status: 'Analyzing image...',
          phase: ModelBootPhase.analyzing,
        ),
      );

      final result = await _runtime.generateResponse(
        _model!,
        ChatPrompts.identifyInputPrompt,
        systemInstruction: ChatPrompts.identifySystemInstruction(languageName),
        imageBytes: imageBytes,
        toolSpecs: [searchSpec],
        useNativeToolCalling: false,
        temperature: 0.6,
        topK: 100,
        topP: 0.9,
        languageName: languageName,
        onProgress: onProgress,
        onTrace: onTrace,
      );

      // Strip fences then rsanitize common truncation patterns before parsing
      final repaired = _sanitizeBrokenJson(_stripJsonFences(result));

      Map<String, dynamic> repairedMap;
      try {
        repairedMap = jsonDecode(repaired) as Map<String, dynamic>;
      } catch (_) {
        debugPrint('[identifySpecies] Garbage result detected — rejecting response.');
        throw Exception('Model returned an unparseable response. Please try again.');
      }

      _downloadService.updateState(
        _downloadService.state.copyWith(
          status: 'Analysis complete',
          phase: ModelBootPhase.ready,
        ),
      );

      onTrace?.call(
        AnalysisStoryFormatter(isId: languageName == 'Bahasa Indonesia')
          .finalResult(repairedMap)
      );

      // Safely read confidence
      final confidence = repairedMap['confidence']?.toString().toLowerCase();

      // Reject low confidence
      if (confidence == 'low') {
        return '{}';
      }

      return repaired;
    } on ModelRepetitionLoopException catch (e) {
      debugPrint('[identifySpecies] Repetition loop detected: $e');
      _downloadService.updateState(
        _downloadService.state.copyWith(
          status: 'Analysis complete',
          phase: ModelBootPhase.ready,
        ),
      );
      return '{}';
    } catch (e) {
      debugPrint('[identifySpecies] Identification failed (model is fine): $e');
      _downloadService.updateState(
        _downloadService.state.copyWith(
          status: 'Identification failed',
          phase: ModelBootPhase.failed,
          error: e.toString(),
        ),
      );
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
      throw Exception('Model not loaded. Please wait for model to download.');
    }

    try {
      _downloadService.updateState(
        _downloadService.state.copyWith(
          status: 'Answering question...',
          phase: ModelBootPhase.analyzing,
        ),
      );

      _emitProgress(onProgress, 'Starting...', 0.0);

      // Use optimized generation method for text-based question
      final response = await _runtime.generateResponse(
        _model!,
        question,
        systemInstruction: systemInstruction ?? ChatPrompts.answerSystemInstruction('English'),
        temperature: 0.7,
        topK: 32,
        topP: 0.9,
        onProgress: onProgress,
        onToken: onToken,
      );

      _downloadService.updateState(
        _downloadService.state.copyWith(
          status: 'Question answered',
          phase: ModelBootPhase.ready,
        ),
      );

      return response.trim();
    } catch (e) {
      final errorMessage = 'Question answering failed: $e';
      _downloadService.updateState(
        _downloadService.state.copyWith(
          status: errorMessage,
          phase: ModelBootPhase.failed,
          error: errorMessage,
        ),
      );
      rethrow;
    }
  }

  /// Translate [text] to [targetLang] using the on-device Gemma model.
  Future<String> translate(
    String text,
    String targetLang, {
    void Function(String token)? onToken,
  }) async {
    if (_model == null) {
      throw Exception('Model not loaded. Please wait for model to download.');
    }

    final prompt = ChatPrompts.translatePrompt(targetLang, text);

    try {
      final response = await _runtime.generateResponse(
        _model!,
        prompt,
        systemInstruction: ChatPrompts.translateSystemInstruction,
        temperature: 0.3,
        topK: 16,
        topP: 0.5,
        maxTokens: 1024,
        onToken: onToken,
      );

      return response.trim();
    } catch (e) {
      debugPrint('Translation failed: $e');
      rethrow;
    }
  }

  void dispose() {
    if (_ownsDownloadService) {
      _downloadService.dispose();
    }
    _runtime.dispose();
    super.dispose();
  }
}
