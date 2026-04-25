import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../services/model_service.dart';
import '../services/permission_service.dart';
import 'analyzing_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  CameraController? _controller;
  late List<CameraDescription> _cameras;
  bool _isCameraReady = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    // ModelService auto-initializes itself - no need to call it here
  }

  Future<void> _initializeCamera() async {
    // Capture context before async gap
    final currentContext = context;

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (currentContext.mounted) {
          ScaffoldMessenger.of(currentContext).showSnackBar(
            const SnackBar(content: Text('No cameras available')),
          );
        }
        return;
      }

      _controller = CameraController(
        _cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _controller!.initialize();
      setState(() {
        _isCameraReady = true;
      });
    } catch (e) {
      if (currentContext.mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text('Failed to initialize camera: $e')),
        );
      }
    }
  }

  Future<bool> _checkAndRequestCameraPermission() async {
    // Check if already granted
    final hasPermission = await PermissionService.hasCameraPermission();
    if (hasPermission) return true;

    // Check if permanently denied
    final isPermanentlyDenied =
        await PermissionService.isPermissionPermanentlyDenied(Permission.camera);

    if (!mounted) return false;

    if (isPermanentlyDenied) {
      // Show settings dialog
      final shouldOpenSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Camera Permission Required'),
          content: Text(
            '${PermissionService.getPermissionRationale('camera')}\n\n'
            'This permission has been permanently denied. Please enable it in app settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );

      if (shouldOpenSettings == true) {
        await PermissionService.openPermissionSettings();
      }
      return false;
    }

    // Show rationale dialog before requesting
    final shouldRequest = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Camera Access'),
        content: Text(PermissionService.getPermissionRationale('camera')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );

    if (shouldRequest != true) return false;

    // Request permission
    final result = await PermissionService.requestCameraPermission();
    return result.isGranted;
  }

  Future<void> _takePhoto() async {
    final currentContext = context;
    final modelService =
        Provider.of<ModelService>(currentContext, listen: false);

    // Check and request camera permission with rationale
    final hasCameraPermission = await _checkAndRequestCameraPermission();
    if (!hasCameraPermission) {
      if (currentContext.mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          const SnackBar(content: Text('Camera permission is required to take photos')),
        );
      }
      return;
    }

    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isProcessing) {
      return;
    }

    if (!modelService.isModelLoaded) {
      if (currentContext.mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          const SnackBar(content: Text('Please download the model first')),
        );
      }
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      // Take picture with error handling
      XFile image;
      try {
        image = await _controller!.takePicture();
      } catch (cameraError) {
        debugPrint('Camera error: $cameraError');
        if (currentContext.mounted) {
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(content: Text('Camera error: $cameraError')),
          );
        }
        return;
      }

      Uint8List bytes;
      try {
        bytes = await image.readAsBytes();
      } catch (readError) {
        debugPrint('Read error: $readError');
        if (currentContext.mounted) {
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(content: Text('Failed to read image: $readError')),
          );
        }
        return;
      }

      if (!currentContext.mounted) return;
      
      // Navigate to analyzing page
      Navigator.push(
        currentContext,
        MaterialPageRoute(
          builder: (context) => AnalyzingPage(rawImageBytes: bytes),
        ),
      );
    } catch (e) {
      if (currentContext.mounted) {
        Navigator.pop(currentContext); // Remove loader if present
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text('Failed to analyze image: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _downloadModel() async {
    final currentContext = context;
    final modelService =
        Provider.of<ModelService>(currentContext, listen: false);

    if (modelService.isLoading || modelService.isModelLoaded) return;

    try {
      await modelService.downloadModel(onProgress: (progress) {
        // Progress updates handled by ModelService notifier
      });
    } catch (e) {
      if (currentContext.mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text('Download could not start: $e')),
        );
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    final modelService = Provider.of<ModelService>(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Picture That',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white),
            onPressed: _showInfoDialog,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera preview
          if (_isCameraReady &&
              _controller != null &&
              _controller!.value.isInitialized)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!.value.previewSize!.height,
                  height: _controller!.value.previewSize!.width,
                  child: CameraPreview(_controller!),
                ),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // Model status indicator (top right)
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            right: 20,
            child: GestureDetector(
              onTap: modelService.isModelLoaded ? null : _downloadModel,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: modelService.isModelLoaded
                      ? Colors.green
                      : modelService.error != null
                          ? Colors.red
                          : modelService.isLoading
                              ? Colors.orange
                              : Colors.grey,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (modelService.isLoading)
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          value: modelService.status.contains('%')
                              ? double.tryParse(modelService.status
                                      .replaceAll(RegExp(r'[^0-9.]'), '')) ??
                                  0.0 / 100
                              : null,
                          strokeWidth: 2,
                          color: Colors.white,
                          backgroundColor: Colors.transparent,
                        ),
                      ),
                    Icon(
                      modelService.isModelLoaded
                          ? Icons.check
                          : modelService.error != null
                              ? Icons.error
                              : Icons.download,
                      color: Colors.white,
                      size: 16,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Capture button at bottom
          if (_isCameraReady)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: FloatingActionButton(
                  onPressed: _isProcessing || !modelService.isModelLoaded
                      ? null
                      : _takePhoto,
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: const CircleBorder(),
                  child: _isProcessing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.black),
                        )
                      : const Icon(Icons.camera_alt, size: 30),
                ),
              ),
            ),

          // Status message overlay
          if (modelService.status.isNotEmpty && !modelService.isModelLoaded)
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Color.fromRGBO(0, 0, 0, 0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Model Status',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      modelService.status,
                      style: const TextStyle(color: Colors.white),
                    ),
                    if (modelService.error != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        modelService.error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                    if (!modelService.isModelLoaded &&
                        !modelService.isLoading) ...[
                      const SizedBox(height: 8),
                      // We removed the manual start download action by making it start automatically
                      // in ModelService._initialize(), but keeping the button as a manual override to redownload
                      // if an error occurs.
                      ElevatedButton(
                        onPressed: _downloadModel,
                        child: const Text('Download Model (2.4GB)'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
