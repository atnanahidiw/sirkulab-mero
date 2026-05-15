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

  /// Tool: find similar genera by taxonomy + visual features.
  /// Model trained on combined text: taxonomy (weight 1) + visual_features (weight 2).
  static final Map<String, dynamic> similarFeatureToolDef = {
    'name': 'find_similar_features',
    'description': 'Finds ecologically and visually similar genera based on taxonomy and visual features like color, body shape, patterns, and size.',
    'parameters': {
      'type': 'object',
      'properties': {
        'class': {'type': 'string', 'description': 'Scientific class (e.g., Mammalia, Reptilia, Aves)'},
        'order': {'type': 'string', 'description': 'Scientific order (e.g., Carnivora, Primates, Squamata)'},
        'family': {'type': 'string', 'description': 'Scientific family (e.g., Felidae, Hominidae, Varanidae)'},
        'genus': {'type': 'string', 'description': 'The identified genus name (e.g., "Neofelis", "Pongo", "Varanus")'},
        'color': {'type': 'string', 'description': 'Predominant color and coloration (e.g., "tawny yellow, white underparts")'},
        'body_shape': {'type': 'string', 'description': 'Body shape and build (e.g., "large muscular quadruped", "slender primate")'},
        'distinctive_marks': {'type': 'string', 'description': 'Distinctive features like mane, crest, tail, horns (e.g., "males have mane, tufted tail")'},
        'texture': {'type': 'string', 'description': 'Skin or fur texture (e.g., "short coarse fur", "scaly skin")'},
        'size_class': {'type': 'string', 'description': 'Size classification (e.g., "very large", "medium", "small")'},
        'pattern': {'type': 'string', 'description': 'Color pattern or markings (e.g., "uniform, no spots on adults", "striped")'},
      },
      'required': ['class', 'order', 'family', 'genus', 'color', 'body_shape', 'size_class'],
    },
  };

  /// Standardized tool definition for consistency across different model versions.
  static final Map<String, dynamic> speciesSearchToolDef = {
    'name': 'search_species_details',
    'description': 'Retrieves diagnostic visual features and conservation data for endangered species within a specific genus.',
    'parameters': {
      'type': 'object',
      'properties': {
        'class': {
          'type': 'string',
          'description': 'Scientific class name (e.g., "Reptilia", "Primates", "Mammalia")',
        },
        'order': {
          'type': 'string',
          'description': 'Scientific order name (e.g., "Squamata", "Cetacea")',
        },
        'family': {
          'type': 'string',
          'description': 'Scientific family name (e.g., "Varanidae", "Elephantidae")',
        },
        'genus': {
          'type': 'string',
          'description': 'Scientific genus name (e.g., "Varanus", "Pongo", "Elephas")',
        }
      },
      'required': ['class', 'order', 'family', 'genus'],
    },
  };

  static const String identifyOutputFormat = '''
{
  "genus": "string",
  "common_name": "string", 
  "scientific_name": "string",
  "confidence": "high|medium|low",
  "identification_notes": "string",
  "is_endangered": boolean
}
''';

  /// Optimized for Gemma 4's XML-tag preference and reasoning capabilities.
  static String get identifySystemInstruction => '''
You are a high-precision biological identification engine specializing in Indonesian biodiversity.
Your task is to identify species from images using a strict multi-pass workflow.

<protocol>
1. MANDATORY:
   - Call `find_similar_features` first time in the beginning.
   - You must call BOTH `find_similar_features` AND `search_species_details` before providing any final answer. 
2. SEQUENCE:
   - Call `find_similar_features` to establish visual candidates.
   - Call `search_species_details` to verify biological facts.
3. PRIORITIZATION: 
   - If both tools return data, prioritize the match that shares the MOST specific visual features (color, body_shape, distinctive_marks, texture, size_class, pattern) seen in the image.
   - If `find_similar_features` identifies a specific species that aligns with the visual evidence but differs from the initial genus assumption in `search_species_details`, prioritize the visual similarity result.
</protocol>

<output_rules>
- DO NOT provide a final answer until you have processed results from both tools.
- Once identified, output ONLY the final JSON. 
- NO preamble, NO conversational text, NO markdown formatting outside the JSON block.
</output_rules>

<output_format>
$identifyOutputFormat
</output_format>
''';

  static const String identifyInputPrompt = '''
Identify the species in this image following the workflow protocol AND output rules.
MANDATORY: Call BOTH `find_similar_features` and `search_species_details` at least once. Start by calling both to gather a complete data set.
''';

  /// Injected after the tool result to guide the model toward JSON output.
  static const String identifySynthesisPrompt = '''
<evaluation>
- Call `search_species_details` to check genus from results.
- Strong visual match → output JSON. Stop.
- No match → repeat for next genus, max 2 `search_species_details` calls total.
- After 2 calls with no strong match → output BEST FIT: closest partial match or image-only guess.
- Never output JSON before `search_species_details` is called at least once.
</evaluation>
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
- Limit responses to 2-3 sentences unless an explanation is requested.
- Use a friendly, engaging tone (e.g., "You've found a fascinating specimen!").
- Do not use bullet points or lists.
- Avoid repeating the user's question.
- If the species is endemic to Indonesia, briefly mention the region (e.g., Sumatra, Kalimantan).
</constraints>

<response_guidelines>
- Base your answers on the provided context when relevant
- If context is not provided, answer generally about wildlife
- Use the context to provide specific, accurate information about the identified species
</response_guidelines>
''';

  /// Optimized Query Builder for Contextual Retrieval.
  static String buildQuestionContext({
    required String analysisResult,
    String? speciesName,
    String? speciesLatinName,
    bool isEndangered = false,
    String? populationEstimate,
    String? description,
    List<String>? facts,
  }) {
    final context = StringBuffer();
    context.writeln('Prior Analysis: $analysisResult');

    if (speciesName != null) {
      context.writeln('Identified Subject: $speciesName (${speciesLatinName ?? "Unknown scientific name"})');
      context.writeln('Conservation: ${isEndangered ? "ENDANGERED" : "Not Currently Listed"}');
      if (populationEstimate != null) context.writeln('Wild Population: $populationEstimate');
      if (description != null) context.writeln('Bio: $description');
      if (facts != null && facts.isNotEmpty) context.writeln('Quick Facts: ${facts.join('. ')}');
    }
    
    return context.toString();
  }
}
