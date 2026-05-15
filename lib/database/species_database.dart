import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'species_database.g.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Table: species — all 19 JSON fields + structured VF sub-fields + visual_blob
// ═══════════════════════════════════════════════════════════════════════════════

@DataClassName('SpeciesData')
class Species extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get commonName => text().named('common_name')();
  TextColumn get latinName => text().named('latin_name')();
  TextColumn get kingdom => text()();
  TextColumn get className => text().named('class')();
  TextColumn get orderName => text().named('order')();
  TextColumn get family => text()();
  TextColumn get genus => text()();
  TextColumn get visualFeatures => text().named('visual_features')();
  TextColumn get description => text()();
  TextColumn get funFact => text().named('fun_fact')();
  TextColumn get ecosystemRole => text().named('ecosystem_role')();
  TextColumn get whatStudentsCanDo => text().named('what_students_can_do')();
  TextColumn get humanConnection => text().named('human_connection')();
  TextColumn get threats => text()();
  TextColumn get habitat => text()();
  TextColumn get habitatTags => text().named('habitat_tags')();
  TextColumn get conservationStatus => text().named('conservation_status')();
  TextColumn get populationEstimate => text().named('population_estimate')();
  TextColumn get populationEstimateSourceUri =>
      text().named('population_estimate_source_uri')();

  // Structured VF sub-fields (for weighted reranker).
  TextColumn get color => text()();
  TextColumn get bodyShape => text().named('body_shape')();
  TextColumn get distinctiveMarks => text().named('distinctive_marks')();
  TextColumn get texture => text()();
  TextColumn get sizeClass => text().named('size_class')();
  TextColumn get pattern => text()();

  // FTS5 consolidated blob.
  TextColumn get visualBlob => text().named('visual_blob')();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Drift database — opens the pre-built asset DB copied to app documents.
// ═══════════════════════════════════════════════════════════════════════════════

@DriftDatabase(tables: [Species])
class SpeciesDatabase extends _$SpeciesDatabase {
  SpeciesDatabase._() : super(_openConnection());

  static SpeciesDatabase? _instance;

  /// Shared singleton — lazy-initialised, thread-safe.
  static SpeciesDatabase get instance {
    _instance ??= SpeciesDatabase._();
    return _instance!;
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      // Pre-built DB already has all tables + FTS5. No migration needed.
    },
  );

  // ── Query helpers ──────────────────────────────────────────────────────

  /// Find a species by its Latin (scientific) name — partial match.
  Future<SpeciesData?> findByNameLatin(String latinName) async {
    final q = latinName.trim().toLowerCase();
    final results = await (select(species)
          ..where((t) => t.latinName.lower().contains(q)))
        .get();
    return results.isNotEmpty ? results.first : null;
  }

  /// Find a species by its common name — partial match.
  Future<SpeciesData?> findByNameCommon(String name) async {
    final q = name.trim().toLowerCase();
    final results = await (select(species)
          ..where((t) => t.commonName.lower().contains(q)))
        .get();
    return results.isNotEmpty ? results.first : null;
  }

  /// Check if a scientific name exists (for endangered lookups).
  Future<bool> existsByName(String name) async {
    final q = name.trim().toLowerCase();
    final rows = await (select(species)
          ..where((t) => t.latinName.lower().contains(q)))
        .get();
    return rows.isNotEmpty;
  }

  /// All species in a given genus.
  Future<List<SpeciesData>> findByGenus(String genusName) async {
    final q = genusName.trim().toLowerCase();
    return (select(species)
          ..where((t) => t.genus.lower().equals(q)))
        .get();
  }

  /// All species — for in-memory caches or counts.
  Future<List<SpeciesData>> getAll() => select(species).get();

  /// Count of all species.
  Future<int> countAll() => select(species).get().then((r) => r.length);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Connection — copy pre-built DB from assets → documents, then open with Drift.
// ═══════════════════════════════════════════════════════════════════════════════

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'species_data.sqlite');

    if (!await File(dbPath).exists()) {
      final blob = await rootBundle.load('assets/data/species_data.sqlite');
      final bytes = blob.buffer.asUint8List(blob.offsetInBytes, blob.lengthInBytes);
      await File(dbPath).create(recursive: true);
      await File(dbPath).writeAsBytes(bytes);
    }

    return driftDatabase(name: 'species_data');
  });
}
