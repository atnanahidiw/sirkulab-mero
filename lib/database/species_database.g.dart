// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'species_database.dart';

// ignore_for_file: type=lint
class $SpeciesTable extends Species with TableInfo<$SpeciesTable, SpeciesData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SpeciesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _commonNameMeta =
      const VerificationMeta('commonName');
  @override
  late final GeneratedColumn<String> commonName = GeneratedColumn<String>(
      'common_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _latinNameMeta =
      const VerificationMeta('latinName');
  @override
  late final GeneratedColumn<String> latinName = GeneratedColumn<String>(
      'latin_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kingdomMeta =
      const VerificationMeta('kingdom');
  @override
  late final GeneratedColumn<String> kingdom = GeneratedColumn<String>(
      'kingdom', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _classNameMeta =
      const VerificationMeta('className');
  @override
  late final GeneratedColumn<String> className = GeneratedColumn<String>(
      'class', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orderNameMeta =
      const VerificationMeta('orderName');
  @override
  late final GeneratedColumn<String> orderName = GeneratedColumn<String>(
      'order', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _familyMeta = const VerificationMeta('family');
  @override
  late final GeneratedColumn<String> family = GeneratedColumn<String>(
      'family', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _genusMeta = const VerificationMeta('genus');
  @override
  late final GeneratedColumn<String> genus = GeneratedColumn<String>(
      'genus', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _visualFeaturesMeta =
      const VerificationMeta('visualFeatures');
  @override
  late final GeneratedColumn<String> visualFeatures = GeneratedColumn<String>(
      'visual_features', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _descriptionMeta =
      const VerificationMeta('description');
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
      'description', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _funFactMeta =
      const VerificationMeta('funFact');
  @override
  late final GeneratedColumn<String> funFact = GeneratedColumn<String>(
      'fun_fact', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _ecosystemRoleMeta =
      const VerificationMeta('ecosystemRole');
  @override
  late final GeneratedColumn<String> ecosystemRole = GeneratedColumn<String>(
      'ecosystem_role', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _whatStudentsCanDoMeta =
      const VerificationMeta('whatStudentsCanDo');
  @override
  late final GeneratedColumn<String> whatStudentsCanDo =
      GeneratedColumn<String>('what_students_can_do', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _humanConnectionMeta =
      const VerificationMeta('humanConnection');
  @override
  late final GeneratedColumn<String> humanConnection = GeneratedColumn<String>(
      'human_connection', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _threatsMeta =
      const VerificationMeta('threats');
  @override
  late final GeneratedColumn<String> threats = GeneratedColumn<String>(
      'threats', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _habitatMeta =
      const VerificationMeta('habitat');
  @override
  late final GeneratedColumn<String> habitat = GeneratedColumn<String>(
      'habitat', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _habitatTagsMeta =
      const VerificationMeta('habitatTags');
  @override
  late final GeneratedColumn<String> habitatTags = GeneratedColumn<String>(
      'habitat_tags', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conservationStatusMeta =
      const VerificationMeta('conservationStatus');
  @override
  late final GeneratedColumn<String> conservationStatus =
      GeneratedColumn<String>('conservation_status', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _populationEstimateMeta =
      const VerificationMeta('populationEstimate');
  @override
  late final GeneratedColumn<String> populationEstimate =
      GeneratedColumn<String>('population_estimate', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _populationEstimateSourceUriMeta =
      const VerificationMeta('populationEstimateSourceUri');
  @override
  late final GeneratedColumn<String> populationEstimateSourceUri =
      GeneratedColumn<String>(
          'population_estimate_source_uri', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
      'color', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _bodyShapeMeta =
      const VerificationMeta('bodyShape');
  @override
  late final GeneratedColumn<String> bodyShape = GeneratedColumn<String>(
      'body_shape', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _distinctiveMarksMeta =
      const VerificationMeta('distinctiveMarks');
  @override
  late final GeneratedColumn<String> distinctiveMarks = GeneratedColumn<String>(
      'distinctive_marks', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _textureMeta =
      const VerificationMeta('texture');
  @override
  late final GeneratedColumn<String> texture = GeneratedColumn<String>(
      'texture', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sizeClassMeta =
      const VerificationMeta('sizeClass');
  @override
  late final GeneratedColumn<String> sizeClass = GeneratedColumn<String>(
      'size_class', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _patternMeta =
      const VerificationMeta('pattern');
  @override
  late final GeneratedColumn<String> pattern = GeneratedColumn<String>(
      'pattern', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _visualBlobMeta =
      const VerificationMeta('visualBlob');
  @override
  late final GeneratedColumn<String> visualBlob = GeneratedColumn<String>(
      'visual_blob', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        commonName,
        latinName,
        kingdom,
        className,
        orderName,
        family,
        genus,
        visualFeatures,
        description,
        funFact,
        ecosystemRole,
        whatStudentsCanDo,
        humanConnection,
        threats,
        habitat,
        habitatTags,
        conservationStatus,
        populationEstimate,
        populationEstimateSourceUri,
        color,
        bodyShape,
        distinctiveMarks,
        texture,
        sizeClass,
        pattern,
        visualBlob
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'species';
  @override
  VerificationContext validateIntegrity(Insertable<SpeciesData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('common_name')) {
      context.handle(
          _commonNameMeta,
          commonName.isAcceptableOrUnknown(
              data['common_name']!, _commonNameMeta));
    } else if (isInserting) {
      context.missing(_commonNameMeta);
    }
    if (data.containsKey('latin_name')) {
      context.handle(_latinNameMeta,
          latinName.isAcceptableOrUnknown(data['latin_name']!, _latinNameMeta));
    } else if (isInserting) {
      context.missing(_latinNameMeta);
    }
    if (data.containsKey('kingdom')) {
      context.handle(_kingdomMeta,
          kingdom.isAcceptableOrUnknown(data['kingdom']!, _kingdomMeta));
    } else if (isInserting) {
      context.missing(_kingdomMeta);
    }
    if (data.containsKey('class')) {
      context.handle(_classNameMeta,
          className.isAcceptableOrUnknown(data['class']!, _classNameMeta));
    } else if (isInserting) {
      context.missing(_classNameMeta);
    }
    if (data.containsKey('order')) {
      context.handle(_orderNameMeta,
          orderName.isAcceptableOrUnknown(data['order']!, _orderNameMeta));
    } else if (isInserting) {
      context.missing(_orderNameMeta);
    }
    if (data.containsKey('family')) {
      context.handle(_familyMeta,
          family.isAcceptableOrUnknown(data['family']!, _familyMeta));
    } else if (isInserting) {
      context.missing(_familyMeta);
    }
    if (data.containsKey('genus')) {
      context.handle(
          _genusMeta, genus.isAcceptableOrUnknown(data['genus']!, _genusMeta));
    } else if (isInserting) {
      context.missing(_genusMeta);
    }
    if (data.containsKey('visual_features')) {
      context.handle(
          _visualFeaturesMeta,
          visualFeatures.isAcceptableOrUnknown(
              data['visual_features']!, _visualFeaturesMeta));
    } else if (isInserting) {
      context.missing(_visualFeaturesMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
          _descriptionMeta,
          description.isAcceptableOrUnknown(
              data['description']!, _descriptionMeta));
    } else if (isInserting) {
      context.missing(_descriptionMeta);
    }
    if (data.containsKey('fun_fact')) {
      context.handle(_funFactMeta,
          funFact.isAcceptableOrUnknown(data['fun_fact']!, _funFactMeta));
    } else if (isInserting) {
      context.missing(_funFactMeta);
    }
    if (data.containsKey('ecosystem_role')) {
      context.handle(
          _ecosystemRoleMeta,
          ecosystemRole.isAcceptableOrUnknown(
              data['ecosystem_role']!, _ecosystemRoleMeta));
    } else if (isInserting) {
      context.missing(_ecosystemRoleMeta);
    }
    if (data.containsKey('what_students_can_do')) {
      context.handle(
          _whatStudentsCanDoMeta,
          whatStudentsCanDo.isAcceptableOrUnknown(
              data['what_students_can_do']!, _whatStudentsCanDoMeta));
    } else if (isInserting) {
      context.missing(_whatStudentsCanDoMeta);
    }
    if (data.containsKey('human_connection')) {
      context.handle(
          _humanConnectionMeta,
          humanConnection.isAcceptableOrUnknown(
              data['human_connection']!, _humanConnectionMeta));
    } else if (isInserting) {
      context.missing(_humanConnectionMeta);
    }
    if (data.containsKey('threats')) {
      context.handle(_threatsMeta,
          threats.isAcceptableOrUnknown(data['threats']!, _threatsMeta));
    } else if (isInserting) {
      context.missing(_threatsMeta);
    }
    if (data.containsKey('habitat')) {
      context.handle(_habitatMeta,
          habitat.isAcceptableOrUnknown(data['habitat']!, _habitatMeta));
    } else if (isInserting) {
      context.missing(_habitatMeta);
    }
    if (data.containsKey('habitat_tags')) {
      context.handle(
          _habitatTagsMeta,
          habitatTags.isAcceptableOrUnknown(
              data['habitat_tags']!, _habitatTagsMeta));
    } else if (isInserting) {
      context.missing(_habitatTagsMeta);
    }
    if (data.containsKey('conservation_status')) {
      context.handle(
          _conservationStatusMeta,
          conservationStatus.isAcceptableOrUnknown(
              data['conservation_status']!, _conservationStatusMeta));
    } else if (isInserting) {
      context.missing(_conservationStatusMeta);
    }
    if (data.containsKey('population_estimate')) {
      context.handle(
          _populationEstimateMeta,
          populationEstimate.isAcceptableOrUnknown(
              data['population_estimate']!, _populationEstimateMeta));
    } else if (isInserting) {
      context.missing(_populationEstimateMeta);
    }
    if (data.containsKey('population_estimate_source_uri')) {
      context.handle(
          _populationEstimateSourceUriMeta,
          populationEstimateSourceUri.isAcceptableOrUnknown(
              data['population_estimate_source_uri']!,
              _populationEstimateSourceUriMeta));
    } else if (isInserting) {
      context.missing(_populationEstimateSourceUriMeta);
    }
    if (data.containsKey('color')) {
      context.handle(
          _colorMeta, color.isAcceptableOrUnknown(data['color']!, _colorMeta));
    } else if (isInserting) {
      context.missing(_colorMeta);
    }
    if (data.containsKey('body_shape')) {
      context.handle(_bodyShapeMeta,
          bodyShape.isAcceptableOrUnknown(data['body_shape']!, _bodyShapeMeta));
    } else if (isInserting) {
      context.missing(_bodyShapeMeta);
    }
    if (data.containsKey('distinctive_marks')) {
      context.handle(
          _distinctiveMarksMeta,
          distinctiveMarks.isAcceptableOrUnknown(
              data['distinctive_marks']!, _distinctiveMarksMeta));
    } else if (isInserting) {
      context.missing(_distinctiveMarksMeta);
    }
    if (data.containsKey('texture')) {
      context.handle(_textureMeta,
          texture.isAcceptableOrUnknown(data['texture']!, _textureMeta));
    } else if (isInserting) {
      context.missing(_textureMeta);
    }
    if (data.containsKey('size_class')) {
      context.handle(_sizeClassMeta,
          sizeClass.isAcceptableOrUnknown(data['size_class']!, _sizeClassMeta));
    } else if (isInserting) {
      context.missing(_sizeClassMeta);
    }
    if (data.containsKey('pattern')) {
      context.handle(_patternMeta,
          pattern.isAcceptableOrUnknown(data['pattern']!, _patternMeta));
    } else if (isInserting) {
      context.missing(_patternMeta);
    }
    if (data.containsKey('visual_blob')) {
      context.handle(
          _visualBlobMeta,
          visualBlob.isAcceptableOrUnknown(
              data['visual_blob']!, _visualBlobMeta));
    } else if (isInserting) {
      context.missing(_visualBlobMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SpeciesData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SpeciesData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      commonName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}common_name'])!,
      latinName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}latin_name'])!,
      kingdom: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kingdom'])!,
      className: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}class'])!,
      orderName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}order'])!,
      family: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}family'])!,
      genus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}genus'])!,
      visualFeatures: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}visual_features'])!,
      description: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}description'])!,
      funFact: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}fun_fact'])!,
      ecosystemRole: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}ecosystem_role'])!,
      whatStudentsCanDo: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}what_students_can_do'])!,
      humanConnection: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}human_connection'])!,
      threats: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}threats'])!,
      habitat: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}habitat'])!,
      habitatTags: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}habitat_tags'])!,
      conservationStatus: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conservation_status'])!,
      populationEstimate: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}population_estimate'])!,
      populationEstimateSourceUri: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}population_estimate_source_uri'])!,
      color: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}color'])!,
      bodyShape: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}body_shape'])!,
      distinctiveMarks: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}distinctive_marks'])!,
      texture: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}texture'])!,
      sizeClass: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}size_class'])!,
      pattern: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}pattern'])!,
      visualBlob: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}visual_blob'])!,
    );
  }

  @override
  $SpeciesTable createAlias(String alias) {
    return $SpeciesTable(attachedDatabase, alias);
  }
}

