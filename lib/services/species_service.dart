import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import '../database/species_database.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Domain model
// ═══════════════════════════════════════════════════════════════════════════════

class SpeciesDetail {
  final String scientificName;
  final String commonName;
  final String visualFeatures;
  final String description;
  final String conservationStatus;
  final String habitat;
  final List<String> threats;
  final String ecosystemRole;
  final String humanConnection;
  final List<String> whatStudentsCanDo;
  final List<String> funFacts;
  final List<String> habitatTags;
  final Map<String, String> taxonomy;
  final String visualGroup;
  final String populationEstimate;
  final String sourceUri;

  SpeciesDetail({
    required this.scientificName,
    required this.commonName,
    required this.visualFeatures,
    required this.description,
    required this.conservationStatus,
    required this.habitat,
    required this.threats,
    required this.ecosystemRole,
    required this.humanConnection,
    required this.whatStudentsCanDo,
    required this.funFacts,
    required this.habitatTags,
    required this.taxonomy,
    this.visualGroup = '',
    this.populationEstimate = '',
    this.sourceUri = '',
  });

  factory SpeciesDetail.fallback({
    required String scientificName,
    required String commonName,
  }) {
    return SpeciesDetail(
      scientificName: scientificName,
      commonName: commonName,
      visualFeatures: '',
      description: '',
      conservationStatus: '',
      habitat: '',
      threats: [],
      ecosystemRole: '',
      humanConnection: '',
      whatStudentsCanDo: [],
      funFacts: [],
      habitatTags: [],
      taxonomy: {},
    );
  }

  factory SpeciesDetail.fromDrift(SpeciesData row) {
    final funFacts = _parseJsonList(row.funFact);
    final studentActions = _parseJsonList(row.whatStudentsCanDo);
    final threats = _parseJsonList(row.threats);
    final habitatTags = _parseJsonList(row.habitatTags);
    return SpeciesDetail(
      scientificName: row.latinName,
      commonName: row.commonName,
      visualFeatures: row.visualFeatures,
      description: row.description,
      conservationStatus: row.conservationStatus,
      habitat: row.habitat,
      threats: threats.map((e) => e.toString()).toList(),
      ecosystemRole: row.ecosystemRole,
      humanConnection: row.humanConnection,
      whatStudentsCanDo: studentActions.map((e) => e.toString()).toList(),
      funFacts: funFacts.map((e) => e.toString()).toList(),
      habitatTags: habitatTags.map((e) => e.toString()).toList(),
      taxonomy: {
        'kingdom': row.kingdom,
        'class': row.className,
        'order': row.orderName,
        'family': row.family,
        'genus': row.genus,
      },
      visualGroup: row.visualGroup,
      populationEstimate: row.populationEstimate,
      sourceUri: row.populationEstimateSourceUri,
    );
  }

  static List<dynamic> _parseJsonList(String text) {
    if (text.trim().isEmpty) return [];
    try { return jsonDecode(text) as List<dynamic>; } catch (_) { return []; }
  }

  String get genus => taxonomy['genus'] ?? '';
}

// ═══════════════════════════════════════════════════════════════════════════════
// FTS5 search result
// ═══════════════════════════════════════════════════════════════════════════════

class RankedSpecies {
  final double score;
  final double confidence;
  final SpeciesDetail detail;

