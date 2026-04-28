import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class Species {
  final String name;
  final String latinName;
  final String description;
  final List<String> facts;
  final String? populationEstimate;
  final String? sourceUri;

  Species({
    required this.name,
    required this.latinName,
    required this.description,
    required this.facts,
    this.populationEstimate,
    this.sourceUri,
  });

  factory Species.fromJson(Map<String, dynamic> json) {
    return Species(
      name: json['name'] ?? '',
      latinName: json['latinName'] ?? '',
      description: json['description'] ?? '',
      facts: List<String>.from(json['facts'] ?? []),
      populationEstimate: json['population_estimate'],
      sourceUri: json['source_uri'],
    );
  }
}

class SpeciesService {
  static const String _dataPath = 'assets/data/species_data.json';
  List<Species>? _speciesCache;

  /// Load all species data from JSON asset
  Future<List<Species>> loadSpecies() async {
    try {
      if (_speciesCache != null) return _speciesCache!;

      final String response = await rootBundle.loadString(_dataPath);
      final data = json.decode(response);
      _speciesCache = (data as List).map((json) => Species.fromJson(json)).toList();
      return _speciesCache!;
    } catch (e) {
      debugPrint('Error loading species data: $e');
      return [];
    }
  }

  Future<String?> parseLatinName(String cleanedResponse) async {
    // Parse response format: [COMMON_ENGLISH_NAME] | [LATIN_NAME] | [ENDANGERED_STATUS]
    final _speciesList = await loadSpecies();
    final parts = cleanedResponse.split('|').map((p) => p.trim()).toList();
    
    if (parts.length >= 3) {
      final name = parts[0];
      final latinName = parts[1];
      final status = parts[2].toLowerCase();

      // Check if it's in the endangered list
      Species? matchedSpecies;
      for (final species in _speciesList) {
        if (latinName.toLowerCase().contains(species.latinName.toLowerCase()) ||
            species.latinName.toLowerCase().contains(latinName.toLowerCase())) {
          matchedSpecies = species;
          break;
        }
      }

      if (matchedSpecies != null) {
        // Found endangered species in list
        return matchedSpecies.latinName;
      } else {
        // Not in endangered list - return special format
        return 'NOT_LISTED|$name|$latinName';
      }
    }

    // Fallback: check if response contains any species from list
    Species? matchedSpecies;
    for (final species in _speciesList) {
      if (cleanedResponse.toLowerCase().contains(species.latinName.toLowerCase())) {
        matchedSpecies = species;
        break;
      }
    }

    if (matchedSpecies != null) {
      return matchedSpecies.latinName;
    }

    if (!cleanedResponse.toLowerCase().contains('not recognized')) {
      return cleanedResponse;
    }

    return '';
  }

  /// Find species by Latin name
  Future<Species?> findSpeciesByLatinName(String latinName) async {
    try {
      final _speciesList = await loadSpecies();

      return _speciesList.firstWhere(
        (s) => s.latinName.toLowerCase().contains(latinName.toLowerCase()) ||
               latinName.toLowerCase().contains(s.latinName.toLowerCase()),
        orElse: () => Species(
          name: '',
          latinName: '',
          description: '',
          facts: [],
        ),
      );
    } catch (e) {
      debugPrint('Error finding species: $e');
      return null;
    }
  }

  /// Find species by common name (for fallback use)
  Future<Species?> findSpeciesByName(String name) async {
    try {
      final _speciesList = await loadSpecies();

      return _speciesList.firstWhere(
        (s) => s.name.toLowerCase().contains(name.toLowerCase()) ||
               name.toLowerCase().contains(s.name.toLowerCase()),
        orElse: () => Species(
          name: '',
          latinName: '',
          description: '',
          facts: [],
        ),
      );
    } catch (e) {
      debugPrint('Error finding species: $e');
      return null;
    }
  }
}
