import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Abstract interface for on-device text embedding.
/// Implementation: convert BGE-small-en-v1.5 → ONNX → `onnxruntime` package.
abstract class TextEmbedder {
  /// Returns a 384-dim vector for [text] (NOT necessarily unit-norm).
  Future<Float32List> embed(String text);

  bool get isLoaded;
  Future<void> dispose();
}

/// Stemmer — "stripes"/"striped"/"stripe" → normalized token.
String _normalizeToken(String t) {
  if (t.endsWith('ed') && t.length > 4) return t.substring(0, t.length - 2);
  if (t.endsWith('ies') && t.length > 5) {
    return '${t.substring(0, t.length - 3)}y';
  }
  if (t.endsWith('es') && t.length > 4) return t.substring(0, t.length - 2);
  if (t.endsWith('s') && t.length > 3 && !t.endsWith('ss')) {
    return t.substring(0, t.length - 1);
  }
  return t;
}

Set<String> _tokenize(String text) => text
    .toLowerCase()
    .split(RegExp(r'\W+'))
    .where((t) => t.length > 1)
    .map(_normalizeToken)
    .toSet();

/// Dice coefficient ∈ [0, 1].
/// Dice = 2|A∩B| / (|A| + |B|). Better than Jaccard for short
/// biological descriptions — less aggressive on low-token-count matches.
double _tokenOverlap(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0.0;
  final ta = _tokenize(a);
  final tb = _tokenize(b);
  if (ta.isEmpty || tb.isEmpty) return 0.0;
  final intersection = ta.intersection(tb).length;
  if (intersection == 0) return 0.0;
  return (2.0 * intersection) / (ta.length + tb.length);
}

class SimilarSpeciesResult {
  final String scientificName;
  final String commonName;
  final String genus;
  final Map<String, String> visualFeatures;

  /// Final blended score ∈ [0, 1].
  final double score;

  /// Semantic embedding cosine similarity ∈ [0, 1].
  final double semanticScore;

  /// VF token overlap score ∈ [0, 1].
  final double tokenScore;

  /// Taxonomy token overlap score ∈ [0, 1].
  final double taxonomyScore;

  const SimilarSpeciesResult({
    required this.scientificName,
    required this.commonName,
    required this.genus,
    required this.visualFeatures,
    required this.score,
    required this.semanticScore,
    required this.tokenScore,
    required this.taxonomyScore,
  });
}

class VisualFeaturesSearchService {
  static const _vfKeys = [
    'color',
    'body_shape',
    'distinctive_marks',
    'texture',
    'size_class',
    'pattern',
  ];

  static const _taxKeys = ['class', 'order', 'family', 'genus'];

  /// Biologically-informed VF field weights.
  static const _vfWeights = {
    'pattern': 0.30,
    'body_shape': 0.25,
    'color': 0.20,
    'distinctive_marks': 0.15,
    'texture': 0.05,
    'size_class': 0.05,
  };

  /// Blend weights for the 3 independent signals.
  /// These are applied after each signal is independently computed.
  static const _wSemantic = 0.55;
  static const _wToken = 0.20;
  static const _wTaxonomy = 0.25;

  final TextEmbedder? _embedder;

  /// Species metadata (id-indexed).
  List<Map<String, dynamic>>? _speciesList;

  /// Pre-normalized combined embeddings (384-dim per species).
  Float32List? _embeddings;
  final int _embDim = 384;

  Future<void>? _loadFuture;

  VisualFeaturesSearchService({TextEmbedder? embedder}) : _embedder = embedder;

  /// Load metadata JSON + binary embeddings.
  Future<void> load() => _loadFuture ??= _doLoad();

