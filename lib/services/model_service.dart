import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'model_boot_state.dart';
import 'model_download_service.dart';
import 'species_service.dart';
import '../models/chat_prompts.dart';
import '../models/model_spec.dart';

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

abstract class ModelRuntime {
  Future<InferenceModel> getActiveModel({
    required int maxTokens,
  });

  Future<void> installFromFile(String filePath);

  Future<String> generateResponse(
    InferenceModel model,
    String prompt, {
    String? systemInstruction,
    Uint8List? imageBytes,
    List<ToolSpec>? toolSpecs,
    int maxTokens,
    double temperature,
    int topK,
    double topP,
    int seed,
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  });

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

      // Clear cached model after installation to ensure fresh loading
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
  @override
  Future<String> generateResponse(
    InferenceModel model,
    String prompt, {
    String? systemInstruction,
    Uint8List? imageBytes,
    List<ToolSpec>? toolSpecs,
    int maxTokens = 4096,
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
          enableVisionModality: imageBytes != null,
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
          try {
            await session.close();
          } catch (closeError) {
            debugPrint('Session close error (non-fatal): $closeError');
          }
        }
      }

      // ── Tool-calling flow via InferenceChat ──
      onProgress?.call('Preparing chat...', 0.15);

      final chat = await model.createChat(
        supportImage: imageBytes != null,
        tools: resolvedTools,
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
              if (!useToolCalling) onToken?.call(response.token);
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
  static const ModelType modelType = ModelType.gemma4;
  static const int maxTokens = 4096;

  late final ModelRuntime _runtime;
  late final ModelDownloadService _downloadService;
  final SpeciesService _speciesService = SpeciesService();
  InferenceModel? _model;

  final String modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

  ModelService({
    ModelDownloadBackend? downloader,
    ModelRuntime? runtime,
    ModelBootStateStore? stateStore,
    bool autoInitialize = true,
  }) {
    _runtime = runtime ??
        FlutterGemmaModelRuntime(
          modelType: modelType,
        );
    _downloadService = ModelDownloadService(
      downloader: downloader,
      stateStore: stateStore,
      modelUrl: modelUrl,
      installModel: _installDownloadedModel,
      tryActivateExistingModel: _tryActivateExistingModel,
    );

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
    String imageFormat,
  ) async {
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
        systemInstruction: ChatPrompts.identifySystemInstruction,
        imageBytes: imageBytes,
        toolSpecs: [searchSpec],
        temperature: 0.6,
        topK: 100,
        topP: 0.9,
        onProgress: (phase, progress) {
          debugPrint('Progress: $phase ($progress)');
        },
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

      // Safely read confidence
      final confidence = repairedMap['confidence']?.toString().toLowerCase();

      // Reject low confidence
      if (confidence == 'low') {
        return '{}';
      }

      return repaired;
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

      onProgress?.call('Starting...', 0.0);

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
    _downloadService.dispose();
    _runtime.dispose();
    super.dispose();
  }
}
