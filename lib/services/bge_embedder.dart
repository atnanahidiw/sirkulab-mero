import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
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

  await dir.create(recursive: true);
  for (final entry in archive) {
    if (entry.isFile) {
      final file = File(p.join(extractDir, entry.name));
      await file.create(recursive: true);
      await file.writeAsBytes(entry.content);
    }
  }

  debugPrint('ModelZip: extracted ${archive.length} files to $extractDir');
  return extractDir;
}

// ============================================================================
// BGE Embedder — flutter_onnxruntime + BERT Tokenizer
// ============================================================================

class BgeEmbedder implements TextEmbedder {
  final BertTokenizer _tokenizer = BertTokenizer();
  final OnnxRuntime _ort = OnnxRuntime();
  OrtSession? _session;
  bool _loaded = false;
  bool _disposed = false;

  static const int embDim = 384;
  static const int _maxLen = 512;

  String? _modelDir;

  @override
  bool get isLoaded => _loaded && !_disposed;

  BgeEmbedder();

  /// Load ONNX model (from zip) + vocab.
  Future<void> load({
    String zipAssetPath = 'assets/models/bge-small-en-v1.5.zip',
    String? cacheDir,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final extractDir = cacheDir ?? p.join(appDir.path, 'bge-small-en-v1.5');
    await _extractModelZip(zipAssetPath: zipAssetPath, extractDir: extractDir);
    _modelDir = extractDir;

    // Load tokenizer
    final vocabContent =
        await File(p.join(extractDir, 'vocab.txt')).readAsString();
    await _tokenizer.load(vocabContent);

    // Create ONNX session with CoreML provider
    final modelPath = p.join(extractDir, 'model_q4f16.onnx');
    final opts = OrtSessionOptions(
      intraOpNumThreads: 2,
      providers: [OrtProvider.CORE_ML, OrtProvider.CPU],
    );
    _session = await _ort.createSession(modelPath, options: opts);
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
    const shape = [1, 512];

    final inIds = await OrtValue.fromList(
      Int32List.fromList(ids),
      shape,
    );
    final inAttn = await OrtValue.fromList(
      Int32List.fromList(attn),
      shape,
    );
    final inTypes = await OrtValue.fromList(
      Int32List.fromList(types),
      shape,
    );

    // Run inference
    final outputMap = await session.run({
      'input_ids': inIds,
      'attention_mask': inAttn,
      'token_type_ids': inTypes,
    });

    // Extract sentence_embedding output
    final embTensor = outputMap['sentence_embedding']!;
    final embList = await embTensor.asFlattenedList();

    final result = Float32List(embDim);
    final n = math.min(embList.length, embDim);
    for (int i = 0; i < n; i++) {
      result[i] = (embList[i] as num).toDouble();
    }

    // Cleanup
    await inIds.dispose();
    await inAttn.dispose();
    await inTypes.dispose();
    await embTensor.dispose();

    return result;
  }

  @override
  Future<void> dispose() async {
    await _session?.close();
    _disposed = true;
  }

  Future<void> clearCache() async {
    if (_modelDir != null) {
      await Directory(_modelDir!).delete(recursive: true);
      _modelDir = null;
    }
  }
}
