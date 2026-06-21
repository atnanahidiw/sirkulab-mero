import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// CLIP byte-level BPE tokenizer — a faithful Dart port of OpenAI CLIP's
/// `SimpleTokenizer` + `clip.tokenize`, so `check_visual_evidence` claims are
/// tokenised on-device exactly as the exported text encoder expects.
///
/// Vocab (`clip_vocab_talk2dino.json`) and merges (`clip_merges_talk2dino.txt`) are produced by
/// `scripts/export_vision_model.py` (`dump_tokenizer`). The byte↔unicode map is
/// recomputed here (it's a deterministic standard table).
class ClipTokenizer {
  ClipTokenizer({
    this.vocabAsset = 'assets/models/clip_vocab_talk2dino.json',
    this.mergesAsset = 'assets/models/clip_merges_talk2dino.txt',
    this.contextLength = 77,
  });

  final String vocabAsset;
  final String mergesAsset;
  final int contextLength;

  static const int _sot = 49406; // <|startoftext|>
  static const int _eot = 49407; // <|endoftext|>

  final Map<String, int> _encoder = {}; // BPE token string -> id
  final Map<String, int> _bpeRanks = {}; // "ab" -> rank
  late final Map<int, String> _byteEncoder = _bytesToUnicode();
  final Map<String, String> _cache = {};

  // CLIP's pre-tokenization pattern (text is lower-cased first).
  static final RegExp _pat = RegExp(
    r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|\p{L}+|\p{N}|[^\s\p{L}\p{N}]+",
    unicode: true,
    caseSensitive: false,
  );
  static final RegExp _whitespace = RegExp(r'\s+');

  bool get isLoaded => _encoder.isNotEmpty;

  Future<void> load() async {
    if (isLoaded) return;
    final vocabRaw = await rootBundle.loadString(vocabAsset);
    (jsonDecode(vocabRaw) as Map<String, dynamic>).forEach((k, v) {
      _encoder[k] = v as int;
    });
    final mergesRaw = await rootBundle.loadString(mergesAsset);
    var rank = 0;
    for (final line in const LineSplitter().convert(mergesRaw)) {
      if (line.isEmpty) continue;
      final sp = line.indexOf(' ');
      if (sp <= 0) continue;
      _bpeRanks['${line.substring(0, sp)}${line.substring(sp + 1)}'] = rank++;
    }
  }

  /// Tokenise one string → fixed-length [contextLength] int32 IDs (SOT … EOT,
  /// zero-padded; truncated with a forced trailing EOT if too long).
  Int32List tokenize(String text) {
    final ids = Int32List(contextLength);
    final tokens = <int>[_sot, ...encode(text), _eot];
    final n = tokens.length;
    if (n <= contextLength) {
      for (var i = 0; i < n; i++) {
        ids[i] = tokens[i];
      }
    } else {
      for (var i = 0; i < contextLength; i++) {
        ids[i] = tokens[i];
      }
      ids[contextLength - 1] = _eot; // keep EOT in the last slot
    }
    return ids;
  }

  /// BPE token IDs for [text], without SOT/EOT/padding.
  List<int> encode(String text) {
    final cleaned = text.replaceAll(_whitespace, ' ').trim().toLowerCase();
    final out = <int>[];
    for (final m in _pat.allMatches(cleaned)) {
      final piece = m.group(0)!;
      final encoded =
          utf8.encode(piece).map((b) => _byteEncoder[b]!).join();
      for (final bpeTok in _bpe(encoded).split(' ')) {
        final id = _encoder[bpeTok];
        if (id != null) out.add(id);
      }
    }
    return out;
  }

  String _bpe(String token) {
    final cached = _cache[token];
    if (cached != null) return cached;

    // word = chars of token, with '</w>' appended to the last char.
    final chars = token.runes.map(String.fromCharCode).toList();
    if (chars.isEmpty) return token;
    var word = <String>[
      ...chars.sublist(0, chars.length - 1),
      '${chars.last}</w>',
    ];

    if (word.length == 1) {
      final res = word.first;
      _cache[token] = res;
      return res;
    }

    while (true) {
      // pick the adjacent pair with the lowest BPE rank
      var bestRank = 1 << 30;
      var bestI = -1;
      for (var i = 0; i < word.length - 1; i++) {
        final r = _bpeRanks['${word[i]}${word[i + 1]}'];
        if (r != null && r < bestRank) {
          bestRank = r;
          bestI = i;
        }
      }
      if (bestI < 0) break;

      final first = word[bestI];
      final second = word[bestI + 1];
      final merged = first + second;
      final newWord = <String>[];
      var i = 0;
      while (i < word.length) {
        if (i < word.length - 1 && word[i] == first && word[i + 1] == second) {
          newWord.add(merged);
          i += 2;
        } else {
          newWord.add(word[i]);
          i += 1;
        }
      }
      word = newWord;
      if (word.length == 1) break;
    }

    final res = word.join(' ');
    _cache[token] = res;
    return res;
  }

  /// GPT-2/CLIP byte→unicode table (printable bytes map to themselves; the rest
  /// to U+0100.. so every byte becomes a single reversible char).
  static Map<int, String> _bytesToUnicode() {
    final bs = <int>[
      for (var i = 0x21; i <= 0x7e; i++) i, // '!'..'~'
      for (var i = 0xa1; i <= 0xac; i++) i, // '¡'..'¬'
      for (var i = 0xae; i <= 0xff; i++) i, // '®'..'ÿ'
    ];
    final cs = List<int>.from(bs);
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    return {for (var i = 0; i < bs.length; i++) bs[i]: String.fromCharCode(cs[i])};
  }
}
