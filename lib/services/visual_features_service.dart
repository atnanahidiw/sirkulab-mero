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

/// Splits a string into lowercase tokens (length > 2) for overlap scoring.
Set<String> _tokenize(String text) => text
    .toLowerCase()
    .split(RegExp(r'\W+'))
    .where((t) => t.length > 2)
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

/// One result entry returned by [EmbeddingSearchService].
class SimilarSpeciesResult {
  final String scientificName;
  final String commonName;
  final String genus;
  final Map<String, String> visualFeatures;

  /// Combined weighted score ∈ [0, 1]:
  ///   score = (taxonomyScore × 1 + visualScore × 2) / 3
  final double score;

  /// Taxonomy sub-score ∈ [0, 1] (weight 1×).
  final double taxonomyScore;

  /// Visual-feature sub-score ∈ [0, 1] (weight 2×).
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

  List<Map<String, dynamic>>? _speciesList;

  // use a Future to guard concurrent load calls.
  Future<void>? _loadFuture;

  Future<void> load() => _loadFuture ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final raw = await rootBundle.loadString('assets/data/visual_features_embeddings.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final list = data['species'];
      _speciesList = (list is List)
          ? List<Map<String, dynamic>>.from(list.cast<Map<String, dynamic>>())
          : [];
      debugPrint(
          'VisualFeaturesSearchService: loaded ${_speciesList!.length} species');
    } catch (e) {
      debugPrint('VisualFeaturesSearchService: failed to load index — $e');
      _speciesList = [];
    }
  }

  /// Find up to [topK] species similar to the query.
  ///
  /// Returns [SimilarSpeciesResult] objects sorted by [score] descending.
  List<SimilarSpeciesResult> findSimilarSpecies({
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
    int topK = 5,
    double stage1Boost = 1.2,
  }) {
    final species = _speciesList;
    if (species == null || species.isEmpty) return [];

    final genusQ = genus.trim().toLowerCase();

    // --- Stage 1: genus anchor → MiniLM pre-computed similar_species ---
    List<SimilarSpeciesResult> stage1 = [];
    if (genusQ.isNotEmpty) {
      final anchor = _findBestAnchor(
        species: species,
        taxClass: taxClass,
        order: order,
        family: family,
        genus: genusQ,
        visualFeatures: visualFeatures,
      );
      if (anchor != null) {
        stage1 = _extractPrecomputed(anchor, topK);
      }
    }

    // --- Stage 2: score ALL species with weighted token overlap ---
    final stage2 = _scoreAllSpecies(
      species: species,
      taxClass: taxClass,
      order: order,
      family: family,
      genus: genusQ,
      visualFeatures: visualFeatures,
      topK: topK,
    );

    // --- Merge: boost stage1 scores, then rank purely by score ---

    final boostedStage1 = stage1.map((r) => SimilarSpeciesResult(
      scientificName: r.scientificName,
      commonName: r.commonName,
      genus: r.genus,
      visualFeatures: r.visualFeatures,
      score: (r.score * stage1Boost).clamp(0.0, 1.0),
      taxonomyScore: r.taxonomyScore,
      visualScore: r.visualScore,
    )).toList();

    // Deduplicate by scientificName — stage1 entry wins if same species appears
    // in both (it carries the boosted score).
    final seen = <String, SimilarSpeciesResult>{};
    for (final r in [...boostedStage1, ...stage2]) {
      seen.putIfAbsent(r.scientificName, () => r);
    }

    final merged = seen.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

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
      if (!spGenus.contains(genus) && !genus.contains(spGenus)) continue;

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

  /// Converts a species entry's `similar_species` list into typed results.
  List<SimilarSpeciesResult> _extractPrecomputed(
    Map<String, dynamic> anchor,
    int topK,
  ) {
    final raw = anchor['similar_species'];
    if (raw is! List) return [];
    return raw.take(topK).map<SimilarSpeciesResult>((item) {
      final m = item as Map<String, dynamic>;
      final rawVf = m['visual_features'] as Map<String, dynamic>? ?? {};
      final vf = <String, String>{
        for (final k in _vfKeys) k: (rawVf[k] as String? ?? ''),
      };
      final score = (m['score'] as num?)?.toDouble() ?? 0.0;
      return SimilarSpeciesResult(
        scientificName: m['scientific_name'] as String? ?? '',
        commonName: m['common_name'] as String? ?? '',
        genus: m['genus'] as String? ?? '',
        visualFeatures: vf,
        // Pre-computed score is already MiniLM cosine similarity.
        // Report it as-is; sub-scores are unavailable from pre-computation.
        score: score,
        taxonomyScore: double.nan,
        visualScore: double.nan,
      );
    }).toList();
  }

  /// Scores every species in the DB and returns the top-K.
  ///
  /// combined = (taxScore × 1 + visScore × 2) / 3
  List<SimilarSpeciesResult> _scoreAllSpecies({
    required List<Map<String, dynamic>> species,
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeatures,
    required int topK,
  }) {
    final scored = <(double, double, double, Map<String, dynamic>)>[];

    for (final sp in species) {
      final combined = _computeWeightedScore(
        sp: sp,
        taxClass: taxClass,
        order: order,
        family: family,
        genus: genus,
        visualFeatures: visualFeatures,
      );
      // Re-compute sub-scores for the result object
      final tax = _taxonomyScore(sp, taxClass, order, family, genus);
      final vis = _visualScore(sp, visualFeatures);
      scored.add((combined, tax, vis, sp));
    }

    scored.sort((a, b) => b.$1.compareTo(a.$1));

    return scored.take(topK).map((t) {
      final sp = t.$4;
      final rawVf = sp['visual_features'] as Map<String, dynamic>? ?? {};
      final vf = <String, String>{
        for (final k in _vfKeys) k: (rawVf[k] as String? ?? ''),
      };
      return SimilarSpeciesResult(
        scientificName: sp['scientific_name'] as String? ?? '',
        commonName: sp['common_name'] as String? ?? '',
        genus: sp['genus'] as String? ?? '',
        visualFeatures: vf,
        score: t.$1,
        taxonomyScore: t.$2,
        visualScore: t.$3,
      );
    }).toList();
  }

  /// Combined weighted score ∈ [0, 1] for one species entry.
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
    // Mirrors Python: weight_tax=1, weight_vis=2 → divide by 3
    return (tax * 1.0 + vis * 2.0) / 3.0;
  }

  /// Taxonomy similarity ∈ [0, 1].
  ///
  /// Scores each of (class, order, family, genus) with substring containment
  /// and averages them. Genus gets an extra 0.5 bonus because it is the most
  /// specific differentiator (capped at 1.0 per field).
  double _taxonomyScore(
    Map<String, dynamic> sp,
    String taxClass,
    String order,
    String family,
    String genus,
  ) {
    double total = 0.0;
    const fields = ['class', 'order', 'family', 'genus'];
    final queries = [taxClass, order, family, genus];
    const weights = [1.0, 1.0, 1.0, 1.5]; // genus slightly boosted

    double weightSum = 0;
    for (int i = 0; i < fields.length; i++) {
      final q = queries[i].trim().toLowerCase();
      final s = (sp[fields[i]] as String? ?? '').trim().toLowerCase();
      if (q.isEmpty || s.isEmpty) continue;
      final match = (s.contains(q) || q.contains(s)) ? 1.0 : 0.0;
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
}
