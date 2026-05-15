import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'visual_features_service.dart';

// ============================================================================
// BERT WordPiece Tokenizer
// ============================================================================

class BertTokenizer {
  final Map<String, int> _vocab = {};
  bool _loaded = false;

  int get vocabSize => _vocab.length;
  bool get isLoaded => _loaded;

  static const String clsToken = '[CLS]';
  static const String sepToken = '[SEP]';
  static const String padToken = '[PAD]';
  static const String unkToken = '[UNK]';

  late int clsId;
  late int sepId;
  late int padId;
  late int unkId;

  Future<void> load(String vocabContent) async {
    if (_loaded) return;
    int i = 0;
    for (final line in LineSplitter.split(vocabContent)) {
      final token = line.trim();
      if (token.isNotEmpty) {
        _vocab[token] = i++;
      }
    }
    clsId = _vocab[clsToken] ?? 101;
    sepId = _vocab[sepToken] ?? 102;
    padId = _vocab[padToken] ?? 0;
    unkId = _vocab[unkToken] ?? 100;
    _loaded = true;
    debugPrint('BertTokenizer: ${_vocab.length} tokens loaded');
  }

  List<int> encode(String text, {int maxLen = 512}) {
    final tokens = <int>[clsId];
    for (final raw in _basicTokenize(text)) {
      if (tokens.length >= maxLen - 1) break;
      tokens.addAll(_wordPiece(raw, maxLen - 1 - tokens.length));
    }
    tokens.add(sepId);

    final out = List<int>.filled(maxLen, padId);
    final n = math.min(tokens.length, maxLen);
    for (int i = 0; i < n; i++) out[i] = tokens[i];
    return out;
  }

  List<String> _basicTokenize(String text) {
    final result = <String>[];
    final buf = StringBuffer();
    for (final ch in text.toLowerCase().split('')) {
      if (ch == "'") {
        buf.write(ch);
      } else if (RegExp(r'[a-z0-9]').hasMatch(ch)) {
        buf.write(ch);
      } else {
        if (buf.isNotEmpty) {
          result.add(buf.toString());
          buf.clear();
        }
        if (!RegExp(r'\s').hasMatch(ch)) {
          result.add(ch);
        }
      }
    }
    if (buf.isNotEmpty) result.add(buf.toString());
    return result;
  }

  List<int> _wordPiece(String token, int maxSubTokens) {
    if (_vocab.containsKey(token)) return [_vocab[token]!];
    final ids = <int>[];
    int start = 0;
    while (start < token.length && ids.length < maxSubTokens) {
      int end = token.length;
      bool found = false;
      while (end > start) {
        final sub = start == 0
            ? token.substring(start, end)
            : '##${token.substring(start, end)}';
        if (_vocab.containsKey(sub)) {
          ids.add(_vocab[sub]!);
          start = end;
          found = true;
          break;
        }
        end--;
      }
      if (!found) {
        ids.add(unkId);
        break;
      }
    }
    return ids;
  }
}

// ============================================================================
// Zip-based model extraction
// ============================================================================

Future<String> _extractModelZip({
  required String zipAssetPath,
  required String extractDir,
}) async {
  final dir = Directory(extractDir);
  if (await dir.exists()) {
    debugPrint('ModelZip: using cached $extractDir');
    return extractDir;
  }

  final raw = await rootBundle.load(zipAssetPath);
  final bytes = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
  final archive = ZipDecoder().decodeBytes(bytes);

  // Determine common root prefix from first entry to strip it.
  String prefix = '';
  if (archive.isNotEmpty && archive.first.name.contains('/')) {
    prefix = archive.first.name.split('/').first + '/';
  }

  await dir.create(recursive: true);
  for (final entry in archive) {
    if (entry.isFile) {
      // Strip common prefix so files go directly into extractDir.
      final relPath = entry.name.startsWith(prefix)
          ? entry.name.substring(prefix.length)
          : entry.name;
      final file = File(p.join(extractDir, relPath));
      await file.create(recursive: true);
      await file.writeAsBytes(entry.content);
    }
  }

  debugPrint('ModelZip: extracted ${archive.length} files to $extractDir');
  return extractDir;
}

