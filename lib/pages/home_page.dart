import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../services/model_service.dart';
import 'result_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  bool _isProcessing = false;
  String? _selectedImagePath;
  Uint8List? _selectedImageBytes;

  @override
  Widget build(BuildContext context) {
    final modelService = Provider.of<ModelService>(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Picture That'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showInfoDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Model Status',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(modelService.status),
                    if (modelService.error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        modelService.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (!modelService.isModelLoaded && modelService.isInitialized) ...[
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: modelService.isLoading
                            ? null
                            : () => _downloadModel(modelService),
                        child: modelService.isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(),
                              )
                            : const Text('Download Model (2.4GB)'),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Note: Model download required for first use. After download, works offline.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Image preview
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text(
                        'Select Image',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: _selectedImageBytes != null
                            ? Image.memory(_selectedImageBytes!)
                            : const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.photo_camera,
                                    size: 80,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    'No image selected',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            onPressed: modelService.isModelLoaded && !_isProcessing
                                ? () => _pickImage(ImageSource.camera)
                                : null,
                            icon: const Icon(Icons.camera_alt),
                            label: const Text('Camera'),
                          ),
                          ElevatedButton.icon(
                            onPressed: modelService.isModelLoaded && !_isProcessing
                                ? () => _pickImage(ImageSource.gallery)
                                : null,
                            icon: const Icon(Icons.photo_library),
                            label: const Text('Gallery'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Analyze button
            ElevatedButton(
              onPressed: _selectedImageBytes != null &&
                      modelService.isModelLoaded &&
                      !_isProcessing
                  ? () => _analyzeImage(modelService)
                  : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isProcessing
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(),
                        ),
                        SizedBox(width: 12),
                        Text('Analyzing...'),
                      ],
                    )
                  : const Text(
                      'Identify Endangered Species',
                      style: TextStyle(fontSize: 16),
                    ),
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _downloadModel(ModelService modelService) async {
    try {
      await modelService.downloadModel(onProgress: (progress) {
        // Progress updates handled by ModelService notifier
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model downloaded successfully!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }
  
  Future<void> _pickImage(ImageSource source) async {
    if (source == ImageSource.camera) {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission required')),
        );
        return;
      }
    } else {
      final status = await Permission.photos.request();
      if (!status.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo library permission required')),
        );
        return;
      }
    }
    
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image != null) {
        final bytes = await image.readAsBytes();
        setState(() {
          _selectedImagePath = image.path;
          _selectedImageBytes = bytes;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick image: $e')),
      );
    }
  }
  
  Future<void> _analyzeImage(ModelService modelService) async {
    if (_selectedImageBytes == null) return;
    
    setState(() {
      _isProcessing = true;
    });
    
    try {
      // Determine image format from path or default to jpeg
      String format = 'jpeg';
      if (_selectedImagePath != null) {
        final ext = _selectedImagePath!.split('.').last.toLowerCase();
        if (ext == 'png' || ext == 'jpg' || ext == 'jpeg') {
          format = ext == 'png' ? 'png' : 'jpeg';
        }
      }
      
      final result = await modelService.identifySpecies(_selectedImageBytes!, format);
      
      // Navigate to result page
      if (!mounted) return;
      
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ResultPage(
            imageBytes: _selectedImageBytes!,
            analysisResult: result,
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Analysis failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }
  
  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About Picture That'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This app uses Gemma 4 AI model to identify endangered species from images.',
                style: TextStyle(fontSize: 16),
              ),
              SizedBox(height: 16),
              Text(
                'Features:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('• Works offline after initial model download'),
              Text('• Uses on-device AI for privacy'),
              Text('• Identifies species and conservation status'),
              Text('• Provides conservation information'),
              SizedBox(height: 16),
              Text(
                'Note:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('• First use requires downloading ~2.4GB model'),
              Text('• Works best with clear animal/plant photos'),
              Text('• Conservation data based on model knowledge'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}