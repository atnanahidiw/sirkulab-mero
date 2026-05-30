import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import '../models/model_spec.dart';

/// Returns true when [text] contains a word or short phrase repeated
/// consecutively more than [threshold] times — the hallmark of a
/// degeneration loop (e.g. "Quadri Quadri Quadri...").
bool _isRepetitionLoop(String text, {int threshold = 6}) {
  if (text.isEmpty) return false;
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

class ModelRepetitionLoopException implements Exception {
  final String message;

  const ModelRepetitionLoopException(this.message);

  @override
  String toString() => 'ModelRepetitionLoopException: $message';
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
    bool useNativeToolCalling = true,
    int maxTokens,
    double temperature,
    int topK,
    double topP,
    int seed,
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  });

  void dispose();
}

class FlutterGemmaModelRuntime implements ModelRuntime {
  final ModelType modelType;
  InferenceModel? _cachedModel;
  bool _isInitialized = false;

  static const bool _useGpu = true;

  FlutterGemmaModelRuntime({
    required this.modelType,
  });

  @override
  Future<InferenceModel> getActiveModel({required int maxTokens}) async {
    try {
      if (_cachedModel != null && _isInitialized) {
        return _cachedModel!;
      }

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
      await Future.any([
        FlutterGemma.installModel(
                modelType: modelType,
                fileType: ModelFileType.litertlm)
            .fromFile(filePath)
            .install(),
        Future.delayed(const Duration(minutes: 5), () {
          throw TimeoutException(
            'Model installation timed out after 5 minutes',
          );
        }),
      ]);

      _cachedModel = null;
      _isInitialized = false;
    } catch (e) {
      debugPrint('Model installation failed: $e');
      rethrow;
    }
  }

  @override
  Future<String> generateResponse(
    InferenceModel model,
    String prompt, {
    String? systemInstruction,
    Uint8List? imageBytes,
    List<ToolSpec>? toolSpecs,
    bool useNativeToolCalling = true,
    int maxTokens = 4096,
    double temperature = 0.7,
    int topK = 40,
    double topP = 0.9,
    int seed = 31415926,
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  }) async {
    try {
      if (toolSpecs == null || toolSpecs.isEmpty) {
        return _generateWithoutToolCalling(
          model,
          prompt,
          systemInstruction: systemInstruction,
          imageBytes: imageBytes,
          maxTokens: maxTokens,
          temperature: temperature,
          topK: topK,
          topP: topP,
          seed: seed,
          onProgress: onProgress,
          onToken: onToken,
        );
      }

      return _generateWithToolCalling(
        model,
        prompt,
        systemInstruction: systemInstruction,
        imageBytes: imageBytes,
        toolSpecs: toolSpecs,
        useNativeToolCalling: useNativeToolCalling,
        maxTokens: maxTokens,
        temperature: temperature,
        topK: topK,
        topP: topP,
        seed: seed,
        onProgress: onProgress,
        onToken: onToken,
      );
    } catch (e) {
      debugPrint('Generation failed: $e');
      rethrow;
    }
  }

