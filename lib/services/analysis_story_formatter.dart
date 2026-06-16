import 'dart:convert';

/// Formats agentic pipeline events into child-friendly, bilingual story text
/// suitable for streaming into the analyzing page trace box.
///
/// All output is Markdown-compatible (bold via `**`, italic via `*`).
/// Pass [isId] = true for Bahasa Indonesia, false for English.
class AnalysisStoryFormatter {
  final bool isId;

  const AnalysisStoryFormatter({required this.isId});

  // ── Phase narration ──────────────────────────────────────────────────────
  // Short child-friendly lines for each stage of the pipeline. These pair with
  // the internal phase keywords passed to onProgress (which stay in English so
  // phase detection keeps working).

  String get wakingUp =>
      isId ? 'Membangunkan otakku...' : 'Waking up my brain...';

  String get lookingAtPhoto =>
      isId ? 'Melihat fotomu...' : 'Looking at your photo...';

  String get readingClues =>
      isId ? 'Membaca petunjuknya...' : 'Reading the clues...';

  String get thinkingHard => isId
      ? 'Berpikir keras tentang apa yang kulihat...'
      : 'Thinking hard about what I see...';

  String get investigating =>
      isId ? 'Saatnya menyelidiki!' : 'Time to investigate!';

  String get puttingTogether =>
      isId ? 'Menyatukan semuanya...' : 'Putting it all together...';

  String get done => isId ? 'Selesai!' : 'Done!';

  // ── Entry-point helpers ──────────────────────────────────────────────────

  /// Emitted once before the agentic loop begins.
  String opening() => isId
      ? 'Hmm, biarkan aku melihat gambar ini dengan sangat teliti...\n\n'
      : 'Hmm, let me look at this picture very carefully...\n\n';

  /// Emitted when the model fires a tool call.
  /// [pass] starts at 1; [parallelIndex]/[parallelTotal] are set for
  /// parallel tool calls.
  String toolCall(
    String toolName,
    Map<String, dynamic> args,
    int pass, {
    int? parallelIndex,
    int? parallelTotal,
  }) {
    final color = (args['color'] ?? '').toString().trim();
    final bodyShape = (args['body_shape'] ?? '').toString().trim();
    final marks = (args['distinctive_marks'] ?? '').toString().trim();
    final texture = (args['texture'] ?? '').toString().trim();
    final visualGroup = (args['visualGroup'] ?? '').toString().trim();

    final traits = <String>[
      if (color.isNotEmpty) color,
      if (bodyShape.isNotEmpty) bodyShape,
      if (marks.isNotEmpty) marks,
      if (texture.isNotEmpty) texture,
    ];
    final traitText = traits.isNotEmpty
        ? traits.join(', ')
        : (isId ? 'beberapa fitur menarik' : 'some interesting features');

    final parallelPrefix = (parallelIndex != null && parallelTotal != null)
        ? (isId
            ? 'Pencarian ${parallelIndex + 1} dari $parallelTotal: '
            : 'Search ${parallelIndex + 1} of $parallelTotal: ')
        : '';

    if (pass == 1) {
      if (isId) {
        final groupHint = visualGroup.isNotEmpty
            ? ' Ini sepertinya bisa jadi **$visualGroup**.'
            : '';
        return '${parallelPrefix}Aku bisa melihat **$traitText**.$groupHint '
            'Biarkan aku membalik buku alamku untuk menemukannya!\n\n';
      } else {
        final groupHint = visualGroup.isNotEmpty
            ? ' This looks like it could be a **$visualGroup**.'
            : '';
        return '${parallelPrefix}I can spot **$traitText**.$groupHint '
            'Let me flip through my nature book to find it!\n\n';
      }
    } else {
      if (isId) {
        final groupHint = visualGroup.isNotEmpty
            ? ' Mungkin ini adalah **$visualGroup**?'
            : '';
        return '${parallelPrefix}Hmm, biarkan aku lihat lagi dengan cara berbeda... '
            'Kali ini aku memperhatikan **$traitText**.$groupHint '
            'Aku ubah pencarianku!\n\n';
      } else {
        final groupHint = visualGroup.isNotEmpty
            ? ' Could this be a **$visualGroup**?'
            : '';
        return '${parallelPrefix}Hmm, let me look at this differently... '
            'This time I notice **$traitText**.$groupHint '
            'Changing my search!\n\n';
      }
    }
  }

  /// Emitted when multiple tool calls fire in parallel (before individual results).
  String parallelToolsIntro(int count) => isId
      ? 'Aku memeriksa **$count hal** sekaligus — semakin banyak clue, semakin baik!\n\n'
      : 'I\'m checking **$count things** at the same time — the more clues, the better!\n\n';

  /// Emitted after each tool result arrives.
  String toolResult(String toolName, Object result, int pass) {
    if (result is! String) {
      return isId
          ? 'Aku menemukan beberapa kemungkinan! Mari kita bandingkan...\n\n'
          : 'I found some possibilities! Let me compare them...\n\n';
    }

    final trimmed = result.trim();

    if (trimmed.isEmpty || trimmed.contains('No matching')) {
      return _noMatchText(pass);
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List && decoded.isEmpty) {
        return isId
            ? 'Tidak ada hewan yang cocok. Saatnya berpikir berbeda!\n\n'
            : 'No animals matched those clues. Time to think differently!\n\n';
      }
      if (decoded is List && decoded.isNotEmpty) {
        return _candidateListText(decoded, pass);
      }
    } catch (_) {}

