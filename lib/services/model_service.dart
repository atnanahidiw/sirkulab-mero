import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'species_service.dart';

class ModelService extends ChangeNotifier {
  bool _isInitialized = false;
  bool _isLoading = false;
  bool _isModelLoaded = false;
  String _status = 'Initializing...';
  String? _error;
  InferenceModel? _model;
  
  // Model configuration - Gemma 4 2B Instruct (quantized)
  final String modelUrl = 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
  final ModelType modelType = ModelType.gemmaIt;
  final int maxTokens = 1024;
  
  // Species database
  final SpeciesService _speciesService = SpeciesService();
  List<Species> _speciesList = [];
  
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  bool get isModelLoaded => _isModelLoaded;
  String get status => _status;
  String? get error => _error;
  InferenceModel? get model => _model;
  
  ModelService() {
    _initialize();
  }
  
  Future<void> _initialize() async {
    try {
      _status = 'Checking for local model...';
      notifyListeners();
      
      // Load species database
      try {
        final speciesList = await _speciesService.loadSpecies();
        _speciesList = speciesList;
        debugPrint('Loaded ${_speciesList.length} species');
      } catch (e) {
        debugPrint('Failed to load species data: $e');
      }
      
      // 1. Cek apakah model sudah terinstall via FlutterGemma
      final isInstalled = await FlutterGemma.isModelInstalled(modelUrl);
      if (isInstalled) {
        _status = 'Existing model found. Loading...';
        notifyListeners();
        await _loadModel();
        _isInitialized = true;
        return;
      }

      // 2. Cek manual di folder Download (untuk AI Edge Gallery/Manual Download)
      _status = 'Scanning Download folder...';
      notifyListeners();
      final localModelPath = await _checkForLocalModel();
      if (localModelPath != null) {
        _status = 'Local model found! Installing...';
        notifyListeners();
        try {
          await FlutterGemma.installModel(modelType: modelType).fromFile(localModelPath).install();
          await _loadModel();
          _isInitialized = true;
          return;
        } catch (e) {
          debugPrint('Local install failed: $e');
        }
      }
      
      _status = 'Model not found. Ready to download.';
      notifyListeners();
      _isInitialized = true;
    } catch (e) {
      _error = 'Initialization failed: $e';
      _status = 'Error: $e';
      notifyListeners();
    }
  }

  Future<String?> _checkForLocalModel() async {
    try {
      // Common path for Android downloads
      final directory = Directory('/storage/emulated/0/Download');
      if (await directory.exists()) {
        final files = directory.listSync();
        for (var file in files) {
          if (file is File && file.path.endsWith('.litertlm')) {
            if (file.path.toLowerCase().contains('gemma')) {
              return file.path;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error checking local model: $e');
    }
    return null;
  }
  
  Future<void> downloadModel({void Function(double)? onProgress}) async {
    if (_isLoading) return;
    
    _isLoading = true;
    _error = null;
    _status = 'Downloading model...';
    notifyListeners();
    
    try {
      await FlutterGemma.installModel(
        modelType: modelType,
      ).fromNetwork(
        modelUrl,
        token: null, 
      ).withProgress((progress) {
        // Correct API for 0.13.6: progress is int (0-100)
        _status = 'Downloading: $progress%';
        if (onProgress != null) {
          onProgress(progress / 100);
        }
        notifyListeners();
      }).install();
      
      _status = 'Model downloaded successfully. Loading...';
      notifyListeners();
      
      await _loadModel();
    } catch (e) {
      _error = 'Download failed: $e';
      _status = 'Error: $e';
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }
  
  Future<void> _loadModel() async {
    try {
      _status = 'Loading model...';
      notifyListeners();
      
      _model = await FlutterGemma.getActiveModel(
        maxTokens: maxTokens,
        preferredBackend: PreferredBackend.gpu,
      );
      
      _isModelLoaded = true;
      _isLoading = false;
      _status = 'Model ready';
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load model: $e';
      _status = 'Error: $e';
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }
  
  Future<String> identifySpecies(Uint8List imageBytes, String imageFormat) async {
    if (_model == null) {
      throw Exception('Model not loaded');
    }
    
    try {
      _status = 'Analyzing image...';
      notifyListeners();
      
      // Prepare species list for prompt
      final speciesNames = _speciesList.map((s) => s.name).toList();
      final speciesListString = speciesNames.isNotEmpty ? speciesNames.join(', ') : 'endangered Indonesian species';
      
      // Create session with Vision enabled for multimodal analysis
      final session = await _model!.createSession(
        enableVisionModality: true,
        systemInstruction: '''
You are an expert wildlife biologist specializing in endangered Indonesian species identification.
Your task is to analyze images and identify if they contain endangered species from the following list:
$speciesListString.

If the species is in the list, respond with ONLY the exact common name as shown in the list.
If the species is not in the list or you are unsure, respond with "Not recognized".
Do not add any additional text, explanations, or formatting.
''',
      );
      
      // Use Message.withImage to provide both image and text prompt
      await session.addQueryChunk(Message.withImage(
        text: 'Identify the endangered Indonesian species in this image.',
        imageBytes: imageBytes,
        isUser: true,
      ));
      
      _status = 'Generating analysis...';
      notifyListeners();
      
      // Get response
      final response = await session.getResponse();
      final cleanedResponse = response.trim();
      
      _status = 'Analysis complete';
      notifyListeners();
      
      // Try to match the response with known species
      Species? matchedSpecies;
      for (final species in _speciesList) {
        if (cleanedResponse.toLowerCase().contains(species.name.toLowerCase())) {
          matchedSpecies = species;
          break;
        }
      }
      
      // If we found a match, format a detailed response
      if (matchedSpecies != null) {
        return '''
## ${matchedSpecies.name}
*Scientific name:* ${matchedSpecies.latinName}

${matchedSpecies.description}

**Interesting facts:**
${matchedSpecies.facts.map((fact) => '• $fact').join('\n')}

*This species is endangered and protected in Indonesian National Parks.*
''';
      }
      
      // If not recognized but response is not "Not recognized", maybe the AI gave some info
      if (!cleanedResponse.toLowerCase().contains('not recognized')) {
        // Return raw response (maybe the AI identified something else)
        return '## Analysis Result\n$cleanedResponse\n\n*Note: This species is not in our endangered Indonesian species database.*';
      }
      
      // Default fallback
      return '## Species Not Recognized\nUnable to identify an endangered Indonesian species from the image.\n\nPlease ensure the image contains a clear view of an animal or plant from Indonesian National Parks.';
    } catch (e) {
      _error = 'Identification failed: $e';
      _status = 'Error: $e';
      notifyListeners();
      rethrow;
    }
  }
  
  Future<void> clearModel() async {
    if (_model != null) {
      await _model!.close();
      _model = null;
      _isModelLoaded = false;
      _status = 'Model cleared';
      notifyListeners();
    }
  }
  
  @override
  void dispose() {
    clearModel();
    super.dispose();
  }
}