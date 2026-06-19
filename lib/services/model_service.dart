import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'analysis_story_formatter.dart';
import 'model_boot_state.dart';
import 'model_download_service.dart';
import 'model_runtime.dart';
import 'species_service.dart';
import 'vision_runtime.dart';
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

  // ───────────────────────── Model configuration ─────────────────────────
  // Text reasoning core. The model is TEXT-ONLY and never sees the photo — the
  // image is handled by [VisionRuntime] through the `extract_visual_features`
  // tool. Swapping the LLM should only touch this block.
  static const ModelType modelType = ModelType.qwen3;
  static const int _maxTokens = 4096;
  static int get maxTokens => _maxTokens;

  // Qwen3-0.6B (LiteRT) — ~0.47 GB; strong tool calling + reasoning mode.
  final String modelUrl =
      'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/$_modelRevision/Qwen3-0.6B.litertlm';

  /// Human-readable *download* size (the vision model is bundled in assets, so
  /// only the LLM is downloaded). Kept here next to the URL so swapping models
  /// only touches this file, never the l10n.
  final String downloadSizeLabel = '0.5GB';
  // ────────────────────────────────────────────────────────────────────────

  late final ModelRuntime _runtime;
  late final ModelDownloadService _downloadService;
  late final bool _ownsDownloadService;
  final SpeciesService _speciesService = SpeciesService();
  final VisionRuntime _vision = VisionRuntime();
  InferenceModel? _model;

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
    // The vision model is bundled in assets → load it eagerly, offline.
    // notifyListeners on completion so the UI's vision indicator updates.
    unawaited(_vision.loadFromAssets().then((_) {
      notifyListeners();
    }).catchError((Object e) {
      debugPrint('VisionRuntime load failed: $e');
      notifyListeners();
    }));
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
  bool get isModelLoaded => _downloadService.isModelLoaded && _vision.isLoaded;
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
      // Tool ordering: the model must OBSERVE before it can SEARCH. A 0.6B model
      // otherwise jumps straight to search_similar_features with all-"none"
      // traits (it can't see the photo). This flag gates search until extract
      // has run at least once. `observed` holds the latest real traits so the
      // search can backfill fields the model fails to copy (it tends to pass
      // "unknown" even right after observing).
      var hasObserved = false;
      final observed = <String, String>{};

      // Vision tool — the text-only LLM "observes" the photo through this.
      final extractSpec = ToolSpec(
        name: ChatPrompts.extractVisualFeaturesToolDef['name'] as String,
        description:
            ChatPrompts.extractVisualFeaturesToolDef['description'] as String,
        parameters: ChatPrompts.extractVisualFeaturesToolDef['parameters']
            as Map<String, dynamic>,
        execute: (args) async {
          final focus = (args['focus'] as List?)?.cast<String>();
          final traits =
              await _vision.extractVisualFeatures(imageBytes, focus: focus);
          hasObserved = true;
          observed.addAll(traits); // merge so focused re-observes update fields
          return jsonEncode(traits);
        },
      );

      // A search value is "missing" if blank or a filler the model emits when it
      // fails to copy the observed trait → fall back to the real observed value.
      String trait(Map<String, dynamic> args, String argKey, String traitKey) {
        final v = (args[argKey] as String?)?.trim() ?? '';
        const filler = {'', 'none', 'unknown', 'n/a', 'na', 'null'};
        return filler.contains(v.toLowerCase()) ? (observed[traitKey] ?? '') : v;
      }

      // Verify tool (v2) — score arbitrary claims against the photo via the
      // runtime text encoder. Only advertised when the text encoder loaded, so
      // the prompt never offers a tool the runtime can't back.
      final checkSpec = ToolSpec(
        name: ChatPrompts.checkVisualEvidenceToolDef['name'] as String,
        description:
            ChatPrompts.checkVisualEvidenceToolDef['description'] as String,
        parameters: ChatPrompts.checkVisualEvidenceToolDef['parameters']
            as Map<String, dynamic>,
        execute: (args) async {
          final claims = (args['claims'] as List?)?.cast<String>() ?? const [];
          if (claims.isEmpty) {
            return 'No claims provided. Pass one or more visual claims to score.';
          }
          final scores = await _vision.checkVisualEvidence(imageBytes, claims);
          return jsonEncode({
            for (final e in scores.entries)
              e.key: double.parse(e.value.toStringAsFixed(3)),
          });
        },
      );

      final searchSpec = ToolSpec(
        name: ChatPrompts.speciesSearchToolDef['name'] as String,
        description: ChatPrompts.speciesSearchToolDef['description'] as String,
        parameters: ChatPrompts.speciesSearchToolDef['parameters']
            as Map<String, dynamic>,
        execute: (args) async {
          // Guardrail: refuse to search before the photo has been observed, so
          // an all-"none" search can't short-circuit the workflow.
          if (!hasObserved) {
            return 'ERROR: You have not observed the photo yet. Call '
                'extract_visual_features FIRST to get the real visual traits, '
                'then call search_similar_features with those values (never "none").';
          }
          // Backfill visual traits the model failed to copy from the observation
          // (it often passes "unknown"). Taxonomy hints are the model's own
          // inference, so those are left as-is.
          final results = await _speciesService.searchSimilarByFeatures(
            color: trait(args, 'color', 'color'),
            bodyShape: trait(args, 'body_shape', 'body_shape'),
            distinctiveMarks: trait(args, 'distinctive_marks', 'distinctive_marks'),
            texture: trait(args, 'texture', 'texture'),
            sizeClass: trait(args, 'size_class', 'size_class'),
            pattern: trait(args, 'pattern', 'pattern'),
            visualGroup: trait(args, 'visualGroup', 'visual_group'),
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

      // No image is sent to the model — it is text-only and reaches the photo
      // only through the vision tools.
      final result = await _runtime.generateResponse(
        _model!,
        ChatPrompts.identifyInputPrompt,
        systemInstruction: ChatPrompts.identifySystemInstruction(languageName),
        toolSpecs: [
          extractSpec,
          if (_vision.canVerify) checkSpec,
          searchSpec,
        ],
        // Native function calling: Qwen3 emits real tool calls via its chat
        // template, avoiding the conflicting custom-JSON envelope that made the
        // model skip the tools and emit an immediate "Unknown" answer.
        useNativeToolCalling: true,
        // Thinking mode: lets Qwen3 plan the multi-step workflow (observe →
        // search → verify) instead of shortcutting — the 0.6B's planning lever.
        enableThinking: true,
        temperature: 0.6,
        topK: 100,
        topP: 0.9,
        languageName: languageName,
        onProgress: onProgress,
        onTrace: onTrace,
      );
      _vision.disposeImageCache();

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
    unawaited(_vision.dispose());
    super.dispose();
  }
}
