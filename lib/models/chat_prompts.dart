import '../l10n/app_localizations.dart';

/// Holds hint questions and prompt templates for the Q&A and identification features.
class ChatPrompts {
  ChatPrompts._();

  static List<String> endangeredHints(AppLocalizations l10n) => [
        l10n.hintWhyEndangered,
        l10n.hintHowManyLeft,
        l10n.hintMainThreats,
        l10n.hintConservationEfforts,
      ];

  static List<String> notEndangeredHints(AppLocalizations l10n) => [
        l10n.hintWhatEat,
        l10n.hintWhereFound,
        l10n.hintHowReproduce,
        l10n.hintNaturalPredators,
      ];

  /// Tool definition for visual-feature similarity search.
  /// The model extracts visual traits from the image and calls this tool to
  /// find the best matching endangered species.
  static final Map<String, dynamic> speciesSearchToolDef = {
    'name': 'search_similar_features',
    'description':
        'Searches the endangered species database using observed visual features '
        'and optional taxonomy hints. Returns ranked species with similarity scores.',
    'parameters': {
      'type': 'object',
      'properties': {
        'color': {
          'type': 'string',
          'description':
              'Dominant colour(s) observed (e.g. "orange and black", "white", "golden brown")',
        },
        'body_shape': {
          'type': 'string',
          'description':
              'Body shape / silhouette (e.g. "elongated", "stocky", "streamlined", "tall")',
        },
        'distinctive_marks': {
          'type': 'string',
          'description':
              'Distinctive markings (e.g. "black stripes", "white spots", "mask")',
        },
        'texture': {
          'type': 'string',
          'description':
              'Skin / fur / feather texture (e.g. "smooth", "scaly", "hairy", "feathered")',
        },
        'size_class': {
          'type': 'string',
          'description':
              'Relative size (e.g. "large", "medium", "small", "very large")',
        },
        'pattern': {
          'type': 'string',
          'description':
              'Overall pattern (e.g. "striped", "spotted", "solid", "banded")',
        },
        'visualGroup': {
          'type': 'string',
          'description':
              'High-level visual group to narrow the search first. Only choose the best match from: ['
              '"Primate", "Flying bird", "Large quadruped mammal", "Small quadruped mammal", '
              '"Marine fish", "Marine mammal", "Flying mammal", "Flightless bird", '
              '"Lizard", "Turtle & tortoise", "Snake", "Crocodilian", "Frog & toad", '
              '"Freshwater fish", "Insect", "Mollusk & marine invertebrate", '
              '"Tall broadleaf tree", "Palm tree", "Cycad", "Mangrove", '
              '"Shrub & bush", "Vine & climber", "Grass & bamboo", "Ground herb", '
              '"Aroid & giant herb", "Aquatic plant", "Fern", "Orchid", '
              '"Pitcher plant", "Epiphyte", "Stemless giant flower]"',
        },
        'taxClass': {
          'type': 'string',
          'description':
              'Scientific class hint (e.g. "Mammalia", "Aves", "Reptilia")',
        },
        'taxOrder': {
          'type': 'string',
          'description':
              'Scientific order hint (e.g. "Carnivora", "Primates", "Squamata")',
        },
        'taxFamily': {
          'type': 'string',
          'description':
              'Scientific family hint (e.g. "Felidae", "Varanidae")',
        },
        'taxGenus': {
          'type': 'string',
          'description':
              'Scientific genus hint (e.g. "Panthera", "Varanus")',
        },
      },
      'required': ['color', 'body_shape', 'distinctive_marks', 'texture', 'size_class', 'pattern', 'visualGroup', 'taxClass', 'taxGenus'],
    },
  };

