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
    // Small delay to let UI initialize first
    await Future.delayed(const Duration(milliseconds: 100));
    
    try {
      // Load species database
      try {
        final speciesList = await _speciesService.loadSpecies();
        _speciesList = speciesList;
        debugPrint('Loaded ${_speciesList.length} species');
      } catch (e) {
        debugPrint('Failed to load species data: $e');
      }
      
      // Step 1: Check if model is already installed and active
      _status = 'Checking for existing model...';
      notifyListeners();
      
      try {
        final existingModel = await FlutterGemma.getActiveModel(
          maxTokens: maxTokens,
          preferredBackend: PreferredBackend.gpu,
        );
        if (existingModel != null) {
          _model = existingModel;
          _isModelLoaded = true;
          _isInitialized = true;
          _status = 'Model ready';
          debugPrint('Found existing active model');
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('No existing model found: $e');
      }
      
      // Step 2: Check for local model file
      _status = 'Scanning for local model...';
      notifyListeners();
      final localModelPath = await _checkForLocalModel();
      if (localModelPath != null) {
        _status = 'Installing local model...';
        notifyListeners();
        try {
          await FlutterGemma.installModel(modelType: modelType).fromFile(localModelPath).install();
          _model = await FlutterGemma.getActiveModel(
            maxTokens: maxTokens,
            preferredBackend: PreferredBackend.gpu,
          );
          _isModelLoaded = true;
          _isInitialized = true;
          _status = 'Model ready';
          notifyListeners();
          return;
        } catch (e) {
          debugPrint('Local install failed: $e');
          // Fall through to download
        }
      }
      
      // Step 3: Download model from network
      _status = 'Downloading model...';
      notifyListeners();
      await downloadModel();
      
      _isInitialized = true;
      _status = 'Model ready';
      notifyListeners();
    } catch (e) {
      _error = 'Initialization failed: $e';
      _status = 'Error: $e';
      notifyListeners();
      debugPrint('Init error: $e');
    }
  }

  Future<String?> _checkForLocalModel() async {
    try {
      final List<String> searchPaths = [];
      
      // 1. Downloads directory
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          searchPaths.add(downloadsDir.path);
        }
      } catch (e) {
        debugPrint('Could not get downloads directory: $e');
      }
      
      // 2. Common Android download path
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
      
      for (final basePath in searchPaths) {
        try {
          final directory = Directory(basePath);
          if (await directory.exists()) {
            final files = directory.listSync(recursive: false);
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
        _status = 'Downloading: $progress%';
        if (onProgress != null) {
          onProgress(progress / 100);
        }
        notifyListeners();
      }).install();
      
      _status = 'Model downloaded. Loading...';
      notifyListeners();
      
      // Get the active model after installation
      _model = await FlutterGemma.getActiveModel(
        maxTokens: maxTokens,
        preferredBackend: PreferredBackend.gpu,
      );
      
      if (_model == null) {
        throw Exception('Model installation failed - no active model');
      }
      
      _isModelLoaded = true;
      _isLoading = false;
      _status = 'Model ready';
      notifyListeners();
    } catch (e) {
      _error = 'Download failed: $e';
      _status = 'Error: $e';
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }
  
  /// Pass image through without compression - let the model handle it
  Uint8List _compressImage(Uint8List imageBytes) {
    debugPrint('Image size: ${imageBytes.length} bytes - passing directly to model');
    return imageBytes;
  }
  
  Future<String> identifySpecies(Uint8List imageBytes, String imageFormat) async {
    if (_model == null) {
      throw Exception('Model not loaded. Please wait for model to download.');
    }
    
    try {
      _status = 'Analyzing image...';
      notifyListeners();
      
      // Compress image before processing
      final compressedBytes = _compressImage(imageBytes);
      
      final speciesNames = _speciesList.map((s) => s.name).toList();
      final speciesListString = speciesNames.isNotEmpty ? speciesNames.join(', ') : 'endangered Indonesian species';
      
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
      
      await session.addQueryChunk(Message.withImage(
        text: 'Identify the endangered Indonesian species in this image.',
        imageBytes: compressedBytes,
        isUser: true,
      ));
      
      _status = 'Generating analysis...';
      notifyListeners();
      
      final response = await session.getResponse();
      final cleanedResponse = response.trim();
      
      _status = 'Analysis complete';
      notifyListeners();
      
      Species? matchedSpecies;
      for (final species in _speciesList) {
        if (cleanedResponse.toLowerCase().contains(species.name.toLowerCase())) {
          matchedSpecies = species;
          break;
        }
      }
      
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
      
      if (!cleanedResponse.toLowerCase().contains('not recognized')) {
        return '## Analysis Result\n$cleanedResponse\n\n*Note: This species is not in our endangered Indonesian species database.*';
      }
      
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
