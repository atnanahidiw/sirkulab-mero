import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'clip_tokenizer.dart';

/// On-device vision tool backing `extract_visual_features` (and, in v2,
/// `check_visual_evidence`).
///
/// It runs a **text-aligned** DINO image encoder — dino.txt / Talk2DINO
/// (DINOv2 + text alignment; SOTA on iNaturalist zero-shot) — via ONNX Runtime
/// ([flutter_onnxruntime]; CoreML on iOS, NNAPI on Android).
///
/// `extract_visual_features` does **zero-shot attribute classification**: embed
/// the photo once, then for each attribute score the image embedding against
/// that attribute's controlled vocabulary of label-text embeddings (precomputed
/// offline with the same model's text encoder and shipped as an asset) and pick
/// the best label. The output is the structured trait text that the unchanged
/// `search_similar_features` (FTS5 + Dice) expects.
///
/// The vision model is small enough (~12–22 MB int8 image encoder) to bundle in
/// `assets/`, so it needs no download and works fully offline.
class VisionRuntime {
  VisionRuntime({
    this.modelAsset = 'assets/models/dino_image_encoder.onnx',
    this.attributeEmbeddingsAsset = 'assets/models/dino_attribute_embeddings.json',
    this.textModelAsset = 'assets/models/dino_text_encoder.onnx',
    ClipTokenizer? tokenizer,
  }) : _tokenizer = tokenizer ?? ClipTokenizer();

  /// Bundled int8 DINO image-encoder ONNX (dino.txt / Talk2DINO).
  final String modelAsset;

  /// Precomputed label-text embeddings per attribute, produced offline with the
  /// SAME model's text encoder. JSON shape:
  /// `{ "color": [{"label": "orange", "emb": [..]}, ..], "pattern": [..], .. }`
  final String attributeEmbeddingsAsset;

  /// Bundled int8 text-encoder ONNX (CLIP text → Talk2DINO projection). Powers
  /// `check_visual_evidence` — embeds arbitrary claim text at runtime.
  final String textModelAsset;

  final ClipTokenizer _tokenizer;

  // ── Model-specific constants — match scripts/export_vision_model.py output. ──
  // Talk2DINO (dinov2_vitb14_reg) CLS-saliency-pooled single-vector export.
  static const int _inputSize = 518; // 518/14 = 37 patches/side (ViT-B/14)
  static const String _inputName = 'pixel_values'; // forced by torch.onnx.export
  static const String _outputName = 'image_embeds'; // forced by torch.onnx.export
  // DINOv2 uses ImageNet normalisation.
  static const List<double> _mean = [0.485, 0.456, 0.406];
  static const List<double> _std = [0.229, 0.224, 0.225];
  // Text-encoder tensor names (forced by torch.onnx.export).
  static const String _textInputName = 'token_ids';
  static const String _textOutputName = 'text_embeds';

  OrtSession? _session;
  OrtSession? _textSession;
  // attribute → ordered list of (label, L2-normalised embedding)
  final Map<String, List<_LabelEmbedding>> _attributeVocab = {};

  // Per-photo image-embedding cache so extract + multiple verify calls on the
  // same photo reuse one forward pass.
  Uint8List? _cachedImageKey;
  Float32List? _cachedImageEmbedding;

  bool get isLoaded => _session != null && _attributeVocab.isNotEmpty;

  /// Whether `check_visual_evidence` (the text-encoder path) is available. If the
  /// text encoder fails to load, the runtime still serves v1 (`extract`).
  bool get canVerify => _textSession != null && _tokenizer.isLoaded;

  Future<void> loadFromAssets() async {
    _session ??= await OnnxRuntime().createSessionFromAsset(modelAsset);
    if (_attributeVocab.isEmpty) await _loadAttributeVocab();
    // v2 text encoder + tokenizer — best-effort; degrade to v1 if unavailable.
    if (_textSession == null) {
      try {
        _textSession = await OnnxRuntime().createSessionFromAsset(textModelAsset);
        await _tokenizer.load();
      } catch (e, st) {
        _textSession = null;
        debugPrint('VisionRuntime: text encoder unavailable, '
            'check_visual_evidence disabled: $e\n$st');
      }
    }
  }

  Future<void> _loadAttributeVocab() async {
    final raw = await rootBundle.loadString(attributeEmbeddingsAsset);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    _attributeVocab.clear();
    for (final entry in decoded.entries) {
      final labels = (entry.value as List).map((e) {
        final m = e as Map<String, dynamic>;
        final emb = Float32List.fromList(
          (m['emb'] as List).map((v) => (v as num).toDouble()).toList(),
        );
        return _LabelEmbedding(m['label'] as String, _l2normalize(emb));
      }).toList();
      _attributeVocab[entry.key] = labels;
    }
  }

