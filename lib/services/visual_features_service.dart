import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Helpers to format a visualFeature map into a compact string for Gemma context.
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

/// Lightweight stemmer for biological English.
///
/// Handles common plural/suffix patterns so that "stripe", "stripes",
/// "striped" all map to the same normalized form.
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

/// Splits a string into lowercase normalized tokens (length > 1).
///
/// - Strips punctuation
/// - Applies lightweight stemming ([_normalizeToken])
/// - Filters out single characters (biologically insignificant)
Set<String> _tokenize(String text) => text
    .toLowerCase()
    .split(RegExp(r'\W+'))
    .where((t) => t.length > 1)
    .map(_normalizeToken)
    .toSet();

/// Jaccard-like token overlap ∈ [0, 1] between two strings.
double _tokenOverlap(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0.0;
  final ta = _tokenize(a);
  final tb = _tokenize(b);
  if (ta.isEmpty || tb.isEmpty) return 0.0;
  final intersection = ta.intersection(tb).length;
  final union = ta.union(tb).length;
  return intersection / union;
}

/// One result entry returned by [VisualFeaturesSearchService].
class SimilarSpeciesResult {
  final String scientificName;
  final String commonName;
  final String genus;
  final Map<String, String> visualFeatures;

  /// Combined weighted score ∈ [0, 1]:
  ///   score = finalVisual × 0.67 + finalTax × 0.33
  final double score;

  /// Taxonomy sub-score ∈ [0, 1] (weight 0.33).
  final double taxonomyScore;

  /// Visual-feature sub-score ∈ [0, 1] (weight 0.67).
  final double visualScore;

  const SimilarSpeciesResult({
    required this.scientificName,
    required this.commonName,
    required this.genus,
    required this.visualFeatures,
    required this.score,
    required this.taxonomyScore,
    required this.visualScore,
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

  // Species metadata.
  List<Map<String, dynamic>>? _speciesList;

  /// Flat Float32List of embeddings:
  ///   per species: [tax_0..127, vis_0..255] = 384 floats
  Float32List? _embeddings;

  /// Config from JSON.
  Map<String, dynamic>? _embeddingConfig;

  int get _taxDim => _embeddingConfig?['taxonomy_dim'] as int? ?? 128;
  int get _visDim => _embeddingConfig?['visual_dim'] as int? ?? 256;
  int get _totalDim => _taxDim + _visDim; // no tags — only tax+vis

  Future<void>? _loadFuture;

  Future<void> load() => _loadFuture ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final raw = await rootBundle.loadString('assets/data/visual_features_embeddings.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _embeddingConfig = data['embedding_config'] as Map<String, dynamic>?;
      final list = data['species'];
      _speciesList = (list is List)
          ? List<Map<String, dynamic>>.from(list.cast<Map<String, dynamic>>())
          : [];

      // Unpack only tax + vis embeddings (skip tags).
      final N = _speciesList!.length;
      final total = _totalDim;
      _embeddings = Float32List(N * total);
      for (int i = 0; i < N; i++) {
        final sp = _speciesList![i];
        final offset = i * total;
        int pos = offset;

        final tax = sp['embedding_taxonomy'] as List<dynamic>;
        for (int j = 0; j < tax.length && j < _taxDim; j++) {
          _embeddings![pos++] = (tax[j] as num).toDouble();
        }

        final vis = sp['embedding_visual'] as List<dynamic>;
        for (int j = 0; j < vis.length && j < _visDim; j++) {
          _embeddings![pos++] = (vis[j] as num).toDouble();
        }
      }

      debugPrint(
          'VisualFeaturesSearchService: loaded ${_speciesList!.length} species, '
          '${_taxDim}t+${_visDim}v = $total dims');
    } catch (e) {
      debugPrint('VisualFeaturesSearchService: failed to load index — $e');
      _speciesList = [];
      _embeddings = Float32List(0);
    }
  }

  /// Find up to [topK] species similar to the query.
  List<SimilarSpeciesResult> findSimilarSpecies({
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
    int topK = 5,
  }) {
    final species = _speciesList;
    final emb = _embeddings;
    if (species == null || species.isEmpty) return [];

    final genusQ = genus.trim().toLowerCase();

    // --- Stage 1: genus anchor → nearest-neighbor in embedding space ---
    List<SimilarSpeciesResult> stage1 = [];
    if (emb != null && genusQ.isNotEmpty) {
      final anchor = _findBestAnchor(
        species: species,
        taxClass: taxClass,
        order: order,
        family: family,
        genus: genusQ,
        visualFeatures: visualFeatures,
      );
      if (anchor != null) {
        stage1 = _nearestNeighbors(anchor, topK);
      }
    }

    // --- Stage 2: score ALL with combined token + embedding ---
    final stage2 = _scoreAllSpecies(
      species: species,
      taxClass: taxClass,
      order: order,
      family: family,
      genus: genusQ,
      visualFeatures: visualFeatures,
      topK: topK,
    );

    // --- Merge (O(N) dedup via Set) ---
    final merged = <SimilarSpeciesResult>[];
    final seen = <String>{};

    // Stage1 entries first (get priority on ties).
    for (final r in stage1) {
      if (seen.add(r.scientificName)) {
        merged.add(r);
      }
    }
    for (final r in stage2) {
      if (seen.add(r.scientificName)) {
        merged.add(r);
      }
    }

    merged.sort((a, b) => b.score.compareTo(a.score));
    return merged.take(topK).toList();
  }

  /// Formatted one-liner for Gemma context:
  ///   "Species -- 85% -- color: …, shape: …"
  String findSimilarFormatted({
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
    int topK = 5,
  }) {
    final results = findSimilarSpecies(
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
      return '${r.scientificName} (genus: ${r.genus}) -- $pct% -- $vfStr';
    }).join(' | ');
  }