  Future<void> _doLoad() async {
    // Load metadata + concatenated embeddings from JSON.
    // NOTE: reading from JSON for simplicity. Will be changed to .bin
    // in the future for faster startup and lower memory footprint.
    try {
      final raw = await rootBundle
          .loadString('assets/data/visual_features_embeddings.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final list = data['species'];
      _speciesList = (list is List)
          ? List<Map<String, dynamic>>.from(list.cast<Map<String, dynamic>>())
          : [];
      debugPrint(
          'VFS: loaded ${_speciesList!.length} species from JSON metadata');

      // Phase 2: build combined embedding (384) by concatenating
      // embedding_taxonomy (128) + embedding_visual (256), then L2-normalize.
      // TODO: migrate to loading from a dedicated .bin file (float32 rows).
      const taxDim = 128;
      const visDim = 256;
      final speciesList = _speciesList!;
      final nSpecies = speciesList.length;
      _embeddings = Float32List(nSpecies * _embDim);

      for (int i = 0; i < nSpecies; i++) {
        final tax = speciesList[i]['embedding_taxonomy'] as List<dynamic>?;
        final vis = speciesList[i]['embedding_visual'] as List<dynamic>?;
        if (tax == null || tax.length < taxDim ||
            vis == null || vis.length < visDim) {
          debugPrint('VFS: species $i missing taxonomy/visual embedding');
          continue;
        }
        // Build combined vector, normalize via existing helper, then store.
        final combined = Float32List(_embDim);
        for (int j = 0; j < taxDim; j++) {
          combined[j] = (tax[j] as num).toDouble();
        }
        for (int j = 0; j < visDim; j++) {
          combined[taxDim + j] = (vis[j] as num).toDouble();
        }
        _normalize(combined);
        _embeddings!.setRange(i * _embDim, i * _embDim + _embDim, combined);
      }

      debugPrint(
          'VFS: built & normalized $nSpecies x $_embDim combined embeddings '
          '(taxonomy 128 + visual 256 = 384) from JSON');
    } catch (e) {
      debugPrint('VFS: failed to load visual_features_embeddings.json — $e');
      _speciesList = [];
      _embeddings = null;
    }
  }

  /// Find up to [topK] species similar to the query.
  ///
  /// Pipeline:
  ///   1. Embed query text → 384-dim → L2-normalize
  ///   2. **Semantic**: cosine(queryEmb, storedEmb) via dot
  ///   3. **Token**: Dice on VF text (weighted fields)
  ///   4. **Taxonomy**: Dice on taxonomy fields (genus boosted)
  Future<List<SimilarSpeciesResult>> findSimilarSpecies({
    String queryText = '',
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
    int topK = 5,
  }) async {
    final species = _speciesList;
    if (species == null || species.isEmpty) return [];

    // Step 0: rebuild query text from structured fields if empty.
    if (queryText.trim().isEmpty) {
      final taxParts = <String>[];
      if (taxClass.isNotEmpty) taxParts.add('class: $taxClass');
      if (order.isNotEmpty) taxParts.add('order: $order');
      if (family.isNotEmpty) taxParts.add('family: $family');
      if (genus.isNotEmpty) taxParts.add('genus: $genus');
      final taxText = taxParts.join(' | ');

      final visParts = <String>[];
      for (final key in ['color', 'body_shape', 'distinctive_marks',
                         'texture', 'size_class', 'pattern']) {
        final v = visualFeatures[key];
        if (v != null && v.isNotEmpty) {
          visParts.add('$key: $v');
        }
      }
      final visText = visParts.join(' | ');

      // Match the weighting used when building stored embeddings:
      // taxonomy x1 + visual x2 (128 + 256 dims proportion ~0.33 + 0.67).
      queryText = taxText.isNotEmpty && visText.isNotEmpty
          ? '$taxText $visText $visText'
          : taxText.isNotEmpty
              ? taxText
              : visText;
    }

    // Step 1: embed query → L2-normalize
    Float32List? queryEmb;
    if (_embedder != null &&
        _embedder!.isLoaded &&
        queryText.trim().isNotEmpty) {
      final raw = await _embedder!.embed(queryText.trim());

      // ── validity guard (critical for on-device stability) ──
      if (raw.length != 384 || raw.every((v) => v == 0 || v.isNaN)) {
        debugPrint('VFS: bad embedding — dim=${raw.length}, allZero=${raw.every((v) => v == 0)}');
        queryEmb = null;
      } else {
        queryEmb = _normalize(raw);
      }
    }

    // Step 2-4: score all species (3 independent signals)
    final scored = <_ScoredSpecies>[];

    for (int i = 0; i < species.length; i++) {
      final sp = species[i];

      // ── Signal 1: Semantic embedding cosine ([-1,1] → [0,1]) ──
      double semantic = 0.0;
      if (queryEmb != null && _embeddings != null) {
        semantic = _cosSimilarity(queryEmb, _embeddings!, i * _embDim, _embDim);
        // Scaled rectifier: shift baseline ~0.25 → 0, scale 0.5 range → [0,1]
        semantic = math.max(0.0, (semantic - 0.25) / 0.5).clamp(0.0, 1.0);
      }

      // ── Signal 2: VF token overlap ──
      final tokenScore = _weightedVisualOverlap(sp, visualFeatures);

      // ── Signal 3: Taxonomy token overlap ──
      final taxScore = _taxonomyOverlap(sp, taxClass, order, family, genus);

      // ── Blend ──
      // semantic×0.55 + token×0.20 + taxonomy×0.25
      final blended = semantic * _wSemantic +
          tokenScore * _wToken +
          taxScore * _wTaxonomy;

      scored.add(_ScoredSpecies(
        idx: i,
        species: sp,
        score: blended.clamp(0.0, 1.0),
        semanticScore: semantic,
        tokenScore: tokenScore,
        taxonomyScore: taxScore,
        visualFeatures: _extractVf(sp),
      ));
    }

    // Step 5: sort + return top-K
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topK).map((e) => e.toResult()).toList();
  }

  /// Text-only query (no structured VF). Falls back to semantic + taxonomy.
  Future<List<SimilarSpeciesResult>> findSimilarByText({
    String queryText = '',
    String taxClass = '',
    String order = '',
    String family = '',
    String genus = '',
    int topK = 5,
  }) async {
    return findSimilarSpecies(
      queryText: queryText,
      taxClass: taxClass,
      order: order,
      family: family,
      genus: genus,
      visualFeatures: {},
      topK: topK,
    );
  }