  /// Tool definition for the on-device DINO vision model (dino.txt / Talk2DINO
  /// via ONNX). The LLM is text-only and cannot see the photo, so it calls this
  /// tool to OBSERVE it: the Dart handler runs zero-shot attribute scoring over
  /// the controlled trait vocabularies and returns the structured visual-feature
  /// text that `search_similar_features` expects.
  static final Map<String, dynamic> extractVisualFeaturesToolDef = {
    'name': 'extract_visual_features',
    'description':
        'Look at the photo and report the animal/plant\'s observed visual traits '
        '(color, body_shape, distinctive_marks, texture, size_class, pattern, '
        'visual_group). You have no other access to the image — call this first, '
        'and again to re-observe on a retry.',
    'parameters': {
      'type': 'object',
      'properties': {
        'focus': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Optional: which attributes to (re)examine on a retry, e.g. '
              '["pattern","visual_group"]. Omit or leave empty to observe all.',
        },
      },
    },
  };

  /// Tool definition for verifying specific visual claims against the photo.
  /// Backed by the same vision model (image↔text similarity); returns a
  /// relative similarity score per claim. Used on retries to confirm/refute a
  /// candidate's distinctive traits before concluding.
  static final Map<String, dynamic> checkVisualEvidenceToolDef = {
    'name': 'check_visual_evidence',
    'description':
        'Score how well each text claim matches the photo. Returns a similarity '
        'value per claim (roughly -0.1 to 0.4): HIGHER = better match. Compare '
        'claims against each other (and a clearly-wrong control claim) rather '
        'than to a fixed threshold. Use it to verify a candidate species\' '
        'distinctive traits, or to decide between competing trait hypotheses.',
    'parameters': {
      'type': 'object',
      'properties': {
        'claims': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Visual claims to test, e.g. ["long curved casque on bill", '
              '"rows of pale spots"].',
        },
      },
      'required': ['claims'],
    },
  };