class SpeciesData extends DataClass implements Insertable<SpeciesData> {
  final int id;
  final String commonName;
  final String latinName;
  final String kingdom;
  final String className;
  final String orderName;
  final String family;
  final String genus;
  final String visualFeatures;
  final String description;
  final String funFact;
  final String ecosystemRole;
  final String whatStudentsCanDo;
  final String humanConnection;
  final String threats;
  final String habitat;
  final String habitatTags;
  final String conservationStatus;
  final String populationEstimate;
  final String populationEstimateSourceUri;
  final String color;
  final String bodyShape;
  final String distinctiveMarks;
  final String texture;
  final String sizeClass;
  final String pattern;
  final String visualBlob;
  const SpeciesData(
      {required this.id,
      required this.commonName,
      required this.latinName,
      required this.kingdom,
      required this.className,
      required this.orderName,
      required this.family,
      required this.genus,
      required this.visualFeatures,
      required this.description,
      required this.funFact,
      required this.ecosystemRole,
      required this.whatStudentsCanDo,
      required this.humanConnection,
      required this.threats,
      required this.habitat,
      required this.habitatTags,
      required this.conservationStatus,
      required this.populationEstimate,
      required this.populationEstimateSourceUri,
      required this.color,
      required this.bodyShape,
      required this.distinctiveMarks,
      required this.texture,
      required this.sizeClass,
      required this.pattern,
      required this.visualBlob});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['common_name'] = Variable<String>(commonName);
    map['latin_name'] = Variable<String>(latinName);
    map['kingdom'] = Variable<String>(kingdom);
    map['class'] = Variable<String>(className);
    map['order'] = Variable<String>(orderName);
    map['family'] = Variable<String>(family);
    map['genus'] = Variable<String>(genus);
    map['visual_features'] = Variable<String>(visualFeatures);
    map['description'] = Variable<String>(description);
    map['fun_fact'] = Variable<String>(funFact);
    map['ecosystem_role'] = Variable<String>(ecosystemRole);
    map['what_students_can_do'] = Variable<String>(whatStudentsCanDo);
    map['human_connection'] = Variable<String>(humanConnection);
    map['threats'] = Variable<String>(threats);
    map['habitat'] = Variable<String>(habitat);
    map['habitat_tags'] = Variable<String>(habitatTags);
    map['conservation_status'] = Variable<String>(conservationStatus);
    map['population_estimate'] = Variable<String>(populationEstimate);
    map['population_estimate_source_uri'] =
        Variable<String>(populationEstimateSourceUri);
    map['color'] = Variable<String>(color);
    map['body_shape'] = Variable<String>(bodyShape);
    map['distinctive_marks'] = Variable<String>(distinctiveMarks);
    map['texture'] = Variable<String>(texture);
    map['size_class'] = Variable<String>(sizeClass);
    map['pattern'] = Variable<String>(pattern);
    map['visual_blob'] = Variable<String>(visualBlob);
    return map;
  }

  SpeciesCompanion toCompanion(bool nullToAbsent) {
    return SpeciesCompanion(
      id: Value(id),
      commonName: Value(commonName),
      latinName: Value(latinName),
      kingdom: Value(kingdom),
      className: Value(className),
      orderName: Value(orderName),
      family: Value(family),
      genus: Value(genus),
      visualFeatures: Value(visualFeatures),
      description: Value(description),
      funFact: Value(funFact),
      ecosystemRole: Value(ecosystemRole),
      whatStudentsCanDo: Value(whatStudentsCanDo),
      humanConnection: Value(humanConnection),
      threats: Value(threats),
      habitat: Value(habitat),
      habitatTags: Value(habitatTags),
      conservationStatus: Value(conservationStatus),
      populationEstimate: Value(populationEstimate),
      populationEstimateSourceUri: Value(populationEstimateSourceUri),
      color: Value(color),
      bodyShape: Value(bodyShape),
      distinctiveMarks: Value(distinctiveMarks),
      texture: Value(texture),
      sizeClass: Value(sizeClass),
      pattern: Value(pattern),
      visualBlob: Value(visualBlob),
    );
  }

  factory SpeciesData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SpeciesData(
      id: serializer.fromJson<int>(json['id']),
      commonName: serializer.fromJson<String>(json['commonName']),
      latinName: serializer.fromJson<String>(json['latinName']),
      kingdom: serializer.fromJson<String>(json['kingdom']),
      className: serializer.fromJson<String>(json['className']),
      orderName: serializer.fromJson<String>(json['orderName']),
      family: serializer.fromJson<String>(json['family']),
      genus: serializer.fromJson<String>(json['genus']),
      visualFeatures: serializer.fromJson<String>(json['visualFeatures']),
      description: serializer.fromJson<String>(json['description']),
      funFact: serializer.fromJson<String>(json['funFact']),
      ecosystemRole: serializer.fromJson<String>(json['ecosystemRole']),
      whatStudentsCanDo: serializer.fromJson<String>(json['whatStudentsCanDo']),
      humanConnection: serializer.fromJson<String>(json['humanConnection']),
      threats: serializer.fromJson<String>(json['threats']),
      habitat: serializer.fromJson<String>(json['habitat']),
      habitatTags: serializer.fromJson<String>(json['habitatTags']),
      conservationStatus:
          serializer.fromJson<String>(json['conservationStatus']),
      populationEstimate:
          serializer.fromJson<String>(json['populationEstimate']),
      populationEstimateSourceUri:
          serializer.fromJson<String>(json['populationEstimateSourceUri']),
      color: serializer.fromJson<String>(json['color']),
      bodyShape: serializer.fromJson<String>(json['bodyShape']),
      distinctiveMarks: serializer.fromJson<String>(json['distinctiveMarks']),
      texture: serializer.fromJson<String>(json['texture']),
      sizeClass: serializer.fromJson<String>(json['sizeClass']),
      pattern: serializer.fromJson<String>(json['pattern']),
      visualBlob: serializer.fromJson<String>(json['visualBlob']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'commonName': serializer.toJson<String>(commonName),
      'latinName': serializer.toJson<String>(latinName),
      'kingdom': serializer.toJson<String>(kingdom),
      'className': serializer.toJson<String>(className),
      'orderName': serializer.toJson<String>(orderName),
      'family': serializer.toJson<String>(family),
      'genus': serializer.toJson<String>(genus),
      'visualFeatures': serializer.toJson<String>(visualFeatures),
      'description': serializer.toJson<String>(description),
      'funFact': serializer.toJson<String>(funFact),
      'ecosystemRole': serializer.toJson<String>(ecosystemRole),
      'whatStudentsCanDo': serializer.toJson<String>(whatStudentsCanDo),
      'humanConnection': serializer.toJson<String>(humanConnection),
      'threats': serializer.toJson<String>(threats),
      'habitat': serializer.toJson<String>(habitat),
      'habitatTags': serializer.toJson<String>(habitatTags),
      'conservationStatus': serializer.toJson<String>(conservationStatus),
      'populationEstimate': serializer.toJson<String>(populationEstimate),
      'populationEstimateSourceUri':
          serializer.toJson<String>(populationEstimateSourceUri),
      'color': serializer.toJson<String>(color),
      'bodyShape': serializer.toJson<String>(bodyShape),
      'distinctiveMarks': serializer.toJson<String>(distinctiveMarks),
      'texture': serializer.toJson<String>(texture),
      'sizeClass': serializer.toJson<String>(sizeClass),
      'pattern': serializer.toJson<String>(pattern),
      'visualBlob': serializer.toJson<String>(visualBlob),
    };
  }

  SpeciesData copyWith(
          {int? id,
          String? commonName,
          String? latinName,
          String? kingdom,
          String? className,
          String? orderName,
          String? family,
          String? genus,
          String? visualFeatures,
          String? description,
          String? funFact,
          String? ecosystemRole,
          String? whatStudentsCanDo,
          String? humanConnection,
          String? threats,
          String? habitat,
          String? habitatTags,
          String? conservationStatus,
          String? populationEstimate,
          String? populationEstimateSourceUri,
          String? color,
          String? bodyShape,
          String? distinctiveMarks,
          String? texture,
          String? sizeClass,
          String? pattern,
          String? visualBlob}) =>
      SpeciesData(
        id: id ?? this.id,
        commonName: commonName ?? this.commonName,
        latinName: latinName ?? this.latinName,
        kingdom: kingdom ?? this.kingdom,
        className: className ?? this.className,
        orderName: orderName ?? this.orderName,
        family: family ?? this.family,
        genus: genus ?? this.genus,
        visualFeatures: visualFeatures ?? this.visualFeatures,
        description: description ?? this.description,
        funFact: funFact ?? this.funFact,
        ecosystemRole: ecosystemRole ?? this.ecosystemRole,
        whatStudentsCanDo: whatStudentsCanDo ?? this.whatStudentsCanDo,
        humanConnection: humanConnection ?? this.humanConnection,
        threats: threats ?? this.threats,
        habitat: habitat ?? this.habitat,
        habitatTags: habitatTags ?? this.habitatTags,
        conservationStatus: conservationStatus ?? this.conservationStatus,
        populationEstimate: populationEstimate ?? this.populationEstimate,
        populationEstimateSourceUri:
            populationEstimateSourceUri ?? this.populationEstimateSourceUri,
        color: color ?? this.color,
        bodyShape: bodyShape ?? this.bodyShape,
        distinctiveMarks: distinctiveMarks ?? this.distinctiveMarks,
        texture: texture ?? this.texture,
        sizeClass: sizeClass ?? this.sizeClass,
        pattern: pattern ?? this.pattern,
        visualBlob: visualBlob ?? this.visualBlob,
      );
  SpeciesData copyWithCompanion(SpeciesCompanion data) {
    return SpeciesData(
      id: data.id.present ? data.id.value : this.id,
      commonName:
          data.commonName.present ? data.commonName.value : this.commonName,
      latinName: data.latinName.present ? data.latinName.value : this.latinName,
      kingdom: data.kingdom.present ? data.kingdom.value : this.kingdom,
      className: data.className.present ? data.className.value : this.className,
      orderName: data.orderName.present ? data.orderName.value : this.orderName,
      family: data.family.present ? data.family.value : this.family,
      genus: data.genus.present ? data.genus.value : this.genus,
      visualFeatures: data.visualFeatures.present
          ? data.visualFeatures.value
          : this.visualFeatures,
      description:
          data.description.present ? data.description.value : this.description,
      funFact: data.funFact.present ? data.funFact.value : this.funFact,
      ecosystemRole: data.ecosystemRole.present
          ? data.ecosystemRole.value
          : this.ecosystemRole,
      whatStudentsCanDo: data.whatStudentsCanDo.present
          ? data.whatStudentsCanDo.value
          : this.whatStudentsCanDo,
      humanConnection: data.humanConnection.present
          ? data.humanConnection.value
          : this.humanConnection,
      threats: data.threats.present ? data.threats.value : this.threats,
      habitat: data.habitat.present ? data.habitat.value : this.habitat,
      habitatTags:
          data.habitatTags.present ? data.habitatTags.value : this.habitatTags,
      conservationStatus: data.conservationStatus.present
          ? data.conservationStatus.value
          : this.conservationStatus,
      populationEstimate: data.populationEstimate.present
          ? data.populationEstimate.value
          : this.populationEstimate,
      populationEstimateSourceUri: data.populationEstimateSourceUri.present
          ? data.populationEstimateSourceUri.value
          : this.populationEstimateSourceUri,
      color: data.color.present ? data.color.value : this.color,
      bodyShape: data.bodyShape.present ? data.bodyShape.value : this.bodyShape,
      distinctiveMarks: data.distinctiveMarks.present
          ? data.distinctiveMarks.value
          : this.distinctiveMarks,
      texture: data.texture.present ? data.texture.value : this.texture,
      sizeClass: data.sizeClass.present ? data.sizeClass.value : this.sizeClass,
      pattern: data.pattern.present ? data.pattern.value : this.pattern,
      visualBlob:
          data.visualBlob.present ? data.visualBlob.value : this.visualBlob,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SpeciesData(')
          ..write('id: $id, ')
          ..write('commonName: $commonName, ')
          ..write('latinName: $latinName, ')
          ..write('kingdom: $kingdom, ')
          ..write('className: $className, ')
          ..write('orderName: $orderName, ')
          ..write('family: $family, ')
          ..write('genus: $genus, ')
          ..write('visualFeatures: $visualFeatures, ')
          ..write('description: $description, ')
          ..write('funFact: $funFact, ')
          ..write('ecosystemRole: $ecosystemRole, ')
          ..write('whatStudentsCanDo: $whatStudentsCanDo, ')
          ..write('humanConnection: $humanConnection, ')
          ..write('threats: $threats, ')
          ..write('habitat: $habitat, ')
          ..write('habitatTags: $habitatTags, ')
          ..write('conservationStatus: $conservationStatus, ')
          ..write('populationEstimate: $populationEstimate, ')
          ..write('populationEstimateSourceUri: $populationEstimateSourceUri, ')
          ..write('color: $color, ')
          ..write('bodyShape: $bodyShape, ')
          ..write('distinctiveMarks: $distinctiveMarks, ')
          ..write('texture: $texture, ')
          ..write('sizeClass: $sizeClass, ')
          ..write('pattern: $pattern, ')
          ..write('visualBlob: $visualBlob')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        commonName,
        latinName,
        kingdom,
        className,
        orderName,
        family,
        genus,
        visualFeatures,
        description,
        funFact,
        ecosystemRole,
        whatStudentsCanDo,
        humanConnection,
        threats,
        habitat,
        habitatTags,
        conservationStatus,
        populationEstimate,
        populationEstimateSourceUri,
        color,
        bodyShape,
        distinctiveMarks,
        texture,
        sizeClass,
        pattern,
        visualBlob
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SpeciesData &&
          other.id == this.id &&
          other.commonName == this.commonName &&
          other.latinName == this.latinName &&
          other.kingdom == this.kingdom &&
          other.className == this.className &&
          other.orderName == this.orderName &&
          other.family == this.family &&
          other.genus == this.genus &&
          other.visualFeatures == this.visualFeatures &&
          other.description == this.description &&
          other.funFact == this.funFact &&
          other.ecosystemRole == this.ecosystemRole &&
          other.whatStudentsCanDo == this.whatStudentsCanDo &&
          other.humanConnection == this.humanConnection &&
          other.threats == this.threats &&
          other.habitat == this.habitat &&
          other.habitatTags == this.habitatTags &&
          other.conservationStatus == this.conservationStatus &&
          other.populationEstimate == this.populationEstimate &&
          other.populationEstimateSourceUri ==
              this.populationEstimateSourceUri &&
          other.color == this.color &&
          other.bodyShape == this.bodyShape &&
          other.distinctiveMarks == this.distinctiveMarks &&
          other.texture == this.texture &&
          other.sizeClass == this.sizeClass &&
          other.pattern == this.pattern &&
          other.visualBlob == this.visualBlob);
}

class SpeciesCompanion extends UpdateCompanion<SpeciesData> {
  final Value<int> id;
  final Value<String> commonName;
  final Value<String> latinName;
  final Value<String> kingdom;
  final Value<String> className;
  final Value<String> orderName;
  final Value<String> family;
  final Value<String> genus;
  final Value<String> visualFeatures;
  final Value<String> description;
  final Value<String> funFact;
  final Value<String> ecosystemRole;
  final Value<String> whatStudentsCanDo;
  final Value<String> humanConnection;
  final Value<String> threats;
  final Value<String> habitat;
  final Value<String> habitatTags;
  final Value<String> conservationStatus;
  final Value<String> populationEstimate;
  final Value<String> populationEstimateSourceUri;
  final Value<String> color;
  final Value<String> bodyShape;
  final Value<String> distinctiveMarks;
  final Value<String> texture;
  final Value<String> sizeClass;
  final Value<String> pattern;
  final Value<String> visualBlob;
  const SpeciesCompanion({
    this.id = const Value.absent(),
    this.commonName = const Value.absent(),
    this.latinName = const Value.absent(),
    this.kingdom = const Value.absent(),
    this.className = const Value.absent(),
    this.orderName = const Value.absent(),
    this.family = const Value.absent(),
    this.genus = const Value.absent(),
    this.visualFeatures = const Value.absent(),
    this.description = const Value.absent(),
    this.funFact = const Value.absent(),
    this.ecosystemRole = const Value.absent(),
    this.whatStudentsCanDo = const Value.absent(),
    this.humanConnection = const Value.absent(),
    this.threats = const Value.absent(),
    this.habitat = const Value.absent(),
    this.habitatTags = const Value.absent(),
    this.conservationStatus = const Value.absent(),
    this.populationEstimate = const Value.absent(),
    this.populationEstimateSourceUri = const Value.absent(),
    this.color = const Value.absent(),
    this.bodyShape = const Value.absent(),
    this.distinctiveMarks = const Value.absent(),
    this.texture = const Value.absent(),
    this.sizeClass = const Value.absent(),
    this.pattern = const Value.absent(),
    this.visualBlob = const Value.absent(),
  });
  SpeciesCompanion.insert({
    this.id = const Value.absent(),
    required String commonName,
    required String latinName,
    required String kingdom,
    required String className,
    required String orderName,
    required String family,
    required String genus,
    required String visualFeatures,
    required String description,
    required String funFact,
    required String ecosystemRole,
    required String whatStudentsCanDo,
    required String humanConnection,
    required String threats,
    required String habitat,
    required String habitatTags,
    required String conservationStatus,
    required String populationEstimate,
    required String populationEstimateSourceUri,
    required String color,
    required String bodyShape,
    required String distinctiveMarks,
    required String texture,
    required String sizeClass,
    required String pattern,
    required String visualBlob,
  })  : commonName = Value(commonName),
        latinName = Value(latinName),
        kingdom = Value(kingdom),
        className = Value(className),
        orderName = Value(orderName),
        family = Value(family),
        genus = Value(genus),
        visualFeatures = Value(visualFeatures),
        description = Value(description),
        funFact = Value(funFact),
        ecosystemRole = Value(ecosystemRole),
        whatStudentsCanDo = Value(whatStudentsCanDo),
        humanConnection = Value(humanConnection),
        threats = Value(threats),
        habitat = Value(habitat),
        habitatTags = Value(habitatTags),
        conservationStatus = Value(conservationStatus),
        populationEstimate = Value(populationEstimate),
        populationEstimateSourceUri = Value(populationEstimateSourceUri),
        color = Value(color),
        bodyShape = Value(bodyShape),
        distinctiveMarks = Value(distinctiveMarks),
        texture = Value(texture),
        sizeClass = Value(sizeClass),
        pattern = Value(pattern),
        visualBlob = Value(visualBlob);
  static Insertable<SpeciesData> custom({
    Expression<int>? id,
    Expression<String>? commonName,
    Expression<String>? latinName,
    Expression<String>? kingdom,
    Expression<String>? className,
    Expression<String>? orderName,
    Expression<String>? family,
    Expression<String>? genus,
    Expression<String>? visualFeatures,
    Expression<String>? description,
    Expression<String>? funFact,
    Expression<String>? ecosystemRole,
    Expression<String>? whatStudentsCanDo,
    Expression<String>? humanConnection,
    Expression<String>? threats,
    Expression<String>? habitat,
    Expression<String>? habitatTags,
    Expression<String>? conservationStatus,
    Expression<String>? populationEstimate,
    Expression<String>? populationEstimateSourceUri,
    Expression<String>? color,
    Expression<String>? bodyShape,
    Expression<String>? distinctiveMarks,
    Expression<String>? texture,
    Expression<String>? sizeClass,
    Expression<String>? pattern,
    Expression<String>? visualBlob,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (commonName != null) 'common_name': commonName,
      if (latinName != null) 'latin_name': latinName,
      if (kingdom != null) 'kingdom': kingdom,
      if (className != null) 'class': className,
      if (orderName != null) 'order': orderName,
      if (family != null) 'family': family,
      if (genus != null) 'genus': genus,
      if (visualFeatures != null) 'visual_features': visualFeatures,
      if (description != null) 'description': description,
      if (funFact != null) 'fun_fact': funFact,
      if (ecosystemRole != null) 'ecosystem_role': ecosystemRole,
      if (whatStudentsCanDo != null) 'what_students_can_do': whatStudentsCanDo,
      if (humanConnection != null) 'human_connection': humanConnection,
      if (threats != null) 'threats': threats,
      if (habitat != null) 'habitat': habitat,
      if (habitatTags != null) 'habitat_tags': habitatTags,
      if (conservationStatus != null) 'conservation_status': conservationStatus,
      if (populationEstimate != null) 'population_estimate': populationEstimate,
      if (populationEstimateSourceUri != null)
        'population_estimate_source_uri': populationEstimateSourceUri,
      if (color != null) 'color': color,
      if (bodyShape != null) 'body_shape': bodyShape,
      if (distinctiveMarks != null) 'distinctive_marks': distinctiveMarks,
      if (texture != null) 'texture': texture,
      if (sizeClass != null) 'size_class': sizeClass,
      if (pattern != null) 'pattern': pattern,
      if (visualBlob != null) 'visual_blob': visualBlob,
    });
  }

  SpeciesCompanion copyWith(
      {Value<int>? id,
      Value<String>? commonName,
      Value<String>? latinName,
      Value<String>? kingdom,
      Value<String>? className,
      Value<String>? orderName,
      Value<String>? family,
      Value<String>? genus,
      Value<String>? visualFeatures,
      Value<String>? description,
      Value<String>? funFact,
      Value<String>? ecosystemRole,
      Value<String>? whatStudentsCanDo,
      Value<String>? humanConnection,
      Value<String>? threats,
      Value<String>? habitat,
      Value<String>? habitatTags,
      Value<String>? conservationStatus,
      Value<String>? populationEstimate,
      Value<String>? populationEstimateSourceUri,
      Value<String>? color,
      Value<String>? bodyShape,
      Value<String>? distinctiveMarks,
      Value<String>? texture,
      Value<String>? sizeClass,
      Value<String>? pattern,
      Value<String>? visualBlob}) {
    return SpeciesCompanion(
      id: id ?? this.id,
      commonName: commonName ?? this.commonName,
      latinName: latinName ?? this.latinName,
      kingdom: kingdom ?? this.kingdom,
      className: className ?? this.className,
      orderName: orderName ?? this.orderName,
      family: family ?? this.family,
      genus: genus ?? this.genus,
      visualFeatures: visualFeatures ?? this.visualFeatures,
      description: description ?? this.description,
      funFact: funFact ?? this.funFact,
      ecosystemRole: ecosystemRole ?? this.ecosystemRole,
      whatStudentsCanDo: whatStudentsCanDo ?? this.whatStudentsCanDo,
      humanConnection: humanConnection ?? this.humanConnection,
      threats: threats ?? this.threats,
      habitat: habitat ?? this.habitat,
      habitatTags: habitatTags ?? this.habitatTags,
      conservationStatus: conservationStatus ?? this.conservationStatus,
      populationEstimate: populationEstimate ?? this.populationEstimate,
      populationEstimateSourceUri:
          populationEstimateSourceUri ?? this.populationEstimateSourceUri,
      color: color ?? this.color,
      bodyShape: bodyShape ?? this.bodyShape,
      distinctiveMarks: distinctiveMarks ?? this.distinctiveMarks,
      texture: texture ?? this.texture,
      sizeClass: sizeClass ?? this.sizeClass,
      pattern: pattern ?? this.pattern,
      visualBlob: visualBlob ?? this.visualBlob,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (commonName.present) {
      map['common_name'] = Variable<String>(commonName.value);
    }
    if (latinName.present) {
      map['latin_name'] = Variable<String>(latinName.value);
    }
    if (kingdom.present) {
      map['kingdom'] = Variable<String>(kingdom.value);
    }
    if (className.present) {
      map['class'] = Variable<String>(className.value);
    }
    if (orderName.present) {
      map['order'] = Variable<String>(orderName.value);
    }
    if (family.present) {
      map['family'] = Variable<String>(family.value);
    }
    if (genus.present) {
      map['genus'] = Variable<String>(genus.value);
    }
    if (visualFeatures.present) {
      map['visual_features'] = Variable<String>(visualFeatures.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (funFact.present) {
      map['fun_fact'] = Variable<String>(funFact.value);
    }
    if (ecosystemRole.present) {
      map['ecosystem_role'] = Variable<String>(ecosystemRole.value);
    }
    if (whatStudentsCanDo.present) {
      map['what_students_can_do'] = Variable<String>(whatStudentsCanDo.value);
    }
    if (humanConnection.present) {
      map['human_connection'] = Variable<String>(humanConnection.value);
    }
    if (threats.present) {
      map['threats'] = Variable<String>(threats.value);
    }
    if (habitat.present) {
      map['habitat'] = Variable<String>(habitat.value);
    }
    if (habitatTags.present) {
      map['habitat_tags'] = Variable<String>(habitatTags.value);
    }
    if (conservationStatus.present) {
      map['conservation_status'] = Variable<String>(conservationStatus.value);
    }
    if (populationEstimate.present) {
      map['population_estimate'] = Variable<String>(populationEstimate.value);
    }
    if (populationEstimateSourceUri.present) {
      map['population_estimate_source_uri'] =
          Variable<String>(populationEstimateSourceUri.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (bodyShape.present) {
      map['body_shape'] = Variable<String>(bodyShape.value);
    }
    if (distinctiveMarks.present) {
      map['distinctive_marks'] = Variable<String>(distinctiveMarks.value);
    }
    if (texture.present) {
      map['texture'] = Variable<String>(texture.value);
    }
    if (sizeClass.present) {
      map['size_class'] = Variable<String>(sizeClass.value);
    }
    if (pattern.present) {
      map['pattern'] = Variable<String>(pattern.value);
    }
    if (visualBlob.present) {
      map['visual_blob'] = Variable<String>(visualBlob.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SpeciesCompanion(')
          ..write('id: $id, ')
          ..write('commonName: $commonName, ')
          ..write('latinName: $latinName, ')
          ..write('kingdom: $kingdom, ')
          ..write('className: $className, ')
          ..write('orderName: $orderName, ')
          ..write('family: $family, ')
          ..write('genus: $genus, ')
          ..write('visualFeatures: $visualFeatures, ')
          ..write('description: $description, ')
          ..write('funFact: $funFact, ')
          ..write('ecosystemRole: $ecosystemRole, ')
          ..write('whatStudentsCanDo: $whatStudentsCanDo, ')
          ..write('humanConnection: $humanConnection, ')
          ..write('threats: $threats, ')
          ..write('habitat: $habitat, ')
          ..write('habitatTags: $habitatTags, ')
          ..write('conservationStatus: $conservationStatus, ')
          ..write('populationEstimate: $populationEstimate, ')
          ..write('populationEstimateSourceUri: $populationEstimateSourceUri, ')
          ..write('color: $color, ')
          ..write('bodyShape: $bodyShape, ')
          ..write('distinctiveMarks: $distinctiveMarks, ')
          ..write('texture: $texture, ')
          ..write('sizeClass: $sizeClass, ')
          ..write('pattern: $pattern, ')
          ..write('visualBlob: $visualBlob')
          ..write(')'))
        .toString();
  }
}

abstract class _$SpeciesDatabase extends GeneratedDatabase {
  _$SpeciesDatabase(QueryExecutor e) : super(e);
  $SpeciesDatabaseManager get managers => $SpeciesDatabaseManager(this);
  late final $SpeciesTable species = $SpeciesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [species];
}

typedef $$SpeciesTableCreateCompanionBuilder = SpeciesCompanion Function({
  Value<int> id,
  required String commonName,
  required String latinName,
  required String kingdom,
  required String className,
  required String orderName,
  required String family,
  required String genus,
  required String visualFeatures,
  required String description,
  required String funFact,
  required String ecosystemRole,
  required String whatStudentsCanDo,
  required String humanConnection,
  required String threats,
  required String habitat,
  required String habitatTags,
  required String conservationStatus,
  required String populationEstimate,
  required String populationEstimateSourceUri,
  required String color,
  required String bodyShape,
  required String distinctiveMarks,
  required String texture,
  required String sizeClass,
  required String pattern,
  required String visualBlob,
});
typedef $$SpeciesTableUpdateCompanionBuilder = SpeciesCompanion Function({
  Value<int> id,
  Value<String> commonName,
  Value<String> latinName,
  Value<String> kingdom,
  Value<String> className,
  Value<String> orderName,
  Value<String> family,
  Value<String> genus,
  Value<String> visualFeatures,
  Value<String> description,
  Value<String> funFact,
  Value<String> ecosystemRole,
  Value<String> whatStudentsCanDo,
  Value<String> humanConnection,
  Value<String> threats,
  Value<String> habitat,
  Value<String> habitatTags,
  Value<String> conservationStatus,
  Value<String> populationEstimate,
  Value<String> populationEstimateSourceUri,
  Value<String> color,
  Value<String> bodyShape,
  Value<String> distinctiveMarks,
  Value<String> texture,
  Value<String> sizeClass,
  Value<String> pattern,
  Value<String> visualBlob,
});

class $$SpeciesTableFilterComposer
    extends Composer<_$SpeciesDatabase, $SpeciesTable> {
  $$SpeciesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get commonName => $composableBuilder(
      column: $table.commonName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get latinName => $composableBuilder(
      column: $table.latinName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kingdom => $composableBuilder(
      column: $table.kingdom, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get className => $composableBuilder(
      column: $table.className, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get orderName => $composableBuilder(
      column: $table.orderName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get family => $composableBuilder(
      column: $table.family, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get genus => $composableBuilder(
      column: $table.genus, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get visualFeatures => $composableBuilder(
      column: $table.visualFeatures,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get description => $composableBuilder(
      column: $table.description, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get funFact => $composableBuilder(
      column: $table.funFact, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ecosystemRole => $composableBuilder(
      column: $table.ecosystemRole, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get whatStudentsCanDo => $composableBuilder(
      column: $table.whatStudentsCanDo,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get humanConnection => $composableBuilder(
      column: $table.humanConnection,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get threats => $composableBuilder(
      column: $table.threats, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get habitat => $composableBuilder(
      column: $table.habitat, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get habitatTags => $composableBuilder(
      column: $table.habitatTags, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conservationStatus => $composableBuilder(
      column: $table.conservationStatus,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get populationEstimate => $composableBuilder(
      column: $table.populationEstimate,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get populationEstimateSourceUri => $composableBuilder(
      column: $table.populationEstimateSourceUri,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get color => $composableBuilder(
      column: $table.color, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bodyShape => $composableBuilder(
      column: $table.bodyShape, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get distinctiveMarks => $composableBuilder(
      column: $table.distinctiveMarks,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get texture => $composableBuilder(
      column: $table.texture, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sizeClass => $composableBuilder(
      column: $table.sizeClass, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get pattern => $composableBuilder(
      column: $table.pattern, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get visualBlob => $composableBuilder(
      column: $table.visualBlob, builder: (column) => ColumnFilters(column));
}

class $$SpeciesTableOrderingComposer
    extends Composer<_$SpeciesDatabase, $SpeciesTable> {
  $$SpeciesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get commonName => $composableBuilder(
      column: $table.commonName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get latinName => $composableBuilder(
      column: $table.latinName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kingdom => $composableBuilder(
      column: $table.kingdom, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get className => $composableBuilder(
      column: $table.className, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get orderName => $composableBuilder(
      column: $table.orderName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get family => $composableBuilder(
      column: $table.family, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get genus => $composableBuilder(
      column: $table.genus, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get visualFeatures => $composableBuilder(
      column: $table.visualFeatures,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get description => $composableBuilder(
      column: $table.description, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get funFact => $composableBuilder(
      column: $table.funFact, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ecosystemRole => $composableBuilder(
      column: $table.ecosystemRole,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get whatStudentsCanDo => $composableBuilder(
      column: $table.whatStudentsCanDo,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get humanConnection => $composableBuilder(
      column: $table.humanConnection,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get threats => $composableBuilder(
      column: $table.threats, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get habitat => $composableBuilder(
      column: $table.habitat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get habitatTags => $composableBuilder(
      column: $table.habitatTags, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conservationStatus => $composableBuilder(
      column: $table.conservationStatus,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get populationEstimate => $composableBuilder(
      column: $table.populationEstimate,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get populationEstimateSourceUri => $composableBuilder(
      column: $table.populationEstimateSourceUri,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get color => $composableBuilder(
      column: $table.color, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bodyShape => $composableBuilder(
      column: $table.bodyShape, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get distinctiveMarks => $composableBuilder(
      column: $table.distinctiveMarks,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get texture => $composableBuilder(
      column: $table.texture, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sizeClass => $composableBuilder(
      column: $table.sizeClass, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get pattern => $composableBuilder(
      column: $table.pattern, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get visualBlob => $composableBuilder(
      column: $table.visualBlob, builder: (column) => ColumnOrderings(column));
}

class $$SpeciesTableAnnotationComposer
    extends Composer<_$SpeciesDatabase, $SpeciesTable> {
  $$SpeciesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get commonName => $composableBuilder(
      column: $table.commonName, builder: (column) => column);

  GeneratedColumn<String> get latinName =>
      $composableBuilder(column: $table.latinName, builder: (column) => column);

  GeneratedColumn<String> get kingdom =>
      $composableBuilder(column: $table.kingdom, builder: (column) => column);

  GeneratedColumn<String> get className =>
      $composableBuilder(column: $table.className, builder: (column) => column);

  GeneratedColumn<String> get orderName =>
      $composableBuilder(column: $table.orderName, builder: (column) => column);

  GeneratedColumn<String> get family =>
      $composableBuilder(column: $table.family, builder: (column) => column);

  GeneratedColumn<String> get genus =>
      $composableBuilder(column: $table.genus, builder: (column) => column);

  GeneratedColumn<String> get visualFeatures => $composableBuilder(
      column: $table.visualFeatures, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
      column: $table.description, builder: (column) => column);

  GeneratedColumn<String> get funFact =>
      $composableBuilder(column: $table.funFact, builder: (column) => column);

  GeneratedColumn<String> get ecosystemRole => $composableBuilder(
      column: $table.ecosystemRole, builder: (column) => column);

  GeneratedColumn<String> get whatStudentsCanDo => $composableBuilder(
      column: $table.whatStudentsCanDo, builder: (column) => column);

  GeneratedColumn<String> get humanConnection => $composableBuilder(
      column: $table.humanConnection, builder: (column) => column);

  GeneratedColumn<String> get threats =>
      $composableBuilder(column: $table.threats, builder: (column) => column);

  GeneratedColumn<String> get habitat =>
      $composableBuilder(column: $table.habitat, builder: (column) => column);

  GeneratedColumn<String> get habitatTags => $composableBuilder(
      column: $table.habitatTags, builder: (column) => column);

  GeneratedColumn<String> get conservationStatus => $composableBuilder(
      column: $table.conservationStatus, builder: (column) => column);

  GeneratedColumn<String> get populationEstimate => $composableBuilder(
      column: $table.populationEstimate, builder: (column) => column);

  GeneratedColumn<String> get populationEstimateSourceUri => $composableBuilder(
      column: $table.populationEstimateSourceUri, builder: (column) => column);

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<String> get bodyShape =>
      $composableBuilder(column: $table.bodyShape, builder: (column) => column);

  GeneratedColumn<String> get distinctiveMarks => $composableBuilder(
      column: $table.distinctiveMarks, builder: (column) => column);

  GeneratedColumn<String> get texture =>
      $composableBuilder(column: $table.texture, builder: (column) => column);

  GeneratedColumn<String> get sizeClass =>
      $composableBuilder(column: $table.sizeClass, builder: (column) => column);

  GeneratedColumn<String> get pattern =>
      $composableBuilder(column: $table.pattern, builder: (column) => column);

  GeneratedColumn<String> get visualBlob => $composableBuilder(
      column: $table.visualBlob, builder: (column) => column);
}

class $$SpeciesTableTableManager extends RootTableManager<
    _$SpeciesDatabase,
    $SpeciesTable,
    SpeciesData,
    $$SpeciesTableFilterComposer,
    $$SpeciesTableOrderingComposer,
    $$SpeciesTableAnnotationComposer,
    $$SpeciesTableCreateCompanionBuilder,
    $$SpeciesTableUpdateCompanionBuilder,
    (
      SpeciesData,
      BaseReferences<_$SpeciesDatabase, $SpeciesTable, SpeciesData>
    ),
    SpeciesData,
    PrefetchHooks Function()> {
  $$SpeciesTableTableManager(_$SpeciesDatabase db, $SpeciesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SpeciesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SpeciesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SpeciesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> commonName = const Value.absent(),
            Value<String> latinName = const Value.absent(),
            Value<String> kingdom = const Value.absent(),
            Value<String> className = const Value.absent(),
            Value<String> orderName = const Value.absent(),
            Value<String> family = const Value.absent(),
            Value<String> genus = const Value.absent(),
            Value<String> visualFeatures = const Value.absent(),
            Value<String> description = const Value.absent(),
            Value<String> funFact = const Value.absent(),
            Value<String> ecosystemRole = const Value.absent(),
            Value<String> whatStudentsCanDo = const Value.absent(),
            Value<String> humanConnection = const Value.absent(),
            Value<String> threats = const Value.absent(),
            Value<String> habitat = const Value.absent(),
            Value<String> habitatTags = const Value.absent(),
            Value<String> conservationStatus = const Value.absent(),
            Value<String> populationEstimate = const Value.absent(),
            Value<String> populationEstimateSourceUri = const Value.absent(),
            Value<String> color = const Value.absent(),
            Value<String> bodyShape = const Value.absent(),
            Value<String> distinctiveMarks = const Value.absent(),
            Value<String> texture = const Value.absent(),
            Value<String> sizeClass = const Value.absent(),
            Value<String> pattern = const Value.absent(),
            Value<String> visualBlob = const Value.absent(),
          }) =>
              SpeciesCompanion(
            id: id,
            commonName: commonName,
            latinName: latinName,
            kingdom: kingdom,
            className: className,
            orderName: orderName,
            family: family,
            genus: genus,
            visualFeatures: visualFeatures,
            description: description,
            funFact: funFact,
            ecosystemRole: ecosystemRole,
            whatStudentsCanDo: whatStudentsCanDo,
            humanConnection: humanConnection,
            threats: threats,
            habitat: habitat,
            habitatTags: habitatTags,
            conservationStatus: conservationStatus,
            populationEstimate: populationEstimate,
            populationEstimateSourceUri: populationEstimateSourceUri,
            color: color,
            bodyShape: bodyShape,
            distinctiveMarks: distinctiveMarks,
            texture: texture,
            sizeClass: sizeClass,
            pattern: pattern,
            visualBlob: visualBlob,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String commonName,
            required String latinName,
            required String kingdom,
            required String className,
            required String orderName,
            required String family,
            required String genus,
            required String visualFeatures,
            required String description,
            required String funFact,
            required String ecosystemRole,
            required String whatStudentsCanDo,
            required String humanConnection,
            required String threats,
            required String habitat,
            required String habitatTags,
            required String conservationStatus,
            required String populationEstimate,
            required String populationEstimateSourceUri,
            required String color,
            required String bodyShape,
            required String distinctiveMarks,
            required String texture,
            required String sizeClass,
            required String pattern,
            required String visualBlob,
          }) =>
              SpeciesCompanion.insert(
            id: id,
            commonName: commonName,
            latinName: latinName,
            kingdom: kingdom,
            className: className,
            orderName: orderName,
            family: family,
            genus: genus,
            visualFeatures: visualFeatures,
            description: description,
            funFact: funFact,
            ecosystemRole: ecosystemRole,
            whatStudentsCanDo: whatStudentsCanDo,
            humanConnection: humanConnection,
            threats: threats,
            habitat: habitat,
            habitatTags: habitatTags,
            conservationStatus: conservationStatus,
            populationEstimate: populationEstimate,
            populationEstimateSourceUri: populationEstimateSourceUri,
            color: color,
            bodyShape: bodyShape,
            distinctiveMarks: distinctiveMarks,
            texture: texture,
            sizeClass: sizeClass,
            pattern: pattern,
            visualBlob: visualBlob,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SpeciesTableProcessedTableManager = ProcessedTableManager<
    _$SpeciesDatabase,
    $SpeciesTable,
    SpeciesData,
    $$SpeciesTableFilterComposer,
    $$SpeciesTableOrderingComposer,
    $$SpeciesTableAnnotationComposer,
    $$SpeciesTableCreateCompanionBuilder,
    $$SpeciesTableUpdateCompanionBuilder,
    (
      SpeciesData,
      BaseReferences<_$SpeciesDatabase, $SpeciesTable, SpeciesData>
    ),
    SpeciesData,
    PrefetchHooks Function()>;

class $SpeciesDatabaseManager {
  final _$SpeciesDatabase _db;
  $SpeciesDatabaseManager(this._db);
  $$SpeciesTableTableManager get species =>
      $$SpeciesTableTableManager(_db, _db.species);
}