// ============================================================================
// BGE Embedder — onnxruntime + BERT Tokenizer
// ============================================================================

class BgeEmbedder implements TextEmbedder {
  final BertTokenizer _tokenizer = BertTokenizer();
  OrtSession? _session;
  bool _loaded = false;
  bool _disposed = false;

  static const int embDim = 384;
  static const int _maxLen = 512;

  String? _modelDir;
  List<OrtValue> _allocatedTensors = [];

  @override
  bool get isLoaded => _loaded && !_disposed;

  BgeEmbedder();

  /// Load ONNX model (from zip) + vocab.
  Future<void> load({
    String zipAssetPath = 'assets/models/bge-small-en-v1.5.zip',
    String? cacheDir,
  }) async {
    OrtEnv.instance.init();

    final appDir = await getApplicationDocumentsDirectory();
    final extractDir = cacheDir ?? p.join(appDir.path, 'bge-small-en-v1.5');
    await _extractModelZip(zipAssetPath: zipAssetPath, extractDir: extractDir);
    _modelDir = extractDir;

    // Load tokenizer
    final vocabContent =
        await File(p.join(extractDir, 'vocab.txt')).readAsString();
    await _tokenizer.load(vocabContent);

    // Create ONNX session
    final modelPath = p.join(extractDir, 'model_q4f16.onnx');
    final opts = OrtSessionOptions();
    opts.setIntraOpNumThreads(2);
    opts.setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      opts.appendCoreMLProvider(CoreMLFlags.useNone);
    }
    opts.appendCPUProvider(CPUFlags.useArena);

    _session = OrtSession.fromFile(File(modelPath), opts);
    _loaded = true;
    debugPrint(
        'BgeEmbedder: loaded — inputs: ${_session!.inputNames}, outputs: ${_session!.outputNames}');
  }

  @override
  Future<Float32List> embed(String text) async {
    if (!isLoaded) throw StateError('BgeEmbedder not loaded');
    final session = _session!;

    // Tokenize
    final ids = _tokenizer.encode(text, maxLen: _maxLen);
    final attn = List.generate(_maxLen, (i) => ids[i] == 0 ? 0 : 1);
    final types = List<int>.filled(_maxLen, 0);

    // Create input tensors: [1, maxLen]
    final inIds = OrtValueTensor.createTensorWithDataList(
      Int32List.fromList(ids),
      [1, 512],
    );
    final inAttn = OrtValueTensor.createTensorWithDataList(
      Int32List.fromList(attn),
      [1, 512],
    );
    final inTypes = OrtValueTensor.createTensorWithDataList(
      Int32List.fromList(types),
      [1, 512],
    );

    _allocatedTensors.addAll([inIds, inAttn, inTypes]);

    // Run inference
    final runOptions = OrtRunOptions();
    final inputs = {
      'input_ids': inIds,
      'attention_mask': inAttn,
      'token_type_ids': inTypes,
    };
    final outputNames = session.outputNames;
    final outputs = session.run(runOptions, inputs, outputNames);

    // Extract sentence_embedding output
    final embIdx = outputNames.indexOf('sentence_embedding');
    final result = Float32List(embDim);

    if (embIdx >= 0 && embIdx < outputs.length) {
      final embTensor = outputs[embIdx] as OrtValueTensor?;
      if (embTensor != null) {
        final raw = embTensor.value;
        // Shape is [1, 384] → nested list: [[f0, f1, ..., f383]]
        if (raw is List && raw.isNotEmpty) {
          final inner = raw[0] as List;
          final n = math.min(inner.length, embDim);
          for (int i = 0; i < n; i++) {
            result[i] = (inner[i] as num).toDouble();
          }
        }
      }
    }

    // Cleanup tensors
    for (final t in _allocatedTensors) {
      t.release();
    }
    _allocatedTensors.clear();
    runOptions.release();

    return result;
  }

  @override
  Future<void> dispose() async {
    _session?.release();
    for (final t in _allocatedTensors) {
      t.release();
    }
    _allocatedTensors.clear();
    OrtEnv.instance.release();
    _disposed = true;
  }

  Future<void> clearCache() async {
    if (_modelDir != null) {
      await Directory(_modelDir!).delete(recursive: true);
      _modelDir = null;
    }
  }
}