  Future<String> _generateWithoutToolCalling(
    InferenceModel model,
    String prompt, {
    String? systemInstruction,
    Uint8List? imageBytes,
    required int maxTokens,
    required double temperature,
    required int topK,
    required double topP,
    required int seed,
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  }) async {
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
      if (imageBytes != null) {
        onProgress?.call('Sending image...', 0.30);
        await session.addQueryChunk(Message.withImage(
          text: '',
          imageBytes: imageBytes,
          isUser: true,
        ));
      }

      onProgress?.call('Sending prompt...', 0.35);
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

  Future<String> _generateWithToolCalling(
    InferenceModel model,
    String prompt, {
    String? systemInstruction,
    Uint8List? imageBytes,
    required List<ToolSpec> toolSpecs,
    required bool useNativeToolCalling,
    required int maxTokens,
    required double temperature,
    required int topK,
    required double topP,
    required int seed,
    void Function(String phase, double progress)? onProgress,
    void Function(String token)? onToken,
  }) async {
    final isNative = useNativeToolCalling;

    // Shared setup: only the response handling differs between native and app-side tool flow.
    final chat = await model.createChat(
      supportImage: imageBytes != null,
      tools: isNative ? ToolSpec.toTools(toolSpecs) : const <Tool>[],
      supportsFunctionCalls: isNative,
      toolChoice: isNative ? ToolChoice.required : ToolChoice.none,
      randomSeed: seed,
      temperature: temperature,
      topK: topK,
      topP: topP,
      modelType: modelType,
      systemInstruction: isNative
          ? systemInstruction
          : _buildCustomToolCallingInstruction(
              systemInstruction: systemInstruction,
              toolSpecs: toolSpecs,
            ),
    );

    try {
      if (imageBytes != null) {
        onProgress?.call('Sending image...', 0.30);
        await chat.addQueryChunk(Message.withImage(
          text: '',
          imageBytes: imageBytes,
          isUser: true,
        ));
      }

      onProgress?.call('Sending prompt...', 0.35);
      await chat.addQueryChunk(Message.text(
        text: prompt,
        isUser: true,
      ));

      onProgress?.call(
        isNative ? 'Identifying species...' : 'Planning tool use...',
        0.45,
      );

      const int maxPasses = 5;
      int pass = 0;
      while (true) {
        pass++;
        debugPrint('── ${isNative ? 'Native' : 'Custom'} generation pass $pass ──');

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
            if (!isNative) {
              onToken?.call(response.token);
            }
          } else if (response is ThinkingResponse) {
            debugPrint('[Pass $pass] Thinking: ${response.content}');
          } else if (isNative && response is FunctionCallResponse) {
            // Native path: the model emits actual function call responses.
            toolWasCalled = true;
            debugPrint('[Pass $pass] Tool call: ${response.name}(${response.args})');
            onProgress?.call('Running tool: ${response.name}...', 0.55);
            final matchedSpec = toolSpecs.firstWhere(
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
          } else if (isNative && response is ParallelFunctionCallResponse) {
            toolWasCalled = true;
            debugPrint(
              '[Pass $pass] Parallel tool calls: ${response.calls.map((c) => '${c.name}(${c.args})').join(', ')}',
            );
            for (final call in response.calls) {
              final matchedSpec = toolSpecs.firstWhere(
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

        final rawOutput = responseBuffer.toString();
        debugPrint(
          '[Pass $pass] ${isNative ? 'Native' : 'Custom'} output: ${rawOutput.trim()}',
        );

        if (_isRepetitionLoop(rawOutput)) {
          debugPrint('[Pass $pass] Repetition loop detected — aborting generation.');
          throw const ModelRepetitionLoopException(
            'Model entered a repetition loop. Please try again.',
          );
        }

        if (isNative) {
          if (!toolWasCalled) {
            debugPrint('[Pass $pass] No tool calls — final answer returned after $pass pass(es)');
            onProgress?.call('Complete', 1.0);
            return rawOutput.trim();
          }

          debugPrint('[Pass $pass] Tool(s) dispatched — starting pass ${pass + 1}');
          onProgress?.call('Generating result...', 0.75);
          continue;
        }

        // App-side path: parse a JSON directive from plain text, then execute the tool locally.
        final directive = _parseCustomToolDirective(rawOutput.trim());
        if (directive.isFinal) {
          onProgress?.call('Complete', 1.0);
          return directive.content?.trim() ?? '';
        }

        final toolName = directive.toolName;
        if (toolName == null || toolName.isEmpty) {
          throw Exception('Custom tool calling response omitted the tool name.');
        }

        final matchedSpec = toolSpecs.firstWhere(
          (s) => s.name == toolName,
          orElse: () => throw Exception('No ToolSpec found for: $toolName'),
        );

        final args = directive.args ?? const <String, dynamic>{};
        debugPrint('[Pass $pass] App-side tool call: $toolName($args)');
        onProgress?.call('Running tool: $toolName...', 0.55);

        final result = await matchedSpec.execute(args);
        debugPrint('[Pass $pass] App-side tool result ($toolName): $result');

        await chat.addQueryChunk(Message.text(
          text: _buildCustomToolResultMessage(
            toolName: toolName,
            result: result,
          ),
          isUser: true,
        ));

        if (matchedSpec.subsequentPrompt != null) {
          await chat.addQueryChunk(matchedSpec.subsequentPrompt!);
        }

        onProgress?.call('Generating result...', 0.75);
      }
    } finally {
      await chat.close();
    }
  }

  String _buildCustomToolCallingInstruction({
    String? systemInstruction,
    required List<ToolSpec> toolSpecs,
  }) {
    final buffer = StringBuffer();

    if (systemInstruction != null && systemInstruction.trim().isNotEmpty) {
      buffer.writeln(systemInstruction.trim());
      buffer.writeln();
    }

    // Keep the model on a strict JSON contract so the app can drive the tool loop.
    buffer.writeln('<custom_tool_calling>');
    buffer.writeln(
      'You do not have native function calling. Use the following JSON protocol only.',
    );
    buffer.writeln(
      'If you need a tool, output EXACTLY one JSON object with this shape:',
    );
    buffer.writeln(
      '{"type":"tool_call","name":"tool_name","args":{...}}',
    );
    buffer.writeln('If you are done, output EXACTLY one JSON object with this shape:');
    buffer.writeln(
      '{"type":"final","content":"final answer text"}',
    );
    buffer.writeln('Never add markdown fences, explanation text, or extra keys.');
    buffer.writeln('Available tools:');
    for (final spec in toolSpecs) {
      buffer.writeln('- ${spec.name}: ${spec.description}');
      buffer.writeln('  parameters: ${jsonEncode(spec.parameters)}');
    }
    buffer.writeln('</custom_tool_calling>');

    return buffer.toString();
  }

  String _buildCustomToolResultMessage({
    required String toolName,
    required String result,
  }) {
    return '''
Tool result for `$toolName`:
$result

Continue using the custom tool protocol. If the task is complete, return the final JSON object only.
''';
  }

  _CustomToolDirective _parseCustomToolDirective(String rawOutput) {
    // Pull the first JSON object out of the model text and normalize it.
    final candidate = _extractJsonObject(rawOutput);
    final decoded = jsonDecode(candidate);

    if (decoded is! Map) {
      throw Exception('Custom tool calling response was not a JSON object.');
    }

    final data = decoded.cast<String, dynamic>();
    final type = data['type']?.toString().toLowerCase().trim();

    if (type == 'final') {
      final content = data['content']?.toString().trim() ?? '';
      return _CustomToolDirective.finalAnswer(content);
    }

    if (type == 'tool_call' || data.containsKey('name')) {
      final toolName = data['name']?.toString().trim() ?? '';
      final args = _decodeArgsMap(data['args'] ?? data['arguments']);
      return _CustomToolDirective.toolCall(toolName, args);
    }

    if (data.containsKey('tool_calls')) {
      final toolCalls = data['tool_calls'];
      if (toolCalls is List && toolCalls.isNotEmpty) {
        final first = toolCalls.first;
        if (first is Map) {
          final firstCall = first.cast<String, dynamic>();
          final toolName = firstCall['name']?.toString().trim() ?? '';
          final args = _decodeArgsMap(firstCall['args'] ?? firstCall['arguments']);
          return _CustomToolDirective.toolCall(toolName, args);
        }
      }
    }

    throw Exception('Custom tool calling response did not match the expected protocol.');
  }

  Map<String, dynamic> _decodeArgsMap(dynamic value) {
    if (value == null) {
      return <String, dynamic>{};
    }
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    }
    return <String, dynamic>{};
  }

  String _extractJsonObject(String rawOutput) {
    final trimmed = rawOutput.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');

    if (start < 0 || end < 0 || end <= start) {
      throw Exception('Custom tool calling response did not contain JSON.');
    }

    return trimmed.substring(start, end + 1);
  }

  @override
  void dispose() {
    _cachedModel?.close();
    _cachedModel = null;
    _isInitialized = false;
  }
}

class _CustomToolDirective {
  final bool isFinal;
  final String? content;
  final String? toolName;
  final Map<String, dynamic>? args;

  const _CustomToolDirective._({
    required this.isFinal,
    this.content,
    this.toolName,
    this.args,
  });

  factory _CustomToolDirective.finalAnswer(String content) =>
      _CustomToolDirective._(isFinal: true, content: content);

  factory _CustomToolDirective.toolCall(
    String toolName,
    Map<String, dynamic> args,
  ) =>
      _CustomToolDirective._(
        isFinal: false,
        toolName: toolName,
        args: args,
      );
}
