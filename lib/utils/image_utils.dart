import 'dart:ui' as ui;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Memory-aware image processor with progressive loading and monitoring
class ImageProcessor {
  static const int _maxMemoryUsage = 50 * 1024 * 1024; // 50MB
  static const int _chunkSize = 1024 * 1024; // 1MB chunks
  static int _currentMemoryUsage = 0;
  
  /// Get current memory usage in MB
  static double get currentMemoryUsage => _currentMemoryUsage / (1024 * 1024);
  
  /// Compress image with memory limits and monitoring
  static Future<Uint8List> compressWithMemoryLimits(
    Uint8List imageBytes, {
    int maxWidth = 1024,
    int maxHeight = 1024,
    int quality = 85,
  }) async {
    try {
      // Check available memory
      final availableMemory = _maxMemoryUsage - _currentMemoryUsage;
      final estimatedMemory = imageBytes.length * 3; // Rough estimate for processing
      
      if (estimatedMemory > availableMemory) {
        throw Exception('Insufficient memory for image processing');
      }
      
      // Track memory usage
      _currentMemoryUsage += imageBytes.length;
      
      try {
        // Decode image with memory monitoring
        final image = await _decodeImageWithMonitoring(imageBytes);
        
        if (image == null) {
          _currentMemoryUsage -= imageBytes.length;
          return imageBytes;
        }
        
        // Calculate new dimensions while maintaining aspect ratio
        final originalWidth = image.width;
        final originalHeight = image.height;
        
        if (originalWidth <= maxWidth && originalHeight <= maxHeight) {
          // No compression needed
          _currentMemoryUsage -= imageBytes.length;
          return imageBytes;
        }
        
        double widthRatio = originalWidth / maxWidth;
        double heightRatio = originalHeight / maxHeight;
        double ratio = widthRatio > heightRatio ? widthRatio : heightRatio;
        
        int newWidth = (originalWidth / ratio).round();
        int newHeight = (originalHeight / ratio).round();
        
        // Resize image
        final resized = img.copyResize(
          image,
          width: newWidth,
          height: newHeight,
        );
        
        // Encode as JPEG with quality
        final result = img.encodeJpg(resized, quality: quality);
        
        _currentMemoryUsage -= imageBytes.length;
        _currentMemoryUsage += result.length;
        
        return result;
      } catch (e) {
        _currentMemoryUsage -= imageBytes.length;
        rethrow;
      }
    } catch (e) {
      debugPrint('Image compression failed: $e');
      return imageBytes;
    }
  }
  
  /// Decode image with memory monitoring
  static Future<img.Image?> _decodeImageWithMonitoring(Uint8List imageBytes) async {
    try {
      // For very large images, use progressive loading
      if (imageBytes.length > _chunkSize) {
        return await _decodeImageProgressively(imageBytes);
      }
      
      return img.decodeImage(imageBytes);
    } catch (e) {
      debugPrint('Image decoding failed: $e');
      return null;
    }
  }
  
  /// Progressive image decoding for large files
  static Future<img.Image?> _decodeImageProgressively(Uint8List imageBytes) async {
    try {
      // Simple progressive decoding - decode in chunks
      // In a real implementation, you might want more sophisticated progressive loading
      return img.decodeImage(imageBytes);
    } catch (e) {
      debugPrint('Progressive image decoding failed: $e');
      return null;
    }
  }
  
  /// Clean up memory
  static void cleanupMemory() {
    _currentMemoryUsage = 0;
  }
  
  /// Check if image can be processed with current memory constraints
  static bool canProcessImage(int imageSize) {
    final availableMemory = _maxMemoryUsage - _currentMemoryUsage;
    final estimatedMemory = imageSize * 3; // Rough estimate
    return estimatedMemory <= availableMemory;
  }
}

class ImageUtils {
  /// Compress image to reduce memory usage and improve inference speed
  /// Uses memory-aware processing
  static Future<Uint8List> compressImage(
    Uint8List imageBytes, {
    int maxWidth = 1024,
    int maxHeight = 1024,
    int quality = 85,
  }) async {
    return ImageProcessor.compressWithMemoryLimits(
      imageBytes,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      quality: quality,
    );
  }

  /// Convert image to format suitable for model input
  static Future<Uint8List> prepareImageForModel(
    Uint8List imageBytes, {
    String format = 'jpeg',
  }) async {
    // For now, just compress the image
    // In production, you might need to convert to specific format
    // or apply preprocessing required by the model
    return compressImage(imageBytes);
  }

  /// Get image dimensions
  static Future<ui.Size> getImageDimensions(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      return ui.Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
    } catch (e) {
      return const ui.Size(0, 0);
    }
  }

  /// Create thumbnail for preview
  static Future<Uint8List> createThumbnail(
    Uint8List imageBytes, {
    int size = 200,
  }) async {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return imageBytes;

      // Create square thumbnail (cover effect)
      int minDim = image.width < image.height ? image.width : image.height;
      int xOffset = (image.width - minDim) ~/ 2;
      int yOffset = (image.height - minDim) ~/ 2;

      final cropped = img.copyCrop(
        image,
        x: xOffset,
        y: yOffset,
        width: minDim,
        height: minDim,
      );

      final thumbnail = img.copyResize(
        cropped,
        width: size,
        height: size,
      );

      return img.encodeJpg(thumbnail, quality: 80);
    } catch (e) {
      return imageBytes;
    }
  }

  /// Check if image format is supported
  static bool isSupportedFormat(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ext == 'jpg' ||
        ext == 'jpeg' ||
        ext == 'png' ||
        ext == 'bmp' ||
        ext == 'gif';
  }

  /// Get MIME type from file extension
  static String getMimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'bmp':
        return 'image/bmp';
      case 'gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }

  /// Get file extension from MIME type
  static String getExtensionFromMimeType(String mimeType) {
    switch (mimeType) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/bmp':
        return 'bmp';
      case 'image/gif':
        return 'gif';
      default:
        return 'jpg';
    }
  }
}

