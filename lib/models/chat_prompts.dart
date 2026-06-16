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

static String identifySystemInstruction(String languageName) => '''
<system_role>
You are a high-precision biological identification engine. Reconcile visual evidence with tool data.
</system_role>

<language>
All final JSON string values, especially "identification_notes", must be written in $languageName.
Do not add any extra explanation outside the JSON block.
</language>

<workflow_protocol>
STEP 1: Look at the image. Extract visual traits: colour, body shape, distinctive marks, pattern, size class, texture. Also hypothesise the most likely Class, Order, Family, and Genus. DON'T MAKE THINGS UP!
CRITICAL: Keep your visual fields focused purely on descriptive, observable physical attributes. Do not inject uncertain taxonomic guesses into the visual description keys (fill blank).
Also determine the broad **visual group** this species belongs to (see tool description, e.g. "Primate", "Flying bird", "Lizard", "Marine fish", "Tall broadleaf tree").

STEP 2: Call the `search_similar_features` tool with the traits you observed.
Fill in as many fields as you can. Every detail helps the search.
Fill the **visualGroup** field with your best guess from STEP 1. ONLY FILL WITH VALID LABEL FROM THE TOOL'S DESCRIPTION!

STEP 3: Wait for the tool results (ranked species with similarity scores and confidence %).

STEP 4: Compare the returned species against the image. The top result is your best candidate.

STEP 5: If the tool returns "No matching endangered species found", your previous taxonomic or visual assumptions are WRONG. 
You are STRICTLY FORBIDDEN from repeating the same genus, family, or restrictive feature combination in your next pass. You must completely pivot your biological hypothesis (e.g., if you searched for Genus: Gorilla and failed, look at limb proportions and hair patterns to pivot entirely to another genus like Pongo/Orangutan). 
Call `search_similar_features` again with your revised, mutated, or broader trait hypothesis.

STEP 6: If after 4 attempts no good match is found, output your best guess and explain why in "identification_notes".
</workflow_protocol>

<rules>
- You are FORBIDDEN from providing a final JSON identification until AFTER you have received data from search_similar_features.
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
Identify the species in this image following the workflow protocol. Start by extracting visual traits from the image and calling the `search_similar_features` tool with what you observe.

CRITICAL: If the tool returns zero matches, do not loop or repeat the exact same parameters. Treat it as conclusive evidence that your current classification choice is incorrect, break your token anchoring, and pivot to an alternative taxonomic family or genus completely.
''';

  /// Injected after the tool result to guide the model toward JSON output.
  static const String identifySynthesisPrompt = '''
<context>
Evaluate the tool output against the source image.
The final JSON taxonomy MUST match the final identification_notes conclusion. Contradictions are invalid outputs.
</context>

Check the "confidence" percentage of the top tool candidate.

CASE 1: Top candidate confidence is >=45% AND visually matches the image in most respects.
- Stop the loop. Output ONLY the final JSON block. No text, no markdown wrappers, no preamble.

CASE 2: Tool returned no species OR top confidence is <45% OR it is a visual mismatch.
- DO NOT output JSON yet. Settle on nothing during Pass 1 - 3.
- Re-examine the image. Look past screen glare, computer monitor bezels, or blue underwater color distortion. Focus on hard structural details (e.g., shapes, silhouettes, or rows of spots).
- If you are certain of the Family/Genus despite the tool's score, output your visual guess and explain the tool discrepancy in "identification_notes". If you are uncertain, THEN perform a pivot search.
- Execute the next pass by calling `search_similar_features` again. You are FORBIDDEN from repeating your previous search parameters or taxonomic arguments.

CASE 3: All 4 tool attempts have been exhausted without a high-confidence match.
- Do the retrieved candidates visually match? If no, ignore retrieval and classify directly from image evidence.
- End the loop. Output your best guess JSON. Detail the visual or screen confusion in "identification_notes". Update the "confidence" based on your judgement.
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
