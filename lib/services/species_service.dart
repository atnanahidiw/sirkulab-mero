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

  Species(
      {required this.name,
      required this.latinName,
      required this.description,
      required this.facts,
      this.populationEstimate,
      this.sourceUri});

  factory Species.fromJson(Map<String, dynamic> json) {
    return Species(
      name: json['name'],
      latinName: json['latinName'] ?? '',
      description: json['description'],
      facts: List<String>.from(json['facts']),
      populationEstimate: json['population_estimate'],
      sourceUri: json['source_uri'],
    );
  }
}

class SpeciesService {
  static const String _dataPath = 'assets/data/species_data.json';

  Future<List<Species>> loadSpecies() async {
    try {
      final String response = await rootBundle.loadString(_dataPath);
      final data = json.decode(response);
      return (data as List).map((json) => Species.fromJson(json)).toList();
    } catch (e) {
      debugPrint('Error loading species data: $e');
      return [];
    }
  }

  Species? findSpecies(String name) {
    // This would be called after the LLM identifies the species name
    // In a real app, this would be a local database or the JSON file
    return null; // Implementation handled in the screen for this demo
  }
}