  /// Finds the species in the DB that best matches the query by weighted score.
  /// Used as the anchor for the pre-computed similar_species lookup (Stage 1).
  Map<String, dynamic>? _findBestAnchor({
    required List<Map<String, dynamic>> species,
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
  }) {
    Map<String, dynamic>? best;
    double bestScore = -1;

    for (final sp in species) {
      final spGenus = (sp['genus'] as String? ?? '').trim().toLowerCase();

      // Only consider genus matches for the anchor
       if (spGenus.isEmpty) continue;

      // Handle abbreviations, typos, OCR noise, partial genus names.
      if (_tokenOverlap(spGenus, genus) < 0.3) continue;

      final score = _computeWeightedScore(
        sp: sp,
        taxClass: taxClass,
        order: order,
        family: family,
        genus: genus,
        visualFeatures: visualFeatures,
      );
      if (score > bestScore) {
        bestScore = score;
        best = sp;
      }
    }
    return best;
  }

  /// Nearest neighbors in taxonomy + visual embedding space.
  List<SimilarSpeciesResult> _nearestNeighbors(
    Map<String, dynamic> anchor,
    int topK,
  ) {
    final emb = _embeddings;
    final species = _speciesList;
    if (emb == null || species == null || species.isEmpty) return [];

    final anchorIdx = (anchor['id'] as int?) ?? -1;
    if (anchorIdx < 0) return [];
    final N = species.length;
    final total = _totalDim;

    final anchorOffset = anchorIdx * total;
    final scores = <_DistScore>[];
    for (int i = 0; i < N; i++) {
      if (i == anchorIdx) continue;
      double dot = 0;
      final offset = i * total;
      for (int j = 0; j < total; j++) {
        dot += emb[anchorOffset + j] * emb[offset + j];
      }
      scores.add(_DistScore(i, dot));
    }
    scores.sort((a, b) => b.score.compareTo(a.score));

    return scores.take(topK).map((s) {
      final sp = species[s.idx];
      final rawVf = sp['visual_features'] as Map<String, dynamic>? ?? {};
      final vf = <String, String>{
        for (final k in _vfKeys) k: (rawVf[k] as String? ?? ''),
      };
      return SimilarSpeciesResult(
        scientificName: sp['latin_name'] as String? ?? '',
        commonName: sp['common_name'] as String? ?? '',
        genus: sp['genus'] as String? ?? '',
        visualFeatures: vf,
        score: s.score.clamp(0.0, 1.0),
        taxonomyScore: double.nan,
        visualScore: double.nan,
      );
    }).toList();
  }