    return isId
        ? 'Aku menemukan beberapa kemungkinan! Mari kita bandingkan...\n\n'
        : 'I found some possibilities! Let me compare them...\n\n';
  }

  /// Emitted after the final JSON is parsed and validated.
  String finalResult(Map<String, dynamic> result) {
    final common = (result['common_name'] ?? '').toString().trim();
    final scientific = (result['scientific_name'] ?? '').toString().trim();
    final fallback = isId ? 'hewan ini' : 'this animal';
    final name = common.isNotEmpty
        ? common
        : (scientific.isNotEmpty ? scientific : fallback);
    final sciLabel =
        scientific.isNotEmpty && scientific != name ? ' *($scientific)*' : '';
    final confidence = result['confidence']?.toString().toLowerCase().trim() ?? '';
    final note = result['identification_notes']?.toString().trim() ?? '';
    final noteText = note.isNotEmpty ? '\n\n$note' : '';

    if (isId) {
      final (opener, closing) = switch (confidence) {
        'high' => ('Aku sangat yakin —', 'Kecocokan visualnya luar biasa!'),
        'medium' => (
            'Aku cukup yakin ini adalah',
            'Tapi masih ada sedikit ketidakpastian.'
          ),
        _ => (
            'Dugaan terbaikku adalah',
            'Gambarnya agak sulit untuk dibaca, tapi ini perkiraanku.'
          ),
      };
      return '$opener **$name**$sciLabel! $closing$noteText\n\n';
    } else {
      final (opener, closing) = switch (confidence) {
        'high' => ("I'm very confident —", 'The visual match is excellent!'),
        'medium' => (
            "I'm fairly sure this is",
            "Though there's a little uncertainty."
          ),
        _ => (
            'My best guess is',
            "The photo was tricky to read, but that's my call."
          ),
      };
      return '$opener **$name**$sciLabel! $closing$noteText\n\n';
    }
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  String _noMatchText(int pass) {
    if (pass == 1) {
      return isId
          ? 'Hmm, tidak ada yang cocok dengan petunjuk itu. '
              'Biarkan aku melihat gambarnya lagi dengan mata segar...\n\n'
          : 'Hmm, nothing matched those clues. '
              'Let me look at the picture again with fresh eyes...\n\n';
    }
    return isId
        ? 'Masih belum ada kecocokan sempurna... tapi aku tidak menyerah! '
            'Biarkan aku berpikir tentang apa yang mungkin aku lewatkan.\n\n'
        : "Still no perfect match... but I'm not giving up! "
            'Let me think about what else I might be missing.\n\n';
  }

  String _candidateListText(List<dynamic> decoded, int pass) {
    final count = decoded.length;
    final top = decoded.first as Map<String, dynamic>?;
    if (top == null) {
      return isId
          ? 'Aku menemukan beberapa kemungkinan!\n\n'
          : 'I found some possibilities!\n\n';
    }

    final topName =
        (top['common_name'] ?? top['scientific_name'] ?? '').toString().trim();
    final topConf = _parseConfidencePercent(top['confidence']);
    final topConfText = topConf != null ? '${topConf.round()}%' : '';

    final lines = <String>[];
    for (int i = 0; i < decoded.length && i < 5; i++) {
      final item = decoded[i] as Map<String, dynamic>?;
      if (item == null) continue;
      final common = (item['common_name'] ?? '').toString().trim();
      final scientific = (item['scientific_name'] ?? '').toString().trim();
      final conf = _parseConfidencePercent(item['confidence']);
      final confStr = conf != null
          ? ' — **${conf.round()}%** ${isId ? 'cocok' : 'match'}'
          : '';
      final displayName = common.isNotEmpty ? common : scientific;
      final sciSuffix = scientific.isNotEmpty && scientific != displayName
          ? ' *($scientific)*'
          : '';
      lines.add('${i + 1}. **$displayName**$sciSuffix$confStr');
    }
    final candidateBlock = lines.join('\n');

    if (pass == 1) {
      if (isId) {
        final certainty = (topConf != null && topConf >= 70)
            ? 'dan aku cukup yakin tentang kandidat teratas'
            : 'tapi aku perlu membandingkannya lebih teliti';
        return 'Aku menemukan **$count hewan** yang terlihat mirip, $certainty!\n\n'
            '$candidateBlock\n\n'
            'Yang paling menjanjikan adalah **$topName**'
            '${topConfText.isNotEmpty ? ' dengan tingkat kecocokan $topConfText' : ''}. '
            'Mari bandingkan dengan foto...\n\n';
      } else {
        final certainty = (topConf != null && topConf >= 70)
            ? "and I'm pretty confident about the top candidate"
            : 'but I need to compare them more carefully';
        return 'I found **$count animals** that look similar, $certainty!\n\n'
            '$candidateBlock\n\n'
            'The most promising is **$topName**'
            '${topConfText.isNotEmpty ? ' with a $topConfText match' : ''}. '
            'Let me compare it with the photo...\n\n';
      }
    } else {
      if (isId) {
        return 'Dengan petunjuk baru, aku menemukan **$count kandidat** lagi!\n\n'
            '$candidateBlock\n\n'
            '**$topName** masih terlihat paling cocok'
            '${topConfText.isNotEmpty ? ' ($topConfText)' : ''}. '
            'Aku akan mempertimbangkan ini...\n\n';
      } else {
        return 'With my new clues, I found **$count candidates** this time!\n\n'
            '$candidateBlock\n\n'
            '**$topName** still looks like the closest fit'
            '${topConfText.isNotEmpty ? ' ($topConfText)' : ''}. '
            "I'll consider this...\n\n";
      }
    }
  }

  double? _parseConfidencePercent(Object? confidence) {
    if (confidence == null) return null;
    final value = double.tryParse(confidence.toString());
    if (value == null) return null;
    return value <= 1.0 ? value * 100.0 : value;
  }
}
