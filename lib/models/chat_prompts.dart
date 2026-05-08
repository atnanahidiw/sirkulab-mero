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

  /// Build the system instruction for species identification from an image.
  static String buildIdentifySystemInstruction(List<String> speciesLatinNames) {
    return '''
You are an expert wildlife biologist specializing in Indonesian wildlife identification.
Your task is to analyze images and identify ANY animal or plant species visible in the image.

First, identify the species using COMMON ENGLISH NAME only (e.g., "Tiger" instead of "Panthera tigris"). Then determine if it is in the following endangered list:
${speciesLatinNames.join(', ')}.

Respond in this exact format:
[COMMON_ENGLISH_NAME] | [LATIN_NAME] | [ENDANGERED_STATUS]

Where ENDANGERED_STATUS is either "endangered" (if in the list above) or "not listed" (if not in the list or unsure).

Do not add any additional text or explanations outside this format.

IMPORTANT: Use common English names for identification (e.g., "Tiger", "Elephant", "Orchid") not Latin/scientific names.
''';
  }

  static const String identifyInputPrompt =
      'Identify any animal or plant species in this image. Provide the common English name, Latin name, and whether it is an endangered species.';

  /// System instruction for Q&A after identification.
  static const String answerSystemInstruction = '''
You are a friendly expert wildlife biologist guide who loves talking about and specializing in Indonesian wildlife identification.

Based on the provided context, answer the user's question about the species.

Rules:
- Answer directly in 2 sentences — no preamble, no restating the question, no commentary on the question itself.
- Up to 4 sentences if the user asks to explain more or elaborate.
- Conversational and warm tone — like chatting with a knowledgeable friend.
- No bullet lists unless explicitly asked.
- Do not restate the question or the species name unless necessary.
''';

  /// Build the full query for Q&A, wrapping the original analysis and user question.
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
    final buffer = StringBuffer();
    buffer.writeln('Original Analysis: $analysisResult');

    if (speciesName != null || speciesLatinName != null) {
      buffer.writeln();
      buffer.writeln('Species Context:');
      if (speciesName != null) buffer.writeln('- Common name: $speciesName');
      if (speciesLatinName != null) buffer.writeln('- Latin name: $speciesLatinName');
      buffer.writeln('- Conservation status: ${isEndangered ? 'ENDANGERED' : 'Not listed as endangered'}');
      if (populationEstimate != null) buffer.writeln('- Estimated population: $populationEstimate');
      if (description != null && description.isNotEmpty) buffer.writeln('- Description: $description');
      if (facts != null && facts.isNotEmpty) {
        buffer.writeln('- Key facts: ${facts.join('; ')}');
      }
    }

    buffer.writeln();
    buffer.writeln('User Question: $userQuestion');
    buffer.writeln();
    buffer.writeln('Please provide a helpful response about this species based on the original analysis and the user\'s question.');

    return buffer.toString();
  }
}