  /// Formatted one-liner for Gemma context.
  Future<String> findSimilarFormatted({
    String queryText = '',
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
    int topK = 5,
  }) async {
    final results = await findSimilarSpecies(
      queryText: queryText,
      taxClass: taxClass,
      order: order,
      family: family,
      genus: genus,
      visualFeatures: visualFeatures,
      topK: topK,
    );
    if (results.isEmpty) {
      return 'No similar species found for genus "$genus".';
    }
    return results.map((r) {
      final pct = (r.score * 100).toStringAsFixed(0);
      final vfStr = vfToToolString(r.visualFeatures);
      return '${r.scientificName} (genus: ${r.genus})  -- $vfStr';
    }).join(' | ');
  }

  /// L2-normalize a vector IN PLACE and return it.
  Float32List _normalize(Float32List v) {
    double sqSum = 0.0;
    for (int i = 0; i < v.length; i++) {
      sqSum += v[i] * v[i];
    }
    final norm = math.sqrt(sqSum);
    if (norm == 0 || norm == 1) return v;
    for (int i = 0; i < v.length; i++) {
      v[i] /= norm;
    }
    return v;
  }

  /// Cosine similarity between [query] (unit-norm) and a stored species
  /// embedding at [offset] (pre-normalized during load).
  ///
  /// Returns raw cosine ∈ [-1, 1].
  /// Caller MUST normalize via scaled rectifier: max(0, (raw - 0.25) / 0.5).
  double _cosSimilarity(
    Float32List query,
    Float32List stored,
    int offset,
    int dims,
  ) {
    double dot = 0.0;
    for (int j = 0; j < dims; j++) {
      dot += query[j] * stored[offset + j];
    }
    return dot; // raw cosine [-1, 1]; both vectors pre-normalized
  }

  // Taxonomy score (Jaccard, genus boosted)
  double _taxonomyOverlap(
    Map<String, dynamic> sp,
    String taxClass,
    String order,
    String family,
    String genus,
  ) {
    double total = 0.0;
    const weights = [1.0, 1.0, 1.0, 1.5];
    final queries = [taxClass, order, family, genus];
    double weightSum = 0;

    for (int i = 0; i < _taxKeys.length; i++) {
      final q = queries[i].trim().toLowerCase();
      final s = (sp[_taxKeys[i]] as String? ?? '').trim().toLowerCase();
      if (q.isEmpty || s.isEmpty) continue;
      total += _tokenOverlap(s, q) * weights[i];
      weightSum += weights[i];
    }
    return weightSum == 0 ? 0.0 : math.min(total / weightSum, 1.0);
  }

  // VF token score (biologically weighted fields)
  double _weightedVisualOverlap(
    Map<String, dynamic> sp,
    Map<String, String> queryVf,
  ) {
    final storedVf = sp['visual_features'] as Map<String, dynamic>? ?? {};
    double total = 0.0;
    double weightSum = 0.0;

    for (final key in _vfKeys) {
      final w = _vfWeights[key] ?? 0.0;
      if (w == 0) continue;
      final q = (queryVf[key] ?? '').trim();
      final s = (storedVf[key] as String? ?? '').trim();
      if (q.isEmpty || s.isEmpty) continue;
      total += _tokenOverlap(q, s) * w;
      weightSum += w;
    }
    return weightSum == 0 ? 0.0 : total / weightSum;
  }

  Map<String, String> _extractVf(Map<String, dynamic> sp) {
    final raw = sp['visual_features'] as Map<String, dynamic>? ?? {};
    return {for (final k in _vfKeys) k: (raw[k] as String? ?? '')};
  }
}

String vfToToolString(Map<String, String> vf) {
  const fields = [
    ('color', 'color'),
    ('body_shape', 'shape'),
    ('distinctive_marks', 'marks'),
    ('texture', 'texture'),
    ('size_class', 'size'),
    ('pattern', 'pattern'),
  ];
  final parts = [
    for (final (key, label) in fields)
      if ((vf[key] ?? '').isNotEmpty) '$label: ${vf[key]}',
  ];
  return parts.isEmpty ? 'no visual data' : parts.join(', ');
}

// Internal data holders
class _ScoredSpecies {
  final int idx;
  final Map<String, dynamic> species;
  final double score;
  final double semanticScore;
  final double tokenScore;
  final double taxonomyScore;
  final Map<String, String> visualFeatures;

  _ScoredSpecies({
    required this.idx,
    required this.species,
    required this.score,
    required this.semanticScore,
    required this.tokenScore,
    required this.taxonomyScore,
    required this.visualFeatures,
  });

  SimilarSpeciesResult toResult() {
    return SimilarSpeciesResult(
      scientificName: species['latin_name'] as String? ?? '',
      commonName: species['common_name'] as String? ?? '',
      genus: species['genus'] as String? ?? '',
      visualFeatures: visualFeatures,
      score: score,
      semanticScore: semanticScore,
      tokenScore: tokenScore,
      taxonomyScore: taxonomyScore,
    );
  }
}