  const RankedSpecies({
    required this.score,
    required this.confidence,
    required this.detail,
  });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Token helpers (synonym normalisation + Dice)
// ═══════════════════════════════════════════════════════════════════════════════

const _synonyms = {
  'stripes': 'striped', 'striping': 'striped', 'stripy': 'striped',
  'golden': 'yellow', 'bluish': 'blue', 'reddish': 'red',
  'greenish': 'green', 'brownish': 'brown', 'whitish': 'white',
  'blackish': 'black', 'greyish': 'grey', 'grayish': 'grey',
  'yellowish': 'yellow', 'orangish': 'orange', 'purplish': 'purple',
  'pinkish': 'pink', 'spotted': 'spot', 'spotty': 'spot',
};

// Remove stop-words to ensure common grammatical filler doesn't skew similarity scores
const _stopWords = {'and', 'with', 'the', 'appears', 'somewhat', 'but', 'on', 'of', 'in'};

Set<String> _tokens(String text) {
  return text
      .toLowerCase()
      .split(RegExp(r'\W+'))
      .map((t) => _synonyms[t] ?? t)
      // Rely on exact matches or external porter libraries instead of destructive suffix slicing
      .where((t) => t.length > 1 && !_stopWords.contains(t))
      .toSet();
}

double _dice(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0.0;
  final i = a.intersection(b).length;
  return i == 0 ? 0.0 : (2.0 * i) / (a.length + b.length);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Service
// ═══════════════════════════════════════════════════════════════════════════════

const _vfKeys = ['color', 'body_shape', 'distinctive_marks', 'texture', 'size_class', 'pattern'];
const _vfWeights = {'distinctive_marks': 5.0, 'pattern': 4.0, 'color': 4.0, 'body_shape': 3.0, 'texture': 1.0, 'size_class': 1.0};
const _taxBoost = 2.0;
class SpeciesService {
  final SpeciesDatabase _db;

  SpeciesService._(this._db);

  factory SpeciesService() => SpeciesService._(SpeciesDatabase.instance);

  // ── Initialisation ──────────────────────────────────────────────────

  Future<void> preloadAll() async {
    await _db.countAll();
    debugPrint('SpeciesService: DB ready');
  }

  // ── Taxonomy / species lookups ──────────────────────────────────────

  Future<String> searchSpeciesByTaxonomy(
    String taxonClass, String taxonOrder, String taxonFamily, String taxonGenus,
  ) async {
    debugPrint('Finding species in: class=$taxonClass, order=$taxonOrder, '
        'family=$taxonFamily, genus=$taxonGenus');
    final species = await _db.findByGenus(taxonGenus);
    if (species.isEmpty) return 'No endangered species found in the genus "$taxonGenus".';
    return species.map((s) => '${s.latinName}: ${s.visualFeatures}').join(' | ');
  }

  Future<bool> isEndangered(String scientificName) => _db.existsByName(scientificName);

  Future<SpeciesDetail?> findSpeciesByLatinName(String latinName) async {
    final row = await _db.findByNameLatin(latinName);
    return row != null ? SpeciesDetail.fromDrift(row) : null;
  }

  Future<SpeciesDetail?> findSpeciesByName(String name) async {
    final row = await _db.findByNameCommon(name);
    return row != null ? SpeciesDetail.fromDrift(row) : null;
  }

  // ── FTS5 + weighted reranker ────────────────────────────────────────

  /// Search for visually similar species by individual observed traits.
  ///
  /// When [visualGroup] is provided, species are first narrowed to that visual
  /// group (e.g. "Primate", "Flying bird") before FTS5 + Dice reranking.
  ///
  /// Internally runs an FTS5 prefix‑match on the concatenated trait values,
  /// then reranks candidates using per‑field Dice‑overlap with fixed weights:
  ///   distinctive_marks×5  pattern×4  color×4  body_shape×3  texture×1  size_class×1
  /// plus a taxonomy boost when [taxFamily] or [taxGenus] matches.
  Future<List<RankedSpecies>> searchSimilarByFeatures({
    String color = '',
    String bodyShape = '',
    String distinctiveMarks = '',
    String texture = '',
    String sizeClass = '',
    String pattern = '',
    String? visualGroup,
    String? taxClass,
    String? taxOrder,
    String? taxFamily,
    String? taxGenus,
    int topK = 5,
  }) async {
    final traits = <String, String>{};
    final queryParts = <String>[];

    void addField(String key, String val) {
      if (val.trim().isEmpty) return;
      traits[key] = val.trim();
      queryParts.add(val.trim());
    }

    addField('color', color);
    addField('body_shape', bodyShape);
    addField('distinctive_marks', distinctiveMarks);
    addField('texture', texture);
    addField('size_class', sizeClass);
    addField('pattern', pattern);

    if (queryParts.isEmpty) return [];

    // Clean terms, apply synonyms (match build-time normalisation), deduplicate.
    final cleanTerms = queryParts
        .join(' ')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .map((w) => (_synonyms[w] ?? w).toLowerCase().trim())
        .where((w) => w.length > 1 && !_stopWords.contains(w))
        .toSet();

    if (cleanTerms.isEmpty) return [];

    // Build the query: filter by visualGroup first if provided
    final useFts = !(traits.isEmpty);
    List<Map<String, dynamic>> unfilteredRows;

    if (useFts) {
      // Use broad 'OR' for flexible offline retrieval.
      final ftsQuery = cleanTerms.map((w) => '"$w"*').join(' OR ');

      if (visualGroup != null && visualGroup.isNotEmpty) {
        // Filter by visual_group + FTS5
        unfilteredRows = (await _db.customSelect(
          'SELECT s.* FROM species s '
          'JOIN species_fts f ON s.id = f.rowid '
          'WHERE species_fts MATCH ?1 AND s.visual_group = ?2 '
          'LIMIT ?3',
          variables: [Variable(ftsQuery), Variable(visualGroup), Variable(42)],
          readsFrom: {_db.species},
        ).get()).map((r) => r.data).toList();

        // FTS5 fallback: if nothing found in group, get all from group unfiltered
        if (unfilteredRows.isEmpty) {
          final vgRows = await _db.customSelect(
            'SELECT s.* FROM species s WHERE s.visual_group = ?1 LIMIT ?2',
            variables: [Variable(visualGroup), Variable(42)],
            readsFrom: {_db.species},
          ).get();
          unfilteredRows = vgRows.map((r) => r.data).toList();
        }
      } else {
        unfilteredRows = (await _db.customSelect(
          'SELECT s.* FROM species s '
          'JOIN species_fts f ON s.id = f.rowid '
          'WHERE species_fts MATCH ?1 '
          'LIMIT ?2',
          variables: [Variable(ftsQuery), Variable(42)],
          readsFrom: {_db.species},
        ).get()).map((r) => r.data).toList();
      }
    } else {
      // No trait query — just visual group lookup
      if (visualGroup != null && visualGroup.isNotEmpty) {
        final vgRows = await _db.customSelect(
          'SELECT s.* FROM species s WHERE s.visual_group = ?1 LIMIT ?2',
          variables: [Variable(visualGroup), Variable(42)],
          readsFrom: {_db.species},
        ).get();
        unfilteredRows = vgRows.map((r) => r.data).toList();
      } else {
        unfilteredRows = [];
      }
    }

    if (unfilteredRows.isEmpty) return [];

    // Parse extracted features into structured data sets
    final obsTokens = <String, Set<String>>{};
    double maximumObservableScore = 0.0;

    for (final k in _vfKeys) {
      final v = traits[k];
      if (v != null && v.isNotEmpty) {
        obsTokens[k] = _tokens(v);
        maximumObservableScore += _vfWeights[k] ?? 1.0; 
      }
    }

    // Add taxonomy fields into dynamic max potential calculation limits
    if (taxFamily?.isNotEmpty ?? false) maximumObservableScore += _taxBoost;
    if (taxGenus?.isNotEmpty ?? false) maximumObservableScore += (_taxBoost * 0.5);
    if (taxClass?.isNotEmpty ?? false) maximumObservableScore += (_taxBoost * 0.3);
    if (taxOrder?.isNotEmpty ?? false) maximumObservableScore += (_taxBoost * 0.2);

    final scored = <_RowScore>[];

    for (final data in unfilteredRows) {
      double score = 0;

      for (final k in _vfKeys) {
        final obs = obsTokens[k];
        if (obs == null) continue;
        
        final stored = (data[k] as String? ?? '').trim();
        final storedT = stored.isNotEmpty
            ? _tokens(stored)
            : _tokens(data['visual_blob'] as String? ?? '');
            
        score += _dice(obs, storedT) * (_vfWeights[k] ?? 1);
      }

      // Taxonomy matches evaluation
      if (taxFamily != null && taxFamily.isNotEmpty &&
          (data['family'] as String? ?? '').toLowerCase() == taxFamily.toLowerCase()) {
        score += _taxBoost;
      }
      if (taxGenus != null && taxGenus.isNotEmpty &&
          (data['genus'] as String? ?? '').toLowerCase() == taxGenus.toLowerCase()) {
        score += _taxBoost * 0.5;
      }
      if (taxClass != null && taxClass.isNotEmpty &&
          (data['class'] as String? ?? '').toLowerCase() == taxClass.toLowerCase()) {
        score += _taxBoost * 0.3;
      }
      if (taxOrder != null && taxOrder.isNotEmpty &&
          (data['order'] as String? ?? '').toLowerCase() == taxOrder.toLowerCase()) {
        score += _taxBoost * 0.2;
      }

      // Confidence bounds are calculated against what was actually queried
      final conf = maximumObservableScore > 0 
          ? (score / maximumObservableScore * 100.0).clamp(0.0, 100.0) 
          : 0.0;

      scored.add(_RowScore(data, score, conf));
    }

    // Sort descending by score
    scored.sort((a, b) => b.score.compareTo(a.score));

    return scored.take(topK).map((s) {
      final row = s.row;
      // Map back safely via drift schema definitions generator directly
      final speciesData = _db.species.map(row); 
      return RankedSpecies(
        score: s.score,
        confidence: s.confidence,
        detail: SpeciesDetail.fromDrift(speciesData),
      );
    }).toList();
  }
}

class _RowScore {
  final Map<String, dynamic> row;
  final double score;
  final double confidence;
  const _RowScore(this.row, this.score, this.confidence);
}
