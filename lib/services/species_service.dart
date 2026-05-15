import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'bge_embedder.dart';
import 'visual_features_service.dart';

/// Detailed species entry from the per-species JSON files bundled in the zip.
class SpeciesDetail {
  final String scientificName;
  final String commonName;
  final Map<String, String> visualFeatures;
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
  final String populationEstimate;
  final String sourceUri;

  const SpeciesDetail({
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
    this.populationEstimate = '',
    this.sourceUri = '',
  });

  factory SpeciesDetail.fromJson(Map<String, dynamic> json) {
    const vfKeys = [
      'color',
      'body_shape',
      'distinctive_marks',
      'texture',
      'size_class',
      'pattern',
    ];
    final rawVf = json['visual_features'];
    final vfMap = <String, String>{for (final k in vfKeys) k: ''};
    if (rawVf is Map) {
      for (final k in vfKeys) {
        final val = rawVf[k];
        if (val is String && val.isNotEmpty) vfMap[k] = val;
      }
    }

    // accept both 'scientific_name' (new schema) and 'latin_name' (old).
    final scientificName =
        (json['scientific_name'] as String? ?? json['latin_name'] as String? ?? '');

    // genus is a top-level field; include it in taxonomy so `get genus` works.
    final taxonomy = <String, String>{
      'class': json['class'] as String? ?? '',
      'order': json['order'] as String? ?? '',
      'family': json['family'] as String? ?? '',
      'genus': json['genus'] as String? ?? '',
    };

    return SpeciesDetail(
      scientificName: scientificName,
      commonName: json['common_name'] as String? ?? '',
      visualFeatures: vfMap,
      description: json['description'] as String? ?? '',
      conservationStatus: json['conservation_status'] as String? ?? '',
      habitat: json['habitat'] as String? ?? '',
      threats: List<String>.from(json['threats'] as List? ?? []),
      ecosystemRole: json['ecosystem_role'] as String? ?? '',
      humanConnection: json['human_connection'] as String? ?? '',
      whatStudentsCanDo:
          List<String>.from(json['what_students_can_do'] as List? ?? []),
      funFacts: List<String>.from(json['fun_fact'] as List? ?? []),
      habitatTags: List<String>.from(json['habitat_tags'] as List? ?? []),
      taxonomy: taxonomy,
      populationEstimate: json['population_estimate'] as String? ?? '',
      sourceUri:
          json['population_estimate_source_uri'] as String? ?? '',
    );
  }

  String get genus => taxonomy['genus'] ?? '';
}

class SpeciesService {
  final BgeEmbedder _bge = BgeEmbedder();
  VisualFeaturesSearchService? _vfsBacking;

  VisualFeaturesSearchService get _visualFeaturesSearch {
    _vfsBacking ??= VisualFeaturesSearchService(embedder: _bge);
    return _vfsBacking!;
  }

  static const String _zipPath = 'assets/data/species_data.zip';

  Map<String, List<SpeciesDetail>>? _genusDb;

  /// Pre-loads the genus DB, BGE embedder, and the embedding index in parallel.
  Future<void> preloadAll() async {
    await Future.wait([
      loadGenusDb(),
      _bge.load(),
      _visualFeaturesSearch.load(),
    ]);
  }

  /// Loads the genus index from [species_data.zip] and caches it.
  Future<Map<String, List<SpeciesDetail>>> loadGenusDb() async {
    if (_genusDb != null) return _genusDb!;

    _genusDb = {};
    try {
      final raw = await rootBundle.load(_zipPath);
      final bytes =
          raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final file in archive) {
        if (!file.isFile || !file.name.endsWith('.json')) continue;
        final detail =
            SpeciesDetail.fromJson(jsonDecode(utf8.decode(file.content)));
        final genus = detail.genus.trim().toLowerCase();
        if (genus.isNotEmpty) {
          _genusDb!.putIfAbsent(genus, () => []).add(detail);
        }
      }

      final total = _genusDb!.values.fold(0, (s, l) => s + l.length);
      debugPrint(
          'SpeciesService: ${_genusDb!.length} genera, $total species loaded');
    } catch (e) {
      debugPrint('SpeciesService: failed to load genus DB — $e');
      _genusDb = {};
    }

    return _genusDb!;
  }

  /// Tool implementation: look up all species in a genus and return a
  /// compact list of scientific names paired with their visual features.
  Future<String> searchSpeciesByTaxonomy(
    String taxonClass,
    String taxonOrder,
    String taxonFamily,
    String taxonGenus,
  ) async {
    final db = await loadGenusDb();
    final key = taxonGenus.trim().toLowerCase();
    final species = db[key];

    debugPrint(
      'Finding species in: class=$taxonClass, order=$taxonOrder, family=$taxonFamily, genus=$taxonGenus'
    );

    if (species == null || species.isEmpty) {
      return 'No endangered species found in the genus "$taxonGenus".';
    }

    return species
        .map((s) => '${s.scientificName}: ${vfToToolString(s.visualFeatures)}')
        .join(' | ');
  }

  /// Semantic similarity search: returns up to [topK] species
  Future<String> findSimilarByFeatures({
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeature,
    int topK = 5,
  }) async {
    await _visualFeaturesSearch.load();
    return _visualFeaturesSearch.findSimilarFormatted(
      taxClass: taxClass,
      order: order,
      family: family,
      genus: genus,
      visualFeatures: visualFeature,
      topK: topK,
    );
  }

  /// Typed variant — returns [SimilarSpeciesResult] objects directly.
  Future<List<SimilarSpeciesResult>> findSimilarByFeaturesTyped({
    required String taxClass,
    required String order,
    required String family,
    required String genus,
    required Map<String, String> visualFeature,
    int topK = 5,
  }) async {
    await _visualFeaturesSearch.load();
    return _visualFeaturesSearch.findSimilarSpecies(
      taxClass: taxClass,
      order: order,
      family: family,
      genus: genus,
      visualFeatures: visualFeature,
      topK: topK,
    );
  }

  /// Check if a given scientific name is in the endangered species database.
  Future<bool> isEndangered(String scientificName) async {
    final db = await loadGenusDb();
    final q = scientificName.trim().toLowerCase();
    for (final list in db.values) {
      for (final s in list) {
        final sn = s.scientificName.toLowerCase();
        if (sn.contains(q) || q.contains(sn)) return true;
      }
    }
    return false;
  }

  /// Finds a SpeciesDetail by scientific / Latin name.
  Future<SpeciesDetail?> findSpeciesByLatinName(String latinName) async {
    final db = await loadGenusDb();
    final q = latinName.trim().toLowerCase();
    for (final list in db.values) {
      for (final s in list) {
        final sn = s.scientificName.toLowerCase();
        if (sn.contains(q) || q.contains(sn)) return s;
      }
    }
    return null;
  }

  /// Finds a SpeciesDetail by common name.
  Future<SpeciesDetail?> findSpeciesByName(String name) async {
    final db = await loadGenusDb();
    final q = name.trim().toLowerCase();
    for (final list in db.values) {
      for (final s in list) {
        final cn = s.commonName.toLowerCase();
        if (cn.contains(q) || q.contains(cn)) return s;
      }
    }
    return null;
  }
}
