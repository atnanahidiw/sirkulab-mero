class AppConstants {
  // App info
  static const String appName = 'Picture That';
  static const String appVersion = '1.0.0';
  
  // Model configuration
  static const String modelUrl = 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-int4.litertlm';
  static const String modelName = 'Gemma 4 E2B';
  static const double modelSizeGB = 2.4;
  static const int maxTokens = 1024;
  
  // Image configuration
  static const int maxImageWidth = 1024;
  static const int maxImageHeight = 1024;
  static const int imageQuality = 85;
  
  // Storage
  static const String modelDirectory = 'models';
  static const String cacheDirectory = 'cache';
  
  // URLs
  static const String privacyPolicyUrl = 'https://example.com/privacy';
  static const String termsOfServiceUrl = 'https://example.com/terms';
  static const String githubRepoUrl = 'https://github.com/example/picture-that';
  
  // Conservation resources
  static const Map<String, String> conservationResources = {
    'IUCN Red List': 'https://www.iucnredlist.org',
    'World Wildlife Fund': 'https://www.worldwildlife.org',
    'Conservation International': 'https://www.conservation.org',
    'CITES': 'https://cites.org',
    'ARKive': 'https://www.arkive.org',
  };
  
  // Endangered species examples for testing
  static const List<Map<String, String>> endangeredSpeciesExamples = [
    {
      'name': 'Bengal Tiger',
      'scientific': 'Panthera tigris tigris',
      'status': 'Endangered',
      'image': 'https://example.com/tiger.jpg',
    },
    {
      'name': 'Giant Panda',
      'scientific': 'Ailuropoda melanoleuca',
      'status': 'Vulnerable',
      'image': 'https://example.com/panda.jpg',
    },
    {
      'name': 'Mountain Gorilla',
      'scientific': 'Gorilla beringei beringei',
      'status': 'Endangered',
      'image': 'https://example.com/gorilla.jpg',
    },
    {
      'name': 'Hawksbill Turtle',
      'scientific': 'Eretmochelys imbricata',
      'status': 'Critically Endangered',
      'image': 'https://example.com/turtle.jpg',
    },
    {
      'name': 'Philippine Eagle',
      'scientific': 'Pithecophaga jefferyi',
      'status': 'Critically Endangered',
      'image': 'https://example.com/eagle.jpg',
    },
  ];
  
  // Analysis prompt templates
  static const String systemPrompt = '''
You are an expert wildlife biologist and conservationist specializing in endangered species identification.
Your task is to analyze images and identify if they contain endangered species.

For each image:
1. Identify the species if possible (common name and scientific name)
2. Determine if it's endangered, threatened, or of least concern
3. Provide conservation status (IUCN Red List category if known)
4. Share interesting facts about the species
5. Suggest conservation actions if endangered

Be concise but informative. If the image doesn't contain an animal or plant, say so.
If you're unsure, admit uncertainty but provide best guess with confidence level.

Format your response with clear sections.
''';
  
  static const String userPrompt = 'Analyze this image for endangered species. Identify the species, conservation status, and provide relevant information.';
  
  // Error messages
  static const String networkError = 'Network error. Please check your connection.';
  static const String modelError = 'Failed to load model. Please try restarting the app.';
  static const String cameraError = 'Camera access denied. Please enable camera permissions.';
  static const String storageError = 'Storage access denied. Please enable storage permissions.';
  static const String analysisError = 'Analysis failed. Please try with a different image.';
  
  // Success messages
  static const String downloadComplete = 'Model downloaded successfully!';
  static const String analysisComplete = 'Analysis complete!';
  static const String imageSaved = 'Image saved to gallery.';
  
  // UI constants
  static const double defaultPadding = 16.0;
  static const double cardElevation = 4.0;
  static const double borderRadius = 12.0;
  
  // Animation durations
  static const Duration fastDuration = Duration(milliseconds: 200);
  static const Duration mediumDuration = Duration(milliseconds: 300);
  static const Duration slowDuration = Duration(milliseconds: 500);
}