  /// Scores every species in the DB and returns the top-K.
  List<SimilarSpeciesResult> _scoreAllSpecies({
    required List<Map<String, dynamic>> species,
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
    required int topK,
  }) {
    final results = <SimilarSpeciesResult>[];

    for (final sp in species) {
      final taxToken = _taxonomyScore(sp, taxClass, order, family, genus);
      final visToken = _visualScore(sp, visualFeatures);

      // Uses token overlap only (no query embedding available).
      final finalVis = _blendDim(visToken, double.nan, visualWeight: 0.4, embWeight: 0.6);
      final finalTax = _blendDim(taxToken, double.nan, visualWeight: 0.7, embWeight: 0.3);

      final combined = finalVis * 0.67 + finalTax * 0.33;

      results.add(SimilarSpeciesResult(
        scientificName: sp['latin_name'] as String? ?? '',
        commonName: sp['common_name'] as String? ?? '',
        genus: sp['genus'] as String? ?? '',
        visualFeatures: _extractVf(sp),
        score: combined.clamp(0.0, 1.0),
        taxonomyScore: finalTax,
        visualScore: finalVis,
      ));
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(topK).toList();
  }

  /// Combined weighted score ∈ [0, 1] for anchor search (token-only fallback).
  double _computeWeightedScore({
    required Map<String, dynamic> sp,
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
  }) {
    final tax = _taxonomyScore(sp, taxClass, order, family, genus);
    final vis = _visualScore(sp, visualFeatures);
    return vis * 0.67 + tax * 0.33;
  }

  /// Blend one dimension's token score with its embedding score.
  ///
  /// When [embScore] is NaN (unavailable), falls back to [tokenScore] alone.
  /// Otherwise: `tokenScore * visualWeight + embScore * embWeight`.
  double _blendDim(
    double tokenScore,
    double embScore, {
    required double visualWeight,
    required double embWeight,
  }) {
    if (embScore.isNaN) return tokenScore.clamp(0.0, 1.0);
    return (tokenScore * visualWeight + embScore * embWeight).clamp(0.0, 1.0);
  }

  /// Taxonomy similarity ∈ [0, 1] using Jaccard token overlap.
  ///
  /// Genus gets 1.5× weight for being the most specific differentiator.
  double _taxonomyScore(
    Map<String, dynamic> sp,
    String taxClass,
    String order,
    String family,
    String genus,
  ) {
    double total = 0.0;
    final queries = [taxClass, order, family, genus];
    const weights = [1.0, 1.0, 1.0, 1.5];

    double weightSum = 0;
    for (int i = 0; i < _taxKeys.length; i++) {
      final q = (queries[i]).trim().toLowerCase();
      final s = (sp[_taxKeys[i]] as String? ?? '').trim().toLowerCase();
      if (q.isEmpty || s.isEmpty) continue;

      final match = _tokenOverlap(s, q);
      total += match * weights[i];
      weightSum += weights[i];
    }
    return weightSum == 0 ? 0.0 : math.min(total / weightSum, 1.0);
  }

  /// Visual-feature similarity ∈ [0, 1].
  ///
  /// For each VF field, computes Jaccard token overlap between query value
  /// and stored value, then averages across fields that have data in both.
  double _visualScore(
    Map<String, dynamic> sp,
    Map<String, String> queryVf,
  ) {
    final storedVf = sp['visual_features'] as Map<String, dynamic>? ?? {};
    double total = 0.0;
    int counted = 0;

    for (final key in _vfKeys) {
      final q = (queryVf[key] ?? '').trim();
      final s = (storedVf[key] as String? ?? '').trim();
      if (q.isEmpty || s.isEmpty) continue;
      total += _tokenOverlap(q, s);
      counted++;
    }
    return counted == 0 ? 0.0 : total / counted;
  }

  Map<String, String> _extractVf(Map<String, dynamic> sp) {
    final raw = sp['visual_features'] as Map<String, dynamic>? ?? {};
    return {for (final k in _vfKeys) k: (raw[k] as String? ?? '')};
  }
}

class _DistScore {
  final int idx;
  final double score;
  _DistScore(this.idx, this.score);
}