  /// Tool 1 — observe the photo: returns the best-matching label per attribute,
  /// as the structured trait text `search_similar_features` consumes.
  /// [focus] restricts which attributes to (re)examine on a retry.
  Future<Map<String, String>> extractVisualFeatures(
    Uint8List image, {
    List<String>? focus,
  }) async {
    final imageEmb = await _embedImage(image);
    final attributes = (focus == null || focus.isEmpty)
        ? _attributeVocab.keys
        : focus.where(_attributeVocab.containsKey);

    final result = <String, String>{};
    for (final attr in attributes) {
      final labels = _attributeVocab[attr]!;
      var bestLabel = '';
      var bestScore = -2.0;
      for (final le in labels) {
        final score = _dot(imageEmb, le.embedding); // both L2-normalised → cosine
        if (score > bestScore) {
          bestScore = score;
          bestLabel = le.label;
        }
      }
      result[attr] = bestLabel;
    }
    return result;
  }

  /// Tool 3 (v2) — score how well each text claim matches the photo.
  ///
  /// Embeds the photo once (cached) and each claim via the runtime text encoder
  /// (CLIP text → Talk2DINO projection, same space), then returns the cosine
  /// similarity per claim. Scores are **relative** (typically ~−0.1 … +0.4):
  /// higher = better match; compare claims against one another rather than to a
  /// fixed threshold.
  Future<Map<String, double>> checkVisualEvidence(
    Uint8List image,
    List<String> claims,
  ) async {
    if (!canVerify) {
      throw StateError(
        'check_visual_evidence unavailable: text encoder not loaded.',
      );
    }
    final imageEmb = await _embedImage(image);
    final result = <String, double>{};
    for (final claim in claims) {
      final ids = _tokenizer.tokenize(claim); // Int32List [contextLength]
      final inputs = {
        _textInputName: await OrtValue.fromList(
          ids,
          [1, _tokenizer.contextLength],
        ),
      };
      final outputs = await _textSession!.run(inputs);
      final flat = (await outputs[_textOutputName]!.asList())
          .map((v) => (v as num).toDouble())
          .toList();
      final txtEmb = _l2normalize(Float32List.fromList(flat));
      result[claim] = _dot(imageEmb, txtEmb); // both L2-normalised → cosine
    }
    return result;
  }

  /// Drop the per-photo embedding when an identification finishes.
  void disposeImageCache() {
    _cachedImageKey = null;
    _cachedImageEmbedding = null;
  }

  Future<void> dispose() async {
    disposeImageCache();
    await _session?.close();
    await _textSession?.close();
    _session = null;
    _textSession = null;
    _attributeVocab.clear();
  }

  // ── internals ──

  Future<Float32List> _embedImage(Uint8List image) async {
    if (identical(_cachedImageKey, image) && _cachedImageEmbedding != null) {
      return _cachedImageEmbedding!;
    }
    final input = _preprocess(image); // [1,3,H,W] float32
    final inputs = {
      _inputName: await OrtValue.fromList(
        input,
        [1, 3, _inputSize, _inputSize],
      ),
    };
    final outputs = await _session!.run(inputs);
    final flat = (await outputs[_outputName]!.asList())
        .map((v) => (v as num).toDouble())
        .toList();
    final emb = _l2normalize(Float32List.fromList(flat));
    _cachedImageKey = image;
    _cachedImageEmbedding = emb;
    return emb;
  }

  /// Decode → resize to [_inputSize] → RGB, normalised, NCHW float32.
  Float32List _preprocess(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('VisionRuntime: could not decode image');
    }
    final resized = img.copyResize(
      decoded,
      width: _inputSize,
      height: _inputSize,
      interpolation: img.Interpolation.cubic,
    );

    final out = Float32List(3 * _inputSize * _inputSize);
    final plane = _inputSize * _inputSize;
    for (var y = 0; y < _inputSize; y++) {
      for (var x = 0; x < _inputSize; x++) {
        final p = resized.getPixel(x, y);
        final idx = y * _inputSize + x;
        out[idx] = (p.rNormalized - _mean[0]) / _std[0]; // R plane
        out[plane + idx] = (p.gNormalized - _mean[1]) / _std[1]; // G plane
        out[2 * plane + idx] = (p.bNormalized - _mean[2]) / _std[2]; // B plane
      }
    }
    return out;
  }

  static Float32List _l2normalize(Float32List v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) return v;
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / norm;
    }
    return out;
  }

  static double _dot(Float32List a, Float32List b) {
    final n = math.min(a.length, b.length);
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}

class _LabelEmbedding {
  const _LabelEmbedding(this.label, this.embedding);
  final String label;
  final Float32List embedding;
}