static String identifySystemInstruction(String languageName) => '''
<system_role>
You are a high-precision biological identification engine. Reconcile visual evidence with tool data.
</system_role>

<language>
All final JSON string values, especially "identification_notes", must be written in $languageName.
Do not add any extra explanation outside the JSON block.
</language>

<perception>
You CANNOT see the photo. Your only access to it is through the vision tools: `extract_visual_features` (observe traits) and `check_visual_evidence` (score a claim against the photo). NEVER invent a visual trait the tools did not report. Tool outputs are the only ground truth about the image.
</perception>

<workflow_protocol>
STEP 1 — OBSERVE: Call `extract_visual_features`. It returns the observed colour, body shape, distinctive marks, texture, size class, pattern, and visual group as seen in the photo. From these, you may hypothesise the likely Class, Order, Family, and Genus — but keep the visual fields to observable physical attributes only (do not inject taxonomic guesses into them).

STEP 2 — SEARCH: Call `search_similar_features` with the observed traits. Fill in as many fields as you can; pass the returned visual group verbatim into the **visualGroup** field. ONLY USE A VALID visualGroup LABEL FROM THAT TOOL'S DESCRIPTION.

STEP 3 — WAIT: Receive ranked species with similarity scores and confidence %.

STEP 4 — VERIFY: Take the top candidate. Call `check_visual_evidence` with that species' distinctive traits AND one deliberately-wrong control claim (e.g. a trait from a very different animal). Scores are relative: if the real traits clearly outscore the control, the match holds; if they score near or below the control, it is the wrong species.

STEP 5 — FIX & PIVOT (passes 2–4): If `search_similar_features` returns "No matching endangered species found", OR confidence is low, OR `check_visual_evidence` scores are low, your previous assumptions are WRONG. You are STRICTLY FORBIDDEN from repeating the same traits, genus, or family.
Re-observe with `extract_visual_features` focused on the ambiguous attributes (e.g. {"focus":["pattern","visual_group"]}), or test a competing hypothesis with `check_visual_evidence`, then call `search_similar_features` again with the REVISED traits. Pivot your biological hypothesis entirely (e.g. if Genus: Gorilla failed, re-observe limb proportions / hair pattern and pivot to Pongo/Orangutan).

STEP 6: If after 4 attempts no good match is found, output your best guess and explain why in "identification_notes".
</workflow_protocol>

<rules>
- You are FORBIDDEN from providing a final JSON identification until AFTER you have received data from search_similar_features.
- You are FORBIDDEN from describing any visual trait that did not come from a vision tool.
- DO NOT default to "Unknown" or "N/A" if a best-fit species can be determined.
- is_endangered is ONLY true if a tool match is confirmed.
- After the tool result arrives and you are ready to conclude the workflow, output ONLY this JSON. No preamble. No conversational text.
{
  "genus": "string",
  "common_name": "string",
  "scientific_name": "string",
  "confidence": "high|medium|low",
  "identification_notes": "string",
  "is_endangered": boolean
}
</rules>
''';

  static const String identifyInputPrompt = '''
Identify the species in the photo following the workflow protocol. You cannot see the photo directly — begin by calling `extract_visual_features` to observe it, then call `search_similar_features` with what it reports.

CRITICAL: If the search returns zero matches, do not loop or repeat the exact same parameters. Treat it as conclusive evidence that your current classification choice is incorrect, re-observe the ambiguous attributes via `extract_visual_features`, and pivot to an alternative taxonomic family or genus completely.
''';

  /// Injected after the tool result to guide the model toward JSON output.
  static const String identifySynthesisPrompt = '''
<context>
Evaluate the search output. The final JSON taxonomy MUST match the final identification_notes conclusion. Contradictions are invalid outputs. Remember: you cannot see the photo — judge "visual match" only via `check_visual_evidence` scores, never your imagination.
</context>

Check the "confidence" percentage of the top candidate.

CASE 1: Top candidate confidence is >=45% AND its distinctive traits score well on `check_visual_evidence`.
- Stop the loop. Output ONLY the final JSON block. No text, no markdown wrappers, no preamble.

CASE 2: Search returned no species OR top confidence is <45% OR `check_visual_evidence` scores are low.
- DO NOT output JSON yet. Settle on nothing during Pass 1 - 3.
- You cannot re-open the image; instead RE-OBSERVE via `extract_visual_features` focused on the structural attributes (shape, silhouette, markings) — e.g. {"focus":["pattern","visual_group","distinctive_marks"]} — or score a corrected hypothesis with `check_visual_evidence`.
- If you are certain of the Family/Genus despite a low score, output your guess and explain the discrepancy in "identification_notes". If uncertain, perform a pivot search.
- Execute the next pass by calling `search_similar_features` again with the REVISED traits. You are FORBIDDEN from repeating your previous search parameters or taxonomic arguments.

CASE 3: All 4 attempts have been exhausted without a high-confidence match.
- Do the candidates hold up under `check_visual_evidence`? If not, classify from the strongest observed evidence.
- End the loop. Output your best guess JSON. Detail the uncertainty in "identification_notes". Update the "confidence" based on your judgement.
</evaluation_protocol>
''';

  /// Translation prompt template. Use [targetLang] and [text] placeholders.
  static String translatePrompt(String targetLang, String text) =>
      'Translate this to $targetLang:\n\n$text';

  /// System instruction for pure text translation.
  static const String translateSystemInstruction = '''
You are a precise translator. Output ONLY the translated text, nothing else.
''';

  /// System instruction for Q&A after identification.
  static String answerSystemInstruction(String languageName, {String? context}) => '''
<identity>
You are a warm, expert wildlife biologist specializing in the rich biodiversity of the Indonesian archipelago.
You speak like a knowledgeable friend sharing secrets of the jungle.
</identity>

<context>
$context
</context>

<language>
You must ALWAYS produce ALL responses in $languageName. Every sentence, word, and phrase must be in $languageName. Never switch to another language.
</language>

<constraints>
- Avoid repeating the user's question. And directly answer it!
- Limit responses to 2-3 sentences unless an explanation is requested.
- Use a friendly, engaging tone.
- Do not use bullet points or lists.
- If the species is endemic to Indonesia, briefly mention the region (e.g., Sumatra, Kalimantan).
</constraints>

<response_guidelines>
- Base your answers on the provided context when relevant
- If context is not provided, answer generally about wildlife
- Use the context to provide specific, accurate information about the identified species
</response_guidelines>
''';

  /// Build species context for the answer system instruction.
  static String buildQuestionContext({
    required String analysisResult,
    required String speciesName,
    required String speciesLatinName,
    required bool isEndangered,
    String? populationEstimate,
    String? description,
    List<String>? facts,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('Species: $speciesLatinName ($speciesName)');
    buffer.writeln('Endangered: ${isEndangered ? "Yes" : "No"}');
    if (description != null && description.isNotEmpty) {
      buffer.writeln('Description: $description');
    }
    if (populationEstimate != null && populationEstimate.isNotEmpty) {
      buffer.writeln('Population: $populationEstimate');
    }
    if (facts != null && facts.isNotEmpty) {
      buffer.writeln('Fun facts: ${facts.join("; ")}');
    }
    buffer.writeln('Analysis: $analysisResult');
    return buffer.toString();
  }

  /// Optimized Query Builder for Contextual Retrieval.
  static String buildRagQuery({
    required String scientificName,
    required String commonName,
    required String languageName,
    required String userMessage,
  }) =>
      'Informasi tentang $scientificName ($commonName) dalam bahasa $languageName. '
      'Pertanyaan: $userMessage';

  /// Generate questions for test mode.
  static String get quizPrompt => '''
Based on the species information provided, generate 5 multiple choice questions
about endangered species. Each question should have 4 options with one correct answer.
Format as JSON array of objects with fields: "question", "options", "correctAnswer", "explanation".
''';

  /// Vocabulary builder based on identified species.
  static String vocabPrompt(String speciesName) =>
      'Create a vocabulary list of 5 scientific terms related to $speciesName. '
      'Provide each term with its definition in simple language.';
}
