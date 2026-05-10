import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Detailed species entry from the per-species JSON files.
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
    this.populationEstimate = '',
    this.sourceUri = '',
  });

  factory SpeciesDetail.fromJson(Map<String, dynamic> json) {
    return SpeciesDetail(
      scientificName: json['scientific_name'] ?? json['latin_name'] ?? '',
      commonName: json['common_name'] ?? '',
      visualFeatures: json['visual_features'] ?? '',
      description: json['description'] ?? '',
      conservationStatus: json['conservation_status'] ?? '',
      habitat: json['habitat'] ?? '',
      threats: List<String>.from(json['threats'] ?? []),
      ecosystemRole: json['ecosystem_role'] ?? '',
      humanConnection: json['human_connection'] ?? '',
      whatStudentsCanDo: List<String>.from(json['what_students_can_do'] ?? []),
      funFacts: List<String>.from(json['fun_fact'] ?? []),
      habitatTags: List<String>.from(json['habitat_tags'] ?? []),
      taxonomy: {
        'kingdom': json['kingdom'] ?? '',
        'class': json['class'] ?? '',
        'order': json['order'] ?? '',
        'family': json['family'] ?? '',
        'genus': json['genus'] ?? '',
      },
      populationEstimate: json['population_estimate'] ?? '',
      sourceUri: json['population_estimate_source_uri'] ?? '',
    );
  }

  String get genus => taxonomy['genus'] ?? '';
}

class SpeciesService {
  static const String _speciesPrefix = 'assets/data/species_data/';

  // Genus-indexed in-memory cache (built on first access)
  Map<String, List<SpeciesDetail>>? _genusDb;

  /// Build the genus index from individual JSON files under [species_data/]
  /// using AssetManifest to discover all files at runtime.
  /// Add a new .json file to the folder and it appears automatically.
  /// Cached in memory after first load.
  Future<Map<String, List<SpeciesDetail>>> loadGenusDb() async {
    if (_genusDb != null) return _genusDb!;

    _genusDb = {};

    try {
      final AssetManifest manifest =
          await AssetManifest.loadFromAssetBundle(rootBundle);

      final speciesFiles = manifest.listAssets().where(
            (path) =>
                path.startsWith(_speciesPrefix) && path.endsWith('.json'),
          );

      for (final assetPath in speciesFiles) {
        try {
          final content = await rootBundle.loadString(assetPath);
          final data = json.decode(content) as Map<String, dynamic>;
          final detail = SpeciesDetail.fromJson(data);
          final genus = detail.genus.toLowerCase();

          if (genus.isNotEmpty) {
            _genusDb!.putIfAbsent(genus, () => []).add(detail);
          }
        } catch (e) {
          debugPrint('Error parsing $assetPath: $e');
        }
      }

      final totalSpecies =
          _genusDb!.values.fold(0, (sum, list) => sum + list.length);
      debugPrint(
          'Built genus database from species_data/: '
          '${_genusDb!.length} genera, $totalSpecies species');
    } catch (e) {
      debugPrint('Error building genus database: $e');
      _genusDb = {};
    }

    return _genusDb!;
  }

  /// Tool implementation: look up all species in a genus and return a
  /// compact list of scientific names paired with their visual features.
  Future<String> searchSpeciesByGenus(String genus) async {
    final db = await loadGenusDb();
    final key = genus.trim().toLowerCase();
    final species = db[key];

    if (species == null || species.isEmpty) {
      return 'No endangered species found in the genus "$genus".';
    }

    final buffer = StringBuffer();
    for (int i = 0; i < species.length; i++) {
      final s = species[i];
      if (i > 0) buffer.write(' | ');
      buffer.write('${s.scientificName}: ${s.visualFeatures}');
    }

    return buffer.toString();
  }

  /// Check if a given scientific name is in the endangered species database.
  Future<bool> isEndangered(String scientificName) async {
    final db = await loadGenusDb();
    final query = scientificName.trim().toLowerCase();

    for (final speciesList in db.values) {
      for (final s in speciesList) {
        if (s.scientificName.toLowerCase().contains(query) ||
            query.contains(s.scientificName.toLowerCase())) {
          return true;
        }
      }
    }
    return false;
  }

  /// Find species by Latin name — returns SpeciesDetail if found, null otherwise.
  Future<SpeciesDetail?> findSpeciesByLatinName(String latinName) async {
    try {
      final db = await loadGenusDb();
      final query = latinName.trim().toLowerCase();

      for (final speciesList in db.values) {
        for (final s in speciesList) {
          if (s.scientificName.toLowerCase().contains(query) ||
              query.contains(s.scientificName.toLowerCase())) {
            return s;
          }
        }
      }

      return null;
    } catch (e) {
      debugPrint('Error finding species: $e');
      return null;
    }
  }

  /// Find species by common name — returns SpeciesDetail if found, null otherwise.
  Future<SpeciesDetail?> findSpeciesByName(String name) async {
    try {
      final db = await loadGenusDb();
      final query = name.trim().toLowerCase();

      for (final speciesList in db.values) {
        for (final s in speciesList) {
          if (s.commonName.toLowerCase().contains(query) ||
              query.contains(s.commonName.toLowerCase())) {
            return s;
          }
        }
      }

      return null;
    } catch (e) {
      debugPrint('Error finding species: $e');
      return null;
    }
  }
}