import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:image/image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
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
      // Load species database
      try {
        final speciesList = await _speciesService.loadSpecies();
        _speciesList = speciesList;
        debugPrint('Loaded ${_speciesList.length} species');
      } catch (e) {
        debugPrint('Failed to load species data: $e');
      }
      
      // Try to load model if already installed (regardless of source)
      _status = 'Checking for installed model...';
      notifyListeners();
      try {
        await _loadModel();
        _status = 'Model ready';
        _isInitialized = true;
        return;
      } catch (e) {
        debugPrint('Model not installed or failed to load: $e');
        // Fall through to check for local model or download
      }
      
      // 1. Check for local model file
      _status = 'Scanning for local model...';
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
          // Fall through to download
        }
      }
      
      // 2. No local model found, start download
      _status = 'Downloading model...';
      notifyListeners();
      await downloadModel();
    } catch (e) {
      _error = 'Initialization failed: $e';
      _status = 'Error: $e';
      notifyListeners();
    }
  }

  Future<String?> _checkForLocalModel() async {
    try {
      // Check multiple possible locations for local model
      final List<String> searchPaths = [];
      
      // 1. Downloads directory via path_provider (works across Android versions)
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          searchPaths.add(downloadsDir.path);
        }
      } catch (e) {
        debugPrint('Could not get downloads directory: $e');
      }
      
      // 2. Common Android download path (fallback)
      searchPaths.add('/storage/emulated/0/Download');
      
      // 3. AI Edge Gallery paths
      searchPaths.add('/Android/media/com.google.ai.gallery/files/');
      searchPaths.add('/storage/emulated/0/Android/media/com.google.ai.gallery/files/');
      
      // 4. App-specific documents directory
      try {
        final appDocDir = await getApplicationDocumentsDirectory();
        searchPaths.add(appDocDir.path);
      } catch (e) {
        debugPrint('Could not get app documents directory: $e');
      }
      
      // Search all paths for .litertlm files
      for (final basePath in searchPaths) {
        try {
          final directory = Directory(basePath);
          if (await directory.exists()) {
            final files = directory.listSync(recursive: false); // Don't search recursively for performance
            for (var file in files) {
              if (file is File && 
                  file.path.endsWith('.litertlm') && 
                  file.path.toLowerCase().contains('gemma')) {
                debugPrint('Found local model at: ${file.path}');
                return file.path;
              }
            }
          }
        } catch (e) {
          debugPrint('Error searching path $basePath: $e');
          continue;
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