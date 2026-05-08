import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import '../core/navigation/app_page_route.dart';
import '../services/model_service.dart';
import '../services/permission_service.dart';
import 'analyzing_page.dart';
import 'settings_page.dart';

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
  }

  Future<void> _initializeCamera() async {
    final currentContext = context;

    try {
      if (_controller != null && _controller!.value.isInitialized) {
        await _controller!.dispose();
        _controller = null;
      }

      await Future.delayed(const Duration(milliseconds: 100));

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
      debugPrint('Camera initialization error: $e');
      if (currentContext.mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text('Failed to initialize camera: $e')),
        );
      }
      setState(() {
        _isCameraReady = false;
      });
    }
  }

  Future<bool> _checkAndRequestCameraPermission() async {
    final hasPermission = await PermissionService.hasCameraPermission();
    if (hasPermission) return true;

    final isPermanentlyDenied =
        await PermissionService.isPermissionPermanentlyDenied(Permission.camera);

    if (!mounted) return false;

    if (isPermanentlyDenied) {
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

    final result = await PermissionService.requestCameraPermission();
    return result.isGranted;
  }

  Future<void> _takePhoto() async {
    final currentContext = context;
    final modelService =
        Provider.of<ModelService>(currentContext, listen: false);

    final hasCameraPermission = await _checkAndRequestCameraPermission();
    if (!hasCameraPermission) {
      if (currentContext.mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          const SnackBar(
              content: Text('Camera permission is required to take photos')),
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

      Navigator.push(
        currentContext,
        AppPageRoute.fadeScale((_) => AnalyzingPage(rawImageBytes: bytes)),
      ).then((_) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) {
            _initializeCamera();
          }
        });
      });
    } catch (e) {
      if (currentContext.mounted) {
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

  Widget _buildCameraPreview() {
    if (_isCameraReady &&
        _controller != null &&
        _controller!.value.isInitialized) {
      try {
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: _controller!.value.previewSize!.height,
              height: _controller!.value.previewSize!.width,
              child: CameraPreview(_controller!),
            ),
          ),
        );
      } catch (e) {
        debugPrint('Camera preview error: $e');
        return _buildCameraErrorState();
      }
    } else {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
  }

  Widget _buildCameraErrorState() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.camera_alt, color: Colors.white54, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Camera unavailable',
              style: TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _initializeCamera,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        cameraController.dispose();
        setState(() => _isCameraReady = false);
        break;
      case AppLifecycleState.resumed:
        _initializeCamera();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final modelService = Provider.of<ModelService>(context);
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Full-screen camera
          Positioned.fill(
            child: _isCameraReady ? _buildCameraPreview() : _buildCameraErrorState(),
          ),

          // Top gradient overlay — status chip + settings button
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, topPadding + 12, 8, 20),
                child: Row(
                  children: [
                    _ModelStatusChip(
                      modelService: modelService,
                      colorScheme: colorScheme,
                      textTheme: textTheme,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined,
                          color: Colors.white),
                      onPressed: () => Navigator.push(
                        context,
                        AppPageRoute.slideRight((_) => const SettingsPage()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Model download status overlay
          if (modelService.status.isNotEmpty && !modelService.isModelLoaded)
            Positioned(
              top: topPadding + 80,
              left: 16,
              right: 16,
              child: _ModelStatusCard(
                modelService: modelService,
                colorScheme: colorScheme,
                textTheme: textTheme,
                onDownload: _downloadModel,
              ),
            ),

          // Bottom gradient overlay — capture FAB
          if (_isCameraReady)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.65),
                      Colors.transparent,
                    ],
                  ),
                ),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 32,
                  top: 40,
                ),
                child: Center(
                  child: _ShutterButton(
                    isProcessing: _isProcessing,
                    isEnabled: !_isProcessing && modelService.isModelLoaded,
                    onPressed: _takePhoto,
                    primaryColor: colorScheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _downloadModel() async {
    final currentContext = context;
    final modelService =
        Provider.of<ModelService>(currentContext, listen: false);

    if (modelService.isLoading || modelService.isModelLoaded) return;

    try {
      await modelService.downloadModel(onProgress: (_) {});
    } catch (e) {
      if (currentContext.mounted) {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text('Download could not start: $e')),
        );
      }
    }
  }
}

class _ModelStatusChip extends StatelessWidget {
  final ModelService modelService;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  const _ModelStatusChip({
    required this.modelService,
    required this.colorScheme,
    required this.textTheme,
  });

  @override
  Widget build(BuildContext context) {
    final isReady = modelService.isModelLoaded;
    final isError = modelService.error != null;
    final isLoading = modelService.isLoading;

    Widget icon;
    String label;

    if (isReady) {
      icon = Icon(Icons.check_circle_outline,
          size: 16, color: colorScheme.onPrimaryContainer);
      label = 'Model Ready';
    } else if (isError) {
      icon = Icon(Icons.error_outline,
          size: 16, color: colorScheme.error);
      label = 'Model Error';
    } else if (isLoading) {
      final percent = _extractPercent(modelService.status);
      icon = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: percent != null ? percent / 100 : null,
          color: colorScheme.onPrimaryContainer,
        ),
      );
      label = percent != null ? '$percent%' : 'Loading…';
    } else {
      icon = Icon(Icons.download_outlined,
          size: 16, color: colorScheme.onPrimaryContainer);
      label = 'Tap to Download';
    }

    return GestureDetector(
      onTap: isReady ? null : () {
        final modelService = Provider.of<ModelService>(context, listen: false);
        if (!modelService.isLoading) {
          modelService.downloadModel(onProgress: (_) {});
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 6),
            Text(
              label,
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int? _extractPercent(String status) {
    final match = RegExp(r'(\d+)%').firstMatch(status);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }
}

class _ModelStatusCard extends StatelessWidget {
  final ModelService modelService;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final VoidCallback onDownload;

  const _ModelStatusCard({
    required this.modelService,
    required this.colorScheme,
    required this.textTheme,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'AI Model',
            style: textTheme.labelLarge?.copyWith(color: colorScheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            modelService.status,
            style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant),
          ),
          if (modelService.error != null) ...[
            const SizedBox(height: 4),
            Text(
              modelService.error!,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
            ),
          ],
          if (!modelService.isModelLoaded && !modelService.isLoading) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Download Model (2.4GB)'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool isProcessing;
  final bool isEnabled;
  final VoidCallback onPressed;
  final Color primaryColor;

  const _ShutterButton({
    required this.isProcessing,
    required this.isEnabled,
    required this.onPressed,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isEnabled ? onPressed : null,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: isEnabled ? 0.8 : 0.3),
            width: 3,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isEnabled
                  ? primaryColor
                  : primaryColor.withValues(alpha: 0.4),
            ),
            child: isProcessing
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
