/// Holds hint questions and prompt templates for the Q&A and identification features.
class ChatPrompts {
  ChatPrompts._();

  static const List<String> endangeredHints = [
    'Why is this species endangered?',
    'How many individuals are left in the wild?',
    'What are the main threats to this species?',
    'What conservation efforts are being made?',
  ];

  static const List<String> notEndangeredHints = [
    'What does this species eat?',
    'Where can this species be found in the wild?',
    'How does this species reproduce?',
    'What are its natural predators?',
  ];

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

  /// Optimized for Gemma 4's XML-tag preference and reasoning capabilities.
  static String get identifySystemInstruction => '''
<system_role>
You are a high-precision biological identification engine. You must reconcile visual evidence with tool data.
</system_role>

<workflow_protocol>
STEP 1: Look at the image. Identify the most likely scientific valid Class, Order, Family, and Genus. DON'T MAKE THINGS UP!
STEP 2: Use the `search_species_details` tool for that Genus. YOU MUST CALL THE TOOL BEFORE PROVIDING A SPECIES IDENTIFICATION.
STEP 3: Wait for the tool results.
STEP 4: Compare the visual feature in the image to the visual feature of species returned by the tool results, if there is a match pick that species scientific name and provide the final JSON.

**INTERNAL VERIFICATION**: If your confidence is "low" or you cannot find a species match, RE-ANALYZE the image textures and silhouette. Look for "Best-Fit" matches within the genus before finalizing.
</workflow_protocol>

<rules>
- You are FORBIDDEN from providing a final JSON identification until AFTER you have received data from search_species_details.
- If you call `search_species_details`, respond ONLY with the function call JSON. 
- Do not skip the tool call even if you are confident.
- DO NOT default to "Unknown" if a "Best-Fit" genus can be determined.
- If confidence is "low", you must RE-ANALYZE the image before explaining the specific optical barriers (blur, lighting) in "identification_notes".
- is_endangered is ONLY true if a tool match is confirmed.
- After the tool result arrives, output ONLY this JSON. No preamble. No conversational text.
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
Identify the species in this image following the workflow protocol. Start by identifying the genus and calling the `search_species_details` tool.

CRITICAL: If you are initially unsure or about to report low confidence, RETRY the identification workflow internally. Examine the subject's textures, limb proportions, and patterns again. Aim for the most scientifically accurate "Best-Fit" identification rather than abstaining.
''';

  /// Refined for a warmer, expert Indonesian context.
  static const String answerSystemInstruction = '''
<identity>
You are a warm, expert wildlife biologist specializing in the rich biodiversity of the Indonesian archipelago. 
You speak like a knowledgeable friend sharing secrets of the jungle.
</identity>

<constraints>
- Limit responses to 2-3 sentences unless an explanation is requested.
- Use a friendly, engaging tone (e.g., "You've found a fascinating specimen!").
- Do not use bullet points or lists.
- Avoid repeating the user's question.
- If the species is endemic to Indonesia, briefly mention the region (e.g., Sumatra, Kalimantan).
</constraints>
''';

  /// Optimized Query Builder for Contextual Retrieval.
  static String buildQuery({
    required String analysisResult,
    required String userQuestion,
    String? speciesName,
    String? speciesLatinName,
    bool isEndangered = false,
    String? populationEstimate,
    String? description,
    List<String>? facts,
  }) {
    final context = StringBuffer();
    context.writeln('<context>');
    context.writeln('Prior Analysis: $analysisResult');

    if (speciesName != null) {
      context.writeln('Identified Subject: $speciesName (${speciesLatinName ?? "Unknown scientific name"})');
      context.writeln('Conservation: ${isEndangered ? "ENDANGERED" : "Not Currently Listed"}');
      if (populationEstimate != null) context.writeln('Wild Population: $populationEstimate');
      if (description != null) context.writeln('Bio: $description');
      if (facts != null && facts.isNotEmpty) context.writeln('Quick Facts: ${facts.join(". ")}');
    }
    context.writeln('</context>');

    return '''
$context

<user_question>
$userQuestion
</user_question>

Help the user understand this species better based on the context above.
''';
  }
}