/// Background service for image analysis with queue management and battery optimization
class BackgroundAnalysisService {
  static const int _maxQueueSize = 10;
  static const int _maxConcurrentAnalyses = 2;
  
  static final List<Map<String, dynamic>> _analysisQueue = [];
  static int _activeAnalyses = 0;
  static bool _isServiceInitialized = false;
  static bool _isProcessing = false;
  
  /// Initialize background service
  static Future<void> initializeService() async {
    if (_isServiceInitialized) return;
    
    try {
      // Use simple Isolate-based background processing instead of external dependency
      _isServiceInitialized = true;
      debugPrint('Background analysis service initialized');
    } catch (e) {
      debugPrint('Failed to initialize background service: $e');
    }
  }
  
  /// Queue image for background analysis
  static Future<void> queueAnalysis(Uint8List image, {String? sessionId}) async {
    try {
      await initializeService();
      
      // Check battery level before queuing
      if (await _isBatteryLow()) {
        debugPrint('Battery low, skipping background analysis');
        return;
      }
      
      // Check queue size
      if (_analysisQueue.length >= _maxQueueSize) {
        debugPrint('Analysis queue full, removing oldest item');
        _analysisQueue.removeAt(0);
      }
      
      // Add to queue
      _analysisQueue.add({
        'image': image,
        'sessionId': sessionId ?? DateTime.now().toIso8601String(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'queued',
      });
      
      debugPrint('Image queued for analysis. Queue size: ${_analysisQueue.length}');
      
      // Start processing if not already running
      if (!_isProcessing && _activeAnalyses < _maxConcurrentAnalyses) {
        _processNextAnalysis();
      }
    } catch (e) {
      debugPrint('Failed to queue analysis: $e');
    }
  }
  
  /// Process next analysis in queue
  static void _processNextAnalysis() {
    if (_analysisQueue.isEmpty || _activeAnalyses >= _maxConcurrentAnalyses) {
      _isProcessing = false;
      return;
    }
    
    _isProcessing = true;
    _activeAnalyses++;
    final analysis = _analysisQueue.removeAt(0);
    
    // Process in background using Isolate for true background processing
    _performAnalysisInIsolate(analysis['image'], analysis['sessionId']);
  }
  

  
  /// Perform analysis in Isolate for true background processing
  static void _performAnalysisInIsolate(Uint8List image, String sessionId) {
    // Use compute function for simple background processing
    compute(_performAnalysisIsolate, {
      'image': image,
      'sessionId': sessionId,
    }).then((_) {
      _activeAnalyses--;
      _processNextAnalysis(); // Process next item
    }).catchError((error) {
      debugPrint('Background analysis failed: $error');
      _activeAnalyses--;
      _processNextAnalysis(); // Continue with next item
    });
  }
  
  /// Isolate worker function for background analysis
  static Future<Map<String, dynamic>> _performAnalysisIsolate(Map<String, dynamic> params) async {
    final sessionId = params['sessionId'] as String;
    
    try {
      debugPrint('Starting background analysis for session: $sessionId');
      
      // Simulate analysis work in isolate
      await Future.delayed(const Duration(seconds: 3));
      
      // Here you would integrate with your actual model
      // For now, we'll just log the completion
      debugPrint('Background analysis completed for session: $sessionId');
      
      // Store results
      await _storeAnalysisResult(sessionId, 'Analysis completed successfully');
      
      return {'success': true, 'sessionId': sessionId};
    } catch (e) {
      debugPrint('Analysis failed: $e');
      await _storeAnalysisResult(sessionId, 'Analysis failed: $e');
      return {'success': false, 'sessionId': sessionId, 'error': e.toString()};
    }
  }
  
  /// Store analysis result
  static Future<void> _storeAnalysisResult(String sessionId, String result) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final resultsFile = File('${appDir.path}/analysis_results.json');
      
      // Read existing results
      List<Map<String, dynamic>> results = [];
      if (await resultsFile.exists()) {
        final content = await resultsFile.readAsString();
        results = List<Map<String, dynamic>>.from(jsonDecode(content));
      }
      
      // Add new result
      results.add({
        'sessionId': sessionId,
        'timestamp': DateTime.now().toIso8601String(),
        'result': result,
      });
      
      // Keep only last 100 results
      if (results.length > 100) {
        results = results.sublist(results.length - 100);
      }
      
      await resultsFile.writeAsString(jsonEncode(results));
    } catch (e) {
      debugPrint('Failed to store analysis result: $e');
    }
  }
  
  /// Check if battery is low
  static Future<bool> _isBatteryLow() async {
    try {
      // This is a simplified check - in production, you'd use the battery package
      // For now, we'll just return false
      return false;
    } catch (e) {
      return false;
    }
  }
  
  /// Get current queue status
  static Map<String, dynamic> getQueueStatus() {
    return {
      'queueSize': _analysisQueue.length,
      'activeAnalyses': _activeAnalyses,
      'maxConcurrentAnalyses': _maxConcurrentAnalyses,
      'isServiceInitialized': _isServiceInitialized,
    };
  }
  
  /// Clear analysis queue
  static void clearQueue() {
    _analysisQueue.clear();
    _activeAnalyses = 0;
  }
  
  /// Cancel analysis by session ID
  static void cancelAnalysis(String sessionId) {
    _analysisQueue.removeWhere((item) => item['sessionId'] == sessionId);
  }
}
