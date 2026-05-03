/// Holds hint questions and prompt templates for the Q&A and identification features.
class ChatPrompts {
  ChatPrompts._();

  static const List<String> questionHints = [
    'What does this species eat?',
    'Where can this species be found in the wild?',
    'Why is this species endangered?',
    'How many individuals are left in the wild?',
    'What are the main threats to this species?',
    'What conservation efforts are being made?',
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
You are an expert wildlife biologist specializing in Indonesian wildlife identification.

Based on the provided context, answer the user's question about the species in a helpful and informative way.

Keep your answers concise but informative, and maintain a professional yet approachable tone.
''';

  /// Build the full query for Q&A, wrapping the original analysis and user question.
  static String buildQuery({
    required String analysisResult,
    required String userQuestion,
  }) {
    return '''
Original Analysis: $analysisResult

User Question: $userQuestion

Please provide a helpful response about this species based on the original analysis and the user's question.
''';
  }
}
